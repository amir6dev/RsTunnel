#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
#  RsTunnel Manager (Dagger-Style Automation)
#  - Prefers prebuilt binary (no Go needed) ✅ (Iran-friendly)
#  - Falls back to building from source if needed
#  - Dependency detection (no reinstall if already present)
#  - Systemd services + YAML configs (Dagger-like prompts)
# ============================================================================
# Version: 1.3.0

APP_NAME="RsTunnel"
BIN_NAME="picotun"
REPO_OWNER="amir6dev"
REPO_NAME="RsTunnel"
REPO_BRANCH_DEFAULT="main"

# Where things live
INSTALL_DIR="/etc/${BIN_NAME}"
CONFIG_DIR="${INSTALL_DIR}"
BIN_PATH="/usr/local/bin/${BIN_NAME}"

SERVICE_SERVER="${BIN_NAME}-server"
SERVICE_CLIENT="${BIN_NAME}-client"

# If you publish releases, upload assets with these names:
#   picotun-linux-amd64
#   picotun-linux-arm64
RELEASE_ASSET_PREFIX="${BIN_NAME}-linux"

# If you MUST build from source:
GO_MIN_VERSION="1.22.1"

# ---------- Colors ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'

ok(){ echo -e "${GREEN}✓${NC} $*"; }
warn(){ echo -e "${YELLOW}!${NC} $*"; }
err(){ echo -e "${RED}✖${NC} $*"; }
info(){ echo -e "${CYAN}$*${NC}"; }
muted(){ echo -e "${GRAY}$*${NC}"; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run as root."
    exit 1
  fi
}

pause(){ read -r -p "Press Enter to return..." _; }

banner(){
  clear || true
  echo -e "${CYAN}***  ${APP_NAME}  ***${NC}"
  echo -e "${CYAN}_____________________________${NC}"
  echo -e "${CYAN}***  TELEGRAM : @DaggerConnect ***${NC}"
  echo -e "${CYAN}_____________________________${NC}"
  echo -e "${CYAN}***  ${APP_NAME} ***${NC}"
  echo
}

ask(){
  local prompt="$1" def="${2:-}"
  local v=""
  if [[ -n "$def" ]]; then
    read -r -p "${prompt} [${def}]: " v
    echo "${v:-$def}"
  else
    read -r -p "${prompt}: " v
    echo "$v"
  fi
}

ask_yn(){
  local prompt="$1" def="${2:-Y}"
  local v=""
  read -r -p "${prompt} [${def}/n]: " v
  v="${v:-$def}"
  [[ "$v" =~ ^[Yy]$ ]]
}

safe_cd_root(){
  cd / || true
}

detect_arch(){
  local m
  m="$(uname -m || true)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "amd64" ;;
  esac
}

have(){ command -v "$1" >/dev/null 2>&1; }

# ---------- Dependencies ----------
pkg_install(){
  local pkgs=("$@")
  if have apt-get; then
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  elif have yum; then
    yum install -y "${pkgs[@]}"
  elif have dnf; then
    dnf install -y "${pkgs[@]}"
  elif have apk; then
    apk add --no-cache "${pkgs[@]}"
  else
    err "No supported package manager found."
    exit 1
  fi
}

ensure_deps(){
  info "📦 Checking dependencies..."
  local miss=()
  for c in curl git tar; do
    have "$c" || miss+=("$c")
  done

  if ((${#miss[@]}==0)); then
    ok "Dependencies already installed"
    return 0
  fi

  warn "Installing missing: ${miss[*]}"
  pkg_install "${miss[@]}"
  ok "Dependencies installed"
}

# ---------- Iran-friendly core install ----------
# We try:
#  1) GitHub Releases asset (prebuilt)  ✅ recommended
#  2) Build from source (requires Go)    fallback
download_url(){
  local url="$1" out="$2"
  curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 180 "$url" -o "$out"
}

install_prebuilt_binary(){
  local arch asset tmp
  arch="$(detect_arch)"
  asset="${RELEASE_ASSET_PREFIX}-${arch}"

  info "⬇️  Installing core (prebuilt binary preferred)..."
  tmp="$(mktemp -d /tmp/picotun-bin.XXXXXX)"
  trap 'rm -rf "$tmp" 2>/dev/null || true' RETURN

  # Direct + proxies (some Iran servers need proxy for GitHub)
  local urls=(
    "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/${asset}"
    "https://mirror.ghproxy.com/https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/${asset}"
    "https://ghproxy.com/https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/${asset}"
  )

  local out="${tmp}/${BIN_NAME}"
  local got=0
  for u in "${urls[@]}"; do
    muted "   Downloading: $u"
    if download_url "$u" "$out"; then
      got=1
      break
    fi
  done

  if [[ "$got" -ne 1 ]]; then
    warn "Prebuilt binary not available (or blocked). Falling back to build-from-source."
    return 1
  fi

  chmod +x "$out"
  install -m 0755 "$out" "$BIN_PATH"
  ok "Installed binary to ${BIN_PATH}"
  return 0
}

# ---------- Go fallback install (for build-from-source) ----------
# Iran note: Go download may be blocked; we try package manager first.
go_version(){
  have go || { echo ""; return 0; }
  go version 2>/dev/null | awk '{print $3}' | sed 's/^go//'
}

ver_ge(){
  # return 0 if $1 >= $2 (simple semver-ish compare)
  python3 - <<'PY' "$1" "$2"
import sys
def norm(v):
    v=v.strip()
    if v.startswith("go"): v=v[2:]
    parts=[int(x) for x in v.split(".") if x.isdigit()]
    while len(parts)<3: parts.append(0)
    return parts[:3]
a=norm(sys.argv[1]); b=norm(sys.argv[2])
sys.exit(0 if a>=b else 1)
PY
}

install_go_from_pkg(){
  info "⬇️  Installing Go from package manager (Iran-friendly)..."
  if have apt-get; then
    pkg_install golang-go || return 1
  elif have yum; then
    pkg_install golang || return 1
  elif have dnf; then
    pkg_install golang || return 1
  elif have apk; then
    pkg_install go || return 1
  else
    return 1
  fi
  return 0
}

ensure_go(){
  info "⬇️  Checking Go..."
  local cur
  cur="$(go_version)"

  if [[ -n "$cur" ]] && ver_ge "$cur" "$GO_MIN_VERSION"; then
    ok "Go $cur is OK (>= $GO_MIN_VERSION)"
    return 0
  fi

  # Try package manager first (best for Iran servers)
  if install_go_from_pkg; then
    cur="$(go_version)"
    if [[ -n "$cur" ]] && ver_ge "$cur" "$GO_MIN_VERSION"; then
      ok "Go installed via package manager: $cur"
      return 0
    fi
    warn "Go from package manager is $cur (needs >= $GO_MIN_VERSION). Will try manual tarball only if you provide a mirror."
  fi

  # Manual tarball requires a reachable mirror (user can set GO_TARBALL_URL)
  if [[ -n "${GO_TARBALL_URL:-}" ]]; then
    local tmp arch tarball
    arch="$(detect_arch)"
    tarball="go${GO_MIN_VERSION}.linux-${arch}.tar.gz"
    tmp="$(mktemp -d /tmp/picotun-go.XXXXXX)"
    trap 'rm -rf "$tmp" 2>/dev/null || true' RETURN
    info "   Downloading Go from mirror (GO_TARBALL_URL)..."
    download_url "${GO_TARBALL_URL}" "${tmp}/${tarball}" || { err "Failed to download Go from GO_TARBALL_URL"; exit 1; }
    rm -rf /usr/local/go || true
    tar -C /usr/local -xzf "${tmp}/${tarball}"
    export PATH="$PATH:/usr/local/go/bin"
    cur="$(go_version)"
    if [[ -n "$cur" ]] && ver_ge "$cur" "$GO_MIN_VERSION"; then
      ok "Go installed from mirror: $cur"
      return 0
    fi
  fi

  err "Go is not available (>= $GO_MIN_VERSION)."
  echo
  echo "Iran-friendly options:"
  echo "  1) Publish prebuilt binaries in GitHub Releases (recommended) and rerun setup."
  echo "  2) Or set GO_TARBALL_URL to a reachable mirror, e.g.:"
  echo "     GO_TARBALL_URL='https://your-mirror/go${GO_MIN_VERSION}.linux-amd64.tar.gz' bash <(curl -fsSL .../setup.sh)"
  echo
  exit 1
}

clone_repo(){
  local repo_url="$1" branch="$2"
  safe_cd_root
  local builddir
  builddir="$(mktemp -d /tmp/picobuild.XXXXXX)"
  info "🌐 Cloning from GitHub ..."
  git clone --depth 1 --branch "$branch" "$repo_url" "$builddir" >/dev/null
  echo "$builddir"
}

build_from_source(){
  local repo_url="$1" branch="$2"
  ensure_deps
  ensure_go

  info "⬇️  Preparing source code..."
  local builddir
  builddir="$(clone_repo "$repo_url" "$branch")"
  trap 'rm -rf "$builddir" 2>/dev/null || true' RETURN

  info "📦 Downloading Libraries..."
  export GOFLAGS="-mod=mod"
  export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
  (cd "$builddir" && go mod download) || true
  (cd "$builddir" && go mod tidy) || true

  info "🔨 Building binary..."
  if [[ -d "${builddir}/cmd/picotun" ]]; then
    (cd "$builddir" && go build -trimpath -ldflags="-s -w" -o "${BIN_NAME}" ./cmd/picotun)
  else
    (cd "$builddir" && go build -trimpath -ldflags="-s -w" -o "${BIN_NAME}" .)
  fi

  [[ -f "${builddir}/${BIN_NAME}" ]] || { err "Build failed: binary not created"; exit 1; }

  install -m 0755 "${builddir}/${BIN_NAME}" "$BIN_PATH"
  ok "Installed binary to ${BIN_PATH}"
}

ensure_core(){
  local repo_url="$1" branch="$2"

  # If binary exists, keep it (Update Core menu handles updates)
  if [[ -x "$BIN_PATH" ]]; then
    ok "Core already installed (${BIN_PATH})"
    return 0
  fi

  # Try prebuilt binary (no Go needed)
  if install_prebuilt_binary; then
    return 0
  fi

  # Fallback build
  build_from_source "$repo_url" "$branch"
}

# ---------- systemd ----------
write_server_service(){
  local cfg="$1"
  cat > "/etc/systemd/system/${SERVICE_SERVER}.service" <<EOF
[Unit]
Description=${APP_NAME} Server Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH} -c ${cfg}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_client_service(){
  local cfg="$1"
  cat > "/etc/systemd/system/${SERVICE_CLIENT}.service" <<EOF
[Unit]
Description=${APP_NAME} Client Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH} -c ${cfg}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

systemd_reload(){
  systemctl daemon-reload
}

enable_start(){
  local svc="$1"
  systemctl enable --now "${svc}.service"
}

ua_by_choice(){
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

gen_psk(){
  # 16 chars
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16
}

# ---------- Flows ----------
install_server(){
  banner
  local repo_url branch
  repo_url="$(ask "Repo URL" "https://github.com/${REPO_OWNER}/${REPO_NAME}.git")"
  branch="$(ask "Repo branch" "${REPO_BRANCH_DEFAULT}")"

  ensure_deps
  ensure_core "$repo_url" "$branch"

  echo -e "${CYAN}═══════════════════════════════════════${NC}"
  echo -e "${CYAN}      SERVER CONFIGURATION${NC}"
  echo -e "${CYAN}═══════════════════════════════════════${NC}"
  echo

  local tunnel_port user_psk psk transport
  tunnel_port="$(ask "Tunnel Port" "2020")"
  user_psk="$(ask "Enter PSK (Pre-Shared Key) [Leave empty to generate]" "")"
  if [[ -z "$user_psk" ]]; then
    psk="$(gen_psk)"
    ok "Generated PSK: ${psk}"
  else
    psk="$user_psk"
  fi

  echo
  echo -e "${YELLOW}Select Transport:${NC}"
  echo "  1) httpsmux  - HTTPS Mimicry (Recommended)"
  echo "  2) httpmux   - HTTP Mimicry"
  echo "  3) wssmux    - WebSocket Secure (TLS)"
  echo "  4) wsmux     - WebSocket"
  echo "  5) kcpmux    - KCP (UDP based)"
  echo "  6) tcpmux    - Simple TCP"
  local ch
  ch="$(ask "Choice [1-6]" "2")"
  case "$ch" in
    1) transport="httpsmux" ;;
    2) transport="httpmux" ;;
    3) transport="wssmux" ;;
    4) transport="wsmux" ;;
    5) transport="kcpmux" ;;
    6) transport="tcpmux" ;;
    *) transport="httpmux" ;;
  esac

  echo
  echo -e "${CYAN}═══════════════════════════════════════${NC}"
  echo -e "${CYAN}      PORT MAPPINGS${NC}"
  echo -e "${CYAN}═══════════════════════════════════════${NC}"
  echo

  local maps_yaml=""
  local count=1
  while true; do
    echo -e "${YELLOW}Port Mapping #${count}${NC}"
    local bind_port target_port proto
    bind_port="$(ask "Bind Port (port on this server, e.g., 2222)" "")"
    target_port="$(ask "Target Port (destination port, e.g., 22)" "")"
    proto="$(ask "Protocol (tcp/udp/both)" "tcp")"
    maps_yaml+=$'  - type: '"${proto}"$'\n    bind: "0.0.0.0:'"${bind_port}"$'"\n    target: "127.0.0.1:'"${target_port}"$'"\n'
    ok "Mapping added: 0.0.0.0:${bind_port} → 127.0.0.1:${target_port} (${proto})"
    echo
    if ! ask_yn "Add another mapping?" "N"; then
      break
    fi
    count=$((count+1))
  done

  local optimize
  echo
  optimize="$(ask "Optimize system now?" "n")"
  # (optional optimizer hook later)

  mkdir -p "$CONFIG_DIR"
  local cfg="${CONFIG_DIR}/server.yaml"

  cat > "$cfg" <<EOF
mode: "server"
listen: "0.0.0.0:${tunnel_port}"
transport: "${transport}"
psk: "${psk}"
profile: "latency"
verbose: true

heartbeat: 2

maps:
$(echo -e "${maps_yaml}")

advanced:
  session_timeout: 15
  connection_timeout: 20

obfuscation:
  enabled: true
  min_padding: 8
  max_padding: 32
  min_delay_ms: 0
  max_delay_ms: 0
  burst_chance: 0

http_mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
  chunked_encoding: false
  session_cookie: true
  custom_headers:
    - "Accept-Language: en-US,en;q=0.9"
    - "Accept-Encoding: gzip, deflate, br"
EOF

  write_server_service "$cfg"
  systemd_reload
  enable_start "$SERVICE_SERVER"

  echo
  echo -e "${GREEN}═══════════════════════════════════════${NC}"
  echo -e "${GREEN}   ✓ Server configured${NC}"
  echo -e "${GREEN}═══════════════════════════════════════${NC}"
  echo
  echo -e "  Tunnel Port: ${YELLOW}${tunnel_port}${NC}"
  echo -e "  PSK: ${YELLOW}${psk}${NC}"
  echo -e "  Transport: ${YELLOW}${transport}${NC}"
  echo -e "  Config: ${YELLOW}${cfg}${NC}"
  echo
  pause
}

install_client(){
  banner
  local repo_url branch
  repo_url="$(ask "Repo URL" "https://github.com/${REPO_OWNER}/${REPO_NAME}.git")"
  branch="$(ask "Repo branch" "${REPO_BRANCH_DEFAULT}")"

  ensure_deps
  ensure_core "$repo_url" "$branch"

  echo -e "${CYAN}═══════════════════════════════════════${NC}"
  echo -e "${CYAN}      CLIENT CONFIGURATION${NC}"
  echo -e "${CYAN}═══════════════════════════════════════${NC}"
  echo

  echo "Configuration Mode:"
  echo "  1) Automatic - Optimized settings (Recommended)"
  echo "  2) Manual - Custom configuration"
  local mode_choice
  mode_choice="$(ask "Choice [1-2]" "2")"
  # (currently both behave same; keeps UX like Dagger)

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
  echo -e "${CYAN}═══════════════════════════════════════${NC}"
  echo -e "${CYAN}      CONNECTION PATHS${NC}"
  echo -e "${CYAN}═══════════════════════════════════════${NC}"
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
  aggressive="false"
  if ask_yn "Enable aggressive pool?" "N"; then aggressive="true"; fi
  retry="$(ask "Retry interval (seconds)" "3")"
  dial_timeout="$(ask "Dial timeout (seconds)" "10")"

  echo
  echo -e "${CYAN}═══════════════════════════════════════${NC}"
  echo -e "${CYAN}      HTTP MIMICRY SETTINGS${NC}"
  echo -e "${CYAN}═══════════════════════════════════════${NC}"
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

  chunked="true"
  if ! ask_yn "Enable chunked encoding?" "Y"; then chunked="false"; fi
  session_cookie="true"
  if ! ask_yn "Enable session cookies?" "Y"; then session_cookie="false"; fi

  local verbose="false"
  if ask_yn "Enable verbose logging?" "N"; then verbose="true"; fi

  mkdir -p "$CONFIG_DIR"
  local cfg="${CONFIG_DIR}/client.yaml"

  cat > "$cfg" <<EOF
mode: "client"
psk: "${psk}"
profile: "${profile}"
verbose: ${verbose}

paths:
  - transport: "${transport}"
    addr: "${addr}"
    connection_pool: ${pool}
    aggressive_pool: ${aggressive}
    retry_interval: ${retry}
    dial_timeout: ${dial_timeout}

obfuscation:
  enabled: ${obfs_enabled}
  min_padding: 16
  max_padding: 512
  min_delay_ms: 5
  max_delay_ms: 50
  burst_chance: 0.15

http_mimic:
  fake_domain: "${fake_domain}"
  fake_path: "${fake_path}"
  user_agent: "${ua}"
  chunked_encoding: ${chunked}
  session_cookie: ${session_cookie}
  custom_headers:
    - "X-Requested-With: XMLHttpRequest"
    - "Referer: https://${fake_domain}/"
EOF

  write_client_service "$cfg"
  systemd_reload
  enable_start "$SERVICE_CLIENT"

  echo
  ok "Client installation complete!"
  echo
  echo "  Profile: ${profile}"
  echo "  Obfuscation: ${obfs_enabled}"
  echo
  echo "  Config: ${cfg}"
  echo "  View logs: journalctl -u ${SERVICE_CLIENT} -f"
  echo
  pause
}

settings_menu(){
  while true; do
    banner
    echo "═══════════════════════════════════════"
    echo "     SETTINGS (Manage Services & Configs)"
    echo "═══════════════════════════════════════"
    echo
    echo "  1) Status"
    echo "  2) Restart Server"
    echo "  3) Restart Client"
    echo "  4) Stop/Disable Server"
    echo "  5) Stop/Disable Client"
    echo "  6) Show paths"
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
      4) systemctl disable --now "${SERVICE_SERVER}.service" 2>/dev/null || true; ok "Server disabled"; pause ;;
      5) systemctl disable --now "${SERVICE_CLIENT}.service" 2>/dev/null || true; ok "Client disabled"; pause ;;
      6)
        echo "Binary: ${BIN_PATH}"
        echo "Config dir: ${CONFIG_DIR}"
        echo "Server cfg: ${CONFIG_DIR}/server.yaml"
        echo "Client cfg: ${CONFIG_DIR}/client.yaml"
        pause
        ;;
      0) return ;;
      *) ;;
    esac
  done
}

update_core(){
  banner
  local repo_url branch
  repo_url="$(ask "Repo URL" "https://github.com/${REPO_OWNER}/${REPO_NAME}.git")"
  branch="$(ask "Repo branch" "${REPO_BRANCH_DEFAULT}")"

  ensure_deps

  # Try prebuilt first; if fails, build
  if install_prebuilt_binary; then
    ok "Core updated."
    warn "Restart services to apply."
    pause
    return
  fi

  build_from_source "$repo_url" "$branch"
  ok "Core updated (built from source)."
  warn "Restart services to apply."
  pause
}

uninstall_all(){
  banner
  if ! ask_yn "Remove ${APP_NAME} services, configs, and binary?" "n"; then
    warn "Canceled"
    pause
    return
  fi
  systemctl disable --now "${SERVICE_SERVER}.service" 2>/dev/null || true
  systemctl disable --now "${SERVICE_CLIENT}.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_SERVER}.service" "/etc/systemd/system/${SERVICE_CLIENT}.service" || true
  systemctl daemon-reload || true
  rm -rf "$INSTALL_DIR" || true
  rm -f "$BIN_PATH" || true
  ok "Uninstalled."
  pause
}

main_menu(){
  while true; do
    banner
    echo "  1) Install Server"
    echo "  2) Install Client"
    echo "  3) Settings (Manage Services & Configs)"
    echo "  4) Update Core (Prebuilt preferred)"
    echo "  5) Uninstall"
    echo
    echo "  0) Exit"
    echo
    local opt
    opt="$(ask "Select option" "0")"
    case "$opt" in
      1) install_server ;;
      2) install_client ;;
      3) settings_menu ;;
      4) update_core ;;
      5) uninstall_all ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

need_root
main_menu
