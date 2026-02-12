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
	local NEED_INSTALL=0
	local MISSING=()
	for c in curl wget git tar openssl ip; do
		if ! command -v "$c" >/dev/null 2>&1; then
			NEED_INSTALL=1
			MISSING+=("$c")
		fi
	done

	if [[ $NEED_INSTALL -eq 0 ]]; then
		ok "Dependencies already installed"
		return 0
	fi

	echo -e "${YELLOW}📦 Installing dependencies...${NC}"
	warn "Missing: ${MISSING[*]}"
	if command -v apt-get &>/dev/null; then
		apt-get update -qq >/dev/null
		apt-get install -y curl wget git tar openssl iproute2 >/dev/null 2>&1 || die "Failed to install dependencies"
	elif command -v yum &>/dev/null; then
		yum install -y curl wget git tar openssl iproute2 >/dev/null 2>&1 || die "Failed to install dependencies"
	else
		die "Unsupported package manager. Install curl/wget/git/tar/openssl/iproute2 manually."
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

    # If our current working dir was deleted (common when rerunning), recover safely
    cd / || true

    export PATH="/usr/local/go/bin:${PATH}"
    export GOPROXY=https://goproxy.cn,direct
    export GOTOOLCHAIN=local
    export GOSUMDB=off

    echo -e "${YELLOW}⬇️  Preparing source code...${NC}"

    # Use a unique build dir to avoid getcwd issues and parallel runs
    BUILD_DIR="$(mktemp -d /tmp/picobuild.XXXXXX)"
    trap 'rm -rf "$BUILD_DIR" >/dev/null 2>&1 || true' RETURN

    # Clone
    echo -e "${YELLOW}🌐 Cloning from GitHub ...${NC}"
    if ! git clone --depth 1 "$REPO_URL" "$BUILD_DIR"; then
        die "Failed to clone repository."
    fi

    cd "$BUILD_DIR" || die "Cannot enter build dir"

    echo -e "${YELLOW}🔧 Fixing build environment (Iran Safe)...${NC}"

    # Keep project's go.mod (do NOT delete it). Only normalize module/import casing if needed.
    if [[ -f go.mod ]]; then
        sed -i 's|^module github.com/amir6dev/RsTunnel/PicoTun$|module github.com/amir6dev/rstunnel/PicoTun|g' go.mod || true
        sed -i 's|github.com/amir6dev/RsTunnel/PicoTun|github.com/amir6dev/rstunnel/PicoTun|g' -R . 2>/dev/null || true
    fi

    echo -e "${YELLOW}📦 Downloading Libraries...${NC}"
    go mod tidy >/dev/null 2>&1 || true
    go mod download >/dev/null 2>&1 || true

    echo -e "${YELLOW}🔨 Building binary...${NC}"
    go build -trimpath -o picotun ./cmd/picotun || die "Build failed."

    install -m 755 picotun "$BIN_PATH" || die "Cannot install binary"
    ok "Core updated: $BIN_PATH"

    # Build dir cleaned by trap
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
    echo -e "${CYAN}      HTTP MIMICRY SETTINGS            ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    read -r -p "Fake domain (e.g., www.google.com) [www.google.com]: " FAKE_DOMAIN
    FAKE_DOMAIN=${FAKE_DOMAIN:-www.google.com}

    read -r -p "Fake path (e.g., /search) [/search]: " FAKE_PATH
    FAKE_PATH=${FAKE_PATH:-/search}
    if [[ ! "$FAKE_PATH" =~ ^/ ]]; then
        FAKE_PATH="/$FAKE_PATH"
    fi

    echo ""
    echo "Select User-Agent:"
    echo "  1) Chrome Windows (default)"
    echo "  2) Firefox Windows"
    echo "  3) Chrome macOS"
    echo "  4) Safari macOS"
    echo "  5) Chrome Android"
    echo "  6) Custom"
    read -r -p "Choice [1-6]: " UA_CHOICE
    UA_CHOICE=${UA_CHOICE:-1}

    case "$UA_CHOICE" in
        1) USER_AGENT='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' ;;
        2) USER_AGENT='Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:122.0) Gecko/20100101 Firefox/122.0' ;;
        3) USER_AGENT='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' ;;
        4) USER_AGENT='Mozilla/5.0 (Macintosh; Intel Mac OS X 13_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15' ;;
        5) USER_AGENT='Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36' ;;
        6)
            read -r -p "Enter custom User-Agent: " USER_AGENT
            USER_AGENT=${USER_AGENT:-Mozilla/5.0}
            ;;
        *) USER_AGENT='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' ;;
    esac

    read -r -p "Enable chunked encoding? [Y/n]: " CHUNKED_TE
    if [[ "${CHUNKED_TE}" =~ ^[Nn] ]]; then CHUNKED_BOOL="false"; else CHUNKED_BOOL="true"; fi

    read -r -p "Enable session cookies? [Y/n]: " SESSION_COOKIE
    if [[ "${SESSION_COOKIE}" =~ ^[Nn] ]]; then SESSION_COOKIE_BOOL="false"; else SESSION_COOKIE_BOOL="true"; fi

    # Defaults like Dagger
    CUSTOM_HEADERS_YAML="    - \"X-Requested-With: XMLHttpRequest\"\n    - \"Referer: https://${FAKE_DOMAIN}/\"\n"

    echo ""
    read -r -p "Add extra custom headers? [y/N]: " addh
    if [[ "$addh" =~ ^[Yy] ]]; then
        while true; do
            read -r -p "Header (Key: Value) (empty to finish): " HLINE
            [[ -z "$HLINE" ]] && break
            CUSTOM_HEADERS_YAML="${CUSTOM_HEADERS_YAML}    - \"${HLINE}\"\n"
        done
    fi
}


ask_obfs() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      TRAFFIC OBFUSCATION              ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    read -r -p "Enable Traffic Obfuscation? [Y/n]: " ENABLE_OBFS
    if [[ "$ENABLE_OBFS" =~ ^[Nn] ]]; then
        OBFS_BOOL="false"
        MIN_PAD=16; MAX_PAD=512; MIN_DELAY=0; MAX_DELAY=0; BURST_CHANCE=0
        return
    fi

    OBFS_BOOL="true"
    read -r -p "Min Padding bytes [16]: " MIN_PAD
    MIN_PAD=${MIN_PAD:-16}
    read -r -p "Max Padding bytes [512]: " MAX_PAD
    MAX_PAD=${MAX_PAD:-512}
    read -r -p "Min Delay (ms) [5]: " MIN_DELAY
    MIN_DELAY=${MIN_DELAY:-5}
    read -r -p "Max Delay (ms) [50]: " MAX_DELAY
    MAX_DELAY=${MAX_DELAY:-50}
    read -r -p "Burst chance (0.00-1.00) [0.15]: " BURST_CHANCE
    BURST_CHANCE=${BURST_CHANCE:-0.15}
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

    local MAPS_BLOCK=""
    # Convert MAPPINGS_TCP_YAML lines into dagger-style map objects
    if [[ -n "${MAPPINGS_TCP_YAML:-}" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ "$line" =~ \"([^\"]+)\" ]]; then
                local pair="${BASH_REMATCH[1]}"
                local bind="${pair%%->*}"
                local target="${pair##*->}"
                MAPS_BLOCK="${MAPS_BLOCK}  - type: tcp\n    bind: \"${bind}\"\n    target: \"${target}\"\n"
            fi
        done <<< "$(printf "%b" "$MAPPINGS_TCP_YAML")"
    fi

    if [[ -n "${MAPPINGS_UDP_YAML:-}" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ "$line" =~ \"([^\"]+)\" ]]; then
                local pair="${BASH_REMATCH[1]}"
                local bind="${pair%%->*}"
                local target="${pair##*->}"
                MAPS_BLOCK="${MAPS_BLOCK}  - type: udp\n    bind: \"${bind}\"\n    target: \"${target}\"\n"
            fi
        done <<< "$(printf "%b" "$MAPPINGS_UDP_YAML")"
    fi

    # Always have maps key
    if [[ -z "$MAPS_BLOCK" ]]; then
        MAPS_BLOCK="  []"
    else
        MAPS_BLOCK="$(printf "%b" "$MAPS_BLOCK")"
    fi

    cat > "$CONFIG_DIR/server.yaml" <<EOF
mode: "server"
listen: "${LISTEN_ADDR}"
transport: "httpmux"
psk: "${PSK}"
profile: "${PROFILE}"
verbose: ${VERBOSE}

heartbeat: ${HEARTBEAT}

maps:
$(printf "%b" "$MAPS_BLOCK")

advanced:
  session_timeout: ${SESSION_TIMEOUT}

obfuscation:
  enabled: ${OBFS_BOOL}
  min_padding: ${MIN_PAD}
  max_padding: ${MAX_PAD}
  min_delay_ms: ${MIN_DELAY}
  max_delay_ms: ${MAX_DELAY}
  burst_chance: ${BURST_CHANCE}

http_mimic:
  fake_domain: "${FAKE_DOMAIN}"
  fake_path: "${FAKE_PATH}"
  user_agent: "${USER_AGENT}"
  chunked_encoding: ${CHUNKED_BOOL}
  session_cookie: ${SESSION_COOKIE_BOOL}
  custom_headers:
$(printf "%b" "${CUSTOM_HEADERS_YAML:-    - \"Accept-Language: en-US,en;q=0.9\"\n    - \"Accept-Encoding: gzip, deflate, br\"\n}")
EOF
}


write_client_config() {
    mkdir -p "$CONFIG_DIR"

    # Paths YAML (support multiple later; currently 1)
    local PATHS_YAML=""
    PATHS_YAML="${PATHS_YAML}  - transport: \"httpmux\"\n"
    PATHS_YAML="${PATHS_YAML}    addr: \"${SIP}:${SPORT}\"\n"
    PATHS_YAML="${PATHS_YAML}    connection_pool: ${POOL_SIZE}\n"
    PATHS_YAML="${PATHS_YAML}    aggressive_pool: ${AGGRESSIVE_POOL}\n"
    PATHS_YAML="${PATHS_YAML}    retry_interval: ${RETRY_INTERVAL}\n"
    PATHS_YAML="${PATHS_YAML}    dial_timeout: ${DIAL_TIMEOUT}\n"

    cat > "$CONFIG_DIR/client.yaml" <<EOF
mode: "client"
psk: "${PSK}"
profile: "${PROFILE}"
verbose: ${VERBOSE}

paths:
$(printf "%b" "$PATHS_YAML")

obfuscation:
  enabled: ${OBFS_BOOL}
  min_padding: ${MIN_PAD}
  max_padding: ${MAX_PAD}
  min_delay_ms: ${MIN_DELAY}
  max_delay_ms: ${MAX_DELAY}
  burst_chance: ${BURST_CHANCE}

http_mimic:
  fake_domain: "${FAKE_DOMAIN}"
  fake_path: "${FAKE_PATH}"
  user_agent: "${USER_AGENT}"
  chunked_encoding: ${CHUNKED_BOOL}
  session_cookie: ${SESSION_COOKIE_BOOL}
  custom_headers:
$(printf "%b" "${CUSTOM_HEADERS_YAML:-    - \"X-Requested-With: XMLHttpRequest\"\n    - \"Referer: https://${FAKE_DOMAIN}/\"\n}")
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
    echo -e "${CYAN}      SERVER CONFIGURATION             ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    read -r -p "Tunnel Port [2020]: " LPORT
    LPORT=${LPORT:-2020}
    LISTEN_ADDR="0.0.0.0:${LPORT}"

    read -r -p "Enter PSK (Pre-Shared Key): " PSK
    [[ -z "${PSK}" ]] && die "PSK is required"

    echo ""
    echo "Select Transport:"
    echo "  1) httpmux   - HTTP Mimicry"
    read -r -p "Choice [1]: " TR
    TR=${TR:-1}

    PROFILE="latency"
    HEARTBEAT=2
    SESSION_TIMEOUT=15

    read -r -p "Optimize system now? [Y/n]: " opt
    if [[ ! "$opt" =~ ^[Nn] ]]; then
        optimize_system || true
    fi

    # Port mappings like Dagger
    MAPPINGS_TCP_YAML=""
    MAPPINGS_UDP_YAML=""

    echo ""
    echo -e "${CYAN}PORT MAPPINGS${NC}"
    COUNT=0
    while true; do
        echo ""
        echo "Port Mapping #$((COUNT+1))"
        read -r -p "Bind Port (port on this server, e.g., 2222): " BPORT
        [[ -z "$BPORT" ]] && break
        read -r -p "Target Port (destination port, e.g., 22): " TPORT
        [[ -z "$TPORT" ]] && die "Target port required"
        read -r -p "Protocol (tcp/udp/both) [tcp]: " PROTO
        PROTO=${PROTO:-tcp}
        case "$PROTO" in
            tcp|TCP)
                MAPPINGS_TCP_YAML="${MAPPINGS_TCP_YAML}    - \"0.0.0.0:${BPORT}->127.0.0.1:${TPORT}\"\n"
                ok "Mapping added: 0.0.0.0:${BPORT} → 127.0.0.1:${TPORT} (tcp)"
                ;;
            udp|UDP)
                MAPPINGS_UDP_YAML="${MAPPINGS_UDP_YAML}    - \"0.0.0.0:${BPORT}->127.0.0.1:${TPORT}\"\n"
                ok "Mapping added: 0.0.0.0:${BPORT} → 127.0.0.1:${TPORT} (udp)"
                ;;
            both|BOTH)
                MAPPINGS_TCP_YAML="${MAPPINGS_TCP_YAML}    - \"0.0.0.0:${BPORT}->127.0.0.1:${TPORT}\"\n"
                MAPPINGS_UDP_YAML="${MAPPINGS_UDP_YAML}    - \"0.0.0.0:${BPORT}->127.0.0.1:${TPORT}\"\n"
                ok "Mapping added: 0.0.0.0:${BPORT} → 127.0.0.1:${TPORT} (both)"
                ;;
            *)
                warn "Invalid protocol, defaulting to tcp"
                MAPPINGS_TCP_YAML="${MAPPINGS_TCP_YAML}    - \"0.0.0.0:${BPORT}->127.0.0.1:${TPORT}\"\n"
                ;;
        esac

        read -r -p "Add another mapping? [y/N]: " more
        if [[ ! "$more" =~ ^[Yy] ]]; then
            break
        fi
        COUNT=$((COUNT+1))
    done

    # Mimic + obfs (server usually no delay)
    ask_mimic
    # Server-side default: obfs enabled but delay 0 (similar to Dagger sample)
    OBFS_BOOL="true"; MIN_PAD=8; MAX_PAD=32; MIN_DELAY=0; MAX_DELAY=0; BURST_CHANCE=0

    read -r -p "Enable verbose logging? [Y/n]: " v
    if [[ "$v" =~ ^[Nn] ]]; then VERBOSE="false"; else VERBOSE="true"; fi

    write_server_config
    create_service "server"

    systemctl restart picotun-server || true

    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo -e "  Tunnel Port: ${YELLOW}${LPORT}${NC}"
    echo -e "  PSK: ${YELLOW}${PSK}${NC}"
    echo -e "  Transport: ${YELLOW}httpmux${NC}"
    echo -e "  Config: ${YELLOW}${CONFIG_DIR}/server.yaml${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    pause
}


configure_client() {
    banner
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      CLIENT CONFIGURATION             ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    echo "Configuration Mode:"
    echo "  1) Automatic - Optimized settings (Recommended)"
    echo "  2) Manual - Custom configuration"
    read -r -p "Choice [1-2]: " CMODE
    CMODE=${CMODE:-1}

    read -r -p "Enter PSK (must match server): " PSK
    [[ -z "${PSK}" ]] && die "PSK is required"

    echo ""
    echo "Select Performance Profile:"
    echo "  1) balanced      - Standard balanced performance (Recommended)"
    echo "  2) aggressive    - High speed, aggressive settings"
    echo "  3) latency       - Optimized for low latency"
    echo "  4) cpu-efficient - Low CPU usage"
    echo "  5) gaming        - Optimized for gaming (low latency + high speed)"
    read -r -p "Choice [1-5]: " PSEL
    PSEL=${PSEL:-1}
    case "$PSEL" in
        1) PROFILE="balanced" ;;
        2) PROFILE="aggressive" ;;
        3) PROFILE="latency" ;;
        4) PROFILE="cpu-efficient" ;;
        5) PROFILE="gaming" ;;
        *) PROFILE="balanced" ;;
    esac

    # Obfuscation (Dagger default = enabled)
    if [[ "$CMODE" == "1" ]]; then
        OBFS_BOOL="true"; MIN_PAD=16; MAX_PAD=512; MIN_DELAY=5; MAX_DELAY=50; BURST_CHANCE=0.15
    else
        ask_obfs
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}      CONNECTION PATHS                 ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo ""

    # Transport selection (only httpmux implemented in RsTunnel right now)
    echo "Select Transport Type:"
    echo "  1) httpmux  - HTTP Mimicry"
    read -r -p "Choice [1]: " TCH
    TCH=${TCH:-1}
    if [[ "$TCH" != "1" ]]; then
        warn "Only httpmux is available in RsTunnel. Using httpmux."
    fi

    read -r -p "Server address with Tunnel Port (e.g., 1.2.3.4:2020): " ADDR
    [[ -z "$ADDR" ]] && die "Server address required"
    SIP="${ADDR%%:*}"
    SPORT="${ADDR##*:}"

    # Pool options
    POOL_SIZE=2
    AGGRESSIVE_POOL="false"
    RETRY_INTERVAL=3
    DIAL_TIMEOUT=10

    if [[ "$CMODE" == "2" ]]; then
        read -r -p "Connection pool size [2]: " POOL_SIZE
        POOL_SIZE=${POOL_SIZE:-2}
        read -r -p "Enable aggressive pool? [y/N]: " ap
        if [[ "$ap" =~ ^[Yy] ]]; then AGGRESSIVE_POOL="true"; else AGGRESSIVE_POOL="false"; fi
        read -r -p "Retry interval (seconds) [3]: " RETRY_INTERVAL
        RETRY_INTERVAL=${RETRY_INTERVAL:-3}
        read -r -p "Dial timeout (seconds) [10]: " DIAL_TIMEOUT
        DIAL_TIMEOUT=${DIAL_TIMEOUT:-10}
    else
        # Automatic defaults similar to Dagger's wizard defaults
        AGGRESSIVE_POOL="true"
    fi

    ask_mimic

    read -r -p "Enable verbose logging? [y/N]: " v
    if [[ "$v" =~ ^[Yy] ]]; then VERBOSE="true"; else VERBOSE="false"; fi

    write_client_config
    create_service "client"
    systemctl restart picotun-client || true
    ok "Client installation complete!"
    echo "Config: $CONFIG_DIR/client.yaml"
    echo "View logs: journalctl -u picotun-client -f"
    pause
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
cd / || true
main_menu