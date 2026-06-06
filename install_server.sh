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
LOG_DIR="/var/log/twin-server"
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

    local _version
    _version=$(curl -sSL "$RELEASES_URL" | grep -oP "/condercx/twin-server/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+" | head -1 | grep -oP "v[0-9]+\.[0-9]+\.[0-9]+")
    if [[ -z "$_version" ]]; then
      echo "Error: could not determine latest version" >&2
      exit 1
    fi
    echo "Latest version: $_version"

    local _url="$RELEASES_URL/download/$_version/twin-server-linux-$ARCH"
    echo -n "Downloading ... "
    curl -fsSL -R "$_url" -o "$_tmpfile" || { echo "download failed" >&2; exit 1; }
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

  # Create directories
  mkdir -p "$LOG_DIR"
  touch "$LOG_DIR/twin.log"
  mkdir -p "$CONFIG_DIR"

  # Generate random password
  local _password
  _password=$(dd if=/dev/random bs=18 count=1 status=none | base64 | tr -d '\n')
  cat > "$CONFIG_DIR/config.conf" <<- EOC
# twin-server configuration
password = ${_password}

[[listener]]
listen = :80
tls = ws
EOC

  echo "Config:   $CONFIG_DIR/config.conf"
  echo "Password: $_password"

  # Install logrotate config
  cat > /etc/logrotate.d/twin-server <<- EOL
$LOG_DIR/twin.log {
    daily
    rotate 3
    maxsize 10M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOL

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

  # Set permissions
  chown -R twin "$CONFIG_DIR" "$LOG_DIR" 2>/dev/null || true

  echo ""
  echo "========================================"
  echo "  Twin-server installed!"
  echo "========================================"
  echo ""
  echo "  Start:   systemctl start twin-server"
  echo "  Status:  systemctl status twin-server -l"
  echo "  Restart: systemctl restart twin-server"
  systemctl enable twin-server 2>/dev/null || true
  echo "  Logs:    tail -f $LOG_DIR/twin.log"
  echo "  Password: $_password"
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

  echo "Removing logrotate config ..."
  rm -f /etc/logrotate.d/twin-server
  echo "  ok"

  echo ""
  echo "twin-server has been removed."
  echo ""
  echo "You may also want to remove:"
  echo "  rm -rf $CONFIG_DIR"
  echo "  rm -rf $LOG_DIR"
  echo "  userdel -r twin"
  echo ""
}

main "$@"
