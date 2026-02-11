#!/bin/bash

set -e

REPO="amir6dev/RsHttpMux"
BINARY_NAME="rshttpmux"
INSTALL_DIR="/usr/local/bin"
SERVICE_NAME="rshttpmux.service"
CONFIG_DIR="/etc/rshttpmux"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

echo ">>> Installing dependencies..."
apt update -y
apt install -y wget curl unzip tar jq

mkdir -p "$CONFIG_DIR"

echo ">>> Fetching latest release..."
LATEST_URL=$(curl -s https://api.github.com/repos/$REPO/releases/latest | jq -r '.assets[] | select(.name | contains("linux_amd64")) | .browser_download_url')

if [ -z "$LATEST_URL" ]; then
    echo "Could not find latest release asset."
    exit 1
fi

echo ">>> Downloading binary..."
wget -O /tmp/$BINARY_NAME.tar.gz "$LATEST_URL"

echo ">>> Extracting..."
tar -xzf /tmp/$BINARY_NAME.tar.gz -C /tmp

chmod +x /tmp/$BINARY_NAME
mv /tmp/$BINARY_NAME "$INSTALL_DIR/$BINARY_NAME"

echo ">>> Creating default config..."

cat > $CONFIG_FILE <<EOF
mode: server
bind: 0.0.0.0:8080
session_timeout: 15

mimic:
  fake_domain: www.google.com
  fake_path: /search
  user_agent: Mozilla/5.0
  custom_headers:
    - "Accept-Language: en-US"
  session_cookie: true

obfs:
  enabled: true
  min_padding: 8
  max_padding: 32

EOF

echo ">>> Creating systemd service..."

cat > /etc/systemd/system/$SERVICE_NAME <<EOF
[Unit]
Description=RsHttpMux Tunnel Service
After=network.target

[Service]
ExecStart=$INSTALL_DIR/$BINARY_NAME -config $CONFIG_FILE
Restart=always
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

echo ">>> Reloading systemd..."
systemctl daemon-reload

echo ">>> Enabling service..."
systemctl enable $SERVICE_NAME
systemctl restart $SERVICE_NAME

echo ">>> Installation completed!"
echo "Service running: systemctl status $SERVICE_NAME"
echo "Config file: $CONFIG_FILE"
