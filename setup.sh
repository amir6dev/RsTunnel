#!/usr/bin/env bash
set -euo pipefail

# ========= UI =========
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
# Fix: Added spaces inside braces to prevent syntax errors
say() { echo -e "${CYAN}➤${NC} $*"; }
ok()  { echo -e "${GREEN}✓${NC} $*"; }
warn(){ echo -e "${YELLOW}⚠${NC} $*"; }
die() { echo -e "${RED}✖${NC} $*"; exit 1; }

# ========= Project =========
REPO_URL="https://github.com/amir6dev/RsTunnel.git"
APP="picotun"

INSTALL_DIR="/usr/local/bin"
BIN_PATH="${INSTALL_DIR}/${APP}"

CONFIG_DIR="/etc/picotun"
SERVER_CFG="${CONFIG_DIR}/server.yaml"
CLIENT_CFG="${CONFIG_DIR}/client.yaml"

SYSTEMD_DIR="/etc/systemd/system"
SERVER_SVC="picotun-server"
CLIENT_SVC="picotun-client"
BUILD_DIR="/tmp/picobuild"

# ========= Helpers =========
need_root(){ [[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."; }

ensure_deps(){
  say "Checking dependencies..."
  if command -v apt >/dev/null 2>&1; then
    apt-get update -qq >/dev/null
    apt-get install -y git curl tar >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y git curl tar >/dev/null
  fi
  ok "Dependencies installed"
}

# New: Install stable Go version to fix 404 errors
install_go(){
  if command -v go >/dev/null 2>&1; then
    # Check if version is > 1.21
    if go version | grep -E "go1\.(2[1-9]|[3-9][0-9])"; then
       return
    fi
  fi
  
  say "Installing Go 1.22.1..."
  local url="https://go.dev/dl/go1.22.1.linux-amd64.tar.gz"
  rm -rf /usr/local/go
  if ! curl -fsSL -L "$url" -o /tmp/go.tgz; then
     die "Download failed. Check internet."
  fi
  tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz
  export PATH="/usr/local/go/bin:${PATH}"
}

banner(){
  echo -e "${GREEN}*** RsTunnel / PicoTun  ***${NC}"
  echo -e "Repo: ${REPO_URL}"
  echo -e "================================="
  echo ""
}

# ========= Build Core (Replaces Download) =========
update_core() {
  ensure_deps
  install_go
  
  say "Cloning source code..."
  rm -rf "$BUILD_DIR"
  git clone --depth 1 "$REPO_URL" "$BUILD_DIR" >/dev/null
  
  say "Building binary..."
  # Handle nested directory if needed
  if [[ -d "${BUILD_DIR}/PicoTun" ]]; then
     cd "${BUILD_DIR}/PicoTun"
  else
     cd "${BUILD_DIR}"
  fi
  
  # Auto-fix go.mod
  rm -f go.mod go.sum
  go mod init github.com/amir6dev/rstunnel
  go mod tidy
  
  # Find main
  local TARGET=""
  if [[ -f "cmd/picotun/main.go" ]]; then TARGET="cmd/picotun/main.go"; fi
  if [[ -f "main.go" ]]; then TARGET="main.go"; fi
  
  if [[ -z "$TARGET" ]]; then die "Could not find main.go"; fi
  
  CGO_ENABLED=0 go build -o picotun "$TARGET"
  
  install -m 0755 picotun "${BIN_PATH}"
  ok "Core updated successfully: ${BIN_PATH}"
}

# ========= Config =========
ensure_config_dir(){ mkdir -p "${CONFIG_DIR}"; }

write_default_server_config_if_missing(){
  ensure_config_dir
  [[ -f "${SERVER_CFG}" ]] && return
  cat > "${SERVER_CFG}" <<EOF
mode: "server"
listen: "0.0.0.0:1010"
psk: "$(openssl rand -hex 16)"

mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0"
  session_cookie: true

obfs:
  enabled: true
  min_padding: 8
  max_padding: 64
  min_delay: 0
  max_delay: 25
  burst_chance: 10

forward:
  tcp: []
  udp: []
EOF
  ok "Created default server config: ${SERVER_CFG}"
}

write_default_client_config_if_missing(){
  ensure_config_dir
  [[ -f "${CLIENT_CFG}" ]] && return
  cat > "${CLIENT_CFG}" <<'YAML'
mode: "client"
server_url: "http://SERVER_IP:1010/tunnel"
session_id: "default"
psk: "PASTE_SERVER_PSK_HERE"

mimic:
  fake_domain: "www.google.com"
  session_cookie: true

obfs:
  enabled: true
  min_padding: 8
  max_padding: 64
YAML
  ok "Created default client config: ${CLIENT_CFG}"
}

# ========= systemd =========
create_service() {
  local mode="$1" svc cfg
  if [[ "$mode" == "server" ]]; then
    svc="${SERVER_SVC}"; cfg="${SERVER_CFG}"
  else
    svc="${CLIENT_SVC}"; cfg="${CLIENT_CFG}"
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
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  ok "Service created: ${svc}.service"
}

enable_start_service(){
  local svc="$1"
  systemctl enable --now "$svc" >/dev/null 2>&1 || true
  ok "Started: $svc"
}

# ========= Flows =========
install_server(){
  banner
  update_core
  write_default_server_config_if_missing
  create_service "server"
  enable_start_service "${SERVER_SVC}"
  echo ""; echo "👉 Config: ${SERVER_CFG}"; echo "👉 PSK is inside the config."; echo ""
  read -r -p "Press Enter..." _
}

install_client(){
  banner
  update_core
  write_default_client_config_if_missing
  create_service "client"
  enable_start_service "${CLIENT_SVC}"
  echo ""; echo "👉 Config: ${CLIENT_CFG}"; echo "⚠️  Edit config to set Server IP & PSK!"; echo ""
  read -r -p "Press Enter..." _
}

manage_service(){
  local mode="$1" svc cfg title
  if [[ "$mode" == "server" ]]; then
    svc="${SERVER_SVC}"; cfg="${SERVER_CFG}"; title="SERVER MANAGEMENT"
  else
    svc="${CLIENT_SVC}"; cfg="${CLIENT_CFG}"; title="CLIENT MANAGEMENT"
  fi

  while true; do
    banner
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
      8) [[ -f "$cfg" ]] && cat "$cfg" || warn "Config not found"; read -r -p "Press Enter..." _ ;;
      9)
        if [[ -f "$cfg" ]]; then
          ${EDITOR:-nano} "$cfg"
          systemctl restart "$svc" || true
          ok "Service restarted with new config"
        else
          warn "Config not found"
        fi
        ;;
      10)
        read -r -p "Delete ${mode}? [y/N]: " y
        if [[ "$y" =~ ^[Yy]$ ]]; then
          systemctl stop "$svc" 2>/dev/null || true
          systemctl disable "$svc" 2>/dev/null || true
          rm -f "${SYSTEMD_DIR}/${svc}.service" "$cfg"
          systemctl daemon-reload
          ok "Deleted."
          sleep 1
        fi
        ;;
      0) break ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

settings_menu(){
  while true; do
    banner
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
      1) manage_service "server" ;;
      2) manage_service "client" ;;
      0) break ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

show_logs_picker(){
  banner
  echo ""
  echo "  1) Server logs"
  echo "  2) Client logs"
  read -r -p "Select: " l
  if [[ "$l" == "1" ]]; then journalctl -u "${SERVER_SVC}" -f; fi
  if [[ "$l" == "2" ]]; then journalctl -u "${CLIENT_SVC}" -f; fi
}

uninstall_all(){
  banner
  echo -e "${RED}═══════════════════════════════════════${NC}"
  echo -e "${RED}        UNINSTALL RsTunnel${NC}"
  echo -e "${RED}═══════════════════════════════════════${NC}"
  echo ""
  read -r -p "Are you sure? [y/N]: " y
  [[ "$y" =~ ^[Yy]$ ]] || return

  say "Stopping services..."
  systemctl stop "${SERVER_SVC}" "${CLIENT_SVC}" 2>/dev/null || true
  systemctl disable "${SERVER_SVC}" "${CLIENT_SVC}" 2>/dev/null || true

  say "Removing files..."
  rm -f "${SYSTEMD_DIR}/${SERVER_SVC}.service" "${SYSTEMD_DIR}/${CLIENT_SVC}.service"
  systemctl daemon-reload
  rm -f "${BIN_PATH}"
  rm -rf "${CONFIG_DIR}"

  ok "Uninstalled successfully."
  exit 0
}

main_menu(){
  while true; do
    banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}            MAIN MENU${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo "  1) Install Server"
    echo "  2) Install Client"
    echo "  3) Settings (Manage Services & Configs)"
    echo "  4) Show Logs (Pick service)"
    echo "  5) Update Core (Build from Source)"
    echo "  6) Uninstall (Remove everything)"
    echo ""
    echo "  0) Exit"
    echo ""
    read -r -p "Select option: " c

    case "${c:-}" in
      1) install_server ;;
      2) install_client ;;
      3) settings_menu ;;
      4) show_logs_picker ;;
      5) update_core; ok "Done."; sleep 2 ;;
      6) uninstall_all ;;
      0) ok "Goodbye!"; exit 0 ;;
      *) warn "Invalid option"; sleep 1 ;;
    esac
  done
}

need_root
main_menu