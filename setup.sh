#!/usr/bin/env bash
set -euo pipefail

REPO="amir6dev/RsTunnel"
BIN_NAME="picotun"
INSTALL_BIN="/usr/local/bin/${BIN_NAME}"
CFG_DIR="/etc/picotun"
SERVER_CFG="${CFG_DIR}/server.yaml"
CLIENT_CFG="${CFG_DIR}/client.yaml"
VER_FILE="${CFG_DIR}/.version"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

info() { echo -e "${COLOR_BLUE}ℹ️  $*${COLOR_RESET}"; }
ok()   { echo -e "${COLOR_GREEN}✅ $*${COLOR_RESET}"; }
warn() { echo -e "${COLOR_YELLOW}⚠️  $*${COLOR_RESET}"; }
err()  { echo -e "${COLOR_RED}❌ $*${COLOR_RESET}"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Please run as root (sudo)."
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_deps() {
  local pkgs=(curl tar sed awk grep systemctl)
  local missing=()
  for p in "${pkgs[@]}"; do
    if ! need_cmd "$p"; then
      missing+=("$p")
    fi
  done
  if ((${#missing[@]}==0)); then
    return
  fi

  info "Installing dependencies: ${missing[*]}"
  if need_cmd apt-get; then
    apt-get update -y
    apt-get install -y curl ca-certificates tar nano
  elif need_cmd yum; then
    yum install -y curl ca-certificates tar nano
  elif need_cmd dnf; then
    dnf install -y curl ca-certificates tar nano
  else
    err "Unsupported package manager. Please install: curl, tar, nano"
    exit 1
  fi
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64";;
    aarch64|arm64) echo "arm64";;
    *)
      err "Unsupported arch: $arch (only amd64/arm64 supported)"
      exit 1
      ;;
  esac
}

get_latest_tag() {
  # Prefer GitHub API (no redirect weirdness)
  local tag
  tag="$(
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
      | grep -m1 '"tag_name"' \
      | sed -E 's/.*"tag_name"\s*:\s*"([^"]+)".*/\1/'
  )" || true

  if [[ -z "${tag}" || "${tag}" == "null" ]]; then
    err "Could not fetch latest release tag from GitHub API."
    exit 1
  fi
  echo "$tag"
}

get_installed_tag() {
  if [[ -f "${VER_FILE}" ]]; then
    cat "${VER_FILE}" 2>/dev/null || true
  fi
}

set_installed_tag() {
  mkdir -p "${CFG_DIR}"
  echo -n "$1" > "${VER_FILE}"
}

download_and_install() {
  local tag="$1"
  local arch="$2"

  local asset="${BIN_NAME}_linux_${arch}.tar.gz"
  local url="https://github.com/${REPO}/releases/download/${tag}/${asset}"

  info "Downloading ${asset} (${tag})"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN

  if ! curl -fL --retry 3 --retry-delay 1 -o "${tmpdir}/${asset}" "$url"; then
    err "Failed to download asset: ${url}"
    err "Make sure your GitHub Release contains ${asset}."
    exit 1
  fi

  if ! tar -tzf "${tmpdir}/${asset}" >/dev/null 2>&1; then
    err "Downloaded file is not a valid tar.gz (maybe GitHub returned HTML/404)."
    exit 1
  fi

  tar -xzf "${tmpdir}/${asset}" -C "${tmpdir}"
  if [[ ! -f "${tmpdir}/${BIN_NAME}" ]]; then
    err "Archive does not contain ${BIN_NAME} binary."
    exit 1
  fi

  install -m 0755 "${tmpdir}/${BIN_NAME}" "${INSTALL_BIN}"
  set_installed_tag "$tag"
  ok "Installed ${INSTALL_BIN} (${tag})"
}

ensure_default_server_config() {
  mkdir -p "${CFG_DIR}"
  if [[ -f "${SERVER_CFG}" ]]; then
    return
  fi

  cat > "${SERVER_CFG}" <<'YAML'
mode: "server"
listen: "0.0.0.0:4040"
transport: "httpmux"
psk: "change_me_please"
profile: "aggressive"
verbose: false

# Example port mappings (Server side):
# Expose 1400 & 1402 on server and forward to local services on the server.
maps:
  - type: tcp
    bind: "0.0.0.0:1400"
    target: "127.0.0.1:1400"
  - type: udp
    bind: "0.0.0.0:1400"
    target: "127.0.0.1:1400"
  - type: tcp
    bind: "0.0.0.0:1402"
    target: "127.0.0.1:1402"
  - type: udp
    bind: "0.0.0.0:1402"
    target: "127.0.0.1:1402"

obfuscation:
  enabled: true
  min_padding: 16
  max_padding: 512
  min_delay_ms: 5
  max_delay_ms: 50
  burst_chance: 0.15

http_mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  chunked_encoding: true
  session_cookie: true
  custom_headers:
    - "X-Requested-With: XMLHttpRequest"
    - "Referer: https://www.google.com/"
YAML

  ok "Created default server config: ${SERVER_CFG}"
}

ensure_default_client_config() {
  mkdir -p "${CFG_DIR}"
  if [[ -f "${CLIENT_CFG}" ]]; then
    return
  fi

  cat > "${CLIENT_CFG}" <<'YAML'
mode: "client"
psk: "change_me_please"
profile: "aggressive"
verbose: false

# Add one or more paths (multi-path) to your server.
# addr can be "IP:PORT". For httpmux the path defaults to fake_path (/search).
paths:
  - transport: "httpmux"
    addr: "YOUR_SERVER_IP:4040"
    connection_pool: 4
    aggressive_pool: false
    retry_interval: 3
    dial_timeout: 10

obfuscation:
  enabled: true
  min_padding: 16
  max_padding: 512
  min_delay_ms: 5
  max_delay_ms: 50
  burst_chance: 0.15

http_mimic:
  fake_domain: "www.google.com"
  fake_path: "/search"
  user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  chunked_encoding: true
  session_cookie: true
  custom_headers:
    - "X-Requested-With: XMLHttpRequest"
    - "Referer: https://www.google.com/"
YAML

  ok "Created default client config: ${CLIENT_CFG}"
}

write_service() {
  local mode="$1" # server|client
  local unit="${BIN_NAME}-${mode}.service"
  local cfg
  if [[ "$mode" == "server" ]]; then
    cfg="${SERVER_CFG}"
  else
    cfg="${CLIENT_CFG}"
  fi

  cat > "/etc/systemd/system/${unit}" <<EOF
[Unit]
Description=RsTunnel Reverse Tunnel ${mode^}
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${CFG_DIR}
ExecStart=${INSTALL_BIN} -config ${cfg}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  ok "Created systemd service: ${unit}"
}

svc_name() {
  echo "${BIN_NAME}-$1"
}

svc_status() {
  systemctl --no-pager status "$(svc_name "$1")" || true
}

svc_restart() {
  systemctl restart "$(svc_name "$1")"
  ok "Restarted $(svc_name "$1")"
}

svc_logs() {
  journalctl -u "$(svc_name "$1")" -f
}

svc_enable() {
  systemctl enable "$(svc_name "$1")"
  ok "Enabled autostart: $(svc_name "$1")"
}

svc_disable() {
  systemctl disable "$(svc_name "$1")" || true
  ok "Disabled autostart: $(svc_name "$1")"
}

svc_stop() {
  systemctl stop "$(svc_name "$1")" || true
}

delete_mode() {
  local mode="$1"
  local unit="/etc/systemd/system/${BIN_NAME}-${mode}.service"
  svc_stop "$mode"
  rm -f "$unit"
  if [[ "$mode" == "server" ]]; then
    rm -f "${SERVER_CFG}"
  else
    rm -f "${CLIENT_CFG}"
  fi
  systemctl daemon-reload
  ok "Deleted ${mode} config + service"
}

ensure_binary_installed() {
  if [[ -x "${INSTALL_BIN}" ]]; then
    return
  fi
  warn "${INSTALL_BIN} not found. Installing latest release..."
  local tag arch
  tag="$(get_latest_tag)"
  arch="$(detect_arch)"
  download_and_install "$tag" "$arch"
}

install_server() {
  ensure_binary_installed
  ensure_default_server_config
  write_service "server"
  systemctl enable --now "$(svc_name server)"
  ok "Server installed + started."
}

install_client() {
  ensure_binary_installed
  ensure_default_client_config
  write_service "client"
  systemctl enable --now "$(svc_name client)"
  ok "Client installed + started."
}

update_core() {
  ensure_binary_installed
  local current latest arch
  current="$(get_installed_tag)"
  latest="$(get_latest_tag)"
  arch="$(detect_arch)"

<<<<<<< HEAD
write_server_service() {
  local cfg="$1"
  cat >"/etc/systemd/system/${SERVICE_SERVER}.service" <<EOF
[Unit]
Description=${APP_NAME} Reverse Tunnel Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH} -config ${cfg}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_client_service() {
  local cfg="$1"
  cat >"/etc/systemd/system/${SERVICE_CLIENT}.service" <<EOF
[Unit]
Description=${APP_NAME} Reverse Tunnel Client
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH} -config ${cfg}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

# --------- health checks ----------
health_check_server() {
  local port="$1"
  local cfg="${INSTALL_DIR}/server.yaml"

  echo
  log "🔎 Checking server service & tunnel port..."
  if systemctl is-active --quiet "${SERVICE_SERVER}.service"; then
    ok "Service is active"
  else
    warn "Service not active (check: journalctl -u ${SERVICE_SERVER} -f)"
  fi

  if have_cmd ss; then
    ss -lntp | grep -E "[: ]${port}\\b" >/dev/null 2>&1 && ok "Listening on port ${port}" || warn "Not listening on port ${port}"
  elif have_cmd netstat; then
    netstat -lntp 2>/dev/null | grep -E "[:.]${port}\\b" >/dev/null 2>&1 && ok "Listening on port ${port}" || warn "Not listening on port ${port}"
  fi

  # Try to detect fake_path from yaml (best-effort, no full YAML parser)
  local fake_path="/tunnel"
  if [[ -f "$cfg" ]]; then
    local fp
    fp="$(grep -E '^\\\s*fake_path:' "$cfg" 2>/dev/null | head -n1 | awk -F: '{print $2}' | tr -d ' "\\r' || true)"
    if [[ -n "$fp" ]]; then
      [[ "$fp" == /* ]] || fp="/$fp"
      fake_path="$fp"
    fi
  fi

  # Probe (POST) both fake_path and /tunnel
  curl -fsS -X POST "http://127.0.0.1:${port}${fake_path}" -o /dev/null 2>&1 \
    && ok "HTTP tunnel endpoint responds (${fake_path})" \
    || warn "Tunnel endpoint probe failed (${fake_path}) (may still be OK if it expects framed traffic)"

  if [[ "$fake_path" != "/tunnel" ]]; then
    curl -fsS -X POST "http://127.0.0.1:${port}/tunnel" -o /dev/null 2>&1 \
      && ok "Fallback endpoint responds (/tunnel)" \
      || warn "Fallback endpoint probe failed (/tunnel)"
  fi
}

health_check_client() {
  echo
  log "🔎 Checking client service..."
  systemctl is-active --quiet "${SERVICE_CLIENT}.service" && ok "Service is active" || warn "Service not active"
}

# --------- flows ----------
install_server_flow() {
  clear
  echo "═══════════════════════════════════════"
  echo "         SERVER CONFIGURATION"
  echo "═══════════════════════════════════════"
  echo

  local tunnel_port psk transport
  tunnel_port="$(ask "Tunnel Port" "2020")"
  psk="$(ask "Enter PSK (Pre-Shared Key)" "")"

  echo
  echo "Select Transport:"
  echo "  1) httpsmux  - HTTPS Mimicry (Recommended)"
  echo "  2) httpmux   - HTTP Mimicry"
  echo "  3) wssmux    - WebSocket Secure (TLS)"
  echo "  4) wsmux     - WebSocket"
  echo "  5) kcpmux    - KCP (UDP based)"
  echo "  6) tcpmux    - Simple TCP"
  local tchoice
  tchoice="$(ask "Choice [1-6]" "2")"
  case "$tchoice" in
    1) transport="httpsmux" ;;
    2) transport="httpmux" ;;
    3) transport="wssmux" ;;
    4) transport="wsmux" ;;
    5) transport="kcpmux" ;;
    6) transport="tcpmux" ;;
    *) transport="httpmux" ;;
  esac

  echo
  echo "PORT MAPPINGS"
  echo

  local maps=()
  local idx=1
  while true; do
    echo
    echo "Port Mapping #$idx"
    local bind_port target_port proto
    bind_port="$(ask "Bind Port (port on this server, e.g., 2222)" "")"
    target_port="$(ask "Target Port (destination port, e.g., 22)" "")"
    proto="$(ask "Protocol (tcp/udp/both)" "tcp")"

    maps+=("${proto}|0.0.0.0:${bind_port}|127.0.0.1:${target_port}")
    ok "Mapping added: 0.0.0.0:${bind_port} → 127.0.0.1:${target_port} (${proto})"

    if ! ask_yn "Add another mapping?" "N"; then break; fi
    idx=$((idx+1))
  done

  echo
  echo "═══════════════════════════════════════"
  echo "      HTTP MIMICRY SETTINGS"
  echo "═══════════════════════════════════════"
  echo

  local fake_domain fake_path ua uac chunked session_cookie
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
  uac="$(ask "Choice [1-6]" "1")"
  if [[ "$uac" == "6" ]]; then
    ua="$(ask "Enter custom User-Agent" "Mozilla/5.0")"
  else
    ua="$(ua_by_choice "$uac")"
  fi

  if ask_yn "Enable chunked encoding?" "n"; then chunked="true"; else chunked="false"; fi
  if ask_yn "Enable session cookies?" "Y"; then session_cookie="true"; else session_cookie="false"; fi

  if ! install_core_from_release; then
    pause
=======
  if [[ "$current" == "$latest" ]]; then
    ok "Already on latest: ${latest}"
>>>>>>> 6b30d3e (New Update)
    return
  fi

  info "Updating from ${current:-unknown} -> ${latest}"
  download_and_install "$latest" "$arch"

  # restart services if installed
  if systemctl list-unit-files | grep -q "^${BIN_NAME}-server\.service"; then
    systemctl restart "${BIN_NAME}-server" || true
  fi
  if systemctl list-unit-files | grep -q "^${BIN_NAME}-client\.service"; then
    systemctl restart "${BIN_NAME}-client" || true
  fi

<<<<<<< HEAD
  pause
}

install_client_flow() {
  clear
  echo "═══════════════════════════════════════"
  echo "      CLIENT CONFIGURATION"
  echo "═══════════════════════════════════════"
  echo

  local psk
  psk="$(ask "Enter PSK (must match server)" "")"

  echo
  echo "Select Performance Profile:"
  echo "  1) balanced      - Standard balanced performance (Recommended)"
  echo "  2) aggressive    - High speed, aggressive settings"
  echo "  3) latency       - Optimized for low latency"
  echo "  4) cpu-efficient - Low CPU usage"
  echo "  5) gaming        - Optimized for gaming (low latency + high speed)"
  local profc profile
  profc="$(ask "Choice [1-5]" "1")"
  case "$profc" in
    2) profile="aggressive" ;;
    3) profile="latency" ;;
    4) profile="cpu-efficient" ;;
    5) profile="gaming" ;;
    *) profile="balanced" ;;
  esac

  local obfs_enabled
  if ask_yn "Enable Traffic Obfuscation?" "Y"; then obfs_enabled="true"; else obfs_enabled="false"; fi

  echo
  echo "═══════════════════════════════════════"
  echo "      CONNECTION PATHS"
  echo "═══════════════════════════════════════"
  echo

  local paths_yaml=""
  local path_idx=0

  while true; do
    path_idx=$((path_idx+1))
    echo "Add Connection Path #${path_idx}"

    echo "Select Transport Type:"
    echo "  1) tcpmux   - TCP Multiplexing"
    echo "  2) kcpmux   - KCP Multiplexing (UDP)"
    echo "  3) wsmux    - WebSocket"
    echo "  4) wssmux   - WebSocket Secure"
    echo "  5) httpmux  - HTTP Mimicry"
    echo "  6) httpsmux - HTTPS Mimicry ⭐"
    local tc transport
    tc="$(ask "Choice [1-6]" "5")"
    case "$tc" in
      1) transport="tcpmux" ;;
      2) transport="kcpmux" ;;
      3) transport="wsmux" ;;
      4) transport="wssmux" ;;
      6) transport="httpsmux" ;;
      *) transport="httpmux" ;;
    esac

    local addr pool aggressive retry dial_timeout
    addr="$(ask "Server address with Tunnel Port (e.g., 1.2.3.4:4000)" "")"
    pool="$(ask "Connection pool size" "2")"
    if ask_yn "Enable aggressive pool?" "N"; then aggressive="true"; else aggressive="false"; fi
    retry="$(ask "Retry interval (seconds)" "3")"
    dial_timeout="$(ask "Dial timeout (seconds)" "10")"

    paths_yaml+=$'  - transport: "'${transport}$'"
'
    paths_yaml+=$'    addr: "'${addr}$'"
'
    paths_yaml+=$'    connection_pool: '${pool}$'
'
    paths_yaml+=$'    aggressive_pool: '${aggressive}$'
'
    paths_yaml+=$'    retry_interval: '${retry}$'
'
    paths_yaml+=$'    dial_timeout: '${dial_timeout}$'
'

    echo
    if ! ask_yn "Add another path?" "N"; then
      break
    fi
    echo
  done

echo "═══════════════════════════════════════"
  echo "      HTTP MIMICRY SETTINGS"
  echo "═══════════════════════════════════════"
  echo

  local fake_domain fake_path ua uac chunked session_cookie
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
  uac="$(ask "Choice [1-6]" "1")"
  if [[ "$uac" == "6" ]]; then
    ua="$(ask "Enter custom User-Agent" "Mozilla/5.0")"
  else
    ua="$(ua_by_choice "$uac")"
  fi

  if ask_yn "Enable chunked encoding?" "Y"; then chunked="true"; else chunked="false"; fi
  if ask_yn "Enable session cookies?" "Y"; then session_cookie="true"; else session_cookie="false"; fi

  local verbose
  if ask_yn "Enable verbose logging?" "N"; then verbose="true"; else verbose="false"; fi

  if ! install_core_from_release; then
    pause
    return
  fi

  mkdir -p "$INSTALL_DIR"
  local cfg="${INSTALL_DIR}/client.yaml"

  {
    echo "mode: \"client\""
    echo "psk: \"${psk}\""
    echo "profile: \"${profile}\""
    echo "verbose: ${verbose}"
    echo
    echo "paths:"
    echo -e "${paths_yaml%\n}"
    echo
    echo "obfuscation:"
    echo "  enabled: ${obfs_enabled}"
    echo "  min_padding: 16"
    echo "  max_padding: 512"
    echo "  min_delay_ms: 5"
    echo "  max_delay_ms: 50"
    echo "  burst_chance: 0.15"
    echo
    echo "http_mimic:"
    echo "  fake_domain: \"${fake_domain}\""
    echo "  fake_path: \"${fake_path}\""
    echo "  user_agent: \"${ua}\""
    echo "  chunked_encoding: ${chunked}"
    echo "  session_cookie: ${session_cookie}"
    echo "  custom_headers:"
    echo "    - \"X-Requested-With: XMLHttpRequest\""
    echo "    - \"Referer: https://${fake_domain}/\""
  } > "$cfg"

  write_client_service "$cfg"
  systemd_reload
  enable_start "$SERVICE_CLIENT"

  ok "✓ Client installation complete!"
  echo
  echo "Important Info:"
  echo "  Profile: ${profile}"
  echo "  Obfuscation: ${obfs_enabled}"
  echo
  echo "  Config: ${cfg}"
  echo "  View logs: journalctl -u ${SERVICE_CLIENT} -f"

  if ask_yn "Check service now?" "Y"; then
    health_check_client
  fi

  pause
}

settings_menu() {
  while true; do
    clear
    echo "═══════════════════════════════════════"
    echo "     SETTINGS (Manage Services)"
    echo "═══════════════════════════════════════"
    echo
    echo "  1) Status"
    echo "  2) Restart Server"
    echo "  3) Restart Client"
    echo "  4) Stop/Disable Server"
    echo "  5) Stop/Disable Client"
    echo "  6) View Config Paths"
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
      4) stop_disable "${SERVICE_SERVER}"; ok "Server disabled"; pause ;;
      5) stop_disable "${SERVICE_CLIENT}"; ok "Client disabled"; pause ;;
      6)
        echo "Config dir: ${INSTALL_DIR}"
        echo "Server cfg: ${INSTALL_DIR}/server.yaml"
        echo "Client cfg: ${INSTALL_DIR}/client.yaml"
        echo "Binary: ${BIN_PATH}"
        echo "Installed tag: $(read_installed_tag)"
        pause
        ;;
      0) return ;;
      *) ;;
    esac
  done
}

update_core_flow() {
  clear
  echo "═══════════════════════════════════════"
  echo "           UPDATE CORE"
  echo "═══════════════════════════════════════"
  echo
  if install_core_from_release; then
    ok "Core updated."
  else
    err "Core update failed."
  fi
  pause
=======
  ok "Update done."
>>>>>>> 6b30d3e (New Update)
}

uninstall_all() {
  warn "Removing services, configs, and binary..."
  delete_mode server || true
  delete_mode client || true
  rm -f "${INSTALL_BIN}" || true
  rm -rf "${CFG_DIR}" || true
  ok "Uninstalled."
}

edit_file() {
  local f="$1"
  if ! need_cmd nano; then
    warn "nano not found; using vi"
    ${EDITOR:-vi} "$f"
  else
    nano "$f"
  fi
}

view_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    warn "File not found: $f"
    return
  fi
  sed -n '1,260p' "$f" || true
}

manage_menu() {
  local mode="$1"
  while true; do
    echo
    echo "=============================="
    echo " Manage ${mode^}"
    echo "=============================="
    echo "  1) Restart ${mode}"
    echo "  2) ${mode^} Status"
    echo "  3) View ${mode^} Logs (Live)"
    echo "  4) Enable ${mode^} Auto-start"
    echo "  5) Disable ${mode^} Auto-start"
    echo
    echo "  6) View ${mode^} Config"
    echo "  7) Edit ${mode^} Config"
    echo "  8) Delete ${mode^} Config & Service"
    echo
    echo "  0) Back"
    echo -n "Select option: "
    read -r opt

    case "$opt" in
      1) svc_restart "$mode";;
      2) svc_status "$mode";;
      3) svc_logs "$mode";;
      4) svc_enable "$mode";;
      5) svc_disable "$mode";;
      6)
        if [[ "$mode" == "server" ]]; then view_file "$SERVER_CFG"; else view_file "$CLIENT_CFG"; fi
        ;;
      7)
        if [[ "$mode" == "server" ]]; then edit_file "$SERVER_CFG"; else edit_file "$CLIENT_CFG"; fi
        ;;
      8) delete_mode "$mode";;
      0) break;;
      *) warn "Invalid option";;
    esac
  done
}

main_menu() {
  while true; do
    local installed latest
    installed="$(get_installed_tag)"
    latest="$(get_latest_tag 2>/dev/null || true)"

    echo
    echo "========================================"
    echo " RsTunnel / picotun Setup"
    echo "========================================"
    echo " Installed: ${installed:-not installed}"
    echo " Latest:    ${latest:-unknown}"
    echo
    echo "  1) Install/Start Server"
    echo "  2) Install/Start Client"
    echo
    echo "  3) Manage Server"
    echo "  4) Manage Client"
    echo
    echo "  5) Update Core (download latest release)"
    echo "  6) Uninstall (remove everything)"
    echo
    echo "  0) Exit"
    echo -n "Select option: "
    read -r opt

    case "$opt" in
      1) install_server;;
      2) install_client;;
      3) manage_menu server;;
      4) manage_menu client;;
      5) update_core;;
      6) uninstall_all;;
      0) exit 0;;
      *) warn "Invalid option";;
    esac
  done
}

require_root
install_deps
main_menu
