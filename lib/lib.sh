#!/bin/bash

set -e

#############################################################################
#                                                                           #
# Project 'clientxcms-installer'                                            #
#                                                                           #
# Unofficial installation script for ClientXCMS (https://clientxcms.com).   #
# Released under the GNU GPL v3 license. This script is community-made and   #
# is NOT affiliated with the official ClientXCMS project.                   #
#                                                                           #
# Shared library: helpers used by the entrypoint, the UI and the installer. #
#                                                                           #
#############################################################################

# ------------------ Variables ----------------- #

# Versioning (overridable by the entrypoint)
export GITHUB_SOURCE=${GITHUB_SOURCE:-main}
export SCRIPT_RELEASE=${SCRIPT_RELEASE:-canary}

# Where the installer modules are served from. Override GITHUB_BASE_URL to use
# your own fork/mirror so the `bash <(curl ...)` one-liner keeps working.
export GITHUB_BASE_URL=${GITHUB_BASE_URL:-"https://raw.githubusercontent.com/alexwrite/clientxcms-installer"}
export GITHUB_URL="$GITHUB_BASE_URL/$GITHUB_SOURCE"

# ClientXCMS source (Git repository, master branch)
export CLIENTXCMS_REPO=${CLIENTXCMS_REPO:-"https://github.com/ClientXCMS/ClientXCMS.git"}
export CLIENTXCMS_BRANCH=${CLIENTXCMS_BRANCH:-master}

# Target versions
export PHP_VERSION=${PHP_VERSION:-8.3}
export NODE_VERSION=${NODE_VERSION:-20}

# Default install location (Laravel public/ is the document root)
export INSTALL_DIR=${INSTALL_DIR:-/var/www/clientxcms}

# Path (export everything we might need, harmless if already present)
export PATH="$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin"

# OS detection results
export OS=""
export OS_VER=""
export OS_VER_MAJOR=""
export CPU_ARCHITECTURE=""
export ARCH=""
export SUPPORTED=false

# Colors
COLOR_YELLOW='\033[1;33m'
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_NC='\033[0m'

# Email validation regex
email_regex="^(([A-Za-z0-9]+((\.|\-|\_|\+)?[A-Za-z0-9]?)*[A-Za-z0-9]+)|[A-Za-z0-9]+)@(([A-Za-z0-9]+)+((\.|\-|\_)?([A-Za-z0-9]+)+)*)+\.([A-Za-z]{2,})+$"

# Charset for generated passwords (alphanumeric only: safe in .env and MySQL grants)
password_charset='A-Za-z0-9'

# --------------------- Lib -------------------- #

lib_loaded() {
  return 0
}

# -------------- Visual functions -------------- #

output() {
  echo -e "* $1"
}

success() {
  echo ""
  output "${COLOR_GREEN}SUCCESS${COLOR_NC}: $1"
  echo ""
}

error() {
  echo ""
  echo -e "* ${COLOR_RED}ERROR${COLOR_NC}: $1" 1>&2
  echo ""
}

warning() {
  echo ""
  output "${COLOR_YELLOW}WARNING${COLOR_NC}: $1"
  echo ""
}

print_brake() {
  for ((n = 0; n < $1; n++)); do
    echo -n "#"
  done
  echo ""
}

hyperlink() {
  echo -e "\e]8;;${1}\a${1}\e]8;;\a"
}

welcome() {
  print_brake 70
  output "ClientXCMS unofficial installation script @ $SCRIPT_RELEASE"
  output ""
  output "This community script is NOT affiliated with the official ClientXCMS"
  output "project. Source: https://github.com/alexwrite/clientxcms-installer"
  output ""
  output "Running $OS version $OS_VER."
  print_brake 70
}

# ---------------- Lib functions --------------- #

get_latest_release() {
  curl -sL "https://api.github.com/repos/$1/releases/latest" |
    grep '"tag_name":' |
    sed -E 's/.*"([^"]+)".*/\1/'
}

update_lib_source() {
  GITHUB_URL="$GITHUB_BASE_URL/$GITHUB_SOURCE"
  rm -rf /tmp/lib.sh
  curl -sSL -o /tmp/lib.sh "$GITHUB_URL"/lib/lib.sh
  # shellcheck source=lib/lib.sh
  source /tmp/lib.sh
}

run_ui() {
  bash <(curl -sSL "$GITHUB_URL/ui/$1.sh")
}

run_installer() {
  bash <(curl -sSL "$GITHUB_URL/installers/$1.sh")
}

valid_email() {
  [[ $1 =~ ${email_regex} ]]
}

# Loose FQDN check: at least one dot, no spaces, valid characters.
valid_fqdn() {
  [[ $1 =~ ^([a-zA-Z0-9](-?[a-zA-Z0-9])*\.)+[a-zA-Z]{2,}$ ]]
}

gen_passwd() {
  local length=$1
  local password=""
  while [ ${#password} -lt "$length" ]; do
    password=$(head -c 200 /dev/urandom | LC_ALL=C tr -dc "$password_charset" | head -c "$length")
  done
  echo "$password"
}

# ------------ User input functions ------------ #

# required_input VARNAME "prompt" "error if empty" "default (optional)"
required_input() {
  local __resultvar=$1
  local result=''

  while [ -z "$result" ]; do
    echo -n "* ${2}"
    read -r result

    if [ -n "${4}" ]; then
      [ -z "$result" ] && result="${4}"
    else
      [ -z "$result" ] && error "${3}"
    fi
  done

  eval "$__resultvar="'$result'""
}

email_input() {
  local __resultvar=$1
  local result=''

  while ! valid_email "$result"; do
    echo -n "* ${2}"
    read -r result
    valid_email "$result" || error "${3}"
  done

  eval "$__resultvar="'$result'""
}

password_input() {
  local __resultvar=$1
  local result=''
  local default="$4"

  while [ -z "$result" ]; do
    echo -n "* ${2}"
    # Read silently, render a star per character, handle backspace.
    while IFS= read -r -s -n1 char; do
      [[ -z $char ]] && { printf '\n'; break; }
      if [[ $char == $'\x7f' ]]; then
        if [ -n "$result" ]; then
          result=${result%?}
          printf '\b \b'
        fi
      else
        result+=$char
        printf '*'
      fi
    done
    [ -z "$result" ] && [ -n "$default" ] && result="$default"
    [ -z "$result" ] && error "${3}"
  done

  eval "$__resultvar="'$result'""
}

# yes_no VARNAME "question" -> sets VARNAME to true/false (default No)
yes_no() {
  local __resultvar=$1
  echo -e -n "* ${2} (y/N): "
  read -r answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    eval "$__resultvar=true"
  else
    eval "$__resultvar=false"
  fi
}

# -------------------- MySQL ------------------- #

# MariaDB CLI wrapper: the `mariadb` command exists on 10.4+; older versions
# (MariaDB 10.3 on EL8/AlmaLinux 8) only ship the `mysql` client.
mariadb_cli() {
  if command -v mariadb >/dev/null 2>&1; then
    command mariadb "$@"
  else
    command mysql "$@"
  fi
}

create_db_user() {
  local db_user_name="$1"
  local db_user_password="$2"
  local db_host="${3:-127.0.0.1}"

  output "Creating database user $db_user_name..."
  mariadb_cli -u root -e "CREATE USER IF NOT EXISTS '$db_user_name'@'$db_host' IDENTIFIED BY '$db_user_password';"
  mariadb_cli -u root -e "FLUSH PRIVILEGES;"
  output "Database user $db_user_name created."
}

grant_all_privileges() {
  local db_name="$1"
  local db_user_name="$2"
  local db_host="${3:-127.0.0.1}"

  output "Granting privileges on $db_name to $db_user_name..."
  mariadb_cli -u root -e "GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user_name'@'$db_host' WITH GRANT OPTION;"
  mariadb_cli -u root -e "FLUSH PRIVILEGES;"
}

create_db() {
  local db_name="$1"
  local db_user_name="$2"
  local db_host="${3:-127.0.0.1}"

  output "Creating database $db_name..."
  mariadb_cli -u root -e "CREATE DATABASE IF NOT EXISTS $db_name CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  grant_all_privileges "$db_name" "$db_user_name" "$db_host"
  output "Database $db_name created."
}

# --------------- Package Manager -------------- #

update_repos() {
  case "$OS" in
  ubuntu | debian)
    output "Updating package repositories..."
    apt-get update -y
    ;;
  rocky | almalinux)
    output "Refreshing dnf metadata..."
    dnf makecache -y >/dev/null || true
    ;;
  esac
}

# install_packages "pkg1 pkg2 ..."
install_packages() {
  case "$OS" in
  ubuntu | debian)
    # shellcheck disable=SC2086
    eval apt-get -y install $1
    ;;
  rocky | almalinux)
    # shellcheck disable=SC2086
    eval dnf -y install $1
    ;;
  esac
}

# ------------------ Firewall ------------------ #

install_firewall() {
  case "$OS" in
  ubuntu | debian)
    output "Installing Uncomplicated Firewall (UFW)..."
    [ -x "$(command -v ufw)" ] || install_packages "ufw"
    ufw --force enable
    success "UFW enabled."
    ;;
  rocky | almalinux)
    output "Installing FirewallD..."
    [ -x "$(command -v firewall-cmd)" ] || install_packages "firewalld"
    systemctl --now enable firewalld >/dev/null
    success "FirewallD enabled."
    ;;
  esac
}

firewall_allow_ports() {
  case "$OS" in
  ubuntu | debian)
    for port in $1; do ufw allow "$port"; done
    ufw --force reload
    ;;
  rocky | almalinux)
    for port in $1; do firewall-cmd --zone=public --add-port="$port"/tcp --permanent; done
    firewall-cmd --reload -q
    ;;
  esac
}

# ---------------- System checks --------------- #

# Exit if not root
if [[ $EUID -ne 0 ]]; then
  error "This script must be executed with root privileges (use sudo)."
  exit 1
fi

# curl is required
if ! [ -x "$(command -v curl)" ]; then
  error "curl is required for this script to work."
  exit 1
fi

# Detect OS
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS=$(echo "$ID" | awk '{print tolower($0)}')
  OS_VER=$VERSION_ID
elif type lsb_release >/dev/null 2>&1; then
  OS=$(lsb_release -si | awk '{print tolower($0)}')
  OS_VER=$(lsb_release -sr)
elif [ -f /etc/debian_version ]; then
  OS="debian"
  OS_VER=$(cat /etc/debian_version)
else
  OS=$(uname -s)
  OS_VER=$(uname -r)
fi

OS=$(echo "$OS" | awk '{print tolower($0)}')
OS_VER_MAJOR=$(echo "$OS_VER" | cut -d. -f1)
CPU_ARCHITECTURE=$(uname -m)

case "$CPU_ARCHITECTURE" in
x86_64) ARCH=amd64 ;;
arm64 | aarch64) ARCH=arm64 ;;
*)
  error "Only x86_64 and arm64 architectures are supported."
  exit 1
  ;;
esac

case "$OS" in
ubuntu)
  # 20.04 (focal) is intentionally excluded: ondrej/php no longer builds PHP for
  # focal, and Ubuntu only ships PHP 7.4 there, so PHP 8.3 is unobtainable.
  [ "$OS_VER_MAJOR" == "22" ] && SUPPORTED=true
  [ "$OS_VER_MAJOR" == "24" ] && SUPPORTED=true
  export DEBIAN_FRONTEND=noninteractive
  ;;
debian)
  [ "$OS_VER_MAJOR" == "11" ] && SUPPORTED=true
  [ "$OS_VER_MAJOR" == "12" ] && SUPPORTED=true
  [ "$OS_VER_MAJOR" == "13" ] && SUPPORTED=true
  export DEBIAN_FRONTEND=noninteractive
  ;;
rocky | almalinux)
  [ "$OS_VER_MAJOR" == "8" ] && SUPPORTED=true
  [ "$OS_VER_MAJOR" == "9" ] && SUPPORTED=true
  ;;
*)
  SUPPORTED=false
  ;;
esac

if [ "$SUPPORTED" == false ]; then
  error "Unsupported OS: $OS $OS_VER. Supported: Ubuntu 20/22/24, Debian 11/12/13, Rocky/AlmaLinux 8/9."
  exit 1
fi
