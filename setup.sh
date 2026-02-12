#!/usr/bin/env bash
set -euo pipefail

# ========= Colors =========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========= Project Paths =========
APP_NAME="picotun"

INSTALL_DIR="/usr/local/bin"
BIN_PATH="${INSTALL_DIR}/${APP_NAME}"

CONFIG_DIR="/etc/picotun"
SERVER_CFG="${CONFIG_DIR}/server.yaml"
CLIENT_CFG="${CONFIG_DIR}/client.yaml"

SYSTEMD_DIR="/etc/systemd/system"
SERVER_SVC="picotun-server"
CLIENT_SVC="picotun-client"

# Repo (your project)
REPO_URL="https://github.com/amir6dev/RsTunnel.git"
BUILD_DIR="/tmp/picobuild"

say() { echo -e "${CYAN}➤${NC} $*"; }
ok()  { echo -e "${GREEN}✓${NC} $*"; }
warn(){ echo -e "${YELLOW}⚠${NC} $*"; }
die() { echo -e "${RED}✖${NC} $*"; exit 1; }

show_banner() {
  echo -e "${CYAN}"
  echo -e "${GREEN}*** RsTunnel / PicoTun  ***${NC}"
  echo -e "${CYAN}Repo: ${NC}${REPO_URL}"
  echo -e "${CYAN}=================================${NC}"
  echo ""
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (use sudo)."
  fi
}

install_deps() {
  say "Installing dependencies..."
  if command -v apt &>/dev/null; then
    apt update -qq
    apt install -y git curl ca-certificates tar >/dev/null 2>&1
  elif command -v yum &>/dev/null; then
    yum install -y git curl ca-certificates tar >/dev/null 2>&1
  else
    die "Unsupported package manager (need apt or yum)."
  fi
  ok "Dependencies installed"
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "Unsupported arch: $arch" ;;
  esac
}

install_go_new() {
  # Updated to Go 1.22.5 to avoid 404 errors with older versions
  local GO_VERSION="1.22.5"

  if command -v go >/dev/null 2>&1; then
    # Check if version is recent enough (1.21+)
    if go version | grep -E "go1\.(2[1-9]|[3-9][0-9])"; then
      ok "Go already installed: $(go version)"
      return
    fi
    warn "Go exists but is old: $(go version)"
  fi

  say "Installing Go ${GO_VERSION}..."
  local arch url
  arch="$(detect_arch)"
  url="https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz"

  rm -rf /usr/local/go
  # Added -L to follow redirects if needed
  if ! curl -fsSL "$url" -o /tmp/go.tgz; then
     die "Failed to download Go from $url. Check internet connection."
  fi
  
  tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz

  export PATH="/usr/local/go/bin:${PATH}"
  
  # Verify installation
  if ! /usr/local/go/bin/go version >/dev/null 2>&1; then
     die "Go installation failed."
  fi
  
  ok "Go installed: $(/usr/local/go/bin/go version)"
}

clone_repo() {
  say "Cloning source code..."
  rm -rf "$BUILD_DIR"
  git clone --depth 1 "$REPO_URL" "$BUILD_DIR" >/dev/null
  ok "Cloned to $BUILD_DIR"
}

build_binary() {
  say "Building ${APP_NAME} from source..."

  export PATH="/usr/local/go/bin:${PATH}"
  export GOPROXY=direct
  export GOSUMDB=off

  # Adjust build path based on repo structure
  if [[ -d "${BUILD_DIR}/PicoTun" ]]; then
    cd "${BUILD_DIR}/PicoTun"
    /usr/local/go/bin/go mod tidy
    CGO_ENABLED=0 /usr/local/go/bin/go build -o "${BUILD_DIR}/${APP_NAME}" ./cmd/picotun
  else
    cd "${BUILD_DIR}"
    /usr/local/go/bin/go mod tidy
    CGO_ENABLED=0 /usr/local/go/bin/go build -o "${BUILD_DIR}/${APP_NAME}" ./cmd/picotun
  fi

  if [[ ! -f "${BUILD_DIR}/${APP_NAME}" ]]; then
      die "Build failed! Binary not found."
  fi

  ok "Build done: ${BUILD_DIR}/${APP_NAME}"
}

install_binary() {
  say "Installing binary..."
  install -m 0755 "${BUILD_DIR}/${APP_NAME}" "${BIN_PATH}"
  ok "Installed: ${BIN_PATH}"
}

ensure_config_dir() {
  mkdir -p "${CONFIG_DIR}"
}

write_default_server_config_if_missing() {
  ensure_config_dir
  if [[ -f "${SERVER_CFG}" ]]; then
    ok "Server config exists: ${SERVER_CFG}"
    return
  fi

  cat > "${SERVER_CFG}" <<'YAML'
mode: "server"
listen: "0.0.0.0:1010"
psk: ""

mimic:
  fake_domain: ""
  fake_path: ""
  user_agent: "Mozilla/5.0"
  custom_headers: []
  session_cookie: true

obfs:
  enabled: true
  min_padding: 8
  max_padding: 64
  min_delay: 0
  max_delay: 25
  burst_chance: 0

forward:
  tcp:
    - "1412->127.0.0.1:1412"
  udp: []
YAML

  ok "Created default server config: ${SERVER_CFG}"
}

write_default_client_config_if_missing() {
  ensure_config_dir
  if [[ -f "${CLIENT_CFG}" ]]; then
    ok "Client config exists: ${CLIENT_CFG}"
    return
  fi

  cat > "${CLIENT_CFG}" <<'YAML'
mode: "client"
server_url: "http://SERVER_IP:1010/tunnel"
session_id: "default"
psk: ""

mimic:
  fake_domain: ""
  fake_path: ""
  user_agent: "Mozilla/5.0"
  custom_headers: []
  session_cookie: true

obfs:
  enabled: true
  min_padding: 8
  max_padding: 64
  min_delay: 0
  max_delay: 25
  burst_chance: 0
YAML

  ok "Created default client config: ${CLIENT_CFG}"
}

create_systemd_service() {
  local mode="$1" # server|client
  local svc cfg

  if [[ "$mode" == "server" ]]; then
    svc="${SERVER_SVC}"
    cfg="${SERVER_CFG}"
  else
    svc="${CLIENT_SVC}"
    cfg="${CLIENT_CFG}"
  fi

  say "Creating systemd service: ${svc}"

  cat > "${SYSTEMD_DIR}/${svc}.service" <<EOF
[Unit]
Description=RsTunnel PicoTun (${mode})
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${CONFIG_DIR}
ExecStart=${BIN_PATH} -config ${cfg}
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  ok "Service created: ${svc}.service"
}

install_server_flow() {
  show_banner
  install_deps
  install_go_new
  clone_repo
  build_binary
  install_binary
  write_default_server_config_if_missing
  create_systemd_service "server"

  systemctl enable --now "${SERVER_SVC}" >/dev/null 2>&1 || true
  ok "Server installed + started"
  echo ""
  systemctl status "${SERVER_SVC}" --no-pager || true
  echo ""
  read -r -p "Press Enter to return..." _
}

install_client_flow() {
  show_banner
  install_deps
  install_go_new
  clone_repo
  build_binary
  install_binary
  write_default_client_config_if_missing
  create_systemd_service "client"

  systemctl enable --now "${CLIENT_SVC}" >/dev/null 2>&1 || true
  ok "Client installed + started"
  echo ""
  systemctl status "${CLIENT_SVC}" --no-pager || true
  echo ""
  read -r -p "Press Enter to return..." _
}

service_management() {
  local mode="$1" # server|client
  local svc cfg title

  if [[ "$mode" == "server" ]]; then
    svc="${SERVER_SVC}"
    cfg="${SERVER_CFG}"
    title="SERVER MANAGEMENT"
  else
    svc="${CLIENT_SVC}"
    cfg="${CLIENT_CFG}"
    title="CLIENT MANAGEMENT"
  fi

  while true; do
    show_banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}         ${title}${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo "  1) Start"
    echo "  2) Stop"
    echo "  3) Restart"
    echo "  4) Status"
    echo "  5) Logs (Live)"
    echo "  6) Enable Auto-start"
    echo "  7) Disable Auto-start"
    echo ""
    echo "  8) View Config"
    echo "  9) Edit Config"
    echo "  10) Delete Config & Service"
    echo ""
    echo "  0) Back"
    echo ""
    read -r -p "Select option: " c

    case "${c:-}" in
      1) systemctl start "$svc" || true; ok "Started"; sleep 1 ;;
      2) systemctl stop "$svc" || true; ok "Stopped"; sleep 1 ;;
      3) systemctl restart "$svc" || true; ok "Restarted"; sleep 1 ;;
      4) systemctl status "$svc" --no-pager || true; read -r -p "Press Enter..." _ ;;
      5) journalctl -u "$svc" -f ;;
      6) systemctl enable "$svc" >/dev/null 2>&1 || true; ok "Auto-start enabled"; sleep 1 ;;
      7) systemctl disable "$svc" >/dev/null 2>&1 || true; ok "Auto-start disabled"; sleep 1 ;;
      8)
        if [[ -f "$cfg" ]]; then
          cat "$cfg"
        else
          warn "Config not found: $cfg"
        fi
        read -r -p "Press Enter..." _
        ;;
      9)
        if [[ -f "$cfg" ]]; then
          ${EDITOR:-nano} "$cfg"
          echo ""
          read -r -p "Restart service to apply changes? [y/N]: " r
          if [[ "$r" =~ ^[Yy]$ ]]; then
            systemctl restart "$svc" || true
            ok "Service restarted"
            sleep 1
          fi
        else
          warn "Config not found: $cfg"
          sleep 1
        fi
        ;;
      10)
        read -r -p "Delete ${mode} config and service? [y/N]: " y
        if [[ "$y" =~ ^[Yy]$ ]]; then
          systemctl stop "$svc" >/dev/null 2>&1 || true
          systemctl disable "$svc" >/dev/null 2>&1 || true
          rm -f "${SYSTEMD_DIR}/${svc}.service"
          rm -f "$cfg"
          systemctl daemon-reload
          ok "Deleted ${mode} config + service"
          sleep 1
        fi
        ;;
      0) break ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

settings_menu() {
  while true; do
    show_banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}            SETTINGS MENU${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo "  1) Manage Server"
    echo "  2) Manage Client"
    echo ""
    echo "  0) Back"
    echo ""
    read -r -p "Select option: " c
    case "${c:-}" in
      1) service_management "server" ;;
      2) service_management "client" ;;
      0) break ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

uninstall_all() {
  show_banner
  echo -e "${RED}═══════════════════════════════════════${NC}"
  echo -e "${RED}        UNINSTALL RsTunnel / PicoTun${NC}"
  echo -e "${RED}═══════════════════════════════════════${NC}"
  echo ""
  echo -e "${YELLOW}This will remove:${NC}"
  echo "  - Binary: ${BIN_PATH}"
  echo "  - Configs: ${CONFIG_DIR}"
  echo "  - Systemd services: ${SERVER_SVC}, ${CLIENT_SVC}"
  echo ""
  read -r -p "Are you sure? [y/N]: " y
  if [[ ! "$y" =~ ^[Yy]$ ]]; then
    return
  fi

  say "Stopping and disabling services..."
  systemctl stop "${SERVER_SVC}" >/dev/null 2>&1 || true
  systemctl stop "${CLIENT_SVC}" >/dev/null 2>&1 || true
  systemctl disable "${SERVER_SVC}" >/dev/null 2>&1 || true
  systemctl disable "${CLIENT_SVC}" >/dev/null 2>&1 || true

  say "Removing systemd files..."
  rm -f "${SYSTEMD_DIR}/${SERVER_SVC}.service"
  rm -f "${SYSTEMD_DIR}/${CLIENT_SVC}.service"
  systemctl daemon-reload

  say "Removing binary and configs..."
  rm -f "${BIN_PATH}"
  rm -rf "${CONFIG_DIR}"

  ok "Uninstalled successfully"
  exit 0
}

main_menu() {
  while true; do
    show_banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}            MAIN MENU${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo "  1) Install Server"
    echo "  2) Install Client"
    echo "  3) Settings (Manage Services & Configs)"
    echo "  4) Show Logs (Pick service)"
    echo "  5) Uninstall (Remove everything)"
    echo ""
    echo "  0) Exit"
    echo ""
    read -r -p "Select option: " c

    case "${c:-}" in
      1) install_server_flow ;;
      2) install_client_flow ;;
      3) settings_menu ;;
      4)
        echo ""
        echo "  1) Server logs"
        echo "  2) Client logs"
        read -r -p "Select: " l
        if [[ "$l" == "1" ]]; then journalctl -u "${SERVER_SVC}" -f; fi
        if [[ "$l" == "2" ]]; then journalctl -u "${CLIENT_SVC}" -f; fi
        ;;
      5) uninstall_all ;;
      0) ok "Goodbye!"; exit 0 ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

check_root
main_menu