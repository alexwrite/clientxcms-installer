#!/bin/bash

set -e

#############################################################################
#                                                                           #
# clientxcms-installer - uninstaller module.                               #
#                                                                           #
# Removes the ClientXCMS app, its services and (optionally) its database.   #
# Leaves PHP, MariaDB, Nginx and Redis installed (they may serve other      #
# sites). NOT affiliated with the official ClientXCMS project.              #
#                                                                           #
#############################################################################

fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  # shellcheck source=lib/lib.sh
  source /tmp/lib.sh || source <(curl -sSL "$GITHUB_BASE_URL/$GITHUB_SOURCE"/lib/lib.sh)
  ! fn_exists lib_loaded && echo "* ERROR: Could not load lib script" && exit 1
fi

INSTALL_DIR="${INSTALL_DIR:-/var/www/clientxcms}"

WEBUSER="www-data"
case "$OS" in
rocky | almalinux) WEBUSER="nginx" ;;
esac

print_brake 70
warning "This will remove ClientXCMS from $INSTALL_DIR and its services."
warning "PHP, MariaDB, Nginx and Redis packages are kept."
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
  mariadb -u root -e "DROP DATABASE IF EXISTS $DB_NAME;"
  mariadb -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
  mariadb -u root -e "DROP USER IF EXISTS '$DB_USER'@'127.0.0.1';"
  mariadb -u root -e "FLUSH PRIVILEGES;"
  success "Database and user dropped."
fi

# Remove application files
echo ""
yes_no DROP_FILES "Delete the application directory $INSTALL_DIR"
if [ "$DROP_FILES" == true ]; then
  rm -rf "$INSTALL_DIR"
  success "Application directory removed."
fi

success "ClientXCMS uninstalled."
