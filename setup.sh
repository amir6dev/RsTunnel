#!/usr/bin/env bash
set -euo pipefail

# =========================
# PicoTun Manager (Full Automation)
# =========================
REPO_DEFAULT="amir6dev/RsTunnel"
BINARY_NAME="picotun"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/picotun"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SERVICE_FILE="/etc/systemd/system/picotun.service"

# --- Colors ---
NC='\033[0m'
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'

# --- Helpers ---
print_header() {
    clear
    echo -e "${CYAN}===============================================${NC}"
    echo -e "${GREEN}      🚀 PicoTun Tunnel Manager (Pro)      ${NC}"
    echo -e "${CYAN}===============================================${NC}"
    echo ""
}

print_msg() { echo -e "${BLUE}➤ $1${NC}"; }
print_ok() { echo -e "${GREEN}✔ $1${NC}"; }
print_err() { echo -e "${RED}✖ $1${NC}"; }

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        print_err "Run as root!"
        exit 1
    fi
}

# --- Core Logic ---
install_core() {
    print_msg "Checking environment..."
    apt-get update -qq >/dev/null
    apt-get install -y curl git golang openssl >/dev/null

    print_msg "Cloning & Building..."
    rm -rf /tmp/picobuild
    git clone "https://github.com/${REPO_DEFAULT}.git" /tmp/picobuild
    cd /tmp/picobuild || exit
    
    # ✅ FIX: حل مشکل go.sum و وابستگی‌ها
    if [ -f "PicoTun/go.mod" ]; then
        cd PicoTun
        print_msg "Resolving dependencies (go mod tidy)..."
        go mod tidy
        cd ..
    elif [ -f "go.mod" ]; then
        print_msg "Resolving dependencies (go mod tidy)..."
        go mod tidy
    fi
    
    # Build Correct Path
    TARGET=""
    if [ -f "cmd/picotun/main.go" ]; then TARGET="cmd/picotun/main.go"; fi
    if [ -f "PicoTun/cmd/picotun/main.go" ]; then TARGET="PicoTun/cmd/picotun/main.go"; fi
    
    if [ -z "$TARGET" ]; then
        print_err "Could not find main.go!"
        exit 1
    fi

    CGO_ENABLED=0 go build -o picotun "$TARGET"
    
    if [ -f "picotun" ]; then
        mv picotun "$INSTALL_DIR/$BINARY_NAME"
        chmod +x "$INSTALL_DIR/$BINARY_NAME"
        rm -rf /tmp/picobuild
        print_ok "Installed successfully!"
    else
        print_err "Build failed!"
        exit 1
    fi
}

configure_wizard() {
    MODE=$1
    mkdir -p "$CONFIG_DIR"
    
    echo ""
    read -p "Tunnel Port [1010]: " PORT; PORT=${PORT:-1010}
    read -p "PSK (Password): " PSK
    if [[ -z "$PSK" ]]; then PSK=$(openssl rand -hex 16); echo "Generated: $PSK"; fi
    
    if [[ "$MODE" == "server" ]]; then
        # Port Mapping Wizard
        TCP_MAPS=""
        echo -e "${YELLOW}Port Forwarding (Reverse Tunnel):${NC}"
        while true; do
            read -p "Add Map? (y/N): " yn
            [[ ! "$yn" =~ ^[Yy] ]] && break
            read -p "  Bind Port (e.g. 2080): " bp
            read -p "  Target (e.g. 127.0.0.1:80): " tg
            TCP_MAPS+="    - \"0.0.0.0:${bp}->${tg}\"\n"
        done
        
        cat > "$CONFIG_FILE" <<EOF
mode: server
listen: "0.0.0.0:${PORT}"
session_timeout: 15
psk: "${PSK}"
mimic:
  fake_domain: "www.google.com"
  session_cookie: true
obfs:
  enabled: true
  min_padding: 16
  max_padding: 256
forward:
  tcp:
${TCP_MAPS}
EOF
    else
        read -p "Server IP: " SIP
        cat > "$CONFIG_FILE" <<EOF
mode: client
server_url: "http://${SIP}:${PORT}/tunnel"
session_id: "sess-$(date +%s)"
psk: "${PSK}"
mimic:
  fake_domain: "www.google.com"
  session_cookie: true
obfs:
  enabled: true
  min_padding: 16
  max_padding: 256
forward:
  tcp: []
EOF
    fi
    
    install_service
}

install_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PicoTun
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/$BINARY_NAME -config $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable picotun >/dev/null 2>&1
    systemctl restart picotun
    print_ok "Service Restarted"
}

manage_menu() {
    while true; do
        print_header
        echo -e "${YELLOW}:: Service Management ::${NC}"
        echo "1) Start Service"
        echo "2) Stop Service"
        echo "3) Restart Service"
        echo "4) View Logs (Live)"
        echo "5) View Config"
        echo "6) Delete Config & Service"
        echo "0) Back"
        echo ""
        read -p "Select: " opt
        case $opt in
            1) systemctl start picotun; print_ok "Started"; sleep 1 ;;
            2) systemctl stop picotun; print_ok "Stopped"; sleep 1 ;;
            3) systemctl restart picotun; print_ok "Restarted"; sleep 1 ;;
            4) journalctl -u picotun -f ;;
            5) cat $CONFIG_FILE; read -p "Press Enter..." ;;
            6) uninstall_all; return ;;
            0) return ;;
        esac
    done
}

uninstall_all() {
    echo ""
    read -p "Are you sure you want to DELETE everything? (y/N): " yn
    if [[ "$yn" =~ ^[Yy] ]]; then
        print_msg "Uninstalling..."
        systemctl stop picotun >/dev/null 2>&1 || true
        systemctl disable picotun >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE" "$INSTALL_DIR/$BINARY_NAME"
        rm -rf "$CONFIG_DIR"
        systemctl daemon-reload
        print_ok "Uninstalled completely."
        sleep 2
    fi
}

main_menu() {
    while true; do
        print_header
        echo "1) Install / Update Core"
        echo "2) Install Server (Iran)"
        echo "3) Install Client (Kharej)"
        echo "4) Settings (Manage Service)"
        echo "5) Uninstall"
        echo "0) Exit"
        echo ""
        read -p "Select: " opt
        case $opt in
            1) install_core; read -p "Press Enter..." ;;
            2) configure_wizard "server" ;;
            3) configure_wizard "client" ;;
            4) manage_menu ;;
            5) uninstall_all ;;
            0) exit ;;
        esac
    done
}

need_root
main_menu