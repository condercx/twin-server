#!/usr/bin/env bash
#
# install_server.sh - twin-server install script
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/condercx/twin-server/main/install_server.sh)
#   bash install_server.sh --remove
#
set -e

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

curl() { command curl "${CURL_FLAGS[@]}" "$@"; }

mktemp() { command mktemp "$@" "/tmp/twinservinst.XXXXXXXXXX"; }

tred() { tput setaf 1; }
tgreen() { tput setaf 2; }
tyellow() { tput setaf 3; }
tbold() { tput bold; }
treset() { tput sgr0; }

note()  { echo -e "$SCRIPT_NAME: $(tbold)note: $1$(treset)"; }
warning() { echo -e "$SCRIPT_NAME: $(tyellow)warning: $1$(treset)"; }
error()  { echo -e "$SCRIPT_NAME: $(tred)error: $1$(treset)"; }

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
  return 0
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
  echo -e "Usage:"
  echo -e "  Install:  bash <(curl -fsSL $RAW_URL)"
  echo -e "  Remove:   bash <(curl -fsSL $RAW_URL) --remove"
  echo
  echo -e "Flags:"
  echo -e "  -l <file>  Install from local file"
  echo -e "  -f         Force reinstall"
  echo -e "  --remove   Remove twin-server"
  echo
  exit 0
}

parse_arguments() {
  while [[ "$#" -gt "0" ]]; do
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
        break ;;
      *) error "Unknown option: $1"; exit 22 ;;
    esac
    shift
  done
  [[ -z "$OPERATION" ]] && OPERATION="install"
}

check_root() {
  if [[ "$UID" -ne "0" ]]; then
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

  # Get latest version from GitHub releases if not specified
  if [[ -z "$_version" ]]; then
    local _tmpfile="$(mktemp)"
    if ! curl -sS "$RELEASES_URL" -o "$_tmpfile"; then
      error "Failed to get releases list."
      exit 11
    fi
    _version=$(grep -oP "/condercx/twin-server/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+" "$_tmpfile" | head -1 | grep -oP "v[0-9]+\.[0-9]+\.[0-9]+")
    rm -f "$_tmpfile"
    if [[ -z "$_version" ]]; then
      error "No releases found."
      exit 11
    fi
  fi

  local _url="$RELEASES_URL/download/$_version/twin-server-linux-$ARCH"
  echo "Downloading twin-server $_version ($ARCH) ..."
  if ! curl -R "$_url" -o "$_dest"; then
    error "Download failed."
    exit 11
  fi
  echo "ok"
}

perform_install() {
  detect_arch

  # 1. Install binary
  if [[ -n "$LOCAL_FILE" ]]; then
    echo -ne "Installing twin-server from $LOCAL_FILE ... "
    install -Dm755 "$LOCAL_FILE" "$EXECUTABLE_INSTALL_PATH" && echo "ok"
  else
    local _tmpfile="$(mktemp)"
    download_binary "" "$_tmpfile"
    echo -ne "Installing twin-server executable ... "
    install -Dm755 "$_tmpfile" "$EXECUTABLE_INSTALL_PATH" && echo "ok"
    rm -f "$_tmpfile"
  fi

  # 2. Create twin user
  if ! is_user_exists "twin"; then
    echo -ne "Creating twin user ... "
    useradd -r -d /var/lib/twin -m twin && echo "ok"
  fi

  # 3. Install openssl if needed
  if ! has_command openssl; then
    echo "Installing openssl ..."
    install_software openssl
  fi

  # 4. Generate self-signed certificate
  mkdir -p "$CONFIG_DIR"
  echo -ne "Generating self-signed TLS certificate ... "
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 36500 -keyout "$CONFIG_DIR/server.key" -out "$CONFIG_DIR/server.crt" \
    -subj "/CN=bing.com" 2>/dev/null && echo "ok"
  chown twin "$CONFIG_DIR/server.key" "$CONFIG_DIR/server.crt"

  # 5. Generate config file
  local _password="$(dd if=/dev/random bs=18 count=1 status=none | base64)"
  cat > "$CONFIG_DIR/config.conf" <<- EOC
# twin-server configuration
listen = :8443
password = ${_password}
cert = ${CONFIG_DIR}/server.crt
key = ${CONFIG_DIR}/server.key
EOC
  chown -R twin "$CONFIG_DIR"
  echo "Config file: $CONFIG_DIR/config.conf"

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

  # 7. Print success
  echo
  echo "$(tbold)----------------------------------------$(treset)"
  echo "$(tbold)  Twin-server has been installed!$(treset)"
  echo "$(tbold)----------------------------------------$(treset)"
  echo
  echo "  Config: $CONFIG_DIR/config.conf"
  echo "  Password: $(tred)$_password$(treset)"
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
  echo -ne "Stopping twin-server ... "
  systemctl stop twin-server 2>/dev/null && echo "ok" || echo "not running"

  echo -ne "Disabling twin-server ... "
  systemctl disable twin-server 2>/dev/null && echo "ok" || true

  echo -ne "Removing binary ... "
  rm -f "$EXECUTABLE_INSTALL_PATH" && echo "ok"

  echo -ne "Removing systemd service ... "
  rm -f "$SYSTEMD_SERVICES_DIR/twin-server.service"
  systemctl daemon-reload && echo "ok"

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

  case "$OPERATION" in
    "install") perform_install ;;
    "remove") perform_remove ;;
  esac
}

main "$@"

