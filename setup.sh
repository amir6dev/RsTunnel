#!/usr/bin/env bash
set -euo pipefail

# =======================
# RsTunnel (picotun) Setup - Dagger-style
# =======================

APP_NAME="RsTunnel"
BIN_NAME="picotun"
SERVICE_SERVER="${BIN_NAME}-server"
SERVICE_CLIENT="${BIN_NAME}-client"

REPO_URL_DEFAULT="https://github.com/amir6dev/RsTunnel.git"
REPO_BRANCH_DEFAULT="main"

INSTALL_DIR="/etc/${BIN_NAME}"
BIN_PATH="/usr/local/bin/${BIN_NAME}"

GO_VERSION="1.22.1"

COLOR_RESET="\033[0m"
COLOR_GREEN="\033[0;32m"
COLOR_RED="\033[0;31m"
COLOR_YELLOW="\033[0;33m"
COLOR_CYAN="\033[0;36m"
COLOR_GRAY="\033[0;90m"

log() { echo -e "${COLOR_CYAN}$*${COLOR_RESET}"; }
ok() { echo -e "${COLOR_GREEN}✓${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}!${COLOR_RESET} $*"; }
err() { echo -e "${COLOR_RED}✖${COLOR_RESET} $*"; }

pause() { read -r -p "Press Enter to return..." _; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run as root."
    exit 1
  fi
}

detect_arch() {
  local a
  a="$(uname -m || true)"
  case "$a" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv6l" ;; # best effort
    *) echo "amd64" ;;
  esac
}

pkg_install() {
  local pkgs=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${pkgs[@]}"
  else
    err "No supported package manager found."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_deps() {
  log "📦 Checking dependencies..."
  local missing=()

  for c in curl git tar; do
    have_cmd "$c" || missing+=("$c")
  done

  # optional but useful
  have_cmd systemctl || true

  if ((${#missing[@]} == 0)); then
    ok "Dependencies already installed"
    return 0
  fi

  warn "Installing missing packages: ${missing[*]}"
  pkg_install "${missing[@]}"
  ok "Dependencies installed"
}

version_ge() {
  # returns 0 if $1 >= $2
  # e.g. version_ge 1.22.1 1.22.0
  local v1="$1" v2="$2"
  python3 - <<'PY' "$v1" "$v2"
import sys
from packaging.version import Version
v1, v2 = sys.argv[1], sys.argv[2]
sys.exit(0 if Version(v1) >= Version(v2) else 1)
PY
}

current_go_version() {
  if ! have_cmd go; then
    echo ""
    return 0
  fi
  # go version go1.22.1 linux/amd64
  local gv
  gv="$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
  echo "${gv:-}"
}

download_file() {
  local url="$1" out="$2"
  # -f fail on http errors; -L follow redirect; --retry to be robust
  curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 180 "$url" -o "$out"
}

install_go() {
  log "⬇️  Checking Go..."
  local cur
  cur="$(current_go_version)"

  if [[ -n "$cur" ]]; then
    if version_ge "$cur" "$GO_VERSION"; then
      ok "Go $cur already meets requirement (>= $GO_VERSION)"
      return 0
    fi
    warn "Go $cur found, updating to $GO_VERSION..."
  else
    log "⬇️  Installing Go $GO_VERSION..."
  fi

  local arch
  arch="$(detect_arch)"

  local tarball="go${GO_VERSION}.linux-${arch}.tar.gz"
  local tmpdir
  tmpdir="$(mktemp -d /tmp/picotun-go.XXXXXX)"
  local out="${tmpdir}/${tarball}"

  # Fallback list (اول go.dev، بعد dl.google.com)
  local urls=(
    "https://go.dev/dl/${tarball}"
    "https://dl.google.com/go/${tarball}"
  )

  local downloaded=0
  for u in "${urls[@]}"; do
    log "   Downloading: $u"
    if download_file "$u" "$out"; then
      downloaded=1
      ok "Downloaded Go tarball"
      break
    else
      warn "Failed: $u"
    fi
  done

  if [[ "$downloaded" -ne 1 ]]; then
    err "Failed to download Go."
    rm -rf "$tmpdir" || true
    exit 1
  fi

  rm -rf /usr/local/go || true
  tar -C /usr/local -xzf "$out"
  rm -rf "$tmpdir" || true

  # Ensure PATH system-wide
  if ! grep -q '/usr/local/go/bin' /etc/profile 2>/dev/null; then
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
  fi
  export PATH="$PATH:/usr/local/go/bin"

  local nv
  nv="$(current_go_version)"
  if [[ -z "$nv" ]]; then
    err "Go install failed (go not found after install)."
    exit 1
  fi
  ok "Go environment ready ($nv)"
}

safe_workdir() {
  # avoid getcwd issues if current dir removed
  cd / || true
}

clone_repo() {
  local repo_url="$1" branch="$2"
  safe_workdir

  log "⬇️  Preparing source code..."
  local builddir
  builddir="$(mktemp -d /tmp/picobuild.XXXXXX)"

  log "🌐 Cloning from GitHub ..."
  git clone --depth 1 --branch "$branch" "$repo_url" "$builddir" >/dev/null

  echo "$builddir"
}

build_binary() {
  local builddir="$1"

  log "🔧 Fixing build environment (Iran Safe)..."
  export GOFLAGS="-mod=mod"
  export GOPROXY="https://proxy.golang.org,direct"
  export GOSUMDB="sum.golang.org"

  log "📦 Downloading Libraries..."
  ( cd "$builddir" && go mod download ) || true
  ( cd "$builddir" && go mod tidy ) || true

  log "🔨 Building binary..."
  ( cd "$builddir" && go build -o "${BIN_NAME}" ./cmd/picotun )
  ok "Build complete"
}

install_binary() {
  local builddir="$1"
  install -m 0755 "${builddir}/${BIN_NAME}" "$BIN_PATH"
  ok "Installed binary to $BIN_PATH"
}

write_server_service() {
  local cfg_path="$1"
  cat > "/etc/systemd/system/${SERVICE_SERVER}.service" <<EOF
[Unit]
Description=${APP_NAME} Server Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH} -c ${cfg_path}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_client_service() {
  local cfg_path="$1"
  cat > "/etc/systemd/system/${SERVICE_CLIENT}.service" <<EOF
[Unit]
Description=${APP_NAME} Client Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH} -c ${cfg_path}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

systemd_reload() {
  systemctl daemon-reload
}

enable_start() {
  local svc="$1"
  systemctl enable --now "${svc}.service"
}

stop_disable() {
  local svc="$1"
  systemctl disable --now "${svc}.service" 2>/dev/null || true
}

ua_by_choice() {
  local c="$1"
  case "$c" in
    1) echo "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" ;;
    2) echo "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:122.0) Gecko/20100101 Firefox/122.0" ;;
    3) echo "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" ;;
    4) echo "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15" ;;
    5) echo "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36" ;;
    *) echo "Mozilla/5.0" ;;
  esac
}

ask() {
  local prompt="$1" def="${2:-}"
  local v
  if [[ -n "$def" ]]; then
    read -r -p "$prompt [$def]: " v
    echo "${v:-$def}"
  else
    read -r -p "$prompt: " v
    echo "$v"
  fi
}

ask_yn() {
  local prompt="$1" def="${2:-Y}"
  local v
  read -r -p "$prompt [${def}/n]: " v
  v="${v:-$def}"
  [[ "$v" =~ ^[Yy]$ ]]
}

install_core() {
  local repo_url branch
  repo_url="$(ask "Repo URL" "$REPO_URL_DEFAULT")"
  branch="$(ask "Repo branch" "$REPO_BRANCH_DEFAULT")"

  ensure_deps
  install_go

  local builddir
  builddir="$(clone_repo "$repo_url" "$branch")"
  trap 'rm -rf "$builddir" 2>/dev/null || true' RETURN

  build_binary "$builddir"
  install_binary "$builddir"
}

make_dirs() {
  mkdir -p "$INSTALL_DIR"
}

install_server_flow() {
  clear
  echo "═══════════════════════════════════════"
  echo "         SERVER CONFIGURATION"
  echo "═══════════════════════════════════════"
  echo

  local tunnel_port psk transport
  tunnel_port="$(ask "Tunnel Port" "2020")"
  psk="$(ask "Enter PSK (Pre-Shared Key)" "")"

  echo
  echo "Select Transport:"
  echo "  1) httpsmux  - HTTPS Mimicry (Recommended)"
  echo "  2) httpmux   - HTTP Mimicry"
  echo "  3) wssmux    - WebSocket Secure (TLS)"
  echo "  4) wsmux     - WebSocket"
  echo "  5) kcpmux    - KCP (UDP based)"
  echo "  6) tcpmux    - Simple TCP"
  local tchoice
  tchoice="$(ask "Choice [1-6]" "2")"
  case "$tchoice" in
    1) transport="httpsmux" ;;
    2) transport="httpmux" ;;
    3) transport="wssmux" ;;
    4) transport="wsmux" ;;
    5) transport="kcpmux" ;;
    6) transport="tcpmux" ;;
    *) transport="httpmux" ;;
  esac

  echo
  echo "PORT MAPPINGS"
  echo

  local maps=()
  local idx=1
  while true; do
    echo
    echo "Port Mapping #$idx"
    local bind_port target_port proto
    bind_port="$(ask "Bind Port (port on this server, e.g., 2222)" "")"
    target_port="$(ask "Target Port (destination port, e.g., 22)" "")"
    proto="$(ask "Protocol (tcp/udp/both)" "tcp")"
    maps+=("$proto|0.0.0.0:${bind_port}|127.0.0.1:${target_port}")
    ok "Mapping added: 0.0.0.0:${bind_port} → 127.0.0.1:${target_port} (${proto})"
    if ! ask_yn "Add another mapping?" "N"; then
      break
    fi
    idx=$((idx+1))
  done

  # http mimic on server (optional like dagger)
  local fake_domain fake_path session_cookie chunked ua
  fake_domain="$(ask "Fake domain (e.g., www.google.com)" "www.google.com")"
  fake_path="$(ask "Fake path (e.g., /search)" "/search")"

  echo
  echo "Select User-Agent:"
  echo "  1) Chrome Windows (default)"
  echo "  2) Firefox Windows"
  echo "  3) Chrome macOS"
  echo "  4) Safari macOS"
  echo "  5) Chrome Android"
  echo "  6) Custom"
  local uac
  uac="$(ask "Choice [1-6]" "1")"
  if [[ "$uac" == "6" ]]; then
    ua="$(ask "Enter custom User-Agent" "Mozilla/5.0")"
  else
    ua="$(ua_by_choice "$uac")"
  fi

  if ask_yn "Enable session cookies?" "Y"; then
    session_cookie="true"
  else
    session_cookie="false"
  fi

  # dagger server example: chunked false
  if ask_yn "Enable chunked encoding?" "n"; then
    chunked="true"
  else
    chunked="false"
  fi

  # Build/install core binary first
  install_core
  make_dirs

  local cfg="${INSTALL_DIR}/server.yaml"
  {
    echo "mode: \"server\""
    echo "listen: \"0.0.0.0:${tunnel_port}\""
    echo "transport: \"${transport}\""
    echo "psk: \"${psk}\""
    echo "profile: \"latency\""
    echo "verbose: true"
    echo
    echo "heartbeat: 2"
    echo
    echo "maps:"
    for m in "${maps[@]}"; do
      IFS='|' read -r mtype mbind mtarget <<<"$m"
      echo "  - type: ${mtype}"
      echo "    bind: \"${mbind}\""
      echo "    target: \"${mtarget}\""
    done
    echo
    echo "obfuscation:"
    echo "  enabled: true"
    echo "  min_padding: 8"
    echo "  max_padding: 32"
    echo "  min_delay_ms: 0"
    echo "  max_delay_ms: 0"
    echo "  burst_chance: 0"
    echo
    echo "http_mimic:"
    echo "  fake_domain: \"${fake_domain}\""
    echo "  fake_path: \"${fake_path}\""
    echo "  user_agent: \"${ua}\""
    echo "  chunked_encoding: ${chunked}"
    echo "  session_cookie: ${session_cookie}"
    echo "  custom_headers:"
    echo "    - \"Accept-Language: en-US,en;q=0.9\""
    echo "    - \"Accept-Encoding: gzip, deflate, br\""
  } > "$cfg"

  write_server_service "$cfg"
  systemd_reload
  enable_start "$SERVICE_SERVER"

  echo
  echo "═══════════════════════════════════════"
  ok "Server installation complete!"
  echo "═══════════════════════════════════════"
  echo
  echo "  Tunnel Port: ${tunnel_port}"
  echo "  PSK: ${psk}"
  echo "  Transport: ${transport}"
  echo "  Config: ${cfg}"
  echo "  View logs: journalctl -u ${SERVICE_SERVER} -f"
  echo
  pause
}

install_client_flow() {
  clear
  echo "═══════════════════════════════════════"
  echo "         CLIENT CONFIGURATION"
  echo "═══════════════════════════════════════"
  echo

  echo "Configuration Mode:"
  echo "  1) Automatic - Optimized settings (Recommended)"
  echo "  2) Manual - Custom configuration"
  local cmode
  cmode="$(ask "Choice [1-2]" "2")"

  local psk
  psk="$(ask "Enter PSK (must match server)" "")"

  echo
  echo "Select Performance Profile:"
  echo "  1) balanced      - Standard balanced performance (Recommended)"
  echo "  2) aggressive    - High speed, aggressive settings"
  echo "  3) latency       - Optimized for low latency"
  echo "  4) cpu-efficient - Low CPU usage"
  echo "  5) gaming        - Optimized for gaming (low latency + high speed)"
  local pchoice
  pchoice="$(ask "Choice [1-5]" "1")"
  local profile="balanced"
  case "$pchoice" in
    1) profile="balanced" ;;
    2) profile="aggressive" ;;
    3) profile="latency" ;;
    4) profile="cpu-efficient" ;;
    5) profile="gaming" ;;
  esac

  local obfs_enabled="false"
  if ask_yn "Enable Traffic Obfuscation?" "Y"; then
    obfs_enabled="true"
  fi

  echo
  echo "═══════════════════════════════════════"
  echo "      CONNECTION PATHS"
  echo "═══════════════════════════════════════"
  echo

  echo "Select Transport Type:"
  echo "  1) tcpmux   - TCP Multiplexing"
  echo "  2) kcpmux   - KCP Multiplexing (UDP)"
  echo "  3) wsmux    - WebSocket"
  echo "  4) wssmux   - WebSocket Secure"
  echo "  5) httpmux  - HTTP Mimicry"
  echo "  6) httpsmux - HTTPS Mimicry ⭐"
  local tchoice
  tchoice="$(ask "Choice [1-6]" "5")"
  local transport="httpmux"
  case "$tchoice" in
    1) transport="tcpmux" ;;
    2) transport="kcpmux" ;;
    3) transport="wsmux" ;;
    4) transport="wssmux" ;;
    5) transport="httpmux" ;;
    6) transport="httpsmux" ;;
  esac

  local addr pool aggressive retry dial_timeout
  addr="$(ask "Server address with Tunnel Port (e.g., 1.2.3.4:4000)" "")"
  pool="$(ask "Connection pool size" "2")"
  if ask_yn "Enable aggressive pool?" "N"; then
    aggressive="true"
  else
    aggressive="false"
  fi
  retry="$(ask "Retry interval (seconds)" "3")"
  dial_timeout="$(ask "Dial timeout (seconds)" "10")"

  echo
  echo "═══════════════════════════════════════"
  echo "      HTTP MIMICRY SETTINGS"
  echo "═══════════════════════════════════════"
  echo

  local fake_domain fake_path ua chunked session_cookie
  fake_domain="$(ask "Fake domain (e.g., www.google.com)" "www.google.com")"
  fake_path="$(ask "Fake path (e.g., /search)" "/search")"

  echo
  echo "Select User-Agent:"
  echo "  1) Chrome Windows (default)"
  echo "  2) Firefox Windows"
  echo "  3) Chrome macOS"
  echo "  4) Safari macOS"
  echo "  5) Chrome Android"
  echo "  6) Custom"
  local uac
  uac="$(ask "Choice [1-6]" "1")"
  if [[ "$uac" == "6" ]]; then
    ua="$(ask "Enter custom User-Agent" "Mozilla/5.0")"
  else
    ua="$(ua_by_choice "$uac")"
  fi

  if ask_yn "Enable chunked encoding?" "Y"; then
    chunked="true"
  else
    chunked="false"
  fi
  if ask_yn "Enable session cookies?" "Y"; then
    session_cookie="true"
  else
    session_cookie="false"
  fi

  local verbose="false"
  if ask_yn "Enable verbose logging?" "N"; then
    verbose="true"
  fi

  # Build/install core binary first
  install_core
  make_dirs

  local cfg="${INSTALL_DIR}/client.yaml"
  {
    echo "mode: \"client\""
    echo "psk: \"${psk}\""
    echo "profile: \"${profile}\""
    echo "verbose: ${verbose}"
    echo
    echo "paths:"
    echo "  - transport: \"${transport}\""
    echo "    addr: \"${addr}\""
    echo "    connection_pool: ${pool}"
    echo "    aggressive_pool: ${aggressive}"
    echo "    retry_interval: ${retry}"
    echo "    dial_timeout: ${dial_timeout}"
    echo
    echo "obfuscation:"
    echo "  enabled: ${obfs_enabled}"
    echo "  min_padding: 16"
    echo "  max_padding: 512"
    echo "  min_delay_ms: 5"
    echo "  max_delay_ms: 50"
    echo "  burst_chance: 0.15"
    echo
    echo "http_mimic:"
    echo "  fake_domain: \"${fake_domain}\""
    echo "  fake_path: \"${fake_path}\""
    echo "  user_agent: \"${ua}\""
    echo "  chunked_encoding: ${chunked}"
    echo "  session_cookie: ${session_cookie}"
    echo "  custom_headers:"
    echo "    - \"X-Requested-With: XMLHttpRequest\""
    echo "    - \"Referer: https://${fake_domain}/\""
  } > "$cfg"

  write_client_service "$cfg"
  systemd_reload
  enable_start "$SERVICE_CLIENT"

  echo
  echo "═══════════════════════════════════════"
  ok "Client installation complete!"
  echo "═══════════════════════════════════════"
  echo
  echo "  Profile: ${profile}"
  echo "  Obfuscation: ${obfs_enabled}"
  echo
  echo "  Config: ${cfg}"
  echo "  View logs: journalctl -u ${SERVICE_CLIENT} -f"
  echo
  pause
}

settings_menu() {
  while true; do
    clear
    echo "═══════════════════════════════════════"
    echo "     SETTINGS (Manage Services)"
    echo "═══════════════════════════════════════"
    echo
    echo "  1) Status"
    echo "  2) Restart Server"
    echo "  3) Restart Client"
    echo "  4) Stop/Disable Server"
    echo "  5) Stop/Disable Client"
    echo "  6) View Config Paths"
    echo
    echo "  0) Back"
    echo
    local c
    c="$(ask "Select option" "0")"
    case "$c" in
      1)
        systemctl status "${SERVICE_SERVER}.service" --no-pager || true
        echo
        systemctl status "${SERVICE_CLIENT}.service" --no-pager || true
        pause
        ;;
      2) systemctl restart "${SERVICE_SERVER}.service" || true; ok "Server restarted"; pause ;;
      3) systemctl restart "${SERVICE_CLIENT}.service" || true; ok "Client restarted"; pause ;;
      4) stop_disable "${SERVICE_SERVER}"; ok "Server disabled"; pause ;;
      5) stop_disable "${SERVICE_CLIENT}"; ok "Client disabled"; pause ;;
      6)
        echo "Config dir: ${INSTALL_DIR}"
        echo "Server cfg: ${INSTALL_DIR}/server.yaml"
        echo "Client cfg: ${INSTALL_DIR}/client.yaml"
        echo "Binary: ${BIN_PATH}"
        pause
        ;;
      0) return ;;
      *) ;;
    esac
  done
}

optimizer() {
  clear
  echo "═══════════════════════════════════════"
  echo "        SYSTEM OPTIMIZER"
  echo "═══════════════════════════════════════"
  echo
  warn "This is a minimal optimizer. (Safe defaults)"
  echo

  if ask_yn "Apply basic limits (nofile + sysctl)?" "Y"; then
    cat > /etc/security/limits.d/99-picotun.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    cat > /etc/sysctl.d/99-picotun.conf <<'EOF'
fs.file-max = 2097152
net.core.somaxconn = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
EOF
    sysctl --system >/dev/null 2>&1 || true
    ok "Optimizer applied"
  else
    warn "Skipped optimizer"
  fi

  pause
}

update_core() {
  clear
  echo "═══════════════════════════════════════"
  echo "            UPDATE CORE"
  echo "═══════════════════════════════════════"
  echo
  install_core
  ok "Core updated."
  echo
  warn "Restart services to apply new binary."
  pause
}

uninstall_all() {
  clear
  echo "═══════════════════════════════════════"
  echo "             UNINSTALL"
  echo "═══════════════════════════════════════"
  echo

  if ! ask_yn "Remove ${APP_NAME} services, configs, and binary?" "n"; then
    warn "Canceled"
    pause
    return
  fi

  stop_disable "$SERVICE_SERVER"
  stop_disable "$SERVICE_CLIENT"
  rm -f "/etc/systemd/system/${SERVICE_SERVER}.service" "/etc/systemd/system/${SERVICE_CLIENT}.service" || true
  systemd_reload

  rm -rf "$INSTALL_DIR" || true
  rm -f "$BIN_PATH" || true

  ok "Uninstalled."
  pause
}

main_menu() {
  while true; do
    clear
    echo "  1) Install Server"
    echo "  2) Install Client"
    echo "  3) Settings (Manage Services & Configs)"
    echo "  4) System Optimizer"
    echo "  5) Update Core (Re-build & Install)"
    echo "  6) Uninstall"
    echo
    echo "  0) Exit"
    echo
    local opt
    opt="$(ask "Select option" "0")"
    case "$opt" in
      1) install_server_flow ;;
      2) install_client_flow ;;
      3) settings_menu ;;
      4) optimizer ;;
      5) update_core ;;
      6) uninstall_all ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

need_root
main_menu
