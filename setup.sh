#!/usr/bin/env bash
set -euo pipefail

# RsTunnel installer (Dagger-like UX) - httpmux focused

APP_NAME="RsTunnel"
BIN_NAME="picotun"
INSTALL_DIR="/etc/${BIN_NAME}"
BIN_PATH="/usr/local/bin/${BIN_NAME}"
VERSION_FILE="${INSTALL_DIR}/.installed_tag"
SERVICE_SERVER="${BIN_NAME}-server"
SERVICE_CLIENT="${BIN_NAME}-client"

REPO_OWNER="amir6dev"
REPO_NAME="RsTunnel"

# Prefer release assets (so we DON'T need Go on Iranian servers)
# Expected asset name pattern (must exist in GitHub Releases):
#   picotun_linux_amd64.tar.gz
#   picotun_linux_arm64.tar.gz
#
# Each tar.gz should contain a single executable named "picotun".
DL_PREFIXES=(
  ""  # direct
  "https://ghproxy.com/"
  "https://mirror.ghproxy.com/"
)

COLOR_RESET="\033[0m"
COLOR_GREEN="\033[0;32m"
COLOR_RED="\033[0;31m"
COLOR_YELLOW="\033[0;33m"
COLOR_CYAN="\033[0;36m"

log()  { echo -e "${COLOR_CYAN}$*${COLOR_RESET}"; }
ok()   { echo -e "${COLOR_GREEN}✓${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_YELLOW}!${COLOR_RESET} $*"; }
err()  { echo -e "${COLOR_RED}✖${COLOR_RESET} $*"; }
pause() { read -r -p "Press Enter to return..." _; }

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "Run as root."; exit 1; }; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_arch() {
  case "$(uname -m || true)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "amd64" ;;
  esac
}

pkg_install() {
  local pkgs=("$@")
  if have_cmd apt-get; then
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  elif have_cmd yum; then
    yum install -y "${pkgs[@]}"
  elif have_cmd dnf; then
    dnf install -y "${pkgs[@]}"
  elif have_cmd apk; then
    apk add --no-cache "${pkgs[@]}"
  else
    err "No supported package manager found."
    exit 1
  fi
}

ensure_deps() {
  log "📦 Checking dependencies..."
  local missing=()

  for c in curl tar file; do
    have_cmd "$c" || missing+=("$c")
  done
  have_cmd git || missing+=("git")

  if ((${#missing[@]}==0)); then
    ok "Dependencies already installed"
    return 0
  fi

  warn "Installing missing: ${missing[*]}"
  pkg_install "${missing[@]}"
  ok "Dependencies installed"
}

curl_try() {
  local url="$1" out="$2"
  curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 240 "$url" -o "$out"
}

download_with_prefixes() {
  local url="$1" out="$2"
  local p full
  rm -f "$out" >/dev/null 2>&1 || true
  for p in "${DL_PREFIXES[@]}"; do
    full="${p}${url}"
    if curl_try "$full" "$out" >/dev/null 2>&1; then
      if [[ -s "$out" ]]; then
        return 0
      fi
    fi
    rm -f "$out" >/dev/null 2>&1 || true
  done
  return 1
}

is_json_file() {
  local f="$1"
  [[ -s "$f" ]] || return 1
  local first
  first="$(tr -d '\n\r\t ' <"$f" | head -c 1 || true)"
  [[ "$first" == "{" || "$first" == "[" ]]
}

verify_elf_arch() {
  local bin="$1" arch="$2"
  local info
  info="$(file "$bin" || true)"
  echo "$info" | grep -q "ELF" || { err "Not an ELF binary: $info"; return 1; }
  if [[ "$arch" == "amd64" ]]; then
    echo "$info" | grep -qiE "x86-64|x86_64" || { err "Wrong arch (expected amd64): $info"; return 1; }
  else
    echo "$info" | grep -qiE "aarch64|ARM aarch64" || { err "Wrong arch (expected arm64): $info"; return 1; }
  fi
}

ask() {
  local prompt="$1" def="${2:-}"
  if [[ -n "$def" ]]; then
    read -r -p "${prompt} [${def}]: " ans
    echo "${ans:-$def}"
  else
    read -r -p "${prompt}: " ans
    echo "$ans"
  fi
}

ask_yn() {
  local prompt="$1" def="${2:-Y}"
  local d="$def"
  local ans
  read -r -p "${prompt} [${d}]: " ans
  ans="${ans:-$d}"
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

systemd_reload() { systemctl daemon-reload >/dev/null 2>&1 || true; }
enable_start() {
  local svc="$1"
  systemctl enable --now "${svc}.service" >/dev/null 2>&1 || true
}

stop_disable() {
  local svc="$1"
  systemctl disable --now "${svc}.service" >/dev/null 2>&1 || true
}

get_latest_tag_via_redirect() {
  local url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest"
  local loc p u
  for p in "${DL_PREFIXES[@]}"; do
    u="${p}${url}"
    loc="$(curl -fsSLI "$u" 2>/dev/null | awk -F': ' 'tolower($1)=="location"{print $2}' | tail -n 1 | tr -d '\r')"
    if [[ -n "$loc" ]]; then
      echo "$loc" | awk -F'/tag/' '{print $2}' | tr -d '\r'
      return 0
    fi
  done
  return 1
}

pick_asset_url_no_api() {
  local arch="$1" tag="$2"
  echo "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${tag}/picotun_linux_${arch}.tar.gz"
}

read_installed_tag() {
  [[ -f "$VERSION_FILE" ]] && cat "$VERSION_FILE" || true
}

write_installed_tag() {
  local tag="$1"
  mkdir -p "$INSTALL_DIR"
  echo -n "$tag" > "$VERSION_FILE"
}

install_core_from_release() {
  ensure_deps

  local arch tag url
  arch="$(detect_arch)"
  log "⬇️  Installing core for arch: ${arch}"

  tag=""
  url=""

  local api="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
  local jsonf
  jsonf="$(mktemp /tmp/picotun.release.XXXXXX.json)"

  local have_api=0
  if download_with_prefixes "$api" "$jsonf" && is_json_file "$jsonf" && have_cmd python3; then
    have_api=1
  fi

  if [[ "$have_api" -eq 1 ]]; then
    tag="$(python3 - <<'PY' <"$jsonf" 2>/dev/null || true
import json,sys
try:
    data=json.load(sys.stdin)
    print(data.get("tag_name",""))
except Exception:
    pass
PY
)"
    url="$(python3 - "$arch" <<'PY' <"$jsonf" 2>/dev/null || true
import json,sys
arch=sys.argv[1]
want=f"picotun_linux_{arch}.tar.gz"
try:
    data=json.load(sys.stdin)
    for a in data.get("assets",[]):
        if a.get("name","")==want:
            print(a.get("browser_download_url",""))
            raise SystemExit(0)
except Exception:
    pass
raise SystemExit(1)
PY
)" || true
  fi

  rm -f "$jsonf" >/dev/null 2>&1 || true

  if [[ -z "$tag" ]]; then
    tag="$(get_latest_tag_via_redirect || true)"
  fi

  if [[ -z "$url" ]]; then
    [[ -n "$tag" ]] || { err "Could not detect latest release tag."; return 1; }
    url="$(pick_asset_url_no_api "$arch" "$tag")"
  fi

  local installed
  installed="$(read_installed_tag)"
  if [[ -n "$installed" && "$installed" == "$tag" && -x "$BIN_PATH" ]]; then
    ok "Core already up-to-date (${tag})"
    return 0
  fi

  local tmpd tgz
  tmpd="$(mktemp -d /tmp/picotun-dl.XXXXXX)"
  tgz="${tmpd}/picotun.tgz"

  if ! download_with_prefixes "$url" "$tgz"; then
    rm -rf "$tmpd" || true
    err "Download failed. URL: $url"
    return 1
  fi

  if ! file "$tgz" | grep -qiE "gzip compressed data"; then
    warn "Downloaded file is not a gzip archive. (Maybe blocked/proxy HTML?)"
    rm -rf "$tmpd" || true
    err "Core update failed."
    return 1
  fi

  tar -xzf "$tgz" -C "$tmpd"
  if [[ ! -f "${tmpd}/${BIN_NAME}" ]]; then
    rm -rf "$tmpd" || true
    err "Archive doesn't contain ${BIN_NAME}"
    return 1
  fi

  chmod +x "${tmpd}/${BIN_NAME}"
  verify_elf_arch "${tmpd}/${BIN_NAME}" "$arch" || { rm -rf "$tmpd" || true; return 1; }

  install -m 0755 "${tmpd}/${BIN_NAME}" "$BIN_PATH"
  rm -rf "$tmpd" || true

  write_installed_tag "$tag"
  ok "Core installed: ${BIN_PATH} (${tag})"
  return 0
}

ua_by_choice() {
  case "$1" in
    2) echo "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:122.0) Gecko/20100101 Firefox/122.0" ;;
    3) echo "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" ;;
    4) echo "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15" ;;
    5) echo "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36" ;;
    *) echo "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" ;;
  esac
}

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
ExecStart=${BIN_PATH} -c ${cfg}
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
ExecStart=${BIN_PATH} -c ${cfg}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

health_check_server() {
  local port="$1"
  echo
  log "🔎 Checking server service & tunnel port..."
  systemctl is-active --quiet "${SERVICE_SERVER}.service" && ok "Service is active" || warn "Service not active"
  if have_cmd ss; then
    ss -lntp | grep -E "[: ]${port}\b" >/dev/null 2>&1 && ok "Listening on port ${port}" || warn "Not listening on port ${port}"
  elif have_cmd netstat; then
    netstat -lntp 2>/dev/null | grep -E "[:.]${port}\b" >/dev/null 2>&1 && ok "Listening on port ${port}" || warn "Not listening on port ${port}"
  fi
  curl -fsS "http://127.0.0.1:${port}/tunnel" >/dev/null 2>&1 && ok "HTTP endpoint responds" || warn "HTTP endpoint probe failed (may still be OK if it expects framed traffic)"
}

health_check_client() {
  echo
  log "🔎 Checking client service..."
  systemctl is-active --quiet "${SERVICE_CLIENT}.service" && ok "Service is active" || warn "Service not active"
}

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
    maps+=("$proto|0.0.0.0:${bind_port}|127.0.0.1:${target_port}")
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
    return
  fi

  mkdir -p "$INSTALL_DIR"
  local cfg="${INSTALL_DIR}/server.yaml"

  {
    echo "mode: \"server\""
    echo "listen: \"0.0.0.0:${tunnel_port}\""
    echo "transport: \"${transport}\""
    echo "psk: \"${psk}\""
    echo "profile: \"latency\""
    echo "verbose: true"
    echo
    echo "heartbeat: 2"
    echo
    echo "maps:"
    for m in "${maps[@]}"; do
      IFS='|' read -r proto bind target <<<"$m"
      if [[ "$proto" == "both" ]]; then
        echo "  - type: tcp"
        echo "    bind: \"${bind}\""
        echo "    target: \"${target}\""
        echo "  - type: udp"
        echo "    bind: \"${bind}\""
        echo "    target: \"${target}\""
      else
        echo "  - type: ${proto}"
        echo "    bind: \"${bind}\""
        echo "    target: \"${target}\""
      fi
    done
    echo
    echo "obfuscation:"
    echo "  enabled: true"
    echo "  min_padding: 8"
    echo "  max_padding: 32"
    echo "  min_delay_ms: 0"
    echo "  max_delay_ms: 0"
    echo "  burst_chance: 0"
    echo
    echo "http_mimic:"
    echo "  fake_domain: \"${fake_domain}\""
    echo "  fake_path: \"${fake_path}\""
    echo "  user_agent: \"${ua}\""
    echo "  chunked_encoding: ${chunked}"
    echo "  session_cookie: ${session_cookie}"
    echo "  custom_headers:"
    echo "    - \"Accept-Language: en-US,en;q=0.9\""
    echo "    - \"Accept-Encoding: gzip, deflate, br\""
  } > "$cfg"

  write_server_service "$cfg"
  systemd_reload
  enable_start "$SERVICE_SERVER"

  ok "Systemd service for Server created: ${SERVICE_SERVER}.service"
  echo
  echo "═══════════════════════════════════════"
  echo "   ✓ Server configured"
  echo "═══════════════════════════════════════"
  echo
  echo "  Tunnel Port: ${tunnel_port}"
  echo "  PSK: ${psk}"
  echo "  Transport: ${transport}"
  echo "  Config: ${cfg}"

  if ask_yn "Check tunnel/service now?" "Y"; then
    health_check_server "$tunnel_port"
  fi

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
    echo "  - transport: \"${transport}\""
    echo "    addr: \"${addr}\""
    echo "    connection_pool: ${pool}"
    echo "    aggressive_pool: ${aggressive}"
    echo "    retry_interval: ${retry}"
    echo "    dial_timeout: ${dial_timeout}"
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

  ok "Client configured"
  echo "  Config: ${cfg}"
  echo "  Logs: journalctl -u ${SERVICE_CLIENT} -f"

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

uninstall_all() {
  clear
  echo "═══════════════════════════════════════"
  echo "             UNINSTALL"
  echo "═══════════════════════════════════════"
  echo

  if ! ask_yn "Remove ${APP_NAME} services, configs, and binary?" "n"; then
    warn "Canceled"
    pause
    return
  fi

  stop_disable "$SERVICE_SERVER"
  stop_disable "$SERVICE_CLIENT"
  rm -f "/etc/systemd/system/${SERVICE_SERVER}.service" "/etc/systemd/system/${SERVICE_CLIENT}.service" || true
  systemd_reload

  rm -rf "$INSTALL_DIR" || true
  rm -f "$BIN_PATH" || true

  ok "Uninstalled."
  pause
}

main_menu() {
  while true; do
    clear
    echo "  1) Install Server"
    echo "  2) Install Client"
    echo "  3) Settings (Manage Services & Configs)"
    echo "  4) Update Core (Re-download Binary)"
    echo "  5) Uninstall"
    echo
    echo "  0) Exit"
    echo
    local opt
    opt="$(ask "Select option" "0")"
    case "$opt" in
      1) install_server_flow ;;
      2) install_client_flow ;;
      3) settings_menu ;;
      4)
        if install_core_from_release; then ok "Core updated"; else err "Core update failed"; fi
        pause
        ;;
      5) uninstall_all ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

need_root
main_menu
