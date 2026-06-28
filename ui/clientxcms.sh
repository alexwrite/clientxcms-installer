#!/bin/bash

set -e

#############################################################################
#                                                                           #
# clientxcms-installer - interactive UI for the ClientXCMS install.         #
#                                                                           #
# Collects every parameter, prints a summary, then hands over to the        #
# installer module. NOT affiliated with the official ClientXCMS project.    #
#                                                                           #
#############################################################################

# Load the shared library if not already sourced. Default the source URL vars so
# the module also works when run directly (not via install.sh).
fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  : "${GITHUB_BASE_URL:=https://raw.githubusercontent.com/alexwrite/clientxcms-installer}"
  : "${GITHUB_SOURCE:=main}"
  # shellcheck source=lib/lib.sh
  source /tmp/lib.sh 2>/dev/null || source <(curl -sSL "$GITHUB_BASE_URL/$GITHUB_SOURCE/lib/lib.sh")
  ! fn_exists lib_loaded && echo "* ERROR: Could not load lib script" && exit 1
fi

print_brake 70
output "ClientXCMS installation"
output ""
output "This wizard installs PHP $PHP_VERSION, MariaDB, Nginx, Redis, Node $NODE_VERSION"
output "and ClientXCMS itself into $INSTALL_DIR."
output ""
output "NOTE: ClientXCMS finalisation (license activation + admin account) is"
output "done through the WEB installer once this script completes. You will need"
output "your OAuth Client ID/Secret from https://clientxcms.com/client/services/"
print_brake 70
echo ""

# ----------------------- Domain ----------------------- #

output "Enter the domain name (FQDN) that will point to this server."
output "Example: panel.example.com - leave empty to use the server IP only."
echo -n "* FQDN (or IP): "
read -r FQDN
[ -z "$FQDN" ] && FQDN="localhost"
export FQDN

# ----------------------- Locale ----------------------- #

echo ""
required_input APP_LOCALE "Default locale (fr/en) [fr]: " "" "fr"
export APP_LOCALE

# --------------------- Database ----------------------- #

echo ""
output "Database configuration (a local MariaDB will be installed)."
required_input MYSQL_DB "Database name [clientxcms]: " "" "clientxcms"
required_input MYSQL_USER "Database username [clientxcms]: " "" "clientxcms"

echo ""
output "Leave the password empty to generate a strong one automatically."
password_input MYSQL_PASSWORD "Database password (auto-generated if empty): " "" "$(gen_passwd 64)"
export MYSQL_DB MYSQL_USER MYSQL_PASSWORD
export DB_HOST="127.0.0.1"
export DB_PORT="3306"

# --------------------- Options ------------------------ #

echo ""
output "Use Redis for cache, sessions and queue? (recommended)"
yes_no USE_REDIS "Enable Redis"
export USE_REDIS

echo ""
output "Install a persistent queue worker (systemd service running queue:work)?"
yes_no CONFIGURE_WORKER "Enable queue worker"
export CONFIGURE_WORKER

echo ""
output "Configure the firewall (UFW/firewalld) to allow ports 22, 80, 443?"
yes_no CONFIGURE_FIREWALL "Configure firewall"
export CONFIGURE_FIREWALL

# ------------------- SSL / HTTPS ---------------------- #

echo ""
CONFIGURE_LETSENCRYPT=false
ASSUME_SSL=false
email=""

if valid_fqdn "$FQDN"; then
  output "Obtain a free Let's Encrypt SSL certificate for $FQDN?"
  output "Requirements: $FQDN must already resolve to THIS server's public IP,"
  output "and ports 80/443 must be reachable from the internet."
  yes_no CONFIGURE_LETSENCRYPT "Configure Let's Encrypt"

  if [ "$CONFIGURE_LETSENCRYPT" == true ]; then
    email_input email "Email for Let's Encrypt registration: " "Please enter a valid email."
  fi
else
  warning "No valid FQDN provided ($FQDN). Let's Encrypt requires a real domain; skipping SSL."
fi
export CONFIGURE_LETSENCRYPT ASSUME_SSL email

# ----------------- Timezone --------------------------- #

echo ""
required_input timezone "Server timezone [Europe/Paris]: " "" "Europe/Paris"
export timezone

# ----------------- Summary ---------------------------- #

echo ""
print_brake 70
output "Installation summary"
print_brake 70
output "OS               : $OS $OS_VER ($ARCH)"
output "Install directory: $INSTALL_DIR"
output "Domain (FQDN)    : $FQDN"
output "Default locale   : $APP_LOCALE"
output "Database name    : $MYSQL_DB"
output "Database user    : $MYSQL_USER"
output "Database password: (hidden)"
output "Redis            : $USE_REDIS"
output "Queue worker     : $CONFIGURE_WORKER"
output "Firewall         : $CONFIGURE_FIREWALL"
output "Let's Encrypt    : $CONFIGURE_LETSENCRYPT"
[ "$CONFIGURE_LETSENCRYPT" == true ] && output "LE email         : $email"
output "Timezone         : $timezone"
print_brake 70
echo ""

echo -e -n "* Proceed with the installation? (y/N): "
read -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  error "Installation aborted by user."
  exit 1
fi

run_installer "clientxcms"
