#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
#  RsTunnel / PicoTun Manager (Dagger-Style, Extended Wizard)
#  هدف: شبیه‌سازی تجربه نصب/کانفیگ DaggerConnect برای httpmux
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
    echo -e "${PURPLE}  Dagger-Style Wizard (httpmux) ${NC}"
    echo -e "${BLUE}_____________________________${NC}"
    echo -e "${GREEN}*** Private Tunneling   ***${NC}"
    echo ""
}

pause() { read -r -p "Press Enter to continue..."; }

# ----------------------------------------------------------------------------
#  CORE INSTALLATION (Iran Optimized)
# ----------------------------------------------------------------------------
ensure_deps() {
    echo -e "${YELLOW}📦 Installing dependencies...${NC}"
    if command -v apt &>/dev/null; then
        apt-get update -qq >/dev/null
        apt-get install -y curl wget git tar openssl iproute2 >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y curl wget git tar openssl iproute2 >/dev/null 2>&1
    else
        die "Unsupported package manager"
    fi
    ok "Dependencies installed"
}

install_go() {
    # تنظیمات پروکسی برای ایران
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
    curl -fsSL -L "$url" -o /tmp/go.tgz || die "Go download failed."
    tar -C /usr/local -xzf /tmp/go.tgz
    rm -f /tmp/go.tgz
    export PATH="/usr/local/go/bin:${PATH}"
    ok "Go environment ready."
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

    if [[ -f "${SCRIPT_DIR}/cmd/server/main.go" || -f "${SCRIPT_DIR}/cmd/client/main.go" ]]; then
        echo -e "${YELLOW}📁 Using local source (current directory) ...${NC}"
        mkdir -p "$BUILD_DIR"
        # copy everything except common junk
        rsync -a --delete \
          --exclude ".git" --exclude "bin" --exclude "dist" --exclude "node_modules" \
          "${SCRIPT_DIR}/" "$BUILD_DIR/" >/dev/null 2>&1 || cp -a "${SCRIPT_DIR}/." "$BUILD_DIR/"
    else
        echo -e "${YELLOW}🌐 Cloning from GitHub ...${NC}"
        git clone --depth 1 "$REPO_URL" "$BUILD_DIR" >/dev/null
    fi

    cd "$BUILD_DIR"
    echo -e "${YELLOW}🔧 Fixing build environment (Iran Safe)...${NC}"

    # اصلاح ساختار ماژول و ایمپورت‌ها برای رفع ارور بیلد
    rm -f go.mod go.sum
    go mod init github.com/amir6dev/rstunnel >/dev/null 2>&1 || true

    find . -name "*.go" -type f -exec sed -i 's|github.com/amir6dev/RsTunnel/PicoTun|github.com/amir6dev/rstunnel/PicoTun|g' {} +
    find . -name "*.go" -type f -exec sed -i 's|github.com/amir6dev/RsTunnel|github.com/amir6dev/rstunnel|g' {} +

    # پین کردن نسخه کتابخانه‌ها (جلوگیری از ارور 403 گوگل)
    go get golang.org/x/net@v0.23.0 >/dev/null 2>&1
    go get github.com/refraction-networking/utls@v1.6.0 >/dev/null 2>&1
    go get github.com/xtaci/smux@v1.5.24 >/dev/null 2>&1
    go get gopkg.in/yaml.v3@v3.0.1 >/dev/null 2>&1
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
#  Wizard Blocks (Dagger-like questions)
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
    # NOTE: در کد فعلی endpoint سرور /tunnel است. اگر مسیر دیگری بدهید، فقط ServerURL کلاینت عوض می‌شود.
    # برای جلوگیری از اشتباه، اگر چیزی غیر از /tunnel وارد شد هشدار می‌دهیم.
    if [[ "$FAKE_PATH" != "/tunnel" ]]; then
        warn "در نسخه فعلی، مسیر سرور فقط /tunnel است. مسیر را به /tunnel برمی‌گردانیم."
        FAKE_PATH="/tunnel"
    fi

    read -r -p "User-Agent [Mozilla/5.0]: " USER_AGENT
    USER_AGENT=${USER_AGENT:-Mozilla/5.0}

    read -r -p "Enable Session Cookie header? [Y/n]: " SESSION_COOKIE
    if [[ "${SESSION_COOKIE}" =~ ^[Nn] ]]; then SESSION_COOKIE_BOOL="false"; else SESSION_COOKIE_BOOL="true"; fi

    CUSTOM_HEADERS_YAML=""
    echo ""
    echo -e "${YELLOW}Custom Headers (Optional)${NC}"
    echo -e "${YELLOW}Example: X-Forwarded-For: 1.2.3.4${NC}"
    while true; do
        read -r -p "Add custom header? [y/N]: " yn
        [[ ! "$yn" =~ ^[Yy] ]] && break
        read -r -p "  Header (Key: Value): " hdr
        hdr="$(echo "$hdr" | sed 's/^ *//;s/ *$//')"
        if [[ -z "$hdr" || "$hdr" != *:* ]]; then
            warn "Invalid header format. Skipping."
            continue
        fi
        CUSTOM_HEADERS_YAML="${CUSTOM_HEADERS_YAML}    - "${hdr}"
"
        ok "Added header: $hdr"
    done

    if [[ -z "$CUSTOM_HEADERS_YAML" ]]; then
        CUSTOM_HEADERS_BLOCK="  custom_headers: []"
    else
        CUSTOM_HEADERS_BLOCK=$'  custom_headers:
'"${CUSTOM_HEADERS_YAML%\n}"
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

    for v in MIN_PAD MAX_PAD MIN_DELAY MAX_DELAY; do
        if ! [[ "${!v}" =~ ^[0-9]+$ ]]; then
            warn "Invalid ${v}, using default."
        fi
    done
}

# Port Mapping parser like DaggerConnect (TCP only; UDP not implemented in current core)
build_port_mappings_tcp() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      PORT MAPPINGS (Reverse TCP)      ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Help:${NC}"
    echo "  ${GREEN}Single Port${NC}:        8008                 → Bind=8008, Target=8008"
    echo "  ${GREEN}Range${NC}:             1000/1010            → 1000→1000 ... 1010→1010"
    echo "  ${GREEN}Custom Mapping${NC}:    5000=8008            → 5000→8008"
    echo "  ${GREEN}Range Mapping${NC}:     1000/1010=2000/2010  → 1000→2000 ... 1010→2010"
    echo ""

    read -r -p "Bind IP [0.0.0.0]: " BIND_IP
    BIND_IP=${BIND_IP:-0.0.0.0}
    read -r -p "Target IP [127.0.0.1]: " TARGET_IP
    TARGET_IP=${TARGET_IP:-127.0.0.1}

    MAPPINGS_TCP_YAML=""
    COUNT=0

    while true; do
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}  Mapping #$((COUNT+1))${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        read -r -p "Enter port(s) (or empty to finish): " PORT_INPUT
        PORT_INPUT="$(echo "${PORT_INPUT:-}" | tr -d ' ')"
        [[ -z "$PORT_INPUT" ]] && break

        # 1) Range Mapping: a/b=c/d
        if [[ "$PORT_INPUT" =~ ^([0-9]+)/([0-9]+)=([0-9]+)/([0-9]+)$ ]]; then
            BIND_START="${BASH_REMATCH[1]}"; BIND_END="${BASH_REMATCH[2]}"
            TARGET_START="${BASH_REMATCH[3]}"; TARGET_END="${BASH_REMATCH[4]}"
            BIND_RANGE=$((BIND_END - BIND_START + 1))
            TARGET_RANGE=$((TARGET_END - TARGET_START + 1))
            if [[ "$BIND_RANGE" -ne "$TARGET_RANGE" ]]; then
                warn "Range size mismatch!"
                continue
            fi
            if [[ "$BIND_START" -lt 1 || "$BIND_END" -gt 65535 || "$TARGET_START" -lt 1 || "$TARGET_END" -gt 65535 ]]; then
                warn "Invalid port range (1-65535)"
                continue
            fi
            for ((i=0; i<BIND_RANGE; i++)); do
                BP=$((BIND_START + i))
                TP=$((TARGET_START + i))
                MAPPINGS_TCP_YAML+=$'    - "'"${BIND_IP}:${BP}->${TARGET_IP}:${TP}"$'"
'
                COUNT=$((COUNT + 1))
            done
            ok "Added ${BIND_RANGE} mappings: ${BIND_START}→${TARGET_START} ... ${BIND_END}→${TARGET_END}"
            continue
        fi

        # 2) Range: a/b (Bind=Target)
        if [[ "$PORT_INPUT" =~ ^([0-9]+)/([0-9]+)$ ]]; then
            START_PORT="${BASH_REMATCH[1]}"; END_PORT="${BASH_REMATCH[2]}"
            if [[ "$START_PORT" -gt "$END_PORT" ]]; then
                warn "Start port cannot be greater than end port."
                continue
            fi
            if [[ "$START_PORT" -lt 1 || "$END_PORT" -gt 65535 ]]; then
                warn "Invalid port range (1-65535)"
                continue
            fi
            for ((p=START_PORT; p<=END_PORT; p++)); do
                MAPPINGS_TCP_YAML+=$'    - "'"${BIND_IP}:${p}->${TARGET_IP}:${p}"$'"
'
                COUNT=$((COUNT + 1))
            done
            ok "Added $((END_PORT-START_PORT+1)) mappings (Bind=Target)"
            continue
        fi

        # 3) Custom Mapping: a=b
        if [[ "$PORT_INPUT" =~ ^([0-9]+)=([0-9]+)$ ]]; then
            BP="${BASH_REMATCH[1]}"; TP="${BASH_REMATCH[2]}"
            if [[ "$BP" -lt 1 || "$BP" -gt 65535 || "$TP" -lt 1 || "$TP" -gt 65535 ]]; then
                warn "Invalid ports (1-65535)"
                continue
            fi
            MAPPINGS_TCP_YAML+=$'    - "'"${BIND_IP}:${BP}->${TARGET_IP}:${TP}"$'"
'
            COUNT=$((COUNT + 1))
            ok "Added mapping: ${BP}→${TP}"
            continue
        fi

        # 4) Single Port: a (Bind=Target)
        if [[ "$PORT_INPUT" =~ ^([0-9]+)$ ]]; then
            BP="${BASH_REMATCH[1]}"; TP="${BASH_REMATCH[1]}"
            if [[ "$BP" -lt 1 || "$BP" -gt 65535 ]]; then
                warn "Invalid port (1-65535)"
                continue
            fi
            MAPPINGS_TCP_YAML+=$'    - "'"${BIND_IP}:${BP}->${TARGET_IP}:${TP}"$'"
'
            COUNT=$((COUNT + 1))
            ok "Added mapping: ${BP}→${TP}"
            continue
        fi

        warn "Invalid format. Try again."
    done

    if [[ -z "$MAPPINGS_TCP_YAML" ]]; then
        warn "No TCP mappings added. (Reverse TCP listeners will not start)"
    else
        ok "Total TCP mappings: $COUNT"
    fi
}


# Port Mapping parser like DaggerConnect (UDP)
build_port_mappings_udp() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      PORT MAPPINGS (Reverse UDP)      ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Help:${NC}"
    echo "  ${GREEN}Single Port${NC}:        8008                 → Bind=8008, Target=8008"
    echo "  ${GREEN}Range${NC}:             1000/1010            → 1000→1000 ... 1010→1010"
    echo "  ${GREEN}Custom Mapping${NC}:    5000=8008            → 5000→8008"
    echo "  ${GREEN}Range Mapping${NC}:     1000/1010=2000/2010  → 1000→2000 ... 1010→2010"
    echo ""

    read -r -p "Bind IP [0.0.0.0]: " BIND_IP_UDP
    BIND_IP_UDP=${BIND_IP_UDP:-0.0.0.0}
    read -r -p "Target IP [127.0.0.1]: " TARGET_IP_UDP
    TARGET_IP_UDP=${TARGET_IP_UDP:-127.0.0.1}

    MAPPINGS_UDP_YAML=""
    COUNT_UDP=0

    while true; do
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}  UDP Mapping #$((COUNT_UDP+1))${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        read -r -p "Enter port(s) (or empty to finish): " PORT_INPUT
        PORT_INPUT="$(echo "${PORT_INPUT:-}" | tr -d ' ')"
        [[ -z "$PORT_INPUT" ]] && break

        # 1) Range Mapping: a/b=c/d
        if [[ "$PORT_INPUT" =~ ^([0-9]+)/([0-9]+)=([0-9]+)/([0-9]+)$ ]]; then
            BIND_START="${BASH_REMATCH[1]}"; BIND_END="${BASH_REMATCH[2]}"
            TARGET_START="${BASH_REMATCH[3]}"; TARGET_END="${BASH_REMATCH[4]}"
            BIND_RANGE=$((BIND_END - BIND_START + 1))
            TARGET_RANGE=$((TARGET_END - TARGET_START + 1))
            if [[ "$BIND_RANGE" -ne "$TARGET_RANGE" ]]; then
                warn "Range size mismatch!"
                continue
            fi
            if [[ "$BIND_START" -lt 1 || "$BIND_END" -gt 65535 || "$TARGET_START" -lt 1 || "$TARGET_END" -gt 65535 ]]; then
                warn "Invalid port range (1-65535)"
                continue
            fi
            for ((i=0; i<BIND_RANGE; i++)); do
                BP=$((BIND_START + i))
                TP=$((TARGET_START + i))
                MAPPINGS_UDP_YAML+=$'    - "'"${BIND_IP_UDP}:${BP}->${TARGET_IP_UDP}:${TP}"$'"\n"
                COUNT_UDP=$((COUNT_UDP + 1))
            done
            ok "Added ${BIND_RANGE} UDP mappings: ${BIND_START}→${TARGET_START} ... ${BIND_END}→${TARGET_END}"
            continue
        fi

        # 2) Range: a/b (Bind=Target)
        if [[ "$PORT_INPUT" =~ ^([0-9]+)/([0-9]+)$ ]]; then
            START_PORT="${BASH_REMATCH[1]}"; END_PORT="${BASH_REMATCH[2]}"
            if [[ "$START_PORT" -gt "$END_PORT" ]]; then
                warn "Start port cannot be greater than end port."
                continue
            fi
            if [[ "$START_PORT" -lt 1 || "$END_PORT" -gt 65535 ]]; then
                warn "Invalid port range (1-65535)"
                continue
            fi
            for ((p=START_PORT; p<=END_PORT; p++)); do
                MAPPINGS_UDP_YAML+=$'    - "'"${BIND_IP_UDP}:${p}->${TARGET_IP_UDP}:${p}"$'"\n"
                COUNT_UDP=$((COUNT_UDP + 1))
            done
            ok "Added $((END_PORT-START_PORT+1)) UDP mappings (Bind=Target)"
            continue
        fi

        # 3) Custom Mapping: a=b
        if [[ "$PORT_INPUT" =~ ^([0-9]+)=([0-9]+)$ ]]; then
            BP="${BASH_REMATCH[1]}"; TP="${BASH_REMATCH[2]}"
            if [[ "$BP" -lt 1 || "$BP" -gt 65535 || "$TP" -lt 1 || "$TP" -gt 65535 ]]; then
                warn "Invalid ports (1-65535)"
                continue
            fi
            MAPPINGS_UDP_YAML+=$'    - "'"${BIND_IP_UDP}:${BP}->${TARGET_IP_UDP}:${TP}"$'"\n"
            COUNT_UDP=$((COUNT_UDP + 1))
            ok "Added UDP mapping: ${BP}→${TP}"
            continue
        fi

        # 4) Single Port: a (Bind=Target)
        if [[ "$PORT_INPUT" =~ ^([0-9]+)$ ]]; then
            BP="${BASH_REMATCH[1]}"; TP="${BASH_REMATCH[1]}"
            if [[ "$BP" -lt 1 || "$BP" -gt 65535 ]]; then
                warn "Invalid port (1-65535)"
                continue
            fi
            MAPPINGS_UDP_YAML+=$'    - "'"${BIND_IP_UDP}:${BP}->${TARGET_IP_UDP}:${TP}"$'"\n"
            COUNT_UDP=$((COUNT_UDP + 1))
            ok "Added UDP mapping: ${BP}→${TP}"
            continue
        fi

        warn "Invalid format. Try again."
    done

    if [[ -z "$MAPPINGS_UDP_YAML" ]]; then
        warn "No UDP mappings added. (Reverse UDP listeners will not start)"
    else
        ok "Total UDP mappings: $COUNT_UDP"
    fi
}

# ----------------------------------------------------------------------------
#  Config Writers
# ----------------------------------------------------------------------------
write_server_config() {
    mkdir -p "$CONFIG_DIR"
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
  tcp:
$(printf "%s" "${MAPPINGS_TCP_YAML:-}")
  udp:
$(printf "%s" "${MAPPINGS_UDP_YAML:-}")
EOF
}

write_client_config() {
    mkdir -p "$CONFIG_DIR"
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
  udp:
$(printf "%s" "${MAPPINGS_UDP_YAML:-}")
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
#  Wizards
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
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      REVERSE MODE (TCP/UDP)           ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""
    echo "1) TCP only (recommended)"
    echo "2) UDP only"
    echo "3) TCP + UDP"
    echo "4) None"
    read -r -p "Select [1]: " REV_MODE
    REV_MODE=${REV_MODE:-1}

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
    echo -e "Listen: ${YELLOW}${LISTEN_ADDR}${NC}"
    echo -e "Endpoint: ${YELLOW}${FAKE_PATH}${NC}"
    echo -e "PSK: ${YELLOW}${PSK}${NC} (Copy this for client)"
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

    # Mimic/Obfs should match server
    ask_mimic
    ask_obfs

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
