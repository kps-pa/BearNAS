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
  printf 'Usage: bash setup.sh [--install|--uninstall]\n'
  printf '  --install     install BearNAS\n'
  printf '  --uninstall   remove BearNAS — storage data is never touched\n'
  printf '  (--update / --repair are reserved — the system is not finished yet)\n'
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

download_core() {
  url="$DIST_BASE/bearnas-linux-$GOARCH2/bearnas"
  echo "  From: $url"
  mkdir -p "$INSTALL_DIR"
  if ! curl -fsSL -o "$INSTALL_DIR/bearnas.tmp" "$url"; then
    printf '  [FAIL] Download — could not fetch %s\n' "$url"
    exit 1
  fi
  want="$(curl -fsSL "$DIST_BASE/bearnas-linux-$GOARCH2/bearnas.sha256" 2>/dev/null | awk '{print $1}')"
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
Description=BearNAS core
After=network.target

[Service]
WorkingDirectory=$INSTALL_DIR
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$INSTALL_DIR
PrivateTmp=yes
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
  printf 'This stops BearNAS and deletes: bearnas.service and %s (binary + certificate).\n' "$INSTALL_DIR"
  printf 'Data in %s is NOT touched.\n' "$BEAR_STORAGE"
  if ! read -r -p "Continue? [y/N] " ans; then ans=""; fi
  case "$ans" in
    y|Y) ;;
    *) printf 'Cancelled.\n'; exit 0 ;;
  esac
  systemctl disable --now bearnas >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/bearnas.service
  systemctl daemon-reload
  rm -rf "$INSTALL_DIR"
  printf 'BearNAS removed.\n'
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
      printf '\n  1) Uninstall\n'
      printf '  2) Cancel\n'
      if ! read -r -p 'Choose [1-2]: ' pick; then pick=""; fi
      case "$pick" in
        1) MODE="--uninstall" ;;
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
  --update|--repair)
    printf '\n%s is not available yet — the system is still under construction.\n' "$MODE"
    printf 'It will be enabled once the project is complete.\n'
    exit 0
    ;;
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
download_core

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
