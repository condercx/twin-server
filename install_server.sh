#!/usr/bin/env bash
#
# install_server.sh - twin-server install script
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/condercx/twin-server/main/install_server.sh)
#   bash <(curl -fsSL https://raw.githubusercontent.com/condercx/twin-server/main/install_server.sh) --remove
#
# SPDX-License-Identifier: MIT
#

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

EXECUTABLE_INSTALL_PATH="/usr/local/bin/twin-server"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/twin-server"
RELEASES_URL="https://github.com/condercx/twin-server/releases"
RAW_URL="https://raw.githubusercontent.com/condercx/twin-server/main/install_server.sh"

CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

OPERATION=
LOCAL_FILE=

has_command() { type -P "$1" > /dev/null 2>&1; }

curl()  { command curl "${CURL_FLAGS[@]}" "$@"; }
mktemp() { command mktemp "$@" "/tmp/twinservinst.XXXXXXXXXX"; }

# Color helpers ? safe even when tput is missing
red()    { [[ -n "${NO_COLOR:-}" ]] && return; has_command tput && tput setaf 1 || true; }
green()  { [[ -n "${NO_COLOR:-}" ]] && return; has_command tput && tput setaf 2 || true; }
yellow() { [[ -n "${NO_COLOR:-}" ]] && return; has_command tput && tput setaf 3 || true; }
bold()   { [[ -n "${NO_COLOR:-}" ]] && return; has_command tput && tput bold || true; }
reset()  { [[ -n "${NO_COLOR:-}" ]] && return; has_command tput && tput sgr0 || true; }

note()    { echo -e "$(bold)note:$(reset) $1"; }
warning() { echo -e "$(yellow)warning:$(reset) $1"; }
error()   { echo -e "$(red)error:$(reset) $1" >&2; }

is_user_exists() { id "$1" > /dev/null 2>&1; }

detect_package_manager() {
  if has_command apt; then
    PACKAGE_MANAGEMENT_INSTALL="apt -y --no-install-recommends install"
  elif has_command dnf; then
    PACKAGE_MANAGEMENT_INSTALL="dnf -y install"
  elif has_command yum; then
    PACKAGE_MANAGEMENT_INSTALL="yum -y install"
  elif has_command zypper; then
    PACKAGE_MANAGEMENT_INSTALL="zypper install -y --no-recommends"
  elif has_command pacman; then
    PACKAGE_MANAGEMENT_INSTALL="pacman -Syu --noconfirm"
  else
    return 1
  fi
}

install_software() {
  if ! detect_package_manager; then
    error "No supported package manager found. Please install $1 manually."
    exit 65
  fi
  $PACKAGE_MANAGEMENT_INSTALL "$1"
}

show_usage_and_exit() {
  echo
  echo "Usage:"
  echo "  Install:  bash <(curl -fsSL $RAW_URL)"
  echo "  Remove:   bash <(curl -fsSL $RAW_URL) --remove"
  echo
  echo "Flags:"
  echo "  -l <file>   Install from local file"
  echo "  -f          Force reinstall"
  echo "  --remove    Remove twin-server"
  echo "  -h, --help  Show this help"
  echo
  exit 0
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      "--remove") OPERATION="remove" ;;
      "-f"|"--force") FORCE="1" ;;
      "-h"|"--help") show_usage_and_exit ;;
      "-l"|"--local")
        LOCAL_FILE="$2"
        if [[ -z "$LOCAL_FILE" ]]; then
          error "Please specify file for -l/--local."
          exit 22
        fi
        shift
        break ;;
      *) error "Unknown option: $1"; exit 22 ;;
    esac
    shift
  done
  [[ -z "${OPERATION:-}" ]] && OPERATION="install"
}

check_root() {
  if [[ $UID -ne 0 ]]; then
    error "Please run as root (use sudo)."
    exit 13
  fi
}

detect_arch() {
  case "$(uname -m)" in
    "x86_64"|"amd64") ARCH="amd64" ;;
    "aarch64"|"armv8l") ARCH="arm64" ;;
    *) error "Unsupported architecture: $(uname -m)"; exit 8 ;;
  esac
}

download_binary() {
  local _version="$1" _dest="$2"

  if [[ -z "$_version" ]]; then
    local _tmpfile; _tmpfile="$(mktemp)"
    curl -sS "$RELEASES_URL" -o "$_tmpfile"
    _version=$(grep -oP "/condercx/twin-server/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+" "$_tmpfile" | head -1 | grep -oP "v[0-9]+\.[0-9]+\.[0-9]+" || true)
    rm -f "$_tmpfile"
    if [[ -z "$_version" ]]; then
      error "No releases found."
      exit 11
    fi
  fi

  local _url="$RELEASES_URL/download/$_version/twin-server-linux-$ARCH"
  echo "Downloading twin-server $_version ($ARCH) ..."
  curl -R "$_url" -o "$_dest"
  echo "ok"
}

perform_install() {
  detect_arch

  # 1. Install binary
  if [[ -n "$LOCAL_FILE" ]]; then
    echo -ne "Installing twin-server from $LOCAL_FILE ... "
    install -Dm755 "$LOCAL_FILE" "$EXECUTABLE_INSTALL_PATH"
    echo "ok"
  else
    local _tmpfile; _tmpfile="$(mktemp)"
    download_binary "" "$_tmpfile"
    echo -ne "Installing twin-server executable ... "
    install -Dm755 "$_tmpfile" "$EXECUTABLE_INSTALL_PATH"
    echo "ok"
    rm -f "$_tmpfile"
  fi

  # 2. Create twin user
  if ! is_user_exists "twin"; then
    echo -ne "Creating twin user ... "
    useradd -r -d /var/lib/twin -m twin
    echo "ok"
  fi

  # 3. Install openssl if needed
  if ! has_command openssl; then
    install_software openssl
  fi

  # 4. Generate self-signed certificate
  mkdir -p "$CONFIG_DIR"
  echo -ne "Generating self-signed TLS certificate ... "
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 36500 -keyout "$CONFIG_DIR/server.key" -out "$CONFIG_DIR/server.crt" \
    -subj "/CN=bing.com" 2>/dev/null
  echo "ok"
  chown -R twin "$CONFIG_DIR"

  # 5. Generate config file with random password
  local _password; _password="$(dd if=/dev/random bs=18 count=1 status=none | base64)"
  cat > "$CONFIG_DIR/config.conf" <<- EOC
# twin-server configuration
listen = :8443
password = ${_password}
cert = ${CONFIG_DIR}/server.crt
key = ${CONFIG_DIR}/server.key
EOC

  echo
  echo "  Config:   $CONFIG_DIR/config.conf"
  echo "  Password: $(red)${_password}$(reset)"
  echo

  # 6. Install systemd service
  cat > "$SYSTEMD_SERVICES_DIR/twin-server.service" <<- EOS
[Unit]
Description=Twin Server Service
After=network.target

[Service]
Type=simple
ExecStart=$EXECUTABLE_INSTALL_PATH -conf $CONFIG_DIR/config.conf
User=twin
Group=twin
NoNewPrivileges=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOS
  systemctl daemon-reload

  # 7. Done
  echo "$(bold)----------------------------------------$(reset)"
  echo "$(bold)  Twin-server has been installed!$(reset)"
  echo "$(bold)----------------------------------------$(reset)"
  echo
  echo "  Start:   systemctl start twin-server"
  echo "  Status:  systemctl status twin-server -l"
  echo "  Enable:  systemctl enable twin-server"
  echo "  Restart: systemctl restart twin-server"
  echo "  Logs:    journalctl -u twin-server -f"
  echo
  echo "  Remove:  bash <(curl -fsSL $RAW_URL) --remove"
  echo
}

perform_remove() {
  echo "Stopping twin-server ..."
  systemctl stop twin-server 2>/dev/null || true
  echo "ok"

  echo "Disabling twin-server ..."
  systemctl disable twin-server 2>/dev/null || true
  echo "ok"

  echo "Removing binary ..."
  rm -f "$EXECUTABLE_INSTALL_PATH"
  echo "ok"

  echo "Removing systemd service ..."
  rm -f "$SYSTEMD_SERVICES_DIR/twin-server.service"
  systemctl daemon-reload 2>/dev/null || true
  echo "ok"

  echo
  echo "twin-server removed."
  echo
  echo "You may also want to remove config and user:"
  echo "  rm -rf $CONFIG_DIR"
  echo "  userdel -r twin"
  echo
}

main() {
  parse_arguments "$@"
  check_root

  case "${OPERATION}" in
    "install") perform_install ;;
    "remove")  perform_remove ;;
  esac
}

main "$@"

