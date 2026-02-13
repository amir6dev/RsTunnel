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

  if [[ "$current" == "$latest" ]]; then
    ok "Already on latest: ${latest}"
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

  ok "Update done."
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
