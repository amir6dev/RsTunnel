#!/usr/bin/env bash
# set -e removed to handle errors manually and avoid abrupt exits
# set -euo pipefail 

# ============================================================================
#  RsTunnel / PicoTun Manager (Full Dagger-Style Automation)
# ============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Paths
REPO_URL="https://github.com/amir6dev/RsTunnel.git"
APP="picotun"
INSTALL_DIR="/usr/local/bin"
BIN_PATH="${INSTALL_DIR}/${APP}"
CONFIG_DIR="/etc/picotun"
SYSTEMD_DIR="/etc/systemd/system"
BUILD_DIR="/tmp/picobuild"
HOME_DIR="$HOME"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
say()  { echo -e "${CYAN}➤${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
die()  { echo -e "${RED}✖${NC} $*"; exit 1; }

check_root() { [[ ${EUID} -eq 0 ]] || die "This script must be run as root."; }

banner() {
    clear
    echo -e "${CYAN}"
    echo -e "${GREEN}*** RsTunnel / PicoTun  ***${NC}"
    echo -e "${BLUE}_____________________________${NC}"
    echo -e "${PURPLE}   Automation like Dagger    ${NC}"
    echo -e "${BLUE}_____________________________${NC}"
    echo -e "${GREEN}*** Private Tunneling   ***${NC}"
    echo ""
}

pause() { read -r -p "Press Enter to continue..."; }

# ----------------------------------------------------------------------------
#  CORE INSTALLATION (Iran Optimized & Retry Logic)
# ----------------------------------------------------------------------------
ensure_deps() {
    echo -e "${YELLOW}📦 Installing dependencies...${NC}"
    if command -v apt &>/dev/null; then
        apt-get update -qq >/dev/null
        apt-get install -y curl wget git tar openssl iproute2 >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y curl wget git tar openssl iproute2 >/dev/null 2>&1
    else
        echo "Unsupported package manager. Please install dependencies manually."
    fi
    ok "Dependencies installed"
}

install_go() {
    # Iran Proxy Settings
    export GOPROXY=https://goproxy.cn,direct
    export GOTOOLCHAIN=local
    export GOSUMDB=off

    if command -v go >/dev/null 2>&1; then
        if go version | grep -E "go1\.(2[2-9]|[3-9][0-9])" >/dev/null 2>&1; then
            return
        fi
    fi

    local GO_VER="1.22.1"
    echo -e "${YELLOW}⬇️  Installing Go ${GO_VER} (Mirror)...${NC}"
    local url="https://mirrors.aliyun.com/golang/go${GO_VER}.linux-amd64.tar.gz"

    rm -rf /usr/local/go
    if ! curl -fsSL -L "$url" -o /tmp/go.tgz; then
        warn "Failed to download Go. Checking internet..."
        return 1
    fi
    tar -C /usr/local -xzf /tmp/go.tgz
    rm -f /tmp/go.tgz
    export PATH="/usr/local/go/bin:${PATH}"
    ok "Go environment ready."
}

# Retry helper
go_get_retry() {
    local PKG=$1
    local MAX_RETRIES=3
    local COUNT=0
    
    while [ $COUNT -lt $MAX_RETRIES ]; do
        echo "   Downloading $PKG (Attempt $((COUNT+1)))..."
        if go get "$PKG"; then
            return 0
        fi
        COUNT=$((COUNT+1))
        sleep 1
    done
    return 1
}

update_core() {
    ensure_deps
    install_go

    export PATH="/usr/local/go/bin:${PATH}"
    export GOPROXY=https://goproxy.cn,direct
    export GOTOOLCHAIN=local
    export GOSUMDB=off

    echo -e "${YELLOW}⬇️  Preparing source code...${NC}"
    cd "$HOME_DIR"
    rm -rf "$BUILD_DIR"

    # Clone
    echo -e "${YELLOW}🌐 Cloning from GitHub ...${NC}"
    if ! git clone --depth 1 "$REPO_URL" "$BUILD_DIR"; then
        die "Failed to clone repository."
    fi

    cd "$BUILD_DIR"
    echo -e "${YELLOW}🔧 Fixing build environment (Iran Safe)...${NC}"

    rm -f go.mod go.sum
    go mod init github.com/amir6dev/rstunnel >/dev/null 2>&1 || true

    # Fix imports
    find . -name "*.go" -type f -exec sed -i 's|github.com/amir6dev/RsTunnel/PicoTun|github.com/amir6dev/rstunnel/PicoTun|g' {} +
    find . -name "*.go" -type f -exec sed -i 's|github.com/amir6dev/RsTunnel|github.com/amir6dev/rstunnel|g' {} +

    echo -e "${YELLOW}📦 Downloading Libraries...${NC}"
    go_get_retry "golang.org/x/net@v0.23.0" || die "Failed to download x/net"
    go_get_retry "github.com/refraction-networking/utls@v1.6.0" || die "Failed to download utls"
    go_get_retry "github.com/xtaci/smux@v1.5.24" || die "Failed to download smux"
    go_get_retry "gopkg.in/yaml.v3@v3.0.1" || die "Failed to download yaml"
    
    go mod tidy >/dev/null 2>&1

    echo -e "${YELLOW}🔨 Building binary...${NC}"
    local TARGET=""
    if [[ -f "cmd/picotun/main.go" ]]; then TARGET="cmd/picotun/main.go"; fi
    if [[ -f "main.go" ]]; then TARGET="main.go"; fi
    [[ -z "$TARGET" ]] && die "Main file not found."

    CGO_ENABLED=0 go build -o picotun "$TARGET" || die "Build failed."
    install -m 0755 picotun "${BIN_PATH}"
    ok "Core updated successfully: ${BIN_PATH}"

    cd "$HOME_DIR"
    rm -rf "$BUILD_DIR"
}

# ----------------------------------------------------------------------------
#  SYSTEM OPTIMIZER (BBR/TCP)
# ----------------------------------------------------------------------------
optimize_system() {
    banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      SYSTEM OPTIMIZATION (BBR/TCP)    ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Applying kernel tweaks...${NC}"

    cat > /etc/sysctl.d/99-picotun.conf << 'EOF'
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.core.rmem_default=131072
net.core.wmem_default=131072
net.ipv4.tcp_rmem=4096 65536 8388608
net.ipv4.tcp_wmem=4096 65536 8388608
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
EOF
    sysctl -p /etc/sysctl.d/99-picotun.conf >/dev/null 2>&1 || true
    ok "TCP Tweaks applied"
    ok "BBR enabled"
    echo ""
    pause
}

# ----------------------------------------------------------------------------
#  Wizard Blocks
# ----------------------------------------------------------------------------
ask_session_timeout() {
    read -r -p "Session Timeout (seconds) [30]: " SESSION_TIMEOUT
    SESSION_TIMEOUT=${SESSION_TIMEOUT:-30}
    if ! [[ "$SESSION_TIMEOUT" =~ ^[0-9]+$ ]]; then
        warn "Invalid number, using 30"
        SESSION_TIMEOUT=30
    fi
}

ask_psk() {
    echo ""
    while true; do
        read -r -p "Enter PSK (Leave empty to auto-generate): " USER_PSK
        if [[ -z "${USER_PSK}" ]]; then
            PSK="$(openssl rand -hex 16)"
            echo -e "${GREEN}Generated PSK: ${PSK}${NC}"
            break
        fi
        PSK="${USER_PSK}"
        break
    done
}

ask_mimic() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      HTTP MIMICRY (Headers)           ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    read -r -p "Fake Domain (Host header) [www.google.com]: " FAKE_DOMAIN
    FAKE_DOMAIN=${FAKE_DOMAIN:-www.google.com}

    read -r -p "Fake Path (for ServerURL) [/tunnel]: " FAKE_PATH
    FAKE_PATH=${FAKE_PATH:-/tunnel}
    
    # Force /tunnel for compatibility if needed, or allow it
    if [[ "$FAKE_PATH" != "/tunnel" ]]; then
        # warn "Using path: $FAKE_PATH"
        : # no-op
    fi

    read -r -p "User-Agent [Mozilla/5.0]: " USER_AGENT
    USER_AGENT=${USER_AGENT:-Mozilla/5.0}

    read -r -p "Enable Session Cookie header? [Y/n]: " SESSION_COOKIE
    if [[ "${SESSION_COOKIE}" =~ ^[Nn] ]]; then SESSION_COOKIE_BOOL="false"; else SESSION_COOKIE_BOOL="true"; fi

    CUSTOM_HEADERS_YAML=""
    echo ""
    echo -e "${YELLOW}Custom Headers (Optional)${NC}"
    while true; do
        read -r -p "Add custom header? [y/N]: " yn
        [[ ! "$yn" =~ ^[Yy] ]] && break
        read -r -p "  Header (Key: Value): " hdr
        if [[ -n "$hdr" ]]; then
            # Safe append
            CUSTOM_HEADERS_YAML="${CUSTOM_HEADERS_YAML}    - \"${hdr}\"\n"
            ok "Added header: $hdr"
        fi
    done

    if [[ -z "$CUSTOM_HEADERS_YAML" ]]; then
        CUSTOM_HEADERS_BLOCK="  custom_headers: []"
    else
        # We need to construct the block carefully
        # Remove the last newline using printf inside var
        CUSTOM_HEADERS_BLOCK="  custom_headers:
$(printf "%b" "$CUSTOM_HEADERS_YAML")"
    fi
}

ask_obfs() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      OBFUSCATION (Padding/Delay)      ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    read -r -p "Enable Obfuscation? [Y/n]: " ENABLE_OBFS
    if [[ "$ENABLE_OBFS" =~ ^[Nn] ]]; then
        OBFS_BOOL="false"
        MIN_PAD=16; MAX_PAD=256; MIN_DELAY=0; MAX_DELAY=0
        return
    fi
    OBFS_BOOL="true"

    read -r -p "Min Padding bytes [16]: " MIN_PAD
    MIN_PAD=${MIN_PAD:-16}
    read -r -p "Max Padding bytes [256]: " MAX_PAD
    MAX_PAD=${MAX_PAD:-256}

    read -r -p "Min Delay (ms) [0]: " MIN_DELAY
    MIN_DELAY=${MIN_DELAY:-0}
    read -r -p "Max Delay (ms) [0]: " MAX_DELAY
    MAX_DELAY=${MAX_DELAY:-0}
}

build_port_mappings_tcp() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      PORT MAPPINGS (Reverse TCP)      ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    read -r -p "Bind IP [0.0.0.0]: " BIND_IP
    BIND_IP=${BIND_IP:-0.0.0.0}
    read -r -p "Target IP [127.0.0.1]: " TARGET_IP
    TARGET_IP=${TARGET_IP:-127.0.0.1}

    MAPPINGS_TCP_YAML=""
    COUNT=0

    while true; do
        echo ""
        read -r -p "Enter port(s) (e.g. 8080 or 1000/2000) (Empty to finish): " PORT_INPUT
        PORT_INPUT="$(echo "${PORT_INPUT:-}" | tr -d ' ')"
        [[ -z "$PORT_INPUT" ]] && break

        if [[ "$PORT_INPUT" =~ ^([0-9]+)/([0-9]+)$ ]]; then
            START_PORT="${BASH_REMATCH[1]}"; END_PORT="${BASH_REMATCH[2]}"
            for ((p=START_PORT; p<=END_PORT; p++)); do
                MAPPINGS_TCP_YAML="${MAPPINGS_TCP_YAML}    - \"${BIND_IP}:${p}->${TARGET_IP}:${p}\"\n"
                COUNT=$((COUNT + 1))
            done
            ok "Added range ${START_PORT}-${END_PORT}"
        elif [[ "$PORT_INPUT" =~ ^([0-9]+)$ ]]; then
            BP="${BASH_REMATCH[1]}"
            MAPPINGS_TCP_YAML="${MAPPINGS_TCP_YAML}    - \"${BIND_IP}:${BP}->${TARGET_IP}:${BP}\"\n"
            COUNT=$((COUNT + 1))
            ok "Added port ${BP}"
        else
            warn "Invalid format."
        fi
    done
    ok "Total TCP mappings: $COUNT"
}

build_port_mappings_udp() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      PORT MAPPINGS (Reverse UDP)      ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    read -r -p "Bind IP [0.0.0.0]: " BIND_IP_UDP
    BIND_IP_UDP=${BIND_IP_UDP:-0.0.0.0}
    read -r -p "Target IP [127.0.0.1]: " TARGET_IP_UDP
    TARGET_IP_UDP=${TARGET_IP_UDP:-127.0.0.1}

    MAPPINGS_UDP_YAML=""
    COUNT_UDP=0

    while true; do
        echo ""
        read -r -p "Enter UDP port(s) (Empty to finish): " PORT_INPUT
        PORT_INPUT="$(echo "${PORT_INPUT:-}" | tr -d ' ')"
        [[ -z "$PORT_INPUT" ]] && break

        if [[ "$PORT_INPUT" =~ ^([0-9]+)$ ]]; then
            BP="${BASH_REMATCH[1]}"
            MAPPINGS_UDP_YAML="${MAPPINGS_UDP_YAML}    - \"${BIND_IP_UDP}:${BP}->${TARGET_IP_UDP}:${BP}\"\n"
            COUNT_UDP=$((COUNT_UDP + 1))
            ok "Added UDP port ${BP}"
        else
            warn "Invalid format."
        fi
    done
    ok "Total UDP mappings: $COUNT_UDP"
}

# ----------------------------------------------------------------------------
#  Config Writers (Corrected to avoid heredoc syntax errors)
# ----------------------------------------------------------------------------
write_server_config() {
    mkdir -p "$CONFIG_DIR"
    
    # Process the mappings BEFORE the heredoc to ensure clean variables
    local TCP_BLOCK=" []"
    if [[ -n "${MAPPINGS_TCP_YAML:-}" ]]; then
        # Use printf to format the string properly
        local FORMATTED_TCP
        FORMATTED_TCP=$(printf "%b" "$MAPPINGS_TCP_YAML")
        TCP_BLOCK="
${FORMATTED_TCP}"
    fi

    local UDP_BLOCK=" []"
    if [[ -n "${MAPPINGS_UDP_YAML:-}" ]]; then
        local FORMATTED_UDP
        FORMATTED_UDP=$(printf "%b" "$MAPPINGS_UDP_YAML")
        UDP_BLOCK="
${FORMATTED_UDP}"
    fi

    # Write the file
    cat > "$CONFIG_DIR/server.yaml" <<EOF
mode: "server"
listen: "${LISTEN_ADDR}"
session_timeout: ${SESSION_TIMEOUT}
psk: "${PSK}"

mimic:
  fake_domain: "${FAKE_DOMAIN}"
  fake_path: "${FAKE_PATH}"
  user_agent: "${USER_AGENT}"
  session_cookie: ${SESSION_COOKIE_BOOL}
${CUSTOM_HEADERS_BLOCK}

obfs:
  enabled: ${OBFS_BOOL}
  min_padding: ${MIN_PAD}
  max_padding: ${MAX_PAD}
  min_delay: ${MIN_DELAY}
  max_delay: ${MAX_DELAY}

forward:
  tcp:${TCP_BLOCK}
  udp:${UDP_BLOCK}
EOF
}

write_client_config() {
    mkdir -p "$CONFIG_DIR"
    
    local UDP_BLOCK=" []"
    if [[ -n "${MAPPINGS_UDP_YAML:-}" ]]; then
        local FORMATTED_UDP
        FORMATTED_UDP=$(printf "%b" "$MAPPINGS_UDP_YAML")
        UDP_BLOCK="
${FORMATTED_UDP}"
    fi

    cat > "$CONFIG_DIR/client.yaml" <<EOF
mode: "client"
server_url: "http://${SIP}:${SPORT}${FAKE_PATH}"
session_id: "client-$(openssl rand -hex 4)"
psk: "${PSK}"

mimic:
  fake_domain: "${FAKE_DOMAIN}"
  fake_path: "${FAKE_PATH}"
  user_agent: "${USER_AGENT}"
  session_cookie: ${SESSION_COOKIE_BOOL}
${CUSTOM_HEADERS_BLOCK}

obfs:
  enabled: ${OBFS_BOOL}
  min_padding: ${MIN_PAD}
  max_padding: ${MAX_PAD}
  min_delay: ${MIN_DELAY}
  max_delay: ${MAX_DELAY}

forward:
  tcp: []
  udp:${UDP_BLOCK}
EOF
}

# ----------------------------------------------------------------------------
#  Systemd
# ----------------------------------------------------------------------------
create_service() {
    local TYPE=$1
    local SERVICE_NAME="picotun-${TYPE}"

    cat > "$SYSTEMD_DIR/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=RsTunnel ${TYPE^}
After=network.target

[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} -config ${CONFIG_DIR}/${TYPE}.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    ok "Service ${SERVICE_NAME} created."
}

show_logs() {
    local TYPE=$1
    if [[ -z "${TYPE:-}" ]]; then
        echo ""
        echo "1) Server Logs"
        echo "2) Client Logs"
        read -r -p "Select: " opt
        [[ "$opt" == "1" ]] && TYPE="server" || TYPE="client"
    fi
    journalctl -u "picotun-${TYPE}" -f
}

# ----------------------------------------------------------------------------
#  Main Logic
# ----------------------------------------------------------------------------
configure_server() {
    banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      SERVER CONFIGURATION (httpmux)   ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    read -r -p "Listen IP [0.0.0.0]: " LIP
    LIP=${LIP:-0.0.0.0}
    read -r -p "Tunnel Listen Port [1010]: " LPORT
    LPORT=${LPORT:-1010}
    LISTEN_ADDR="${LIP}:${LPORT}"

    ask_session_timeout
    ask_psk
    ask_mimic
    ask_obfs
    
    echo ""
    echo "1) TCP only (recommended)"
    echo "2) UDP only"
    echo "3) TCP + UDP"
    echo "4) None"
    read -r -p "Select Reverse Mode [1]: " REV_MODE
    REV_MODE=${REV_MODE:-1}

    # Reset mapping vars
    MAPPINGS_TCP_YAML=""
    MAPPINGS_UDP_YAML=""

    case "$REV_MODE" in
        1) build_port_mappings_tcp ;;
        2) build_port_mappings_udp ;;
        3) build_port_mappings_tcp; build_port_mappings_udp ;;
        4) warn "No reverse listeners will be created." ;;
        *) warn "Invalid choice, defaulting to TCP only."; build_port_mappings_tcp ;;
    esac

    write_server_config
    create_service "server"

    echo ""
    echo -e "${GREEN}Configuration Complete!${NC}"
    echo -e "PSK: ${YELLOW}${PSK}${NC}"
    echo ""
    pause

    systemctl restart picotun-server || true
    ok "Server started/restarted."
    echo ""
    read -r -p "View live logs now? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy] ]]; then
        show_logs "server"
    fi
}

configure_client() {
    banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      CLIENT CONFIGURATION (httpmux)   ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    read -r -p "Server IP: " SIP
    [[ -z "${SIP}" ]] && die "Server IP is required"
    read -r -p "Server Port [1010]: " SPORT
    SPORT=${SPORT:-1010}

    echo ""
    read -r -p "Enter PSK (From Server): " PSK
    [[ -z "${PSK}" ]] && die "PSK is required"

    ask_mimic
    ask_obfs
    
    MAPPINGS_UDP_YAML=""
    # Client usually doesn't need reverse listener setup via wizard in same way, 
    # but structure supports it if needed. For now, basic config.
    
    write_client_config
    create_service "client"
    systemctl restart picotun-client || true
    ok "Client configured and started."
    echo ""
    read -r -p "View live logs now? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy] ]]; then
        show_logs "client"
    fi
}

manage_service() {
    while true; do
        banner
        echo -e "${YELLOW}Service Management${NC}"
        echo "1) Restart Server"
        echo "2) Stop Server"
        echo "3) Restart Client"
        echo "4) Stop Client"
        echo "5) View Configs"
        echo "0) Back"
        echo ""
        read -r -p "Select: " opt
        case $opt in
            1) systemctl restart picotun-server; ok "Server Restarted"; sleep 1 ;;
            2) systemctl stop picotun-server; ok "Server Stopped"; sleep 1 ;;
            3) systemctl restart picotun-client; ok "Client Restarted"; sleep 1 ;;
            4) systemctl stop picotun-client; ok "Client Stopped"; sleep 1 ;;
            5) ls -l "$CONFIG_DIR"; pause ;;
            0) return ;;
            *) warn "Invalid option"; sleep 1 ;;
        esac
    done
}

uninstall_all() {
    echo ""
    echo -e "${RED}⚠️  WARNING: This will remove RsTunnel Binary, Configs, and Services!${NC}"
    read -r -p "Are you sure? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy] ]]; then
        systemctl stop picotun-server picotun-client 2>/dev/null || true
        systemctl disable picotun-server picotun-client 2>/dev/null || true
        rm -f "$SYSTEMD_DIR/picotun-server.service" "$SYSTEMD_DIR/picotun-client.service"
        systemctl daemon-reload || true
        rm -rf "$CONFIG_DIR" "$BIN_PATH" "$BUILD_DIR"
        ok "Uninstalled completely."
        sleep 2
        exit 0
    fi
}

main_menu() {
    while true; do
        banner
        echo "1) Install Server (Wizard)"
        echo "2) Install Client (Wizard)"
        echo "3) Settings (Manage Services)"
        echo "4) System Optimizer (BBR/TCP)"
        echo "5) Update Core / Re-install"
        echo "6) Show Logs"
        echo "7) Uninstall"
        echo "0) Exit"
        echo ""
        read -r -p "Select option: " opt
        case $opt in
            1)
                [[ -f "$BIN_PATH" ]] || update_core
                configure_server
                ;;
            2)
                [[ -f "$BIN_PATH" ]] || update_core
                configure_client
                ;;
            3) manage_service ;;
            4) optimize_system ;;
            5) update_core; pause ;;
            6) show_logs "" ;;
            7) uninstall_all ;;
            0) exit 0 ;;
            *) warn "Invalid option"; sleep 1 ;;
        esac
    done
}

check_root
main_menu