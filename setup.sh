#!/usr/bin/env bash
# ==============================================================================
#  BearNAS Setup — official installer
#
#  Run inside the CT as root:
#    bash setup.sh              # menu
#    bash setup.sh --install    # install or upgrade
#    bash setup.sh --update     # update to the latest version from GitHub
#    bash setup.sh --repair     # find and fix problems
#    bash setup.sh --uninstall  # remove BearNAS — storage data is never touched
#
#  Install runs 6 stages. Everything is checked first — if a check fails,
#  nothing is changed. Re-run any time to upgrade.
#
#  Optional settings (environment variables):
#    BEAR_PORT / BEAR_STORAGE / INSTALL_DIR / DIST_BASE
# ==============================================================================
set -euo pipefail

### ── Defaults ──
BEAR_PORT="${BEAR_PORT:-8900}"
BEAR_STORAGE="${BEAR_STORAGE:-/mnt/disk1}"
INSTALL_DIR="${INSTALL_DIR:-/opt/bearnas}"
DIST_BASE="${DIST_BASE:-https://raw.githubusercontent.com/kps-pa/BearNAS/main/dist}"

stage() { printf '\n==> %s\n' "$*"; }
ok()    { printf '  [OK]   %s\n' "$*"; }
warn()  { printf '  [WARN] %s\n' "$*"; }
fail()  { printf '  [FAIL] %s — %s\n' "$1" "$2"; FAILS=$((FAILS+1)); }

usage() {
  printf 'Usage: bash setup.sh [--install|--update|--repair|--uninstall]\n'
  printf '  --install     install BearNAS (re-run any time to upgrade)\n'
  printf '  --update      upgrade to the latest version — settings/users/shares are kept\n'
  printf '  --repair      rewrite the service unit and restart — fixes a broken service\n'
  printf '  --uninstall   remove BearNAS — storage data is never touched\n'
  printf '  (no argument) menu in a terminal, or default to install when piped\n'
}

quick_guard() {
  if [ "$(id -u)" -ne 0 ]; then
    printf 'Run as root.\n'
    exit 1
  fi
  if ! grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
    printf 'Run this inside the CT. On the Proxmox host: pct enter <CT-ID>\n'
    exit 1
  fi
}

download_bearnas() {
  url="$DIST_BASE/bearnas-linux-$GOARCH2/bearnas"
  echo "  From: $url"
  mkdir -p "$INSTALL_DIR"
  if ! curl -fsSL -o "$INSTALL_DIR/bearnas.tmp" "$url"; then
    printf '  [FAIL] Download — could not fetch %s\n' "$url"
    exit 1
  fi
  want="$(curl -fsSL "$DIST_BASE/bearnas-linux-$GOARCH2/bearnas.sha256" 2>/dev/null | awk '{print $1}' || true)"
  got="$(sha256sum "$INSTALL_DIR/bearnas.tmp" 2>/dev/null | awk '{print $1}')"
  if [ -n "$want" ] && [ -n "$got" ]; then
    if [ "$got" != "$want" ]; then
      printf '  [FAIL] Download — checksum mismatch\n'
      rm -f "$INSTALL_DIR/bearnas.tmp"
      exit 1
    fi
    ok "Download verified — checksum matches"
  else
    echo "  (checksum skipped — file or tool missing)"
  fi
  mv -f "$INSTALL_DIR/bearnas.tmp" "$INSTALL_DIR/bearnas"
  chmod 755 "$INSTALL_DIR/bearnas"
  ok "BearNAS binary installed — $(du -h "$INSTALL_DIR/bearnas" | cut -f1)"
}

write_unit() {
  cat >/etc/systemd/system/bearnas.service <<UNIT
[Unit]
Description=BearNAS
After=network.target

[Service]
WorkingDirectory=$INSTALL_DIR
# BearNAS เป็น appliance ที่บริหารระบบเอง (apt ติดตั้ง samba, useradd/groupadd,
# เขียน /etc/samba/smb.conf, สั่ง systemctl) จึงต้องถอด ProtectSystem=strict
# (ทำทั้งไฟล์ระบบ read-only) และ RestrictSUIDSGID (dpkg ตั้ง suid bit ไม่ได้)
# ส่วนการป้องกันที่ไม่ขัดงานติดตั้งแพ็กเกจคงไว้ครบ
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
LockPersonality=yes
Environment=BEAR_PORT=$BEAR_PORT
Environment=BEAR_STORAGE=$BEAR_STORAGE
ExecStart=$INSTALL_DIR/bearnas
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable bearnas >/dev/null 2>&1
  systemctl restart bearnas
  ok "BearNAS service installed and started"
}

wait_health() {
  local _u=0 _i
  for _i in $(seq 1 15); do
    if curl -fsk "https://127.0.0.1:$BEAR_PORT/api/status" >/dev/null 2>&1; then _u=1; break; fi
    sleep 1
  done
  [ "$_u" = 1 ]
}

show_diag() {
  systemctl status bearnas --no-pager 2>&1 | head -15
  journalctl -u bearnas -n 20 --no-pager 2>&1 | tail -20
}

summary() {
  IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '\n'
  printf '==============================================\n'
  printf '  %s\n' "$1"
  printf '%s\n' '----------------------------------------------'
  printf '  Web UI  : https://%s:%s\n' "$IP_ADDR" "$BEAR_PORT"
  printf '  Service : systemctl status bearnas\n'
  printf '  Storage : %s\n' "$BEAR_STORAGE"
  printf '  Cert    : self-signed — accept the browser warning on first visit\n'
  printf '==============================================\n'
}

# current_version: อ่านเวอร์ชันที่รันอยู่จาก journal (binary พิมพ์ตอนสตาร์ท)
current_version() {
  journalctl -u bearnas --no-pager 2>/dev/null | grep -o 'BearNAS v[0-9][0-9.]*' | tail -1 || true
}

update_bearnas() {
  quick_guard
  if [ ! -x "$INSTALL_DIR/bearnas" ]; then
    printf 'BearNAS is not installed — nothing to update. Run: bash setup.sh --install\n'
    exit 0
  fi
  OLD_VER="$(current_version)"
  printf 'Updating BearNAS%s…\n' "${OLD_VER:+ (currently $OLD_VER)}"
  stage "1/3 Download the latest version"
  download_bearnas
  stage "2/3 Service"
  write_unit
  stage "3/3 Health check"
  if wait_health; then
    ok "BearNAS is responding over HTTPS"
  else
    fail "Service" "no response in 15s"
    show_diag
    exit 1
  fi
  NEW_VER="$(current_version)"
  printf '  Version: %s → %s\n' "${OLD_VER:-?}" "${NEW_VER:-?}"
  summary "BearNAS updated"
  exit 0
}

repair_bearnas() {
  quick_guard
  if [ ! -x "$INSTALL_DIR/bearnas" ]; then
    printf 'BearNAS is not installed — nothing to repair. Run: bash setup.sh --install\n'
    exit 0
  fi
  stage "Repairing the BearNAS service"
  if [ -f /etc/systemd/system/bearnas.service ]; then
    ok "Service unit exists"
  else
    warn "Service unit missing — writing a new one"
  fi
  write_unit
  if wait_health; then
    ok "BearNAS is responding over HTTPS"
  else
    fail "Service" "no response in 15s"
    show_diag
    exit 1
  fi
  # ภาพรวมบริการปลั๊กอินให้ผู้ใช้เห็นครบในรอบเดียว
  for u in /etc/systemd/system/bearnas-*.service; do
    [ -e "$u" ] || continue
    printf '  plugin %s: %s\n' "$(basename "$u" .service)" "$(systemctl is-active "$(basename "$u")" 2>/dev/null || echo unknown)"
  done
  if head -1 /etc/samba/smb.conf 2>/dev/null | grep -q 'Managed by BearNAS'; then
    ok "smb.conf is managed by BearNAS (rewritten on next BearNAS start)"
  elif command -v smbd >/dev/null 2>&1; then
    warn "smb.conf is NOT managed by BearNAS — shares will return after BearNAS restarts"
  fi
  summary "BearNAS repaired"
  exit 0
}

remove_bearnas() {
  quick_guard
  case "$INSTALL_DIR" in
    ""|"/"|"/usr"|"/etc"|"/opt"|"/var"|"/bin"|"/lib"|"/home")
      printf 'Refusing to delete INSTALL_DIR=%s\n' "$INSTALL_DIR"
      exit 1
      ;;
  esac
  if [ ! -f /etc/systemd/system/bearnas.service ] && [ ! -x "$INSTALL_DIR/bearnas" ]; then
    printf 'BearNAS is not installed — nothing to remove.\n'
    exit 0
  fi

  # smb.conf ที่ BearNAS เขียนเองจะมีลายเซ็นบรรทัดแรก — ลบเฉพาะไฟล์ของเราเท่านั้น
  # (โมเดลหลายแชร์: เก็บพาธของทุกแชร์ไว้ก่อน เพื่อคืนสิทธิ์บนดิสก์ข้อมูลหลังลบกลุ่ม)
  SMB_MANAGED=0
  SHARE_PATHS=""
  if [ -f /etc/samba/smb.conf ] && head -1 /etc/samba/smb.conf | grep -q 'Managed by BearNAS'; then
    SMB_MANAGED=1
    SHARE_PATHS="$(grep -E '^[[:space:]]*path[[:space:]]*=' /etc/samba/smb.conf | sed -E 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//' | sort -u || true)"
  fi

  printf 'This stops BearNAS and deletes:\n'
  printf '  - bearnas.service and any plugin services (bearnas-*.service)\n'
  printf '  - %s (binary, certificate, settings db, device key, plugin files)\n' "$INSTALL_DIR"
  if [ "$SMB_MANAGED" = 1 ]; then
    printf '  - /etc/samba/smb.conf written by BearNAS (all BearNAS shares stop)\n'
  fi
  printf '  - Samba accounts and the "bearnas" group created by BearNAS\n'
  printf '  - setgid/group "bearnas" markers on shared folders, trash folders and users/ (reset to root)\n'
  printf 'Data files in %s are NOT touched (content stays as-is).\n' "$BEAR_STORAGE"
  if ! read -r -p "Continue? [y/N] " ans; then ans=""; fi
  case "$ans" in
    y|Y) ;;
    *) printf 'Cancelled.\n'; exit 0 ;;
  esac

  PURGE_SAMBA=0
  if command -v smbd >/dev/null 2>&1; then
    if ! read -r -p "Also remove the Samba packages (apt purge samba)? [y/N] " ans2; then ans2=""; fi
    case "$ans2" in y|Y) PURGE_SAMBA=1 ;; esac
  fi

  stage "Stopping BearNAS"
  systemctl disable --now bearnas >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/bearnas.service
  # บริการของปลั๊กอิน (bearnas-qbittorrent ฯลฯ) — ต้องหยุดก่อนลบบัญชี ไม่งั้น userdel ไม่ผ่าน
  # (ตัวไบนารี/โปรไฟล์ของปลั๊กอินอยู่ใต้ INSTALL_DIR → หายตาม rm -rf ด้านล่างเอง)
  for unit_file in /etc/systemd/system/bearnas-*.service; do
    [ -e "$unit_file" ] || continue
    systemctl disable --now "$(basename "$unit_file")" >/dev/null 2>&1 || true
    rm -f "$unit_file"
  done
  systemctl daemon-reload

  stage "Removing Samba accounts created by BearNAS"
  # ลบเฉพาะ user ที่ BearNAS สร้าง: system user ไม่มี shell ล็อกอิน และอยู่ในกลุ่ม bearnas
  if getent group bearnas >/dev/null 2>&1; then
    members="$(getent group bearnas | cut -d: -f4 | tr ',' ' ')"
    for u in $members; do
      [ -n "$u" ] || continue
      if command -v smbpasswd >/dev/null 2>&1; then smbpasswd -x "$u" >/dev/null 2>&1 || true; fi
      shell="$(getent passwd "$u" | cut -d: -f7 || true)"
      case "$shell" in
        */nologin|*/false) userdel "$u" >/dev/null 2>&1 || true ;;
        *) printf '  kept login user %s (not created by BearNAS)\n' "$u" ;;
      esac
    done
    groupdel bearnas >/dev/null 2>&1 || true
  fi

  # คืนสิทธิ์ระดับ "รากโฟลเดอร์" ที่ BearNAS เคยแตะ: ถอด setgid + เปลี่ยนกลุ่มกลับเป็น root
  # (ไฟล์/โฟลเดอร์ข้างในไม่แตะ — ข้อมูลของผู้ใช้ทั้งหมดอยู่ครบ แค่ gid เดิมอาจแสดงเป็นตัวเลข ซึ่งไม่มีผลร้าย)
  stage "Resetting BearNAS permission markers on data disks"
  PERM_TARGETS="$SHARE_PATHS"
  for d in /mnt/disk*/.bearnas-trash; do
    [ -e "$d" ] && PERM_TARGETS="$PERM_TARGETS
$d"
  done
  [ -d "$BEAR_STORAGE/users" ] && PERM_TARGETS="$PERM_TARGETS
$BEAR_STORAGE/users"
  printf '%s\n' "$PERM_TARGETS" | while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ -d "$t" ] || continue
    chgrp root "$t" >/dev/null 2>&1 || true
    chmod g-s "$t" >/dev/null 2>&1 || true
    printf '  reset %s\n' "$t"
  done

  if [ "$SMB_MANAGED" = 1 ]; then
    stage "Restoring default smb.conf"
    # คืนไฟล์ตั้งต้นของ distro ถ้ามี (Debian เก็บไว้ที่ /usr/share/samba) ไม่งั้นใส่ global ว่าง
    # เพื่อให้ smbd ยังเปิดได้แต่ไม่แชร์อะไร — ถ้า purge ด้านล่างจะหายไปทั้งก้อนอยู่แล้ว
    if [ -f /usr/share/samba/smb.conf ]; then
      cp -f /usr/share/samba/smb.conf /etc/samba/smb.conf
    else
      printf '[global]\n\tserver role = standalone server\n\tmap to guest = never\n' > /etc/samba/smb.conf
    fi
    systemctl restart smbd >/dev/null 2>&1 || true
  fi

  if [ "$PURGE_SAMBA" = 1 ]; then
    stage "Purging Samba packages"
    systemctl disable --now smbd nmbd >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y samba samba-common samba-common-bin >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
  fi

  stage "Removing BearNAS files"
  rm -rf "$INSTALL_DIR"
  printf '\nBearNAS removed.\n'
  exit 0
}

### ── Mode selection ──
INSTALLED=0
if [ -f /etc/systemd/system/bearnas.service ] || [ -x "$INSTALL_DIR/bearnas" ]; then
  INSTALLED=1
fi
printf 'BearNAS Setup\n'
MODE="${1:-}"
if [ -z "$MODE" ]; then
  if [ -t 0 ]; then
    if [ "$INSTALLED" = 0 ]; then
      printf '\n  BearNAS is not installed yet.\n'
      printf '\n  1) Install\n'
      printf '  2) Cancel\n'
      if ! read -r -p 'Choose [1-2]: ' pick; then pick=""; fi
      case "$pick" in
        1) MODE="--install" ;;
        *) printf 'Cancelled.\n'; exit 0 ;;
      esac
    else
      printf '\n  BearNAS is installed'
      if systemctl is-active --quiet bearnas 2>/dev/null; then printf ' — service is running'; fi
      printf '\n'
      printf '\n  1) Update to the latest version\n'
      printf '  2) Uninstall\n'
      printf '  3) Cancel\n'
      if ! read -r -p 'Choose [1-3]: ' pick; then pick=""; fi
      case "$pick" in
        1) MODE="--update" ;;
        2) MODE="--uninstall" ;;
        *) printf 'Cancelled.\n'; exit 0 ;;
      esac
    fi
  else
    MODE="--install"
  fi
fi
case "$MODE" in
  --install) ;;
  --uninstall)           remove_bearnas ;;
  --update)              update_bearnas ;;
  --repair)              repair_bearnas ;;
  *) usage; exit 1 ;;
esac

### ── Single-run lock (กันรันซ้อนสอง session) ──
if [ -d /run ] && [ -w /run ]; then
  exec 9>/run/bearnas-setup.lock
  if ! flock -n 9; then
    printf 'Another setup.sh is already running.\n'
    exit 1
  fi
fi

### ═══ Stage 1/6 — System check ═══
stage "1/6 System check"
FAILS=0

if [ "$(id -u)" -eq 0 ]; then ok "Running as administrator (root)"; else fail "Administrator" "run this script as root"; fi

if grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
  ok "Running inside the BearNAS container"
else
  fail "BearNAS container" "run this installer inside the CT — from the Proxmox host: pct enter <CT-ID>"
fi

if [ -f /etc/os-release ]; then . /etc/os-release; fi
if [ "${ID:-}" = "debian" ]; then
  ok "Operating system Debian ${VERSION_ID:-} — supported"
else
  fail "Operating system" "Debian is required, found ${ID:-unknown}"
fi

cpu_model="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
case "$(uname -m)" in
  x86_64)        GOARCH2=amd64 ;;
  aarch64|arm64) GOARCH2=arm64 ;;
  *) GOARCH2="" ;;
esac
kernel_ver="$(uname -r)"
ok "Kernel ${kernel_ver:-unknown}"

cores="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?')"
if [ -n "$GOARCH2" ]; then
  if [ -n "$cpu_model" ]; then
    ok "Processor $cpu_model — $cores cores, $GOARCH2, supported"
  else
    ok "Processor $GOARCH2, $cores cores — supported"
  fi
else
  fail "Processor" "$(uname -m) is not supported"
fi

mem_total_kb="$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || true)"
if [ -n "$mem_total_kb" ]; then
  mem_gb="$(awk -v k="$mem_total_kb" 'BEGIN{printf "%.1f", k/1048576}')"
  ok "Memory ${mem_gb}G"
else
  ok "Memory unknown"
fi

if [ -d /run/systemd/system ]; then ok "Service manager systemd is running"; else fail "Service manager" "systemd is required"; fi

if apt-get update -qq >/dev/null 2>&1; then
  ok "Internet connection works"
else
  fail "Internet connection" "apt update failed — check the network"
fi

if [ -d "$BEAR_STORAGE" ] && touch "$BEAR_STORAGE/.bearnas-check" 2>/dev/null && rm -f "$BEAR_STORAGE/.bearnas-check"; then
  cap="$(df -Ph "$BEAR_STORAGE" | awk 'NR==2{print $2" total, "$4" free"}')"
  ok "Storage $BEAR_STORAGE is ready — $cap"
else
  fail "Storage $BEAR_STORAGE" "drive not found or not writable"
fi

free_mb="$(df -Pm / | awk 'NR==2{print $4}')"
free_gb="$(df -Ph / | awk 'NR==2{print $4}')"
if [ "${free_mb:-0}" -ge 100 ]; then
  ok "System disk has enough space — $free_gb free"
else
  fail "System disk" "only ${free_gb:-?} free, at least 100MB is required"
fi

port_bad=0
case "$BEAR_PORT" in
  ''|*[!0-9]*) port_bad=1 ;;
  *) [ "$BEAR_PORT" -ge 1 ] && [ "$BEAR_PORT" -le 65535 ] || port_bad=1 ;;
esac
port_busy=0
if [ "$port_bad" = 0 ]; then
  (exec 3<>"/dev/tcp/127.0.0.1/$BEAR_PORT") 2>/dev/null && port_busy=1
fi
if systemctl is-active --quiet bearnas 2>/dev/null; then port_busy=0; fi
if [ "$port_bad" = 1 ]; then
  fail "Web port" "port number must be between 1 and 65535"
elif [ "$port_busy" = 0 ]; then
  ok "Web port $BEAR_PORT is free"
else
  fail "Web port $BEAR_PORT" "another program is using this port"
fi
# พอร์ต gateway ของ UI ปลั๊กอิน (qBittorrent = 8901) — BearNAS เปิดเองตอนรัน แค่เตือน
if systemctl is-active --quiet bearnas 2>/dev/null; then
  :
elif (exec 3<>"/dev/tcp/127.0.0.1/8901") 2>/dev/null; then
  warn "Plugin gateway port 8901 is in use by another program — plugin web UI may fail"
else
  ok "Plugin gateway port 8901 is free"
fi

if [ "$FAILS" -gt 0 ]; then
  printf '\nCannot continue — %s problem(s) found. Nothing was changed.\n' "$FAILS"
  exit 1
fi

### ═══ Stage 2/6 — Network ═══
stage "2/6 Network"
CUR_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
CUR_GW="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
printf '  Network: IP %s · gateway %s\n' "${CUR_IP:-?}" "${CUR_GW:-?}"
if [ -n "$CUR_IP" ] && ! grep -q 'iface eth0 inet dhcp' /etc/network/interfaces 2>/dev/null; then
  ok "Fixed IP address is configured — $CUR_IP"
else
  warn "IP comes from DHCP — it may change after a reboot"
  echo  "  Tip: set a fixed IP on the Proxmox host, then restart the CT:"
  echo  "       pct set <CT-ID> -net0 name=eth0,bridge=vmbr0,ip=${CUR_IP:-<ip>}/24,gw=${CUR_GW:-<gw>}"
fi

### ═══ Stage 3/6 — Base packages ═══
stage "3/6 Base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq ca-certificates curl
ok "Required packages installed"

### ═══ Stage 4/6 — Download ═══
stage "4/6 Download"
download_bearnas

### ═══ Stage 5/6 — Service ═══
stage "5/6 Service"
write_unit

### ═══ Stage 6/6 — Health check ═══
stage "6/6 Health check"
if wait_health; then
  ok "BearNAS is responding over HTTPS"
else
  fail "Service" "no response in 15s"
  show_diag
  exit 1
fi

summary "BearNAS is ready"
