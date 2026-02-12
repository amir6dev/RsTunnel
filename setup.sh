#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
#  RsTunnel Manager (Dagger-style installer)
#  - Installs/updates core binary
#  - Generates Dagger-like YAMLs
#  - Creates systemd services
# ============================================================================

APP_NAME="picotun"
REPO_URL="https://github.com/amir6dev/RsTunnel.git"
INSTALL_DIR="/usr/local/bin"
BIN_PATH="${INSTALL_DIR}/${APP_NAME}"
CONFIG_DIR="/etc/picotun"
SYSTEMD_DIR="/etc/systemd/system"

GO_VERSION_REQUIRED="1.22.1"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}✖ Please run as root.${NC}"
    exit 1
  fi
}

pause() {
  echo
  read -r -p "Press Enter to return..." _
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_deps() {
  echo -e "${YELLOW}📦 Checking dependencies...${NC}"
  local missing=()
  for c in curl wget git tar systemctl; do
    have_cmd "$c" || missing+=("$c")
  done

  # package manager
  local pm=""
  if have_cmd apt-get; then pm="apt-get"
  elif have_cmd yum; then pm="yum"
  elif have_cmd dnf; then pm="dnf"
  elif have_cmd apk; then pm="apk"
  fi

  if (( ${#missing[@]} == 0 )); then
    echo -e "${GREEN}✓ Dependencies already installed${NC}"
    return 0
  fi

  if [[ -z "$pm" ]]; then
    echo -e "${RED}✖ Missing commands: ${missing[*]} and no supported package manager found.${NC}"
    exit 1
  fi

  echo -e "${YELLOW}📦 Installing: ${missing[*]}...${NC}"
  case "$pm" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null
      apt-get install -y curl wget git tar ca-certificates >/dev/null
      ;;
    yum|dnf)
      "$pm" install -y curl wget git tar ca-certificates >/dev/null
      ;;
    apk)
      apk add --no-cache curl wget git tar ca-certificates >/dev/null
      ;;
  esac
  echo -e "${GREEN}✓ Dependencies installed${NC}"
}

ver_ge() {
  # returns 0 if $1 >= $2 (semver-ish, dot-separated)
  local IFS=.
  read -r -a a <<< "${1#go}"
  read -r -a b <<< "${2#go}"
  local i max=${#a[@]}
  (( ${#b[@]} > max )) && max=${#b[@]}
  for ((i=0;i<max;i++)); do
    local ai=${a[i]:-0} bi=${b[i]:-0}
    if ((10#$ai > 10#$bi)); then return 0; fi
    if ((10#$ai < 10#$bi)); then return 1; fi
  done
  return 0
}

install_go() {
  echo -e "${YELLOW}⬇️  Checking Go...${NC}"
  if have_cmd go; then
    local gv
    gv="$(go version | awk '{print $3}')"
    if ver_ge "$gv" "go${GO_VERSION_REQUIRED}"; then
      echo -e "${GREEN}✓ Go environment ready (${gv})${NC}"
      return 0
    fi
    echo -e "${YELLOW}↻ Go is old (${gv}), updating to ${GO_VERSION_REQUIRED}...${NC}"
  else
    echo -e "${YELLOW}⬇️  Installing Go ${GO_VERSION_REQUIRED}...${NC}"
  fi

  local arch os
  os="linux"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo -e "${RED}✖ Unsupported arch: ${arch}${NC}"; exit 1 ;;
  esac

  local tarball="go${GO_VERSION_REQUIRED}.${os}-${arch}.tar.gz"
  local url="https://go.dev/dl/${tarball}"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # Iran-safe: try multiple mirrors
  if ! curl -fsSL "$url" -o "${tmp}/${tarball}"; then
    if ! curl -fsSL "https://dl.google.com/go/${tarball}" -o "${tmp}/${tarball}"; then
      echo -e "${RED}✖ Failed to download Go.${NC}"
      exit 1
    fi
  fi

  rm -rf /usr/local/go
  tar -C /usr/local -xzf "${tmp}/${tarball}"
  export PATH="/usr/local/go/bin:${PATH}"

  if ! have_cmd go; then
    echo -e "${RED}✖ Go install failed.${NC}"
    exit 1
  fi
  echo -e "${GREEN}✓ Go environment ready ($(go version | awk '{print $3}'))${NC}"
}

build_and_install_core() {
  echo -e "${YELLOW}⬇️  Preparing source code...${NC}"

  # avoid getcwd issues if caller dir disappears
  cd /

  local build_dir
  build_dir="$(mktemp -d /tmp/picobuild.XXXXXX)"
  trap 'rm -rf "$build_dir"' RETURN

  echo -e "${YELLOW}🌐 Cloning from GitHub ...${NC}"
  git clone --depth 1 "$REPO_URL" "$build_dir" >/dev/null 2>&1 || {
    echo -e "${RED}✖ Clone failed. Check internet connection.${NC}"
    exit 1
  }

  cd "$build_dir/RsTunnel" 2>/dev/null || cd "$build_dir" || {
    echo -e "${RED}✖ Failed to enter repo directory.${NC}"
    exit 1
  }

  echo -e "${YELLOW}🔧 Fixing build environment (Iran Safe)...${NC}"
  # Make sure module can download deps even if system sets readonly
  export GOFLAGS="-mod=mod"
  export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"

  echo -e "${YELLOW}📦 Downloading Libraries...${NC}"
  go mod download >/dev/null 2>&1 || true
  go mod tidy >/dev/null

  echo -e "${YELLOW}🔨 Building binary...${NC}"
  if [[ -d "cmd/picotun" ]]; then
    go build -trimpath -ldflags="-s -w" -o "${APP_NAME}" ./cmd/picotun
  else
    go build -trimpath -ldflags="-s -w" -o "${APP_NAME}" .
  fi

  [[ -f "${APP_NAME}" ]] || { echo -e "${RED}✖ Build failed.${NC}"; exit 1; }

  install -d "$INSTALL_DIR"
  install -m 0755 "${APP_NAME}" "$BIN_PATH"

  echo -e "${GREEN}✓ Core installed: ${BIN_PATH}${NC}"
}

write_systemd_service() {
  local mode="$1" # server|client
  local svc="picotun-${mode}.service"
  local cfg="${CONFIG_DIR}/${mode}.yaml"

  cat > "${SYSTEMD_DIR}/${svc}" <<EOF
[Unit]
Description=RsTunnel ${mode^} Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${CONFIG_DIR}
ExecStart=${BIN_PATH} -config ${cfg}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${svc}" >/dev/null
}

ua_menu() {
  echo
  echo "Select User-Agent:"
  echo "  1) Chrome Windows (default)"
  echo "  2) Firefox Windows"
  echo "  3) Chrome macOS"
  echo "  4) Safari macOS"
  echo "  5) Chrome Android"
  echo "  6) Custom"
  read -r -p "Choice [1-6]: " ch
  case "${ch:-1}" in
    2) echo "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0" ;;
    3) echo "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" ;;
    4) echo "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" ;;
    5) echo "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36" ;;
    6) read -r -p "Enter custom UA: " ua; echo "${ua:-Mozilla/5.0}" ;;
    *) echo "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" ;;
  esac
}

install_server() {
  echo
  echo -e "${CYAN}═══════════════════════════════════════${NC}"
  echo -e "${CYAN}      SERVER CONFIGURATION${NC}"
  echo -e "${CYAN}═══════════════════════════════════════${NC}"

  read -r -p "Tunnel Port [2020]: " tport
  tport="${tport:-2020}"
  read -r -s -p "Enter PSK (Pre-Shared Key): " psk; echo
  [[ -n "${psk}" ]] || { echo -e "${RED}✖ PSK required${NC}"; return; }

  echo
  echo "Select Transport:"
  echo "  1) httpmux   - HTTP Mimicry"
  read -r -p "Choice [1]: " _; transport="httpmux"

  echo
  echo -e "${CYAN}PORT MAPPINGS${NC}"
  local maps=()
  local idx=1
  while true; do
    echo
    echo "Port Mapping #${idx}"
    read -r -p "Bind Port (port on this server, e.g., 2222): " bport
    read -r -p "Target Port (destination port, e.g., 22): " tport2
    read -r -p "Protocol (tcp/udp/both) [tcp]: " proto
    proto="${proto:-tcp}"
    [[ -n "${bport}" && -n "${tport2}" ]] || { echo -e "${RED}✖ Invalid ports${NC}"; continue; }
    maps+=("${proto}|0.0.0.0:${bport}|127.0.0.1:${tport2}")
    echo -e "${GREEN}✓ Mapping added: 0.0.0.0:${bport} → 127.0.0.1:${tport2} (${proto})${NC}"
    read -r -p "Add another mapping? [y/N]: " yn
    [[ "${yn}" =~ ^[Yy]$ ]] || break
    idx=$((idx+1))
  done

  # http mimic defaults (dagger-style)
  echo
  echo -e "${CYAN}HTTP MIMICRY SETTINGS${NC}"
  read -r -p "Fake domain (e.g., www.google.com) [www.google.com]: " fdom
  fdom="${fdom:-www.google.com}"
  read -r -p "Fake path (e.g., /search) [/search]: " fpath
  fpath="${fpath:-/search}"
  local ua; ua="$(ua_menu)"
  read -r -p "Enable chunked encoding? [y/N]: " chunk
  [[ "${chunk}" =~ ^[Yy]$ ]] && chunked=true || chunked=false
  read -r -p "Enable session cookies? [Y/n]: " sess
  [[ "${sess:-Y}" =~ ^[Nn]$ ]] && session_cookie=false || session_cookie=true

  # obfs defaults for server (dagger sample)
  local obfs_enabled=true
  local min_pad=8 max_pad=32 min_delay=0 max_delay=0 burst=0

  install -d "$CONFIG_DIR"

  local cfg="${CONFIG_DIR}/server.yaml"
  {
    echo 'mode: "server"'
    echo "listen: "0.0.0.0:${tport}""
    echo "transport: "${transport}""
    echo "psk: "${psk}""
    echo 'profile: "latency"'
    echo 'verbose: true'
    echo
    echo "heartbeat: 2"
    echo
    echo "maps:"
    for m in "${maps[@]}"; do
      IFS='|' read -r proto bind target <<< "$m"
      echo "  - type: ${proto}"
      echo "    bind: "${bind}""
      echo "    target: "${target}""
    done
    echo
    echo "obfuscation:"
    echo "  enabled: ${obfs_enabled}"
    echo "  min_padding: ${min_pad}"
    echo "  max_padding: ${max_pad}"
    echo "  min_delay_ms: ${min_delay}"
    echo "  max_delay_ms: ${max_delay}"
    echo "  burst_chance: ${burst}"
    echo
    echo "http_mimic:"
    echo "  fake_domain: "${fdom}""
    echo "  fake_path: "${fpath}""
    echo "  user_agent: "${ua}""
    echo "  chunked_encoding: false"
    echo "  session_cookie: ${session_cookie}"
    echo "  custom_headers:"
    echo "    - "Accept-Language: en-US,en;q=0.9""
    echo "    - "Accept-Encoding: gzip, deflate, br""
  } > "$cfg"

  write_systemd_service "server"
  echo -e "${GREEN}✓ Systemd service for Server created: picotun-server.service${NC}"
  echo
  echo -e "${CYAN}═══════════════════════════════════════${NC}"
  echo -e "${GREEN}   ✓ Server configured${NC}"
  echo -e "${CYAN}═══════════════════════════════════════${NC}"
  echo
  echo "  Tunnel Port: ${tport}"
  echo "  PSK: ${psk}"
  echo "  Transport: ${transport}"
  echo "  Config: ${cfg}"
  pause
}

install_client() {
  echo
  echo -e "${CYAN}═══════════════════════════════════════${NC}"
  echo -e "${CYAN}      CLIENT CONFIGURATION${NC}"
  echo -e "${CYAN}═══════════════════════════════════════${NC}"

  echo
  echo "Configuration Mode:"
  echo "  1) Automatic - Optimized settings (Recommended)"
  echo "  2) Manual - Custom configuration"
  read -r -p "Choice [1-2]: " mode
  mode="${mode:-1}"

  read -r -s -p "Enter PSK (must match server): " psk; echo
  [[ -n "${psk}" ]] || { echo -e "${RED}✖ PSK required${NC}"; return; }

  echo
  echo "Select Performance Profile:"
  echo "  1) balanced      - Standard balanced performance (Recommended)"
  echo "  2) aggressive    - High speed, aggressive settings"
  echo "  3) latency       - Optimized for low latency"
  echo "  4) cpu-efficient - Low CPU usage"
  echo "  5) gaming        - Optimized for gaming"
  read -r -p "Choice [1-5]: " prof
  case "${prof:-1}" in
    2) profile="aggressive" ;;
    3) profile="latency" ;;
    4) profile="cpu-efficient" ;;
    5) profile="gaming" ;;
    *) profile="balanced" ;;
  esac

  read -r -p "Enable Traffic Obfuscation? [Y/n]: " ob
  [[ "${ob:-Y}" =~ ^[Nn]$ ]] && obfs_enabled=false || obfs_enabled=true

  # default obfs client like dagger sample
  min_pad=16; max_pad=512; min_delay=5; max_delay=50; burst="0.15"

  echo
  echo -e "${CYAN}CONNECTION PATHS${NC}"

  # only one path for now (dagger style supports multiple; we keep one but same prompts)
  read -r -p "Server address with Tunnel Port (e.g., 1.2.3.4:4000): " addr
  read -r -p "Connection pool size [2]: " pool
  pool="${pool:-2}"
  read -r -p "Enable aggressive pool? [y/N]: " ag
  [[ "${ag}" =~ ^[Yy]$ ]] && aggressive=true || aggressive=false
  read -r -p "Retry interval (seconds) [3]: " retry
  retry="${retry:-3}"
  read -r -p "Dial timeout (seconds) [10]: " dial
  dial="${dial:-10}"

  echo
  echo -e "${CYAN}HTTP MIMICRY SETTINGS${NC}"
  read -r -p "Fake domain (e.g., www.google.com) [www.google.com]: " fdom
  fdom="${fdom:-www.google.com}"
  read -r -p "Fake path (e.g., /search) [/search]: " fpath
  fpath="${fpath:-/search}"
  ua="$(ua_menu)"
  read -r -p "Enable chunked encoding? [Y/n]: " chunk
  [[ "${chunk:-Y}" =~ ^[Nn]$ ]] && chunked=false || chunked=true
  read -r -p "Enable session cookies? [Y/n]: " sess
  [[ "${sess:-Y}" =~ ^[Nn]$ ]] && session_cookie=false || session_cookie=true

  install -d "$CONFIG_DIR"

  local cfg="${CONFIG_DIR}/client.yaml"
  {
    echo 'mode: "client"'
    echo "psk: "${psk}""
    echo "profile: "${profile}""
    echo "verbose: false"
    echo
    echo "paths:"
    echo "  - transport: "httpmux""
    echo "    addr: "${addr}""
    echo "    connection_pool: ${pool}"
    echo "    aggressive_pool: ${aggressive}"
    echo "    retry_interval: ${retry}"
    echo "    dial_timeout: ${dial}"
    echo
    echo "obfuscation:"
    echo "  enabled: ${obfs_enabled}"
    echo "  min_padding: ${min_pad}"
    echo "  max_padding: ${max_pad}"
    echo "  min_delay_ms: ${min_delay}"
    echo "  max_delay_ms: ${max_delay}"
    echo "  burst_chance: ${burst}"
    echo
    echo "http_mimic:"
    echo "  fake_domain: "${fdom}""
    echo "  fake_path: "${fpath}""
    echo "  user_agent: "${ua}""
    echo "  chunked_encoding: ${chunked}"
    echo "  session_cookie: ${session_cookie}"
    echo "  custom_headers:"
    echo "    - "X-Requested-With: XMLHttpRequest""
    echo "    - "Referer: https://www.google.com/""
  } > "$cfg"

  write_systemd_service "client"
  echo -e "${GREEN}✓ Systemd service for Client created: picotun-client.service${NC}"
  echo
  echo -e "${CYAN}═══════════════════════════════════════${NC}"
  echo -e "${GREEN}   ✓ Client installation complete!${NC}"
  echo -e "${CYAN}═══════════════════════════════════════${NC}"
  echo
  echo "Important Info:"
  echo "  Profile: ${profile}"
  echo "  Obfuscation: ${obfs_enabled}"
  echo
  echo "  Config: ${cfg}"
  echo "  View logs: journalctl -u picotun-client -f"
  pause
}

settings_menu() {
  while true; do
    echo
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}   Settings (Manage Services & Configs)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo
    echo "  1) Server status"
    echo "  2) Client status"
    echo "  3) Restart server"
    echo "  4) Restart client"
    echo "  5) Stop server"
    echo "  6) Stop client"
    echo "  7) View server config path"
    echo "  8) View client config path"
    echo "  0) Back"
    read -r -p "Select option: " o
    case "${o:-0}" in
      1) systemctl status picotun-server --no-pager || true; pause ;;
      2) systemctl status picotun-client --no-pager || true; pause ;;
      3) systemctl restart picotun-server || true; echo -e "${GREEN}✓ restarted${NC}"; pause ;;
      4) systemctl restart picotun-client || true; echo -e "${GREEN}✓ restarted${NC}"; pause ;;
      5) systemctl stop picotun-server || true; echo -e "${GREEN}✓ stopped${NC}"; pause ;;
      6) systemctl stop picotun-client || true; echo -e "${GREEN}✓ stopped${NC}"; pause ;;
      7) echo "${CONFIG_DIR}/server.yaml"; pause ;;
      8) echo "${CONFIG_DIR}/client.yaml"; pause ;;
      0) return ;;
      *) echo -e "${YELLOW}Invalid option${NC}" ;;
    esac
  done
}

optimizer() {
  echo -e "${YELLOW}⚙️  System optimizer (basic) ...${NC}"
  sysctl -w net.core.somaxconn=4096 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
  echo -e "${GREEN}✓ Done${NC}"
  pause
}

update_core() {
  ensure_deps
  install_go
  build_and_install_core
  systemctl restart picotun-server 2>/dev/null || true
  systemctl restart picotun-client 2>/dev/null || true
  pause
}

uninstall_all() {
  echo -e "${YELLOW}Uninstalling...${NC}"
  systemctl disable --now picotun-server 2>/dev/null || true
  systemctl disable --now picotun-client 2>/dev/null || true
  rm -f "${SYSTEMD_DIR}/picotun-server.service" "${SYSTEMD_DIR}/picotun-client.service"
  systemctl daemon-reload || true
  rm -f "${BIN_PATH}"
  rm -rf "${CONFIG_DIR}"
  echo -e "${GREEN}✓ Uninstalled${NC}"
  pause
}

main_menu() {
  while true; do
    clear || true
    echo
    echo -e "${CYAN}***  RsTunnel  ***${NC}"
    echo "_____________________________"
    echo "***  Dagger-style Installer ***"
    echo "_____________________________"
    echo
    echo "  1) Install Server"
    echo "  2) Install Client"
    echo "  3) Settings (Manage Services & Configs)"
    echo "  4) System Optimizer"
    echo "  5) Update Core (Re-download & Build)"
    echo "  6) Uninstall"
    echo
    echo "  0) Exit"
    echo
    read -r -p "Select option: " opt
    case "${opt:-0}" in
      1) ensure_deps; install_go; build_and_install_core; install_server ;;
      2) ensure_deps; install_go; build_and_install_core; install_client ;;
      3) settings_menu ;;
      4) optimizer ;;
      5) update_core ;;
      6) uninstall_all ;;
      0) exit 0 ;;
      *) echo -e "${YELLOW}Invalid option${NC}"; sleep 1 ;;
    esac
  done
}

need_root
main_menu
