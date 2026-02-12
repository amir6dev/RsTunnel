#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configurable Defaults
# =========================
REPO_DEFAULT="amir6dev/RsTunnel"
BINARY_DEFAULT="picotun"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/picotun"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SERVICE_FILE="/etc/systemd/system/picotun.service"

# =========================
# Helpers
# =========================
color() { local c="$1"; shift; printf "\033[%sm%s\033[0m\n" "$c" "$*"; }
info() { color "36" "[*] $*"; }
ok()   { color "32" "[+] $*"; }
warn() { color "33" "[!] $*"; }
err()  { color "31" "[-] $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run as root. Try: sudo bash setup.sh"
    exit 1
  fi
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)
      err "Unsupported arch: $arch"
      exit 1
      ;;
  esac
}

ensure_deps() {
  info "Installing dependencies (curl, tar)..."
  apt-get update -y >/dev/null
  apt-get install -y curl tar >/dev/null
}

read_input() {
  local prompt="$1" default="${2:-}"
  local val
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " val
    echo "${val:-$default}"
  else
    read -r -p "$prompt: " val
    echo "$val"
  fi
}

yn() {
  local prompt="$1" default="${2:-y}"
  local ans
  local hint="[y/N]"
  [[ "$default" == "y" ]] && hint="[Y/n]"
  read -r -p "$prompt $hint: " ans
  ans="${ans:-$default}"
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

service_stop_disable() {
  systemctl stop picotun >/dev/null 2>&1 || true
  systemctl disable picotun >/dev/null 2>&1 || true
}

service_write() {
  local exec="${INSTALL_DIR}/${BINARY} -config ${CONFIG_FILE}"
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=PicoTun Service
After=network.target

[Service]
Type=simple
ExecStart=${exec}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

service_enable_start() {
  systemctl enable --now picotun >/dev/null
}

service_status() {
  systemctl status picotun --no-pager || true
}

journal_follow() {
  journalctl -u picotun -f --no-pager
}

gh_latest_asset_url() {
  local repo="$1" arch="$2"
  local api="https://api.github.com/repos/${repo}/releases/latest"
  # try to find: picotun_linux_amd64.tar.gz
  curl -fsSL "$api" \
    | grep -Eo 'https://[^"]+picotun_linux_'"$arch"'\.tar\.gz' \
    | head -n 1
}

download_and_install_binary() {
  local repo="$1" binary="$2"
  local arch url tmp
  arch="$(detect_arch)"
  url="$(gh_latest_asset_url "$repo" "$arch")"
  if [[ -z "$url" ]]; then
    err "Could not find release asset for linux_${arch} in repo ${repo}."
    err "Expected asset name: ${binary}_linux_${arch}.tar.gz (or picotun_linux_${arch}.tar.gz)."
    exit 1
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  info "Downloading: $url"
  curl -fL "$url" -o "$tmp/${binary}.tar.gz" >/dev/null
  tar -xzf "$tmp/${binary}.tar.gz" -C "$tmp"

  if [[ ! -f "$tmp/$binary" ]]; then
    # fallback: sometimes tarball contains different name; try find executable
    local found
    found="$(find "$tmp" -maxdepth 2 -type f -name "$binary" | head -n 1 || true)"
    if [[ -z "$found" ]]; then
      err "Binary '${binary}' not found inside tar.gz."
      exit 1
    fi
    cp "$found" "$tmp/$binary"
  fi

  install -m 0755 "$tmp/$binary" "${INSTALL_DIR}/${binary}"
  ok "Installed binary to ${INSTALL_DIR}/${binary}"
}

write_server_config_interactive() {
  mkdir -p "$CONFIG_DIR"

  local listen timeout psk
  local obfs_enabled min_pad max_pad min_delay max_delay
  local ua session_cookie
  local forward_line tcp_maps=()

  listen="$(read_input "Server listen (HTTP tunnel endpoint)" "0.0.0.0:1010")"
  timeout="$(read_input "Session timeout (seconds)" "15")"
  psk="$(read_input "PSK (empty = no encryption)" "")"

  ua="$(read_input "User-Agent (mimic)" "Mozilla/5.0")"
  session_cookie="true"
  if yn "Send session cookie header?"; then session_cookie="true"; else session_cookie="false"; fi

  obfs_enabled="true"
  if yn "Enable obfuscation (padding/delay)?" "y"; then obfs_enabled="true"; else obfs_enabled="false"; fi
  min_pad="$(read_input "Obfs min padding bytes" "8")"
  max_pad="$(read_input "Obfs max padding bytes" "64")"
  min_delay="$(read_input "Obfs min delay ms" "0")"
  max_delay="$(read_input "Obfs max delay ms" "25")"

  info "Now add TCP forward maps. Format:"
  info '  bind->target   examples: "1412->127.0.0.1:1412"  or  "0.0.0.0:443->127.0.0.1:22"'
  while true; do
    forward_line="$(read_input "Add TCP map (empty = done)" "")"
    [[ -z "$forward_line" ]] && break
    tcp_maps+=("$forward_line")
  done

  # If none provided, put a safe default example
  if [[ "${#tcp_maps[@]}" -eq 0 ]]; then
    tcp_maps+=("1412->127.0.0.1:1412")
  fi

  {
    echo "mode: server"
    echo "listen: \"${listen}\""
    echo "session_timeout: ${timeout}"
    echo "psk: \"${psk}\""
    echo ""
    echo "mimic:"
    echo "  fake_domain: \"\""
    echo "  fake_path: \"\""
    echo "  user_agent: \"${ua}\""
    echo "  custom_headers: []"
    echo "  session_cookie: ${session_cookie}"
    echo ""
    echo "obfs:"
    echo "  enabled: ${obfs_enabled}"
    echo "  min_padding: ${min_pad}"
    echo "  max_padding: ${max_pad}"
    echo "  min_delay: ${min_delay}"
    echo "  max_delay: ${max_delay}"
    echo "  burst_chance: 0"
    echo ""
    echo "forward:"
    echo "  tcp:"
    for m in "${tcp_maps[@]}"; do
      echo "    - \"${m}\""
    done
    echo "  udp: []"
  } > "$CONFIG_FILE"

  ok "Wrote config: $CONFIG_FILE"
}

write_client_config_interactive() {
  mkdir -p "$CONFIG_DIR"

  local server_url session_id psk
  local ua session_cookie
  local obfs_enabled min_pad max_pad min_delay max_delay

  server_url="$(read_input "Server URL (full /tunnel URL)" "http://YOUR_SERVER_IP:1010/tunnel")"
  session_id="$(read_input "Session ID (any string)" "sess-$(date +%s)")"
  psk="$(read_input "PSK (must match server if encryption enabled)" "")"

  ua="$(read_input "User-Agent (mimic)" "Mozilla/5.0")"
  session_cookie="true"
  if yn "Send session cookie header?"; then session_cookie="true"; else session_cookie="false"; fi

  obfs_enabled="true"
  if yn "Enable obfuscation (padding/delay)?" "y"; then obfs_enabled="true"; else obfs_enabled="false"; fi
  min_pad="$(read_input "Obfs min padding bytes" "8")"
  max_pad="$(read_input "Obfs max padding bytes" "64")"
  min_delay="$(read_input "Obfs min delay ms" "0")"
  max_delay="$(read_input "Obfs max delay ms" "25")"

  {
    echo "mode: client"
    echo "server_url: \"${server_url}\""
    echo "session_id: \"${session_id}\""
    echo "psk: \"${psk}\""
    echo ""
    echo "mimic:"
    echo "  fake_domain: \"\""
    echo "  fake_path: \"\""
    echo "  user_agent: \"${ua}\""
    echo "  custom_headers: []"
    echo "  session_cookie: ${session_cookie}"
    echo ""
    echo "obfs:"
    echo "  enabled: ${obfs_enabled}"
    echo "  min_padding: ${min_pad}"
    echo "  max_padding: ${max_pad}"
    echo "  min_delay: ${min_delay}"
    echo "  max_delay: ${max_delay}"
    echo "  burst_chance: 0"
    echo ""
    echo "forward:"
    echo "  tcp: []"
    echo "  udp: []"
  } > "$CONFIG_FILE"

  ok "Wrote config: $CONFIG_FILE"
}

install_or_update() {
  local repo="$1" binary="$2"

  ensure_deps
  download_and_install_binary "$repo" "$binary"

  mkdir -p "$CONFIG_DIR"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    warn "No config found at ${CONFIG_FILE}."
    if yn "Create config now (interactive)?" "y"; then
      configure_menu
    else
      warn "Skipping config creation. You must create ${CONFIG_FILE} manually."
    fi
  fi

  service_write
  service_enable_start
  ok "Service installed & started."
}

configure_menu() {
  echo ""
  echo "==== Configure ===="
  echo "1) Create/overwrite SERVER config"
  echo "2) Create/overwrite CLIENT config"
  echo "3) Back"
  local c
  c="$(read_input "Select" "3")"
  case "$c" in
    1) write_server_config_interactive ;;
    2) write_client_config_interactive ;;
    *) return ;;
  esac
}

control_menu() {
  echo ""
  echo "==== Service Control ===="
  echo "1) Status"
  echo "2) Restart"
  echo "3) Stop"
  echo "4) Start"
  echo "5) Logs (follow)"
  echo "6) Back"
  local c
  c="$(read_input "Select" "6")"
  case "$c" in
    1) service_status ;;
    2) systemctl restart picotun || true; ok "Restarted." ;;
    3) systemctl stop picotun || true; ok "Stopped." ;;
    4) systemctl start picotun || true; ok "Started." ;;
    5) journal_follow ;;
    *) return ;;
  esac
}

uninstall_all() {
  if ! yn "Uninstall picotun (binary + service)?"; then
    return
  fi
  service_stop_disable
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f "${INSTALL_DIR}/${BINARY}"
  ok "Removed binary and service."

  if yn "Also remove config directory (${CONFIG_DIR})?" "n"; then
    rm -rf "$CONFIG_DIR"
    ok "Removed config directory."
  else
    warn "Config kept at: ${CONFIG_DIR}"
  fi
}

# =========================
# Main Menu
# =========================
need_root

echo ""
echo "======================================"
echo " PicoTun setup (menu automation)"
echo "======================================"
echo ""

REPO="$(read_input "GitHub repo (owner/name)" "$REPO_DEFAULT")"
BINARY="$(read_input "Binary name" "$BINARY_DEFAULT")"

while true; do
  echo ""
  echo "==== Main Menu ===="
  echo "1) Install / Update from GitHub Releases"
  echo "2) Configure (interactive config.yaml)"
  echo "3) Service control (status/start/stop/logs)"
  echo "4) Uninstall"
  echo "5) Exit"
  choice="$(read_input "Select" "5")"

  case "$choice" in
    1) install_or_update "$REPO" "$BINARY" ;;
    2) configure_menu ;;
    3) control_menu ;;
    4) uninstall_all ;;
    5) ok "Bye."; exit 0 ;;
    *) warn "Invalid choice." ;;
  esac
done
