#!/bin/bash

set -e

#############################################################################
#                                                                           #
# clientxcms-installer - uninstaller module.                               #
#                                                                           #
# Removes the ClientXCMS app, its services and (optionally) its database.   #
# By default the stack packages (PHP, MariaDB, Nginx, Redis) are kept; a    #
# final opt-in step can purge them too. NOT affiliated with ClientXCMS.     #
#                                                                           #
#############################################################################

fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  : "${GITHUB_BASE_URL:=https://raw.githubusercontent.com/alexwrite/clientxcms-installer}"
  : "${GITHUB_SOURCE:=main}"
  # shellcheck source=lib/lib.sh
  source /tmp/lib.sh 2>/dev/null || source <(curl -sSL "$GITHUB_BASE_URL/$GITHUB_SOURCE/lib/lib.sh")
  ! fn_exists lib_loaded && echo "* ERROR: Could not load lib script" && exit 1
fi

INSTALL_DIR="${INSTALL_DIR:-/var/www/clientxcms}"

WEBUSER="www-data"
case "$OS" in
rocky | almalinux) WEBUSER="nginx" ;;
esac

print_brake 70
warning "This will remove ClientXCMS from $INSTALL_DIR and its services."
warning "Stack packages (PHP, MariaDB, Nginx, Redis) are kept unless you opt to purge at the end."
print_brake 70

yes_no CONFIRM "Are you sure you want to uninstall ClientXCMS"
[ "$CONFIRM" != true ] && error "Uninstall aborted." && exit 1

# Stop and remove the queue worker
if [ -f /etc/systemd/system/clientxcms-worker.service ]; then
  output "Removing queue worker service..."
  systemctl disable --now clientxcms-worker.service 2>/dev/null || true
  rm -f /etc/systemd/system/clientxcms-worker.service
  systemctl daemon-reload
fi

# Remove the cron job
output "Removing scheduler cron job..."
( crontab -u "$WEBUSER" -l 2>/dev/null | grep -v -F "$INSTALL_DIR/artisan schedule:run" ) | crontab -u "$WEBUSER" - 2>/dev/null || true

# Remove the Nginx vhost
output "Removing Nginx vhost..."
rm -f /etc/nginx/sites-enabled/clientxcms.conf /etc/nginx/sites-available/clientxcms.conf /etc/nginx/conf.d/clientxcms.conf
systemctl reload nginx 2>/dev/null || true

# Remove the php-fpm pool (Rocky/Alma)
rm -f /etc/php-fpm.d/clientxcms.conf
systemctl restart php-fpm 2>/dev/null || true

# Optionally drop the database
echo ""
yes_no DROP_DB "Also DROP the ClientXCMS database and user"
if [ "$DROP_DB" == true ]; then
  required_input DB_NAME "Database name to drop [clientxcms]: " "" "clientxcms"
  required_input DB_USER "Database user to drop [clientxcms]: " "" "clientxcms"
  # DB_NAME / DB_USER are assigned just above by required_input via eval.
  # shellcheck disable=SC2153
  mariadb_cli -u root -e "DROP DATABASE IF EXISTS $DB_NAME;"
  mariadb_cli -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
  mariadb_cli -u root -e "DROP USER IF EXISTS '$DB_USER'@'127.0.0.1';"
  mariadb_cli -u root -e "FLUSH PRIVILEGES;"
  success "Database and user dropped."
fi

# Remove application files
echo ""
yes_no DROP_FILES "Delete the application directory $INSTALL_DIR"
if [ "$DROP_FILES" == true ]; then
  rm -rf "$INSTALL_DIR"
  success "Application directory removed."
fi

# Optionally remove the whole stack (destructive: only on a dedicated host)
echo ""
warning "Full purge also removes PHP, MariaDB, Nginx, Redis, Node and Composer,"
warning "plus the repositories this installer added. Do this only on a host"
warning "dedicated to ClientXCMS - other sites using these would break."
yes_no PURGE_STACK "Also REMOVE all stack packages (PHP/MariaDB/Nginx/Redis/Node)"
if [ "$PURGE_STACK" == true ]; then
  output "Removing stack packages..."
  case "$OS" in
  ubuntu | debian)
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "php8.3*" mariadb-server mariadb-client \
      nginx nginx-common redis-server supervisor certbot python3-certbot-nginx nodejs 2>/dev/null || true
    apt-get autoremove --purge -y 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/ondrej-php.list /etc/apt/sources.list.d/php.list \
      /etc/apt/sources.list.d/nodesource.list /usr/share/keyrings/ondrej-php.gpg \
      /etc/apt/trusted.gpg.d/php.gpg
    ;;
  rocky | almalinux)
    dnf remove -y "php*" mariadb mariadb-server nginx redis supervisor \
      certbot python3-certbot-nginx nodejs 2>/dev/null || true
    rm -f /etc/php-fpm.d/clientxcms.conf
    ;;
  esac
  rm -f /usr/local/bin/composer
  warning "Data dirs (/var/lib/mysql, /var/lib/redis) were kept; remove them by hand if wanted."
  success "Stack packages removed."
fi

success "ClientXCMS uninstalled."
