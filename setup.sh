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
GO_WE_INSTALLED=0          # 1 = Go ถูกลงโดย BearNAS เอง (ใช้ตอน uninstall)

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

ensure_go() {
  case "$GO_VER" in
    *[!0-9.]*)
      printf '  [FAIL] Go — invalid GO_VER %s\n' "$GO_VER"
      exit 1
      ;;
  esac
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
    if ! curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VER}.linux-${GOARCH2}.tar.gz"; then
      printf '  [FAIL] Go — download failed\n'
      exit 1
    fi
    if command -v python3 >/dev/null 2>&1; then
      want="$(curl -fsSL "https://go.dev/dl/?mode=json&include=all" \
        | python3 -c 'import json,sys
ver, arch = "go" + sys.argv[1], "linux-" + sys.argv[2]
for r in json.load(sys.stdin):
    if r["version"] == ver:
        for f in r["files"]:
            if f["os"] + "-" + f["arch"] == arch and f["kind"] == "archive":
                print(f["sha256"]); raise SystemExit' "$GO_VER" "$GOARCH2" 2>/dev/null || true)"
      if [ -n "$want" ]; then
        got="$(sha256sum /tmp/go.tgz | awk '{print $1}')"
        if [ "$got" != "$want" ]; then
          printf '  [FAIL] Go — checksum mismatch, aborting\n'
          rm -f /tmp/go.tgz
          exit 1
        fi
        ok "Go checksum verified"
      fi
    else
      echo "  (python3 not found — checksum skipped)"
    fi
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tgz
    rm -f /tmp/go.tgz
    GO_BIN=/usr/local/go/bin/go
    GO_WE_INSTALLED=1
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
  if ! curl -fsSL "$REPO_TARBALL" | tar -xz --strip-components=1 -C "$SRC"; then
    printf '  [FAIL] Source — could not download %s\n' "$REPO_TARBALL"
    exit 1
  fi
  if [ ! -f "$SRC/main.go" ] || [ ! -f "$SRC/go.mod" ]; then
    printf '  [FAIL] Source — no service source found in %s\n' "$REPO_TARBALL"
    printf '         set SOURCE_DIR (local checkout) or REPO_TARBALL (tarball with main.go)\n'
    exit 1
  fi
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
  printf 'Data in %s is NOT touched. The Go toolchain is removed too (when BearNAS installed it).\n' "$BEAR_STORAGE"
  if ! read -r -p "Continue? [y/N] " ans; then ans=""; fi
  case "$ans" in
    y|Y) ;;
    *) printf 'Cancelled.\n'; exit 0 ;;
  esac
  systemctl disable --now bearnas >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/bearnas.service
  systemctl daemon-reload
  REMOVE_GO=0
  if [ -f "$INSTALL_DIR/.bearnas-installed-go" ]; then REMOVE_GO=1; fi
  rm -rf "$INSTALL_DIR"
  if [ "$REMOVE_GO" = 1 ]; then
    rm -rf /usr/local/go
    rm -rf ~/.cache/go-build
    printf 'BearNAS removed — including the Go toolchain.\n'
  else
    printf 'BearNAS removed. Go toolchain kept (it was already installed before BearNAS).\n'
  fi
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
      printf '\n  Status: not installed\n'
      printf '\n  1) Install\n'
      printf '  2) Cancel\n'
      if ! read -r -p 'Choose [1-2]: ' pick; then pick=""; fi
      case "$pick" in
        1) MODE="--install" ;;
        *) printf 'Cancelled.\n'; exit 0 ;;
      esac
    else
      printf '\n  Status: installed'
      if systemctl is-active --quiet bearnas 2>/dev/null; then printf ' — service running'; fi
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

### ═══ Stage 1/7 — System check ═══
stage "1/7 System check"
FAILS=0

if [ "$(id -u)" -eq 0 ]; then ok "Root"; else fail "Root" "run as root"; fi

if grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
  ok "Inside CT"
else
  fail "Inside CT" "run this inside the CT. On the Proxmox host: pct enter <CT-ID>"
fi

if [ -f /etc/os-release ]; then . /etc/os-release; fi
if [ "${ID:-}" = "debian" ]; then
  ok "OS Debian ${VERSION_ID:-}"
else
  fail "OS" "Debian required, found ${ID:-unknown}"
fi

cpu_model="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
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
  fail "Port" "BEAR_PORT must be a number 1-65535"
elif [ "$port_busy" = 0 ]; then
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
if [ "$GO_WE_INSTALLED" = 1 ]; then
  touch "$INSTALL_DIR/.bearnas-installed-go"
fi

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
