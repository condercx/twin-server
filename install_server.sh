#!/bin/bash
#
# install_server.sh - twin-server install script
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/condercx/twin-server/main/install_server.sh | bash -s --
#   curl -fsSL https://raw.githubusercontent.com/condercx/twin-server/main/install_server.sh | bash -s -- --remove
#

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

EXECUTABLE_INSTALL_PATH="/usr/local/bin/twin-server"
CONFIG_DIR="/etc/twin-server"
RELEASES_URL="https://github.com/condercx/twin-server/releases"
RAW_URL="https://raw.githubusercontent.com/condercx/twin-server/main/install_server.sh"

OPERATION=
LOCAL_FILE=

echo "=== twin-server install script ==="

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remove) OPERATION="remove"; shift ;;
      -f|--force) OPERATION="install"; FORCE=1; shift ;;
      -l|--local) LOCAL_FILE="$2"; shift 2; break ;;
      -h|--help)
        echo "Usage:"
        echo "  Install:  curl -fsSL $RAW_URL | bash -s --"
        echo "  Remove:   curl -fsSL $RAW_URL | bash -s -- --remove"
        echo "  Options:"
        echo "    -l <file>   Install from local binary file"
        echo "    -f          Force reinstall"
        echo "    --remove    Remove twin-server"
        exit 0 ;;
      *) echo "Unknown option: $1"; exit 1 ;;
    esac
  done

  [[ -z "$OPERATION" ]] && OPERATION="install"

  if [[ $UID -ne 0 ]]; then
    echo "Error: please run as root (use sudo)." >&2
    exit 1
  fi

  case "$OPERATION" in
    install) perform_install ;;
    remove)  perform_remove ;;
  esac
}

perform_install() {
  local ARCH=""
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|armv8l) ARCH="arm64" ;;
    *)
      echo "Error: unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac

  echo "Architecture: $ARCH"

  # Install binary
  if [[ -n "$LOCAL_FILE" ]]; then
    echo -n "Installing from $LOCAL_FILE ... "
    install -Dm755 "$LOCAL_FILE" "$EXECUTABLE_INSTALL_PATH" || { echo "failed"; exit 1; }
    echo "ok"
  else
    echo "Downloading latest release for linux/$ARCH ..."
    local _tmpfile
    _tmpfile=$(mktemp /tmp/twinservinst.XXXXXXXXXX) || { echo "mktemp failed"; exit 1; }
    trap "rm -f $_tmpfile" EXIT

    # Get latest version
    local _version
    _version=$(curl -sSL "$RELEASES_URL" | grep -oP "/condercx/twin-server/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+" | head -1 | grep -oP "v[0-9]+\.[0-9]+\.[0-9]+")
    if [[ -z "$_version" ]]; then
      echo "Error: could not determine latest version" >&2
      exit 1
    fi
    echo "Latest version: $_version"

    local _url="$RELEASES_URL/download/$_version/twin-server-linux-$ARCH"
    echo -n "Downloading ... "
    curl -sSL -R "$_url" -o "$_tmpfile" || { echo "download failed" >&2; exit 1; }
    echo "ok"

    echo -n "Installing to $EXECUTABLE_INSTALL_PATH ... "
    install -Dm755 "$_tmpfile" "$EXECUTABLE_INSTALL_PATH" || { echo "failed"; exit 1; }
    echo "ok"
    rm -f "$_tmpfile"
    trap "" EXIT
  fi

  # Create user
  if ! id twin &>/dev/null; then
    echo -n "Creating twin user ... "
    useradd -r -d /var/lib/twin -m twin || { echo "failed"; exit 1; }
    echo "ok"
  fi

  # Install openssl if needed
  if ! command -v openssl &>/dev/null; then
    if command -v apt &>/dev/null; then
      apt update && apt install -y openssl || { echo "openssl install failed"; exit 1; }
    elif command -v dnf &>/dev/null; then
      dnf install -y openssl || { echo "openssl install failed"; exit 1; }
    else
      echo "Warning: openssl not found, please install it manually"
    fi
  fi

  # Generate certificate
  mkdir -p /var/log/twin-server
  touch /var/log/twin-server/twin.log
  mkdir -p "$CONFIG_DIR"
  echo -n "Generating self-signed TLS certificate ... "
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 36500 -keyout "$CONFIG_DIR/server.key" -out "$CONFIG_DIR/server.crt" \
    -subj "/CN=bing.com" 2>/dev/null
  echo "ok"
  chown -R twin "$CONFIG_DIR"

  # Generate config
  local _password
  _password=$(dd if=/dev/random bs=18 count=1 status=none | base64)
  cat > "$CONFIG_DIR/config.conf" <<- EOC
# twin-server configuration
listen = :8443
password = ${_password}
cert = ${CONFIG_DIR}/server.crt
key = ${CONFIG_DIR}/server.key
EOC

  echo "Config:   $CONFIG_DIR/config.conf"
  echo "Password: $_password"

  # Install systemd service
  cat > /etc/systemd/system/twin-server.service <<- EOS
[Unit]
Description=Twin Server Service
After=network.target

[Service]
Type=simple
ExecStart=$EXECUTABLE_INSTALL_PATH -conf $CONFIG_DIR/config.conf
User=twin
Group=twin
NoNewPrivileges=true
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOS
  systemctl daemon-reload 2>/dev/null || true

  echo ""
  echo "========================================"
  echo "  Twin-server installed!"
  echo "========================================"
  echo ""
  echo "  Start:   systemctl start twin-server"
  echo "  Status:  systemctl status twin-server -l"
  # Enable on boot
  systemctl enable twin-server 2>/dev/null || true
  echo "  Restart: systemctl restart twin-server"
  echo "  Logs:    journalctl -u twin-server -f"
  echo ""
  echo "  Remove:  curl -fsSL $RAW_URL | bash -s -- --remove"
  echo ""
}

perform_remove() {
  echo "Stopping twin-server ..."
  systemctl stop twin-server 2>/dev/null || true
  echo "  ok"

  echo "Disabling twin-server ..."
  systemctl disable twin-server 2>/dev/null || true
  echo "  ok"

  echo "Removing binary $EXECUTABLE_INSTALL_PATH ..."
  rm -f "$EXECUTABLE_INSTALL_PATH"
  echo "  ok"

  echo "Removing systemd service ..."
  rm -f /etc/systemd/system/twin-server.service
  systemctl daemon-reload 2>/dev/null || true
  echo "  ok"

  echo ""
  echo "twin-server has been removed."
  echo ""
  echo "You may also want to remove:"
  echo "  rm -rf $CONFIG_DIR"
  echo "  userdel -r twin"
  echo ""
}

main "$@"


