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
#  Install runs 7 stages. Everything is checked first — if a check fails,
#  nothing is changed. Re-run any time to upgrade.
#
#  Optional settings (environment variables):
#    GO_VER / BEAR_PORT / BEAR_STORAGE / INSTALL_DIR / REPO_TARBALL / SOURCE_DIR
# ==============================================================================
set -euo pipefail

### ── Defaults ──
GO_VER="${GO_VER:-1.27.2}"
BEAR_PORT="${BEAR_PORT:-8900}"
BEAR_STORAGE="${BEAR_STORAGE:-/mnt/disk1}"
INSTALL_DIR="${INSTALL_DIR:-/opt/bearnas}"
REPO_TARBALL="${REPO_TARBALL:-https://github.com/kps-pa/BearNAS/archive/refs/heads/main.tar.gz}"
SOURCE_DIR="${SOURCE_DIR:-}"

stage() { printf '\n==> %s\n' "$*"; }
ok()    { printf '  [OK]   %s\n' "$*"; }
warn()  { printf '  [WARN] %s\n' "$*"; }
fail()  { printf '  [FAIL] %s — %s\n' "$1" "$2"; FAILS=$((FAILS+1)); }

usage() {
  printf 'Usage: bash setup.sh [--install|--update|--repair|--uninstall]\n'
  printf '  --install     install or upgrade BearNAS\n'
  printf '  --update      update to the latest version from GitHub\n'
  printf '  --repair      find and fix problems (binary, service unit, service)\n'
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

ensure_go() {
  GOARCH2=""
  case "$(uname -m)" in
    x86_64)  GOARCH2=amd64 ;;
    aarch64) GOARCH2=arm64 ;;
    *) printf '  [FAIL] CPU — %s not supported\n' "$(uname -m)"; exit 1 ;;
  esac
  GO_BIN=""
  if command -v go >/dev/null 2>&1; then
    GO_BIN="$(command -v go)"
  elif [ -x /usr/local/go/bin/go ]; then
    GO_BIN=/usr/local/go/bin/go
  fi
  if [ -n "$GO_BIN" ]; then
    ok "Go already installed"
  else
    echo "  Downloading Go $GO_VER..."
    curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VER}.linux-${GOARCH2}.tar.gz"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tgz
    rm -f /tmp/go.tgz
    GO_BIN=/usr/local/go/bin/go
    ok "Go installed"
  fi
}

fetch_src() {  # $1: 1 = allow SOURCE_DIR / adjacent checkout, 0 = GitHub only
  if [ "$1" = 1 ] && [ -n "$SOURCE_DIR" ] && [ -f "$SOURCE_DIR/go.mod" ] && [ -f "$SOURCE_DIR/main.go" ]; then
    SRC="$SOURCE_DIR"
    echo "  Source: $SRC"
    return
  fi
  if [ "$1" = 1 ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -f "$SCRIPT_DIR/go.mod" ] && [ -f "$SCRIPT_DIR/main.go" ]; then
      SRC="$SCRIPT_DIR"
      echo "  Source: local checkout"
      return
    fi
  fi
  SRC=/tmp/bearnas-src
  rm -rf "$SRC"
  mkdir -p "$SRC"
  echo "  Source: GitHub"
  curl -fsSL "$REPO_TARBALL" | tar -xz --strip-components=1 -C "$SRC"
}

build_core() {
  mkdir -p "$INSTALL_DIR"
  (
    cd "$SRC"
    CGO_ENABLED=0 "$GO_BIN" build -trimpath -ldflags "-s -w" -o "$INSTALL_DIR/bearnas" .
  )
  ok "Built $INSTALL_DIR/bearnas — $(du -h "$INSTALL_DIR/bearnas" | cut -f1)"
}

write_unit() {
  cat >/etc/systemd/system/bearnas.service <<UNIT
[Unit]
Description=BearNAS core
After=network.target

[Service]
WorkingDirectory=$INSTALL_DIR
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
  ok "Service started"
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
  printf 'This stops BearNAS and deletes: bearnas.service and %s (binary + certificate).\n' "$INSTALL_DIR"
  printf 'Data in %s is NOT touched. The Go toolchain is kept.\n' "$BEAR_STORAGE"
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
  printf 'Optional — remove the Go toolchain too: rm -rf /usr/local/go ~/.cache/go-build\n'
  exit 0
}

update_bearnas() {
  quick_guard
  stage "Update"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq ca-certificates curl >/dev/null
  ensure_go
  fetch_src 0
  build_core
  write_unit
  if wait_health; then
    ok "Service is up"
  else
    fail "Service" "no response in 15s"
    show_diag
    exit 1
  fi
  summary "BearNAS updated — running the latest version"
  exit 0
}

repair_bearnas() {
  quick_guard
  stage "Repair"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq ca-certificates curl >/dev/null 2>&1 || true
  FIXES=0

  if [ -d "$BEAR_STORAGE" ]; then
    ok "Storage $BEAR_STORAGE present"
  else
    warn "Storage $BEAR_STORAGE missing — bind mount it from the Proxmox host (cannot fix from inside the CT)"
  fi

  if [ -x "$INSTALL_DIR/bearnas" ]; then
    ok "Binary present"
  else
    echo "  Binary missing — rebuilding from GitHub"
    ensure_go
    fetch_src 0
    build_core
    FIXES=$((FIXES+1))
  fi

  if [ -f /etc/systemd/system/bearnas.service ]; then
    ok "Service unit present"
  else
    echo "  Service unit missing — recreating"
    FIXES=$((FIXES+1))
  fi

  if systemctl is-active --quiet bearnas 2>/dev/null; then
    ok "Service running"
  else
    echo "  Service not running — restarting"
    FIXES=$((FIXES+1))
  fi
  write_unit

  if wait_health; then
    ok "HTTPS responding"
  else
    echo "  Service not responding — rebuilding from GitHub"
    ensure_go
    fetch_src 0
    build_core
    write_unit
    FIXES=$((FIXES+1))
    if wait_health; then
      ok "HTTPS responding after rebuild"
    else
      fail "Service" "still not responding — diagnostics below"
      show_diag
      exit 1
    fi
  fi

  printf '\n'
  if [ "$FIXES" -gt 0 ]; then
    printf 'Repair done — %s item(s) fixed.\n' "$FIXES"
  else
    printf 'Repair done — everything was already healthy.\n'
  fi
  summary "BearNAS is healthy"
  exit 0
}

### ── Mode selection ──
printf 'BearNAS Setup\n'
MODE="${1:-}"
if [ -z "$MODE" ]; then
  if [ -t 0 ]; then
    printf '\n  1) Install / upgrade\n'
    printf '  2) Update to latest\n'
    printf '  3) Repair\n'
    printf '  4) Uninstall\n'
    printf '  5) Cancel\n'
    if ! read -r -p 'Choose [1-5]: ' pick; then pick=""; fi
    case "$pick" in
      1) MODE="--install" ;;
      2) MODE="--update" ;;
      3) MODE="--repair" ;;
      4) MODE="--uninstall" ;;
      *) printf 'Cancelled.\n'; exit 0 ;;
    esac
  else
    MODE="--install"
  fi
fi
case "$MODE" in
  --install) ;;
  --update)              update_bearnas ;;
  --repair)              repair_bearnas ;;
  --uninstall)           remove_bearnas ;;
  *) usage; exit 1 ;;
esac

### ═══ Stage 1/7 — System check ═══
stage "1/7 System check"
FAILS=0
MIGRATE_LEGACY=0

if [ "$(id -u)" -eq 0 ]; then ok "Root"; else fail "Root" "run as root"; fi

if grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
  ok "Inside CT"
else
  fail "Inside CT" "run this inside the CT. On the Proxmox host: pct enter <CT-ID>"
fi

[ -f /etc/os-release ] && . /etc/os-release
if [ "${ID:-}" = "debian" ]; then
  ok "OS Debian ${VERSION_ID:-}"
else
  fail "OS" "Debian required, found ${ID:-unknown}"
fi

cpu_model="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
case "$(uname -m)" in
  x86_64)  GOARCH2=amd64 ;;
  aarch64) GOARCH2=arm64 ;;
  *) GOARCH2="" ;;
esac
if [ -n "$GOARCH2" ]; then
  if [ -n "$cpu_model" ]; then
    ok "CPU $cpu_model · $GOARCH2"
  else
    ok "CPU $GOARCH2"
  fi
else
  fail "CPU" "$(uname -m) not supported"
fi

if [ -d /run/systemd/system ]; then ok "systemd"; else fail "systemd" "systemd required"; fi

if apt-get update -qq >/dev/null 2>&1; then
  ok "Internet"
else
  fail "Internet" "apt update failed"
fi

if [ -d "$BEAR_STORAGE" ] && touch "$BEAR_STORAGE/.bearnas-check" 2>/dev/null && rm -f "$BEAR_STORAGE/.bearnas-check"; then
  cap="$(df -Ph "$BEAR_STORAGE" | awk 'NR==2{print $2" total, "$4" free"}')"
  ok "Storage $BEAR_STORAGE — $cap"
else
  fail "Storage $BEAR_STORAGE" "not found or not writable"
fi

free_mb="$(df -Pm / | awk 'NR==2{print $4}')"
free_gb="$(df -Ph / | awk 'NR==2{print $4}')"
if [ "${free_mb:-0}" -ge 600 ]; then
  ok "System disk — $free_gb free"
else
  fail "System disk" "${free_gb:-?} free, need at least 600MB"
fi

port_busy=0
(exec 3<>"/dev/tcp/127.0.0.1/$BEAR_PORT") 2>/dev/null && port_busy=1
if systemctl is-active --quiet bearnas 2>/dev/null; then
  port_busy=0
elif [ "$port_busy" = 1 ] && systemctl is-active --quiet pico-nas 2>/dev/null; then
  MIGRATE_LEGACY=1
  port_busy=0
fi
if [ "$port_busy" = 0 ]; then
  ok "Port $BEAR_PORT free"
else
  fail "Port $BEAR_PORT" "another program is using it"
fi

if [ "$FAILS" -gt 0 ]; then
  printf '\nStopped — %s problem(s) found. Nothing was changed.\n' "$FAILS"
  exit 1
fi

### ═══ Stage 2/7 — Network ═══
stage "2/7 Network"
CUR_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
CUR_GW="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
printf '  IP %s · gateway %s\n' "${CUR_IP:-?}" "${CUR_GW:-?}"
if [ -n "$CUR_IP" ] && ! grep -q 'iface eth0 inet dhcp' /etc/network/interfaces 2>/dev/null; then
  ok "Fixed IP already set: $CUR_IP"
else
  warn "IP comes from DHCP — it may change after a reboot"
  echo  "  Tip: set a fixed IP on the Proxmox host, then restart the CT:"
  echo  "       pct set <CT-ID> -net0 name=eth0,bridge=vmbr0,ip=${CUR_IP:-<ip>}/24,gw=${CUR_GW:-<gw>}"
fi

### ═══ Stage 3/7 — Base packages ═══
stage "3/7 Base packages"
if [ "$MIGRATE_LEGACY" = 1 ]; then
  echo  "  Found old pico-nas service — replacing with BearNAS"
  systemctl disable --now pico-nas >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/pico-nas.service
  rm -rf /opt/pico-nas
  systemctl daemon-reload
  ok "Old service removed"
fi
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq ca-certificates curl
ok "Packages ready"

### ═══ Stage 4/7 — Go ═══
stage "4/7 Go"
ensure_go

### ═══ Stage 5/7 — Build ═══
stage "5/7 Build"
fetch_src 1
build_core

### ═══ Stage 6/7 — Service ═══
stage "6/7 Service"
write_unit

### ═══ Stage 7/7 — Health check ═══
stage "7/7 Health check"
if wait_health; then
  ok "Service is up"
else
  fail "Service" "no response in 15s"
  show_diag
  exit 1
fi

summary "BearNAS is ready"
