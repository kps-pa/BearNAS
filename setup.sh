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

# สถาปัตยกรรมของเครื่อง — ต้องรู้ตั้งแต่ต้นสคริปต์ (download_bearnas ใช้ทุกโหมด ไม่ใช่แค่ --install)
# คำสั่งเจ้าของ: build เฉพาะ linux/amd64 — arm64 ไม่มี binary ให้ จึงปฏิเสศตั้งแต่ต้น ไม่ใช่พังกลางทางตอนดาวน์โหลด
case "$(uname -m)" in
  x86_64)        GOARCH2=amd64 ;;
  aarch64|arm64) GOARCH2="" ;;
  *)             GOARCH2="" ;;
esac

stage() { printf '\n==> %s\n' "$*"; }
ok()    { printf '  [OK]   %s\n' "$*"; }
warn()  { printf '  [WARN] %s\n' "$*"; }
fail()  { printf '  [FAIL] %s — %s\n' "$1" "$2"; FAILS=$((FAILS+1)); }

# ตัวนับปัญหาของ fail() — ตั้งต้นไว้ตั้งแต่ต้นสคริปต์ (โหมด --update/--repair ไม่ผ่าน stage 1)
FAILS=0

usage() {
  printf 'Usage: bash setup.sh [--install|--update|--repair|--uninstall]\n'
  printf '  --install     install BearNAS (re-run to upgrade)\n'
  printf '  --update      download the latest build from GitHub and restart\n'
  printf '  --repair      check the installation and fix what is broken\n'
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

# อ่านค่าที่ "ติดตั้งจริง" จาก unit file (พอร์ต/ดิสก์อาจไม่ใช่ค่า default ของ env วันนี้)
read_unit_env() {
  if [ -f /etc/systemd/system/bearnas.service ]; then
    _p="$(grep -o '^Environment=BEAR_PORT=[0-9]\+' /etc/systemd/system/bearnas.service | tail -1 | cut -d= -f3)"
    # -f3- เก็บค่าทั้งหมดหลัง '=' ที่สอง — พาธอย่าง /mnt/d=1 ต้องไม่ถูกตัดเหลือ /mnt/d
    _s="$(grep -o '^Environment=BEAR_STORAGE=[^ ]*' /etc/systemd/system/bearnas.service | tail -1 | cut -d= -f3-)"
    [ -n "$_p" ] && BEAR_PORT="$_p"
    [ -n "$_s" ] && BEAR_STORAGE="$_s"
  fi
}

# เวอร์ชันจากตัว binary เอง (ธง --version ของ BearNAS) — คืนว่างเมื่อใช้ไม่ได้:
# binary เก่าก่อนมีธงนี้จะลงมือรันเซิร์ฟเวอร์เลย (timeout กันค้าง) หรือผลลัพธ์ไม่ใช่
# รูปแบบ x.y.z (ไฟล์เสีย) — ผู้เรียกต้องมี fallback เป็น sha เสมอ
bin_version() {
  _v="$(timeout 5 "$1" --version 2>/dev/null | head -1 || true)"
  case "$_v" in
    [0-9]*.[0-9]*.[0-9]*) printf '%s' "$_v" ;;
    *) ;;
  esac
}

# unit ที่เขียนไว้เมื่อรุ่นก่อนอาจขาดค่าใหม่ (เช่น UMask=0002 ที่มา after v0.7.0) —
# เทียบไม่ได้ทั้งไฟล์ก็เช็คทีละ marker ที่สำคัญ ขาด = เขียนใหม่ด้วยค่าปัจจุบัน
# (read_unit_env วิ่งก่อนแล้วเสมอ พอร์ต/ดิสก์จึงคงค่าที่ติดตั้งจริง ไม่ใช่ default)
ensure_unit_current() {
  if [ ! -f /etc/systemd/system/bearnas.service ]; then
    return 1
  fi
  if ! grep -q '^UMask=0002$' /etc/systemd/system/bearnas.service; then
    return 1
  fi
  return 0
}

download_bearnas() {
  if [ -z "$GOARCH2" ]; then
    printf '  [FAIL] Download — no build for this CPU architecture (%s)\n' "$(uname -m)"
    exit 1
  fi
  url="$DIST_BASE/bearnas-linux-$GOARCH2/bearnas"
  echo "  From: $url"
  mkdir -p "$INSTALL_DIR"
  if ! curl -fsSL --max-time 600 -o "$INSTALL_DIR/bearnas.tmp" "$url"; then
    rm -f "$INSTALL_DIR/bearnas.tmp"
    printf '  [FAIL] Download — could not fetch %s\n' "$url"
    exit 1
  fi
  want="$(curl -fsSL --max-time 30 "$DIST_BASE/bearnas-linux-$GOARCH2/bearnas.sha256" 2>/dev/null | awk '{print $1}' || true)"
  got="$(sha256sum "$INSTALL_DIR/bearnas.tmp" 2>/dev/null | awk '{print $1}')"
  # fail-closed: อ่าน checksum ไม่ได้ = ยกเลิก ไม่ติดตั้ง binary ที่ตรวจไม่ได้ (เคยข้ามเฉย ๆ)
  if [ -z "$want" ] || [ -z "$got" ] || [ "$got" != "$want" ]; then
    printf '  [FAIL] Download — checksum missing or mismatch\n'
    printf '         GitHub CDN can lag a few minutes after a release — wait and retry.\n'
    rm -f "$INSTALL_DIR/bearnas.tmp"
    exit 1
  fi
  ok "Download verified — checksum matches"
  mv -f "$INSTALL_DIR/bearnas.tmp" "$INSTALL_DIR/bearnas"
  chmod 755 "$INSTALL_DIR/bearnas"
  DL_VER="$(bin_version "$INSTALL_DIR/bearnas")"
  ok "BearNAS binary installed — ${DL_VER:+version $DL_VER · }$(du -h "$INSTALL_DIR/bearnas" | cut -f1)"
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
# 0002 = ไฟล์/โฟลเดอร์ที่ service สร้างให้กลุ่ม bearnas เขียนได้ (โฟลเดอร์ร่วมบนดิสก์ข้อมูล
# ถูก chmod ชัดอยู่แล้ว — ตัวนี้เป็นเบาะกันเหตุสุดท้าย เคยโดน umask default 0022 ตัดบิตกลุ่ม
# จนงานโหลดวิดีโอเขียนไฟล์ไม่ได้ [Errno 13])
UMask=0002
Environment=BEAR_PORT=$BEAR_PORT
Environment=BEAR_STORAGE=$BEAR_STORAGE
ExecStart=$INSTALL_DIR/bearnas
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  # enable ล้ม (systemd พัง/พื้นที่ไม่พอ) ไม่ใช่เหตุให้ติดตั้งค้างกลางทาง — restart ต่างหากคือด่านจริง
  systemctl enable bearnas >/dev/null 2>&1 || true
  systemctl restart bearnas
  ok "BearNAS service installed and started"
}

wait_health() {
  local _u=0 _i
  for _i in $(seq 1 15); do
    # /api/v1/setup/status ถูกยกเว้นจาก rate limit ฝั่งแอป (เป็น health-check หลักของหน้าเว็บด้วย)
    if curl -fsk --max-time 3 "https://127.0.0.1:$BEAR_PORT/api/v1/setup/status" >/dev/null 2>&1; then _u=1; break; fi
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
  printf '  Plugins : qBittorrent / Video Downloader — install from the web UI\n'
  printf '==============================================\n'
}

remove_bearnas() {
  quick_guard
  read_unit_env
  # normalize ก่อนเทียบ blocklist — "/usr/" หรือ "/opt/." ต้องถูกจับเหมือน "/usr"
  INSTALL_DIR="${INSTALL_DIR%/}"
  case "$INSTALL_DIR" in
    ""|"/"|"/usr"|"/etc"|"/opt"|"/var"|"/bin"|"/lib"|"/home"|"/boot"|"/sbin"|"/usr/bin"|"/usr/lib")
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

### ── Update: ดาวน์โหลด build ล่าสุดจาก GitHub + รีสตาร์ท (ข้อมูลผู้ใช้ไม่ถูกแตะ) ──
update_bearnas() {
  quick_guard
  read_unit_env
  if [ ! -x "$INSTALL_DIR/bearnas" ]; then
    printf 'BearNAS is not installed yet — run: bash setup.sh --install\n'
    exit 1
  fi
  if [ ! -f /etc/systemd/system/bearnas.service ]; then
    printf 'Service unit file is missing — run: bash setup.sh --repair\n'
    exit 1
  fi
  stage "Current build"
  CUR_SHA="$(sha256sum "$INSTALL_DIR/bearnas" 2>/dev/null | awk '{print $1}')"
  CUR_VER="$(bin_version "$INSTALL_DIR/bearnas")"
  if [ -n "$CUR_VER" ]; then
    printf '  Installed: version %s (build %s…)\n' "$CUR_VER" "${CUR_SHA:0:12}"
  else
    printf '  Installed: %s…\n' "${CUR_SHA:0:12}"
  fi

  # สำรองตัวเดิมก่อนแตะ — ถ้าตัวใหม่ลุกไม่ขึ้น กู้คืนให้เอง (ตามที่ตัวอัปเดตบนเว็บทำ)
  cp -p "$INSTALL_DIR/bearnas" "$INSTALL_DIR/bearnas.bak"

  stage "Downloading the latest build"
  download_bearnas
  NEW_SHA="$(sha256sum "$INSTALL_DIR/bearnas" 2>/dev/null | awk '{print $1}')"
  NEW_VER="$(bin_version "$INSTALL_DIR/bearnas")"

  # sha ว่างทั้งคู่ (sha256sum พัง) ไม่ใช่ "เหมือนกัน" — ถือว่าไม่เท่ากัน ไปตาม flow อัปเดตปกติ
  if [ -n "$CUR_SHA" ] && [ -n "$NEW_SHA" ] && [ "$CUR_SHA" = "$NEW_SHA" ]; then
    ok "Already up to date${NEW_VER:+ — version $NEW_VER} (same build as on GitHub)"
    rm -f "$INSTALL_DIR/bearnas.bak"
    summary "BearNAS is up to date${NEW_VER:+ — $NEW_VER}"
    exit 0
  fi

  # unit รุ่นเก่า (ก่อน v0.7.0) ไม่มี UMask=0002 — เขียนใหม่พร้อมค่าที่อ่านจาก unit เดิม
  if ! ensure_unit_current; then
    stage "Refreshing service unit"
    warn "Unit file is outdated — rewriting (adds UMask=0002)"
    write_unit
  fi

  stage "Restarting service"
  printf '  Updated: %s → %s\n' "${CUR_VER:-${CUR_SHA:0:12}…}" "${NEW_VER:-${NEW_SHA:0:12}…}"
  # || true เพื่อให้ไหลต่อไปที่ wait_health เสมอ — restart คืน non-zero เอง (systemd แปลก ๆ)
  # เดิม set -e จะออกก่อนถึงด่านตรวจสุขภาพ = binary ใหม่วางแล้วแต่ rollback ไม่ได้พิจารณา
  systemctl restart bearnas || true
  if wait_health; then
    ok "BearNAS is responding over HTTPS"
    rm -f "$INSTALL_DIR/bearnas.bak"
  else
    fail "Service" "no response in 15s — rolling back to the previous build"
    cp -p "$INSTALL_DIR/bearnas.bak" "$INSTALL_DIR/bearnas"
    rm -f "$INSTALL_DIR/bearnas.bak"
    systemctl restart bearnas
    if wait_health; then
      ok "Rolled back — the previous build is running again"
    else
      warn "Rollback did not come up either — check: journalctl -u bearnas -n 50"
    fi
    show_diag
    exit 1
  fi
  summary "BearNAS updated${NEW_VER:+ — now on $NEW_VER}"
  exit 0
}

### ── Repair: ตรวจทีละจุดแล้วซ่อมให้ (ข้อมูลผู้ใช้/ดิสก์ไม่ถูกแตะ) ──
repair_bearnas() {
  quick_guard
  read_unit_env
  printf 'BearNAS Repair — checks everything and fixes what it can.\n\n'
  REPAIRED=0

  stage "Binary"
  NEED_DL=0
  if [ ! -f "$INSTALL_DIR/bearnas" ]; then
    warn "Binary missing — will download"
    NEED_DL=1
  elif [ "$(head -c4 "$INSTALL_DIR/bearnas" 2>/dev/null)" != "$(printf '\177ELF')" ]; then
    warn "Binary is not a Linux executable — will download"
    NEED_DL=1
  elif [ ! -x "$INSTALL_DIR/bearnas" ]; then
    chmod 755 "$INSTALL_DIR/bearnas"
    ok "Execute permission restored"
    REPAIRED=$((REPAIRED+1))
  else
    ok "Binary present"
  fi
  if [ "$NEED_DL" = 1 ]; then
    download_bearnas
    REPAIRED=$((REPAIRED+1))
  fi

  stage "Service unit"
  if [ ! -f /etc/systemd/system/bearnas.service ]; then
    warn "Unit file missing — rewriting"
    write_unit
    REPAIRED=$((REPAIRED+1))
  elif ! ensure_unit_current; then
    warn "Unit file outdated (no UMask=0002) — rewriting"
    write_unit
    REPAIRED=$((REPAIRED+1))
  else
    ok "Unit file present and current"
  fi

  stage "Group and folders"
  if ! getent group bearnas >/dev/null 2>&1; then
    groupadd -f bearnas
    ok "Group bearnas re-created"
    REPAIRED=$((REPAIRED+1))
  else
    ok "Group bearnas present"
  fi
  if [ -d "$INSTALL_DIR" ]; then
    ok "Install folder $INSTALL_DIR present"
  else
    mkdir -p "$INSTALL_DIR"
    ok "Install folder re-created"
    REPAIRED=$((REPAIRED+1))
  fi
  if [ -d "$BEAR_STORAGE" ]; then
    ok "Storage $BEAR_STORAGE present"
  else
    warn "Storage $BEAR_STORAGE not found — check the disk, then re-run --install"
  fi

  stage "Restart"
  systemctl daemon-reload
  systemctl enable bearnas >/dev/null 2>&1 || true
  systemctl restart bearnas
  if wait_health; then
    ok "BearNAS is responding over HTTPS"
  else
    fail "Service" "no response in 15s"
    show_diag
    exit 1
  fi
  printf '\n'
  if [ "$REPAIRED" = 0 ]; then
    summary "Nothing was broken — everything checked out"
  else
    summary "Repaired $REPAIRED item(s) — BearNAS is ready"
  fi
  exit 0
}

### ── Single-run lock (กันรันซ้อนสอง session — ครอบทุกโหมด ไม่ใช่แค่ install) ──
# ถ้า /run ใช้ไม่ได้ก็ "ห้ามรันเงียบ ๆ" โดยไม่มีล็อก — สอง session ซ้อนแย่งเขียน binary ได้
if [ -d /run ] && [ -w /run ]; then
  exec 9>/run/bearnas-setup.lock
  if ! flock -n 9; then
    printf 'Another setup.sh is already running.\n'
    exit 1
  fi
elif [ "$(id -u)" = 0 ]; then
  printf 'Cannot lock /run (not writable?) — refusing to run without the lock.\n'
  exit 1
fi

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
      printf '  2) Repair installation\n'
      printf '  3) Uninstall\n'
      printf '  4) Cancel\n'
      if ! read -r -p 'Choose [1-4]: ' pick; then pick=""; fi
      case "$pick" in
        1) MODE="--update" ;;
        2) MODE="--repair" ;;
        3) MODE="--uninstall" ;;
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
# GOARCH2 ตั้งไว้แล้วตั้งแต่ต้นสคริปต์ (amd64 เท่านั้น — คำสั่งเจ้าของ)
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
# ปลั๊กอินอยู่บนดิสก์ระบบทั้งหมด (yt-dlp+ffmpeg ~200MB · ตัวช่วยล็อกอินเว็บ ~500MB)
if [ "${free_mb:-0}" -ge 1024 ]; then
  ok "System disk space for plugins — $free_gb free"
else
  warn "Only ${free_gb:-?} free — plugins need room on the system disk (login helper ~500MB)"
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

# พาธเก็บข้อมูลต้องเป็น absolute ไม่มีช่องว่าง/บรรทัดใหม่ — มันถูกฝังลงบรรทัด
# Environment= ของ unit file ตรง ๆ (ค่าเพี้ยน = unit เสียทั้งไฟล์)
case "$BEAR_STORAGE" in
  /*) ;;
  *) fail "Storage path" "must be an absolute path (got: $BEAR_STORAGE)" ;;
esac
case "$BEAR_STORAGE" in
  *[[:space:],%]*) fail "Storage path" "must not contain spaces or newlines (got: $BEAR_STORAGE)" ;;
  *) ok "Storage path $BEAR_STORAGE is a valid unit-file value" ;;
esac
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
