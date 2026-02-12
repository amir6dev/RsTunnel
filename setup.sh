#!/bin/bash

# ============================================================================
#  RsTunnel Manager (Dagger-Style Automation)
#  Fixed & Optimized for Iran Servers
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
APP_NAME="picotun"
INSTALL_DIR="/usr/local/bin"
BIN_PATH="${INSTALL_DIR}/${APP_NAME}"
CONFIG_DIR="/etc/picotun" # Changed to picotun to avoid conflict, code handles it
SYSTEMD_DIR="/etc/systemd/system"
BUILD_DIR="/tmp/picobuild"
GO_PATH="/usr/local/go/bin"

# ----------------------------------------------------------------------------
# Helper Functions
# ----------------------------------------------------------------------------

banner() {
    clear
    echo -e "${CYAN}"
    echo -e "${GREEN}*** RsTunnel (Dagger Style)  ***${NC}"
    echo -e "${BLUE}_____________________________${NC}"
    echo -e "${RED}*** POWERED BY HTTPMUX ***${NC}"
    echo -e "${BLUE}_____________________________${NC}"
    echo -e "${GREEN}*** Private Tunneling ***${NC}"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ This script must be run as root${NC}"
        exit 1
    fi
}

pause() {
    echo ""
    read -p "Press Enter to return..."
}

# ----------------------------------------------------------------------------
# Core Installation & Updates
# ----------------------------------------------------------------------------

install_deps() {
    local MISSING_DEPS=0
    for cmd in curl wget git tar openssl ip; do
        if ! command -v $cmd &> /dev/null; then
            MISSING_DEPS=1
        fi
    done

    if [ $MISSING_DEPS -eq 0 ]; then
        echo -e "${GREEN}✓ Dependencies already installed${NC}"
        return
    fi

    echo -e "${YELLOW}📦 Installing dependencies...${NC}"
    if command -v apt &>/dev/null; then
        apt-get update -qq >/dev/null
        apt-get install -y curl wget git tar openssl iproute2 >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y curl wget git tar openssl iproute2 >/dev/null 2>&1
    fi
    echo -e "${GREEN}✓ Dependencies installed${NC}"
}

install_go() {
    # Check if Go is already installed
    if command -v go &> /dev/null; then
        local GO_VERSION=$(go version | grep -oE "go[0-9]+\.[0-9]+")
        # Simple check: if version contains 1.22 or 1.23, strictly speaking we might want newer but let's assume valid
        if [[ "$GO_VERSION" == *"1.2"* ]] || [[ "$GO_VERSION" == *"1.3"* ]]; then
             echo -e "${GREEN}✓ Go environment ready ($GO_VERSION).${NC}"
             return
        fi
    fi

    echo -e "${YELLOW}⬇️  Installing Go 1.22.1 (Mirror)...${NC}"
    
    # Clean old go
    rm -rf /usr/local/go
    
    # Download from mirror for Iran
    wget -q --show-progress "https://mirrors.aliyun.com/golang/go1.22.1.linux-amd64.tar.gz" -O /tmp/go.tgz
    tar -C /usr/local -xzf /tmp/go.tgz
    rm -f /tmp/go.tgz
    
    # Update PATH temporarily for this session
    export PATH=$PATH:/usr/local/go/bin
    
    echo -e "${GREEN}✓ Go environment installed.${NC}"
}

update_core() {
    install_deps
    install_go
    
    # Ensure PATH is correct
    export PATH=$PATH:/usr/local/go/bin
    export GOPROXY=https://goproxy.cn,direct # China proxy works well for Iran usually
    export GOSUMDB=off

    echo -e "${YELLOW}⬇️  Preparing source code...${NC}"
    
    # Fix for getcwd error: ensure we are in a safe dir before deleting build dir
    cd /root
    rm -rf "$BUILD_DIR"
    
    echo -e "${YELLOW}🌐 Cloning from GitHub ...${NC}"
    if ! git clone --depth 1 "$REPO_URL" "$BUILD_DIR" >/dev/null 2>&1; then
        echo -e "${RED}✖ Clone failed. Check internet connection.${NC}"
        return
    fi
    
    cd "$BUILD_DIR"
    echo -e "${YELLOW}🔧 Fixing build environment (Iran Safe)...${NC}"
    
    # Initialize module cleanly to fix dependency errors
    rm -f go.mod go.sum
    # Using the module name expected by your code imports
    go mod init github.com/amir6dev/rstunnel/PicoTun
    
    echo -e "${YELLOW}📦 Downloading Libraries...${NC}"
    # Force tidy to download exactly what's needed
    go mod tidy
    
    echo -e "${YELLOW}🔨 Building binary...${NC}"
    # Build the server/client binary (assuming main is in cmd/picotun based on your provided file list)
    if [ -d "cmd/picotun" ]; then
        go build -trimpath -ldflags="-s -w" -o picotun ./cmd/picotun
    else
        # Fallback if structure is flat
        go build -trimpath -ldflags="-s -w" -o picotun .
    fi
    
    if [ ! -f "picotun" ]; then
        echo -e "${RED}✖ Build failed.${NC}"
        return
    fi
    
    # Stop services before replacing
    systemctl stop picotun-server 2>/dev/null
    systemctl stop picotun-client 2>/dev/null
    
    cp picotun "$BIN_PATH"
    chmod +x "$BIN_PATH"
    
    # Clean up
    cd /root
    rm -rf "$BUILD_DIR"
    
    echo -e "${GREEN}✓ Core updated successfully: ${BIN_PATH}${NC}"
    sleep 2
}

# ----------------------------------------------------------------------------
# Configuration Wizards
# ----------------------------------------------------------------------------

# Generate Random PSK
gen_psk() {
    openssl rand -hex 16
}

install_server() {
    banner
    # Ensure Core is installed
    if [ ! -f "$BIN_PATH" ]; then
        update_core
        banner
    fi

    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      SERVER CONFIGURATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    
    read -p "Tunnel Port [2020]: " TUNNEL_PORT
    TUNNEL_PORT=${TUNNEL_PORT:-2020}
    
    read -p "Enter PSK (Pre-Shared Key) [Leave empty to generate]: " USER_PSK
    if [ -z "$USER_PSK" ]; then
        PSK=$(gen_psk)
        echo -e "${GREEN}Generated PSK: ${PSK}${NC}"
    else
        PSK="$USER_PSK"
    fi
    
    echo ""
    echo -e "${YELLOW}Select Transport:${NC}"
    echo "  1) httpsmux  - HTTPS Mimicry (Recommended)"
    echo "  2) httpmux   - HTTP Mimicry"
    echo "  3) wssmux    - WebSocket Secure (TLS)"
    echo "  4) wsmux     - WebSocket"
    echo "  5) kcpmux    - KCP (UDP based)"
    echo "  6) tcpmux    - Simple TCP"
    read -p "Choice [1-6]: " TRANS_CHOICE
    
    # RsTunnel currently mainly supports httpmux, but we map it for config compatibility
    # Your code maps config.Transport to logic.
    case $TRANS_CHOICE in
        1) TRANSPORT="httpsmux" ;;
        2) TRANSPORT="httpmux" ;;
        3) TRANSPORT="wssmux" ;;
        4) TRANSPORT="wsmux" ;;
        5) TRANSPORT="kcpmux" ;;
        6) TRANSPORT="tcpmux" ;;
        *) TRANSPORT="httpmux" ;;
    esac

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      PORT MAPPINGS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    
    MAPS_YAML=""
    COUNT=1
    while true; do
        echo -e "${YELLOW}Port Mapping #${COUNT}${NC}"
        read -p "Bind Port (port on this server, e.g., 2222): " BIND_PORT
        read -p "Target Port (destination port, e.g., 22): " TARGET_PORT
        read -p "Protocol (tcp/udp/both) [tcp]: " PROTO
        PROTO=${PROTO:-tcp}
        
        # Build YAML entry for RsTunnel (Dagger Style)
        # Assuming RsTunnel reads 'maps' array in config
        MAPS_YAML="${MAPS_YAML}  - type: ${PROTO}\n    bind: \"0.0.0.0:${BIND_PORT}\"\n    target: \"127.0.0.1:${TARGET_PORT}\"\n"
        
        echo -e "${GREEN}✓ Mapping added: 0.0.0.0:${BIND_PORT} → 127.0.0.1:${TARGET_PORT} (${PROTO})${NC}"
        
        echo ""
        read -p "Add another mapping? [y/N]: " YN
        if [[ ! "$YN" =~ ^[Yy] ]]; then
            break
        fi
        COUNT=$((COUNT+1))
    done
    
    create_service "server"
    
    echo ""
    read -p "Optimize system now? [Y/n]: " OPT
    if [[ ! "$OPT" =~ ^[Nn] ]]; then
         optimize_system
    fi
    
    # Write Config
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/server.yaml" <<EOF
mode: "server"
listen: "0.0.0.0:${TUNNEL_PORT}"
transport: "${TRANSPORT}"
psk: "${PSK}"
profile: "latency"
verbose: true

heartbeat: 2

maps:
$(echo -e "$MAPS_YAML")

smux:
  keepalive: 5
  max_recv: 524288
  max_stream: 524288
  frame_size: 2048
  version: 2

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
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  chunked_encoding: false
  session_cookie: true
  custom_headers:
    - "Accept-Language: en-US,en;q=0.9"
    - "Accept-Encoding: gzip, deflate, br"
EOF

    systemctl restart picotun-server
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}   ✓ Server configured (Optimized)${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "  Tunnel Port: ${YELLOW}${TUNNEL_PORT}${NC}"
    echo -e "  PSK: ${YELLOW}${PSK}${NC}"
    echo -e "  Transport: ${YELLOW}${TRANSPORT}${NC}"
    echo -e "  Config: ${YELLOW}${CONFIG_DIR}/server.yaml${NC}"
    echo ""
    pause
}


install_client() {
    banner
    # Ensure Core is installed
    if [ ! -f "$BIN_PATH" ]; then
        update_core
        banner
    fi

    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      CLIENT CONFIGURATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    
    echo "Configuration Mode:"
    echo "  1) Automatic - Optimized settings (Recommended)"
    echo "  2) Manual - Custom configuration"
    echo ""
    read -p "Choice [1-2]: " MODE
    
    read -p "Enter PSK (must match server): " PSK
    
    echo ""
    echo -e "${YELLOW}Select Performance Profile:${NC}"
    echo "  1) balanced      - Standard balanced performance (Recommended)"
    echo "  2) aggressive    - High speed, aggressive settings"
    echo "  3) latency       - Optimized for low latency"
    echo "  4) cpu-efficient - Low CPU usage"
    echo "  5) gaming        - Optimized for gaming (low latency + high speed)"
    read -p "Choice [1-5]: " PROFILE_SEL
    case $PROFILE_SEL in
        1) PROFILE="balanced" ;;
        2) PROFILE="aggressive" ;;
        3) PROFILE="latency" ;;
        4) PROFILE="cpu-efficient" ;;
        5) PROFILE="gaming" ;;
        *) PROFILE="balanced" ;;
    esac
    
    echo ""
    read -p "Enable Traffic Obfuscation? [Y/n]: " OBFS
    if [[ "$OBFS" =~ ^[Nn] ]]; then OBFS_BOOL="false"; else OBFS_BOOL="true"; fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      CONNECTION PATHS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Add Connection Path #1${NC}"
    echo "Select Transport Type:"
    echo "  1) tcpmux   - TCP Multiplexing"
    echo "  2) kcpmux   - KCP Multiplexing (UDP)"
    echo "  3) wsmux    - WebSocket"
    echo "  4) wssmux   - WebSocket Secure"
    echo "  5) httpmux  - HTTP Mimicry"
    echo "  6) httpsmux - HTTPS Mimicry ⭐"
    read -p "Choice [1-6]: " TRANS_CHOICE
    case $TRANS_CHOICE in
        1) TRANSPORT="tcpmux" ;;
        2) TRANSPORT="kcpmux" ;;
        3) TRANSPORT="wsmux" ;;
        4) TRANSPORT="wssmux" ;;
        5) TRANSPORT="httpmux" ;;
        6) TRANSPORT="httpsmux" ;;
        *) TRANSPORT="httpmux" ;;
    esac

    read -p "Server address with Tunnel Port (e.g., 1.2.3.4:2020): " SERVER_ADDR
    read -p "Connection pool size [2]: " POOL
    POOL=${POOL:-2}
    read -p "Enable aggressive pool? [y/N]: " AGGR
    [[ "$AGGR" =~ ^[Yy] ]] && AGGR_BOOL="true" || AGGR_BOOL="false"
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      HTTP MIMICRY SETTINGS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    read -p "Fake domain (e.g., www.google.com) [www.google.com]: " FAKE_DOMAIN
    FAKE_DOMAIN=${FAKE_DOMAIN:-www.google.com}
    read -p "Fake path (e.g., /search) [/search]: " FAKE_PATH
    FAKE_PATH=${FAKE_PATH:-/search}
    
    echo ""
    echo "Select User-Agent:"
    echo "  1) Chrome Windows (default)"
    echo "  2) Firefox Windows"
    read -p "Choice [1-2]: " UA_CHOICE
    if [ "$UA_CHOICE" == "2" ]; then
        UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0"
    else
        UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    fi
    
    read -p "Enable chunked encoding? [Y/n]: " CHUNKED
    [[ "$CHUNKED" =~ ^[Nn] ]] && CHUNKED_BOOL="false" || CHUNKED_BOOL="true"
    read -p "Enable session cookies? [Y/n]: " COOKIES
    [[ "$COOKIES" =~ ^[Nn] ]] && COOKIES_BOOL="false" || COOKIES_BOOL="true"
    
    echo -e "${GREEN}✓ Path added: ${TRANSPORT} -> ${SERVER_ADDR} (pool: ${POOL}, aggressive: ${AGGR_BOOL})${NC}"
    echo ""
    read -p "Enable verbose logging? [y/N]: " VERBOSE
    [[ "$VERBOSE" =~ ^[Yy] ]] && VERBOSE_BOOL="true" || VERBOSE_BOOL="false"

    create_service "client"
    
    # Write Config
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/client.yaml" <<EOF
mode: "client"
psk: "${PSK}"
profile: "${PROFILE}"
verbose: ${VERBOSE_BOOL}

paths:
  - transport: "${TRANSPORT}"
    addr: "${SERVER_ADDR}"
    connection_pool: ${POOL}
    aggressive_pool: ${AGGR_BOOL}
    retry_interval: 3
    dial_timeout: 10

obfuscation:
  enabled: ${OBFS_BOOL}
  min_padding: 16
  max_padding: 512
  min_delay_ms: 5
  max_delay_ms: 50
  burst_chance: 0.15

http_mimic:
  fake_domain: "${FAKE_DOMAIN}"
  fake_path: "${FAKE_PATH}"
  user_agent: "${UA}"
  chunked_encoding: ${CHUNKED_BOOL}
  session_cookie: ${COOKIES_BOOL}
  custom_headers:
    - "X-Requested-With: XMLHttpRequest"
    - "Referer: https://${FAKE_DOMAIN}/"
EOF

    systemctl restart picotun-client
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}   ✓ Client installation complete!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "  Profile: ${YELLOW}${PROFILE}${NC}"
    echo -e "  Obfuscation: ${YELLOW}${OBFS_BOOL}${NC}"
    echo -e "  Config: ${YELLOW}${CONFIG_DIR}/client.yaml${NC}"
    echo -e "  View logs: journalctl -u picotun-client -f"
    echo ""
    pause
}

create_service() {
    local TYPE=$1
    local SERVICE_NAME="picotun-${TYPE}"
    
    cat > "$SYSTEMD_DIR/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=RsTunnel ${TYPE^} Service
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
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    echo -e "${GREEN}✓ Systemd service for ${TYPE^} created: ${SERVICE_NAME}.service${NC}"
}

optimize_system() {
    echo -e "${YELLOW}Applying TCP optimizations...${NC}"
    cat > /etc/sysctl.d/99-picotun.conf << 'EOF'
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.core.rmem_default=131072
net.core.wmem_default=131072
net.ipv4.tcp_rmem=4096 65536 8388608
net.ipv4.tcp_wmem=4096 65536 8388608
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
EOF
    sysctl -p /etc/sysctl.d/99-picotun.conf >/dev/null 2>&1
    echo -e "${GREEN}✓ System Optimized (BBR + TCP Tweaks)${NC}"
}

uninstall_all() {
    echo -e "${RED}⚠️  WARNING: This will remove RsTunnel Binary, Configs, and Services!${NC}"
    read -p "Are you sure? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy] ]]; then
        systemctl stop picotun-server picotun-client 2>/dev/null
        systemctl disable picotun-server picotun-client 2>/dev/null
        rm -f "$SYSTEMD_DIR/picotun-server.service" "$SYSTEMD_DIR/picotun-client.service"
        systemctl daemon-reload
        rm -rf "$CONFIG_DIR" "$BIN_PATH" "$BUILD_DIR"
        echo -e "${GREEN}✓ Uninstalled completely.${NC}"
        sleep 2
        exit 0
    fi
}

# ----------------------------------------------------------------------------
# Main Menu
# ----------------------------------------------------------------------------

main_menu() {
    while true; do
        banner
        echo "  1) Install Server"
        echo "  2) Install Client"
        echo "  3) Settings (Manage Services)"
        echo "  4) System Optimizer"
        echo "  5) Update Core (Re-download Binary)"
        echo "  6) Uninstall RsTunnel"
        echo ""
        echo "  0) Exit"
        echo ""
        read -p "Select option: " opt
        
        case $opt in
            1) install_server ;;
            2) install_client ;;
            3) 
                echo -e "${YELLOW}To manage services, use systemctl or edit configs in /etc/picotun${NC}"
                pause
                ;;
            4) optimize_system; pause ;;
            5) update_core ;;
            6) uninstall_all ;;
            0) exit 0 ;;
            *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
        esac
    done
}

check_root
main_menu