#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/amir6dev/RsTunnel.git"
BUILD_DIR="/tmp/picobuild"
BIN_NAME="picotun"
INSTALL_BIN="/usr/local/bin/${BIN_NAME}"

CONFIG_DIR="/etc/picotun"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SERVICE_FILE="/etc/systemd/system/picotun.service"

GO_VERSION="1.21.13"   # می‌تونی عوضش کنی

say() { echo "➤ $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo bash setup.sh"
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
      echo "Unsupported arch: $arch"
      exit 1
      ;;
  esac
}

ensure_deps() {
  say "Checking environment..."
  apt-get update -y >/dev/null
  apt-get install -y curl git ca-certificates tar >/dev/null
}

install_go_121() {
  if command -v go >/dev/null 2>&1; then
    local gv
    gv="$(go version || true)"
    if echo "$gv" | grep -q "go1.21"; then
      return
    fi
  fi

  say "Installing Go ${GO_VERSION}..."
  local arch
  arch="$(detect_arch)"

  local url="https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz"
  rm -rf /usr/local/go
  curl -fL "$url" -o /tmp/go.tgz >/dev/null
  tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz

  # make go available for this script
  export PATH="/usr/local/go/bin:${PATH}"
}

clone_repo() {
  say "Cloning source code..."
  rm -rf "$BUILD_DIR"
  git clone --depth 1 "$REPO_URL" "$BUILD_DIR" >/dev/null
}

build_binary() {
  say "Building ${BIN_NAME}..."

  export PATH="/usr/local/go/bin:${PATH}"

  # Fix blocked proxy issues
  export GOPROXY=direct
  export GOSUMDB=off

  cd "${BUILD_DIR}/PicoTun"

  say "Resolving dependencies (go mod tidy)..."
  /usr/local/go/bin/go mod tidy

  say "Compiling..."
  CGO_ENABLED=0 /usr/local/go/bin/go build -o "${BUILD_DIR}/${BIN_NAME}" ./cmd/picotun
}

install_binary() {
  install -m 0755 "${BUILD_DIR}/${BIN_NAME}" "${INSTALL_BIN}"
  say "Installed: ${INSTALL_BIN}"
}

write_default_config_if_missing() {
  mkdir -p "${CONFIG_DIR}"

  if [[ -f "${CONFIG_FILE}" ]]; then
    return
  fi

  cat > "${CONFIG_FILE}" <<'YAML'
mode: server
listen: "0.0.0.0:1010"
session_timeout: 15
psk: ""

mimic:
  fake_domain: ""
  fake_path: ""
  user_agent: "Mozilla/5.0"
  custom_headers: []
  session_cookie: true

obfs:
  enabled: true
  min_padding: 8
  max_padding: 64
  min_delay: 0
  max_delay: 25
  burst_chance: 0

forward:
  tcp:
    - "1412->127.0.0.1:1412"
  udp: []
YAML

  say "Created default config: ${CONFIG_FILE}"
}

write_service() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=PicoTun Service
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_BIN} -config ${CONFIG_FILE}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now picotun >/dev/null
  say "Service installed and started."
}

menu() {
  echo ""
  echo "1) Install/Update (build from source + systemd)"
  echo "2) Show service status"
  echo "3) Show logs"
  echo "4) Restart service"
  echo "5) Exit"
  echo ""
  read -r -p "Select: " choice

  case "${choice:-}" in
    1)
      ensure_deps
      install_go_121
      clone_repo
      build_binary
      install_binary
      write_default_config_if_missing
      write_service
      echo ""
      systemctl status picotun --no-pager || true
      ;;
    2) systemctl status picotun --no-pager || true ;;
    3) journalctl -u picotun -n 200 --no-pager || true ;;
    4) systemctl restart picotun || true; systemctl status picotun --no-pager || true ;;
    5) exit 0 ;;
    *) echo "Invalid choice" ;;
  esac
}

need_root
while true; do
  menu
done
