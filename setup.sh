#!/bin/bash

# ==========================================
#      RsTunnel - Ultimate Edition
#    Managed Reverse Tunneling Solution
# ==========================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Variables ---
INSTALL_DIR="/opt/RsTunnel"
BIN_DIR="/usr/local/bin"
# 👇 مطمئن شو که آدرس گیت‌هاب درسته
REPO_URL="https://github.com/amir6dev/RsTunnel.git"
SERVICE_DIR="/etc/systemd/system"

# --- Helper Functions ---

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Error: Please run as root (sudo)!${NC}"
        exit 1
    fi
}

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "=================================================="
    echo "           🚀 RsTunnel Manager v2.0"
    echo "=================================================="
    echo -e "${NC}"
}

detect_service() {
    if [ -f "$SERVICE_DIR/rstunnel-bridge.service" ]; then
        SERVICE_NAME="rstunnel-bridge"
        ROLE="Bridge (Server)"
    elif [ -f "$SERVICE_DIR/rstunnel-upstream.service" ]; then
        SERVICE_NAME="rstunnel-upstream"
        ROLE="Upstream (Client)"
    else
        SERVICE_NAME=""
        ROLE="Not Installed"
    fi
}

install_dependencies() {
    echo -e "${YELLOW}📦 Installing System Dependencies...${NC}"
    apt update -qq >/dev/null 2>&1
    apt install -y git golang openssl curl >/dev/null 2>&1
    echo -e "${GREEN}✅ Dependencies Ready.${NC}"
}

update_core() {
    echo -e "${YELLOW}⬇️ Cloning & Building Core from GitHub...${NC}"
    rm -rf /tmp/rsbuild
    git clone $REPO_URL /tmp/rsbuild
    
    if [ ! -d "/tmp/rsbuild" ]; then
        echo -e "${RED}❌ Error: Could not clone repo. Check URL.${NC}"
        return
    fi

    cd /tmp/rsbuild || exit
    echo -e "${CYAN}⚙️ Compiling Go Binaries...${NC}"
    go mod tidy >/dev/null 2>&1
    go build -o rstunnel-bridge bridge.go
    go build -o rstunnel-upstream upstream.go
    
    mv rstunnel-* $BIN_DIR/
    chmod +x $BIN_DIR/rstunnel-*
    echo -e "${GREEN}✅ Core Installed Successfully.${NC}"
}

generate_cert() {
    echo -e "${YELLOW}🔐 Generating Self-Signed SSL...${NC}"
    mkdir -p /etc/rstunnel/certs
    openssl req -x509 -newkey rsa:2048 -keyout /etc/rstunnel/certs/key.pem \
        -out /etc/rstunnel/certs/cert.pem -days 365 -nodes \
        -subj "/CN=www.google.com" >/dev/null 2>&1
}

optimize_system() {
    echo -e "${YELLOW}🚀 Optimizing BBR & TCP...${NC}"
    cat > /etc/sysctl.d/99-rstunnel.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.ipv4.tcp_rmem=4096 65536 8388608
net.ipv4.tcp_wmem=4096 65536 8388608
EOF
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}✅ System Optimized.${NC}"
}

# --- Service Management Menu ---

service_menu() {
    detect_service
    if [[ -z "$SERVICE_NAME" ]]; then
        echo -e "${RED}❌ No RsTunnel service installed!${NC}"
        read -p "Press Enter..."
        return
    fi

    while true; do
        show_banner
        echo -e "Target Service: ${GREEN}$ROLE${NC}"
        echo -e "Service Name:   ${YELLOW}$SERVICE_NAME${NC}"
        echo ""
        echo "1) Start Tunnel"
        echo "2) Stop Tunnel"
        echo "3) Restart Tunnel"
        echo "4) Enable (Auto-start on boot)"
        echo "5) Disable (Do not start on boot)"
        echo "6) View Live Logs"
        echo "0) Back to Main Menu"
        echo ""
        read -p "Select: " OPT

        case $OPT in
            1) 
                systemctl start $SERVICE_NAME
                echo -e "${GREEN}✅ Started.${NC}"
                sleep 1
                ;;
            2) 
                systemctl stop $SERVICE_NAME
                echo -e "${RED}🛑 Stopped.${NC}"
                sleep 1
                ;;
            3) 
                systemctl restart $SERVICE_NAME
                echo -e "${GREEN}♻️ Restarted.${NC}"
                sleep 1
                ;;
            4) 
                systemctl enable $SERVICE_NAME
                echo -e "${GREEN}✅ Enabled (Permanent).${NC}"
                sleep 1
                ;;
            5) 
                systemctl disable $SERVICE_NAME
                echo -e "${YELLOW}⚠️ Disabled.${NC}"
                sleep 1
                ;;
            6) 
                echo -e "${CYAN}Press Ctrl+C to exit logs...${NC}"
                sleep 2
                journalctl -u $SERVICE_NAME -f
                ;;
            0) return ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# --- Install Logic ---

install_bridge() {
    install_dependencies
    update_core
    
    echo ""
    echo "--- Configure Bridge (Server) ---"
    echo "1) httpmux"
    echo "2) httpsmux (Secure TLS) ⭐"
    read -p "Select Mode [1-2]: " M
    if [[ "$M" == "2" ]]; then
        MODE="httpsmux"
        generate_cert
        CERT_FLAGS="-cert /etc/rstunnel/certs/cert.pem -key /etc/rstunnel/certs/key.pem"
    else
        MODE="httpmux"
        CERT_FLAGS=""
    fi

    echo ""
    echo "1) balanced"
    echo "2) aggressive (Fast)"
    echo "3) gaming (Low Ping)"
    read -p "Select Profile [1-3]: " P
    case $P in 2) PROF="aggressive";; 3) PROF="gaming";; *) PROF="balanced";; esac

    read -p "Tunnel Port [443]: " TPORT
    TPORT=${TPORT:-443}
    read -p "User Port [1432]: " UPORT
    UPORT=${UPORT:-1432}

    echo -e "${YELLOW}⚙️ Creating Service...${NC}"
    cat > $SERVICE_DIR/rstunnel-bridge.service <<EOF
[Unit]
Description=RsTunnel Bridge
After=network.target

[Service]
Type=simple
User=root
LimitNOFILE=1048576
ExecStart=$BIN_DIR/rstunnel-bridge -l :$TPORT -u :$UPORT -m $MODE -profile $PROF $CERT_FLAGS
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable rstunnel-bridge
    systemctl restart rstunnel-bridge
    echo -e "${GREEN}✅ Bridge Server Installed!${NC}"
    read -p "Press Enter..."
}

install_upstream() {
    install_dependencies
    update_core
    
    echo ""
    echo "--- Configure Upstream (Client) ---"
    read -p "Bridge IP (Iran IP): " BIP
    read -p "Bridge Port [443]: " BPORT
    BPORT=${BPORT:-443}
    
    echo "1) httpmux"
    echo "2) httpsmux (Secure) ⭐"
    read -p "Select Mode [1-2]: " M
    if [[ "$M" == "2" ]]; then MODE="httpsmux"; else MODE="httpmux"; fi

    echo ""
    echo "1) balanced"
    echo "2) aggressive"
    echo "3) gaming"
    read -p "Select Profile [1-3]: " P
    case $P in 2) PROF="aggressive";; 3) PROF="gaming";; *) PROF="balanced";; esac
    
    read -p "Local Panel [127.0.0.1:1432]: " PADDR
    PADDR=${PADDR:-127.0.0.1:1432}

    echo -e "${YELLOW}⚙️ Creating Service...${NC}"
    cat > $SERVICE_DIR/rstunnel-upstream.service <<EOF
[Unit]
Description=RsTunnel Upstream
After=network.target

[Service]
Type=simple
User=root
LimitNOFILE=1048576
ExecStart=$BIN_DIR/rstunnel-upstream -c $BIP:$BPORT -p $PADDR -m $MODE -profile $PROF
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable rstunnel-upstream
    systemctl restart rstunnel-upstream
    echo -e "${GREEN}✅ Upstream Client Installed!${NC}"
    read -p "Press Enter..."
}

uninstall() {
    echo -e "${RED}⚠️  DANGER ZONE ⚠️${NC}"
    echo "This will completely remove RsTunnel services and files."
    read -p "Are you sure? (y/n): " CONF
    if [[ "$CONF" != "y" ]]; then return; fi
    
    echo -e "${YELLOW}Stopping services...${NC}"
    systemctl stop rstunnel-bridge 2>/dev/null
    systemctl stop rstunnel-upstream 2>/dev/null
    systemctl disable rstunnel-bridge 2>/dev/null
    systemctl disable rstunnel-upstream 2>/dev/null
    
    rm -f $SERVICE_DIR/rstunnel-bridge.service
    rm -f $SERVICE_DIR/rstunnel-upstream.service
    rm -f $BIN_DIR/rstunnel-*
    rm -rf /etc/rstunnel
    rm -f /etc/sysctl.d/99-rstunnel.conf
    
    systemctl daemon-reload
    echo -e "${GREEN}✅ Uninstalled Successfully.${NC}"
    read -p "Press Enter..."
}

# --- Main Menu ---

while true; do
    show_banner
    detect_service
    if [[ -n "$SERVICE_NAME" ]]; then
        STATUS=$(systemctl is-active $SERVICE_NAME)
        echo -e "Current Role: ${GREEN}$ROLE${NC}"
        echo -e "Status:       ${YELLOW}$STATUS${NC}"
        echo ""
    fi

    echo "1) Install Bridge (Iran)"
    echo "2) Install Upstream (Kharej)"
    echo "3) Service Management (Start/Stop/Logs)"
    echo "4) System Optimizer (BBR)"
    echo "5) Update Core"
    echo "6) Uninstall"
    echo "0) Exit"
    echo ""
    read -p "Select: " OPT

    case $OPT in
        1) install_bridge ;;
        2) install_upstream ;;
        3) service_menu ;;
        4) optimize_system; read -p "Press Enter..." ;;
        5) install_dependencies; update_core; read -p "Press Enter..." ;;
        6) uninstall ;;
        0) exit 0 ;;
        *) echo "Invalid option" ;;
    esac
done