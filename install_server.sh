#!/usr/bin/env bash
#
# install_server.sh - twin-server install script
# Try `install_server.sh --help` for usage.
#
set -e

SCRIPT_NAME="$(basename "$0")"
SCRIPT_ARGS=("$@")

EXECUTABLE_INSTALL_PATH="/usr/local/bin/twin-server"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/twin-server"
LOG_DIR="/var/log/twin-server"
REPO_URL="https://github.com/condercx/twin-server"
RELEASES_URL="https://github.com/condercx/twin-server/releases"

CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
ARCHITECTURE="${ARCHITECTURE:-}"
TWIN_USER="${TWIN_USER:-}"
TWIN_HOME_DIR="${TWIN_HOME_DIR:-}"
SECONTEXT_SYSTEMD_UNIT="${SECONTEXT_SYSTEMD_UNIT:-}"

OPERATION=
VERSION=
FORCE=
LOCAL_FILE=

has_command() {
  local _command=$1
  type -P "$_command" > /dev/null 2>&1
}

curl() {
  command curl "${CURL_FLAGS[@]}" "$@"
}

mktemp() {
  command mktemp "$@" "/tmp/twinservinst.XXXXXXXXXX"
}

tput() {
  if has_command tput; then
    command tput "$@"
  fi
}

tred() { tput setaf 1; }
tgreen() { tput setaf 2; }
tyellow() { tput setaf 3; }
tblue() { tput setaf 6; }
tbold() { tput bold; }
treset() { tput sgr0; }

note() { echo -e "$SCRIPT_NAME: $(tbold)note: $1$(treset)"; }
warning() { echo -e "$SCRIPT_NAME: $(tyellow)warning: $1$(treset)"; }
error() { echo -e "$SCRIPT_NAME: $(tred)error: $1$(treset)"; }

has_prefix() {
    local _s="$1" _prefix="$2"
    if [[ -z "$_prefix" ]]; then return 0; fi
    if [[ -z "$_s" ]]; then return 1; fi
    [[ "x$_s" != "x${_s#"$_prefix"}" ]]
}

generate_random_password() {
  dd if=/dev/random bs=18 count=1 status=none | base64
}

generate_self_signed_cert() {
  local _cert="$1" _key="$2"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -keyout "$_key" -out "$_cert" \
    -subj "/CN=twin-server" 2>/dev/null
}

systemctl() {
  if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]] || ! has_command systemctl; then
    warning "Ignored systemd command: systemctl $@"
    return
  fi
  command systemctl "$@"
}

chcon() {
  if ! has_command chcon || [[ "x$FORCE_NO_SELINUX" == "x1" ]]; then return; fi
  command chcon "$@"
}

get_systemd_version() {
  if ! has_command systemctl; then return; fi
  command systemctl --version | head -1 | cut -d " " -f 2
}

systemd_unit_working_directory() {
  local _systemd_version="$(get_systemd_version || true)"
  if [[ -n "$_systemd_version" && "$_systemd_version" -lt "227" ]]; then
    echo "$TWIN_HOME_DIR"
    return
  fi
  echo "~"
}

get_selinux_context() {
  local _file="$1"
  local _lsres="$(ls -dZ "$_file" | head -1)"
  local _sectx=""
  case "$(echo "$_lsres" | wc -w)" in
    2) _sectx="$(echo "$_lsres" | cut -d " " -f 1)" ;;
    5) _sectx="$(echo "$_lsres" | cut -d " " -f 4)" ;;
  esac
  [[ "x$_sectx" == "x?" ]] && _sectx=""
  echo "$_sectx"
}

show_argument_error_and_exit() {
  error "$1"
  echo "Try \"$0 --help\" for usage." >&2
  exit 22
}

install_content() {
  local _install_flags="$1" _content="$2" _destination="$3" _overwrite="$4"
  local _tmpfile="$(mktemp)"
  echo -ne "Install $_destination ... "
  echo "$_content" > "$_tmpfile"
  if [[ -z "$_overwrite" && -e "$_destination" ]]; then
    echo -e "exists"
  elif install "$_install_flags" "$_tmpfile" "$_destination"; then
    echo -e "ok"
  fi
  rm -f "$_tmpfile"
}

remove_file() {
  local _target="$1"
  echo -ne "Remove $_target ... "
  if rm "$_target"; then echo -e "ok"; fi
}

exec_sudo() {
  local _saved_ifs="$IFS"
  IFS=$"\n"
  local _preserved_env=(
    $(env | grep "^PACKAGE_MANAGEMENT_INSTALL=" || true)
    $(env | grep "^OPERATING_SYSTEM=" || true)
    $(env | grep "^ARCHITECTURE=" || true)
    $(env | grep "^TWIN_\w*=" || true)
    $(env | grep "^SECONTEXT_SYSTEMD_UNIT=" || true)
    $(env | grep "^FORCE_\w*=" || true)
  )
  IFS="$_saved_ifs"
  exec sudo env "${_preserved_env[@]}" "$@"
}

detect_package_manager() {
  if [[ -n "$PACKAGE_MANAGEMENT_INSTALL" ]]; then return 0; fi
  if has_command apt; then
    apt update
    PACKAGE_MANAGEMENT_INSTALL="apt -y --no-install-recommends install"
    return 0
  fi
  if has_command dnf; then PACKAGE_MANAGEMENT_INSTALL="dnf -y install"; return 0; fi
  if has_command yum; then PACKAGE_MANAGEMENT_INSTALL="yum -y install"; return 0; fi
  if has_command zypper; then PACKAGE_MANAGEMENT_INSTALL="zypper install -y --no-recommends"; return 0; fi
  if has_command pacman; then PACKAGE_MANAGEMENT_INSTALL="pacman -Syu --noconfirm"; return 0; fi
  return 1
}

install_software() {
  local _package_name="$1"
  if ! detect_package_manager; then
    error "Supported package manager is not detected, please install the following package manually:"
    echo; echo -e "\t* $_package_name"; echo; exit 65
  fi
  echo "Installing missing dependence '$_package_name' with '$PACKAGE_MANAGEMENT_INSTALL' ... "
  if $PACKAGE_MANAGEMENT_INSTALL "$_package_name"; then echo "ok"
  else error "Cannot install '$_package_name' with detected package manager, please install it manually."; exit 65; fi
}

is_user_exists() { id "$1" > /dev/null 2>&1; }

rerun_with_sudo() {
  if ! has_command sudo; then return 13; fi
  local _target_script
  if has_prefix "$0" "/dev/" || has_prefix "$0" "/proc/"; then
    local _tmp_script="$(mktemp)"
    chmod +x "$_tmp_script"
    if has_command curl; then curl -o "$_tmp_script" "https://raw.githubusercontent.com/condercx/twin-server/main/install_server.sh"
    elif has_command wget; then wget -O "$_tmp_script" "https://raw.githubusercontent.com/condercx/twin-server/main/install_server.sh"
    else return 127; fi
    _target_script="$_tmp_script"
  else _target_script="$0"; fi
  note "Re-running this script with sudo."
  exec_sudo "$_target_script" "${SCRIPT_ARGS[@]}"
}

check_permission() {
  if [[ "$UID" -eq "0" ]]; then return; fi
  note "The user running this script is not root."
  case "$FORCE_NO_ROOT" in
    "1") warning "FORCE_NO_ROOT=1 detected, we will proceed without root, but you may get insufficient privileges errors." ;;
    *)
      if ! rerun_with_sudo; then
        error "Please run this script with root or specify FORCE_NO_ROOT=1."
        exit 13
      fi ;;
  esac
}

check_environment_operating_system() {
  if [[ -n "$OPERATING_SYSTEM" ]]; then warning "OPERATING_SYSTEM=$OPERATING_SYSTEM detected."; return; fi
  if [[ "x$(uname)" == "xLinux" ]]; then OPERATING_SYSTEM=linux; return; fi
  error "This script only supports Linux."
  exit 95
}

check_environment_architecture() {
  if [[ -n "$ARCHITECTURE" ]]; then warning "ARCHITECTURE=$ARCHITECTURE detected."; return; fi
  case "$(uname -m)" in
    "x86_64" | "amd64") ARCHITECTURE="amd64" ;;
    "armv8" | "aarch64") ARCHITECTURE="arm64" ;;
    *) error "The architecture '$(uname -m)' is not supported."; exit 8 ;;
  esac
}

check_environment_systemd() {
  if [[ -d "/run/systemd/system" ]] || grep -q systemd <(ls -l /sbin/init); then return; fi
  case "$FORCE_NO_SYSTEMD" in
    "1") warning "FORCE_NO_SYSTEMD=1, proceeding as if systemd exists." ;;
    "2") warning "FORCE_NO_SYSTEMD=2, skipping all systemd related commands." ;;
    *)
      error "This script only supports Linux distributions with systemd."
      note "Specify FORCE_NO_SYSTEMD=1 or FORCE_NO_SYSTEMD=2 to bypass."
      exit 95 ;;
  esac
}

check_environment_selinux() {
  if ! has_command getenforce; then return; fi
  note "SELinux is detected"
  if [[ "x$FORCE_NO_SELINUX" == "x1" ]]; then warning "FORCE_NO_SELINUX=1, skipping SELinux related commands."; return; fi
  if [[ -z "$SECONTEXT_SYSTEMD_UNIT" ]]; then
    if [[ -z "$FORCE_NO_SYSTEMD" ]] && [[ -e "$SYSTEMD_SERVICES_DIR" ]]; then
      local _sectx="$(get_selinux_context "$SYSTEMD_SERVICES_DIR")"
      if [[ -z "$_sectx" ]]; then warning "Failed to obtain SEContext of $SYSTEMD_SERVICES_DIR"
      else SECONTEXT_SYSTEMD_UNIT="$_sectx"; fi
    fi
  fi
}

check_environment_curl() { if has_command curl; then return; fi; install_software curl; }
check_environment_grep() { if has_command grep; then return; fi; install_software grep; }
check_environment_openssl() { if has_command openssl; then return; fi; install_software openssl; }

check_environment() {
  check_environment_operating_system
  check_environment_architecture
  check_environment_systemd
  check_environment_selinux
  check_environment_curl
  check_environment_grep
  check_environment_openssl
}

vercmp_segment() {
  local _lhs="$1" _rhs="$2"
  if [[ "x$_lhs" == "x$_rhs" ]]; then echo 0; return; fi
  if [[ -z "$_lhs" ]]; then echo -1; return; fi
  if [[ -z "$_rhs" ]]; then echo 1; return; fi
  local _lhs_num="${_lhs//[A-Za-z]*/}" _rhs_num="${_rhs//[A-Za-z]*/}"
  if [[ "x$_lhs_num" == "x$_rhs_num" ]]; then echo 0; return; fi
  if [[ -z "$_lhs_num" ]]; then echo -1; return; fi
  if [[ -z "$_rhs_num" ]]; then echo 1; return; fi
  local _numcmp=$(($_lhs_num - $_rhs_num))
  if [[ "$_numcmp" -ne 0 ]]; then echo "$_numcmp"; return; fi
  local _lhs_suffix="${_lhs#"$_lhs_num"}" _rhs_suffix="${_rhs#"$_rhs_num"}"
  if [[ "x$_lhs_suffix" == "x$_rhs_suffix" ]]; then echo 0; return; fi
  if [[ -z "$_lhs_suffix" ]]; then echo 1; return; fi
  if [[ -z "$_rhs_suffix" ]]; then echo -1; return; fi
  if [[ "$_lhs_suffix" < "$_rhs_suffix" ]]; then echo -1; return; fi
  echo 1
}

vercmp() {
  local _lhs=${1#v} _rhs=${2#v}
  while [[ -n "$_lhs" && -n "$_rhs" ]]; do
    local _clhs="${_lhs/.*/}" _crhs="${_rhs/.*/}"
    local _segcmp="$(vercmp_segment "$_clhs" "$_crhs")"
    if [[ "$_segcmp" -ne 0 ]]; then echo "$_segcmp"; return; fi
    _lhs="${_lhs#"$_clhs"}"; _lhs="${_lhs#.}"
    _rhs="${_rhs#"$_crhs"}"; _rhs="${_rhs#.}"
  done
  if [[ "x$_lhs" == "x$_rhs" ]]; then echo 0; return; fi
  if [[ -z "$_lhs" ]]; then echo -1; return; fi
  if [[ -z "$_rhs" ]]; then echo 1; return; fi
}

check_twin_user() {
  local _default_twin_user="$1"
  if [[ -n "$TWIN_USER" ]]; then return; fi
  if [[ ! -e "$SYSTEMD_SERVICES_DIR/twin-server.service" ]]; then
    TWIN_USER="$_default_twin_user"; return
  fi
  TWIN_USER="$(grep -o "^User=\w*" "$SYSTEMD_SERVICES_DIR/twin-server.service" | tail -1 | cut -d "=" -f 2 || true)"
  [[ -z "$TWIN_USER" ]] && TWIN_USER="$_default_twin_user"
}

check_twin_homedir() {
  local _default_twin_homedir="$1"
  if [[ -n "$TWIN_HOME_DIR" ]]; then return; fi
  if ! is_user_exists "$TWIN_USER"; then
    TWIN_HOME_DIR="$_default_twin_homedir"; return
  fi
  TWIN_HOME_DIR="$(eval echo ~"$TWIN_USER")"
}

show_usage_and_exit() {
  echo
  echo -e "\t$(tbold)$SCRIPT_NAME$(treset) - twin-server install script"
  echo
  echo -e "Usage:"
  echo
  echo -e "$(tbold)Install twin-server$(treset)"
  echo -e "\t$0 [ -f | -l <file> | --version <version> ]"
  echo -e "Flags:"
  echo -e "\t-f, --force\tForce re-install even if installed."
  echo -e "\t-l, --local <file>\tInstall specified binary instead of download."
  echo -e "\t--version <version>\tInstall specified version instead of the latest."
  echo
  echo -e "$(tbold)Remove twin-server$(treset)"
  echo -e "\t$0 --remove"
  echo
  echo -e "$(tbold)Show this help$(treset)"
  echo -e "\t$0 -h, $0 --help"
  exit 0
}

parse_arguments() {
  while [[ "$#" -gt "0" ]]; do
    case "$1" in
      "--remove") OPERATION="remove" ;;
      "--version")
        VERSION="$2"
        if [[ -z "$VERSION" ]]; then show_argument_error_and_exit "Please specify the version for --version."; fi
        shift
        if ! has_prefix "$VERSION" "v"; then show_argument_error_and_exit "Version should begin with 'v' (e.g. 'v0.0.1')."; fi ;;
      "-f" | "--force") FORCE="1" ;;
      "-h" | "--help") show_usage_and_exit ;;
      "-l" | "--local")
        LOCAL_FILE="$2"
        if [[ -z "$LOCAL_FILE" ]]; then show_argument_error_and_exit "Please specify the file for -l/--local."; fi
        break ;;
      *) show_argument_error_and_exit "Unknown option '$1'" ;;
    esac
    shift
  done
  [[ -z "$OPERATION" ]] && OPERATION="install"
  case "$OPERATION" in
    "install")
      if [[ -n "$VERSION" && -n "$LOCAL_FILE" ]]; then show_argument_error_and_exit "--version and --local cannot be used together."; fi ;;
    *) if [[ -n "$VERSION" ]]; then show_argument_error_and_exit "--version is only valid for install."; fi
       if [[ -n "$LOCAL_FILE" ]]; then show_argument_error_and_exit "--local is only valid for install."; fi ;;
  esac
}

tpl_twin_server_service() {
  local _config_name="$1"
  cat << EOF
[Unit]
Description=Twin Server Service (${_config_name}.conf)
After=network.target

[Service]
Type=simple
ExecStart=$EXECUTABLE_INSTALL_PATH -conf ${CONFIG_DIR}/${_config_name}.conf
WorkingDirectory=$(systemd_unit_working_directory)
User=$TWIN_USER
Group=$TWIN_USER
NoNewPrivileges=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
}

tpl_etc_twin_server_config() {
  local _password="$1" _listen="$2" _cert="$3" _key="$4"
  cat << EOF
# twin-server configuration
# Generated by install_server.sh on $(date -u)

listen = ${_listen}
password = ${_password}
cert = ${_cert}
key = ${_key}
EOF
}

get_running_services() {
  if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]]; then return; fi
  systemctl list-units --state=active --plain --no-legend \
    | grep -o "twin-server@*[^\s]*.service" || true
}

restart_running_services() {
  if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]]; then return; fi
  echo "Restarting running service ... "
  for service in $(get_running_services); do
    echo -ne "Restarting $service ... "
    systemctl restart "$service"
    echo "done"
  done
}

stop_running_services() {
  if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]]; then return; fi
  echo "Stopping running service ... "
  for service in $(get_running_services); do
    echo -ne "Stopping $service ... "
    systemctl stop "$service"
    echo "done"
  done
}

is_twin_installed() {
  if [[ -f "$EXECUTABLE_INSTALL_PATH" || -h "$EXECUTABLE_INSTALL_PATH" ]]; then return 0; fi
  return 1
}

get_installed_version() {
  if is_twin_installed; then
    "$EXECUTABLE_INSTALL_PATH" -version 2>/dev/null || echo ""
  fi
}

get_latest_version() {
  if [[ -n "$VERSION" ]]; then echo "$VERSION"; return; fi

  local _tmpfile=$(mktemp)
  if ! curl -sS "$RELEASES_URL" -o "$_tmpfile"; then
    error "Failed to get releases list, please check your network."
    exit 11
  fi

  local _latest_version=$(grep -oP '/condercx/twin-server/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+[^"]*' "$_tmpfile" | head -1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')
  if [[ -n "$_latest_version" ]]; then
    echo "$_latest_version"
  fi

  rm -f "$_tmpfile"
}

download_twin() {
  local _version="$1" _destination="$2"
  local _download_url="$RELEASES_URL/download/$_version/twin-server-$OPERATING_SYSTEM-$ARCHITECTURE"
  echo "Downloading twin-server binary: $_download_url ..."
  if ! curl -R -H "Cache-Control: no-cache" "$_download_url" -o "$_destination"; then
    error "Download failed, please check your network."
    return 11
  fi
  return 0
}

check_update() {
  echo -ne "Checking for installed version ... "
  local _installed_version="$(get_installed_version)"
  if [[ -n "$_installed_version" ]]; then echo "$_installed_version"
  else echo "not installed"; fi

  echo -ne "Checking for latest version ... "
  local _latest_version="$(get_latest_version)"
  if [[ -n "$_latest_version" ]]; then
    echo "$_latest_version"
    VERSION="$_latest_version"
  else
    echo "failed"
    return 1
  fi

  local _vercmp="$(vercmp "$_installed_version" "$_latest_version")"
  if [[ "$_vercmp" -lt 0 ]]; then return 0; fi
  return 1
}

perform_install_twin_binary() {
  if [[ -n "$LOCAL_FILE" ]]; then
    note "Performing local install: $LOCAL_FILE"
    echo -ne "Installing twin-server executable ... "
    if install -Dm755 "$LOCAL_FILE" "$EXECUTABLE_INSTALL_PATH"; then echo "ok"
    else exit 2; fi
    return
  fi

  local _tmpfile=$(mktemp)
  if ! download_twin "$VERSION" "$_tmpfile"; then rm -f "$_tmpfile"; exit 11; fi

  echo -ne "Installing twin-server executable ... "
  if install -Dm755 "$_tmpfile" "$EXECUTABLE_INSTALL_PATH"; then echo "ok"
  else exit 13; fi
  rm -f "$_tmpfile"
}

perform_remove_twin_binary() {
  remove_file "$EXECUTABLE_INSTALL_PATH"
}

perform_install_twin_config() {
  local _password="$1" _listen="$2" _cert="$3" _key="$4"

  install -d -m 755 "$CONFIG_DIR"
  install_content -Dm644 "$(tpl_etc_twin_server_config "$_password" "$_listen" "$_cert" "$_key")" "$CONFIG_DIR/config.conf" ""
}

perform_install_twin_cert() {
  local _cert="$1" _key="$2"

  if [[ -f "$_cert" && -f "$_key" ]]; then
    echo -ne "Install TLS certificate ... ok (existing)"
    return
  fi

  install -d -m 755 "$CONFIG_DIR"
  echo -ne "Generating self-signed TLS certificate ... "
  if generate_self_signed_cert "$_cert" "$_key"; then
    echo "ok"
  else
    echo "failed"
    exit 13
  fi
}

perform_install_twin_systemd() {
  if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]]; then return; fi

  install_content -Dm644 "$(tpl_twin_server_service config)" "$SYSTEMD_SERVICES_DIR/twin-server.service" "1"
  install_content -Dm644 "$(tpl_twin_server_service %i)" "$SYSTEMD_SERVICES_DIR/twin-server@.service" "1"
  if [[ -n "$SECONTEXT_SYSTEMD_UNIT" ]]; then
    chcon "$SECONTEXT_SYSTEMD_UNIT" "$SYSTEMD_SERVICES_DIR/twin-server.service"
    chcon "$SECONTEXT_SYSTEMD_UNIT" "$SYSTEMD_SERVICES_DIR/twin-server@.service"
  fi

  systemctl daemon-reload
}

perform_remove_twin_systemd() {
  remove_file "$SYSTEMD_SERVICES_DIR/twin-server.service"
  remove_file "$SYSTEMD_SERVICES_DIR/twin-server@.service"
  systemctl daemon-reload
}

perform_install_twin_home() {
  if ! is_user_exists "$TWIN_USER"; then
    echo -ne "Creating user $TWIN_USER ... "
    useradd -r -d "$TWIN_HOME_DIR" -m "$TWIN_USER"
    echo "ok"
  fi
}

perform_install() {
  local _is_fresh_install
  if ! is_twin_installed; then _is_fresh_install=1; fi

  if [[ -n "$LOCAL_FILE" ]] || [[ -n "$VERSION" ]] || check_update; then
    : # update required
  fi

  if [[ "x$FORCE" == "x1" ]]; then
    if [[ -z "$_is_update_required" ]]; then
      note "Option --force detected, re-installing."
    fi
    _is_update_required=1
  fi

  perform_install_twin_binary
  perform_install_twin_home

  # Interactive configuration
  local _listen=":8443"
  local _password="$(generate_random_password)"
  local _cert="$CONFIG_DIR/server.crt"
  local _key="$CONFIG_DIR/server.key"

  echo
  echo -e "$(tbold)Twin Server Configuration$(treset)"
  echo
  read -p "Listen address [$_listen]: " _listen_input
  [[ -n "$_listen_input" ]] && _listen="$_listen_input"
  read -p "Auth password [auto-generated]: " _password_input
  [[ -n "$_password_input" ]] && _password="$_password_input"
  echo

  perform_install_twin_cert "$_cert" "$_key"
  perform_install_twin_config "$_password" "$_listen" "$_cert" "$_key"
  perform_install_twin_systemd

  echo
  if [[ -n "$_is_fresh_install" ]]; then
    echo -e "$(tbold)Twin-server has been successfully installed on your server.$(treset)"
    echo
    echo -e "What's next?"
    echo
    echo -e "\t+ Edit server config: $(tred)$CONFIG_DIR/config.conf$(treset)"
    echo -e "\t+ Start: $(tred)systemctl start twin-server$(treset)"
    echo -e "\t+ Enable on boot: $(tred)systemctl enable twin-server$(treset)"
    echo -e "\t+ Check logs: $(tred)journalctl -u twin-server -f$(treset)"
    echo
    echo -e "Your auth password: $(tred)$_password$(treset)"
  else
    restart_running_services
    echo
    echo -e "$(tbold)Twin-server has been successfully updated.$(treset)"
    echo
  fi
}

perform_remove() {
  perform_remove_twin_binary
  stop_running_services
  perform_remove_twin_systemd

  echo
  echo -e "$(tbold)Twin-server has been successfully removed.$(treset)"
  echo
  echo -e "You still need to remove configuration files manually:"
  echo
  echo -e "\t$(tred)rm -rf $CONFIG_DIR$(treset)"
  echo -e "\t$(tred)rm -rf $LOG_DIR$(treset)"
  if [[ "x$TWIN_USER" != "xroot" ]]; then
    echo -e "\t$(tred)userdel -r $TWIN_USER$(treset)"
  fi
  echo
}

main() {
  parse_arguments "$@"
  check_permission
  check_environment
  check_twin_user "twin"
  check_twin_homedir "/var/lib/$TWIN_USER"

  case "$OPERATION" in
    "install") perform_install ;;
    "remove") perform_remove ;;
    *) error "Unknown operation '$OPERATION'." ;;
  esac
}

main "$@"
# vim:set ft=bash ts=2 sw=2 sts=2 et:
