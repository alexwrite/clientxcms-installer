#!/bin/bash

set -e

#############################################################################
#                                                                           #
# clientxcms-installer - main installer module.                            #
#                                                                           #
# Installs the full stack and ClientXCMS, then stops at the web installer   #
# (license activation is an online step that cannot run headless).          #
# NOT affiliated with the official ClientXCMS project.                      #
#                                                                           #
#############################################################################

# Load the shared library if not already sourced. When this module is run
# directly (not via install.sh), GITHUB_BASE_URL/GITHUB_SOURCE are unset, so we
# default them here before building the fallback download URL.
fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  : "${GITHUB_BASE_URL:=https://raw.githubusercontent.com/alexwrite/clientxcms-installer}"
  : "${GITHUB_SOURCE:=main}"
  # shellcheck source=lib/lib.sh
  source /tmp/lib.sh 2>/dev/null || source <(curl -sSL "$GITHUB_BASE_URL/$GITHUB_SOURCE/lib/lib.sh")
  ! fn_exists lib_loaded && echo "* ERROR: Could not load lib script" && exit 1
fi

# composer, git and npm need HOME; it can be unset in headless contexts
# (systemd unit, cron, CI). Default it so unattended installs work.
export HOME="${HOME:-/root}"

# ------------------ Variables ----------------- #

FQDN="${FQDN:-localhost}"
APP_LOCALE="${APP_LOCALE:-fr}"
timezone="${timezone:-Europe/Paris}"

MYSQL_DB="${MYSQL_DB:-clientxcms}"
MYSQL_USER="${MYSQL_USER:-clientxcms}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-$(gen_passwd 64)}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"

USE_REDIS="${USE_REDIS:-true}"
CONFIGURE_WORKER="${CONFIGURE_WORKER:-true}"
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-false}"
CONFIGURE_LETSENCRYPT="${CONFIGURE_LETSENCRYPT:-false}"
ASSUME_SSL="${ASSUME_SSL:-false}"
email="${email:-}"

# Web server system user and php-fpm socket path differ per distro
WEBUSER=""
PHP_SOCKET=""
case "$OS" in
ubuntu | debian)
  WEBUSER="www-data"
  PHP_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
  ;;
rocky | almalinux)
  WEBUSER="nginx"
  PHP_SOCKET="/run/php-fpm/clientxcms.sock"
  ;;
esac

# --------- .env helper --------- #

# set_env KEY VALUE - update KEY in $INSTALL_DIR/.env, or append it if missing.
# Value is wrapped in double quotes; existing double quotes are escaped.
set_env() {
  local key="$1"
  local value="$2"
  local file="$INSTALL_DIR/.env"
  local escaped
  escaped=$(printf '%s' "$value" | sed -e 's/[\/&]/\\&/g')
  if grep -qE "^${key}=" "$file"; then
    sed -i "s/^${key}=.*/${key}=\"${escaped}\"/" "$file"
  else
    echo "${key}=\"${value}\"" >>"$file"
  fi
}

# --------- Dependency installation --------- #

ubuntu_php_repo() {
  install_packages "software-properties-common apt-transport-https ca-certificates gnupg lsb-release wget"
  LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
}

debian_php_repo() {
  install_packages "dirmngr ca-certificates apt-transport-https lsb-release wget gnupg"
  curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/trusted.gpg.d/php.gpg
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" >/etc/apt/sources.list.d/php.list
}

setup_node_repo() {
  output "Adding NodeSource repository for Node ${NODE_VERSION}..."
  case "$OS" in
  ubuntu | debian)
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
    ;;
  rocky | almalinux)
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_VERSION}.x" | bash -
    ;;
  esac
}

dep_install() {
  output "Installing dependencies for $OS $OS_VER. This can take a while..."
  update_repos

  local php_pkgs

  case "$OS" in
  ubuntu | debian)
    [ "$OS" == "ubuntu" ] && ubuntu_php_repo
    [ "$OS" == "debian" ] && debian_php_repo
    setup_node_repo
    update_repos

    php_pkgs="php${PHP_VERSION} php${PHP_VERSION}-{cli,fpm,common,bcmath,curl,gd,intl,mbstring,mysql,xml,zip,opcache}"
    [ "$USE_REDIS" == true ] && php_pkgs="$php_pkgs php${PHP_VERSION}-redis"

    install_packages "$php_pkgs \
      mariadb-server mariadb-client \
      nginx \
      nodejs \
      git unzip zip tar cron supervisor"
    [ "$USE_REDIS" == true ] && install_packages "redis-server"
    [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "certbot python3-certbot-nginx"
    ;;

  rocky | almalinux)
    install_packages "epel-release"
    install_packages "https://rpms.remirepo.net/enterprise/remi-release-${OS_VER_MAJOR}.rpm"
    dnf module reset -y php
    dnf module enable -y "php:remi-${PHP_VERSION}"
    setup_node_repo

    php_pkgs="php php-{cli,fpm,common,bcmath,curl,gd,intl,mbstring,mysqlnd,xml,zip,opcache}"
    [ "$USE_REDIS" == true ] && php_pkgs="$php_pkgs php-redis"

    install_packages "$php_pkgs \
      mariadb mariadb-server \
      nginx \
      nodejs \
      git unzip zip tar cronie supervisor policycoreutils-python-utils"
    [ "$USE_REDIS" == true ] && install_packages "redis"
    [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "certbot python3-certbot-nginx"

    # SELinux: let nginx talk to php-fpm/redis/mariadb and run the app
    selinux_allow
    php_fpm_pool_rocky
    ;;
  esac

  enable_services
  harden_mariadb
  success "Dependencies installed."
}

# Non-interactive equivalent of mysql_secure_installation: drop anonymous users
# and the test database. Root stays on unix_socket auth so `mariadb -u root` works.
harden_mariadb() {
  output "Hardening MariaDB (anonymous users, test database)..."
  mariadb -u root -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
  mariadb -u root -e "DELETE FROM mysql.global_priv WHERE User='';" 2>/dev/null ||
    mariadb -u root -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
  mariadb -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || true
}

enable_services() {
  systemctl enable --now mariadb
  systemctl enable nginx
  systemctl enable --now "php${PHP_VERSION}-fpm" 2>/dev/null || systemctl enable --now php-fpm
  if [ "$USE_REDIS" == true ]; then
    systemctl enable --now redis-server 2>/dev/null || systemctl enable --now redis
  fi
}

selinux_allow() {
  if command -v setsebool >/dev/null 2>&1; then
    setsebool -P httpd_can_network_connect 1 || true
    setsebool -P httpd_execmem 1 || true
    setsebool -P httpd_unified 1 || true
  fi
}

php_fpm_pool_rocky() {
  output "Configuring php-fpm pool (Unix socket)..."
  curl -fsSL -o /etc/php-fpm.d/clientxcms.conf "$GITHUB_URL"/configs/php-fpm-clientxcms.conf
  mkdir -p /run/php-fpm
  # php-fpm only loads *.conf, so renaming the stock pool disables its :9000 listener.
  if [ -f /etc/php-fpm.d/www.conf ]; then
    mv /etc/php-fpm.d/www.conf /etc/php-fpm.d/www.conf.disabled
  fi
  systemctl restart php-fpm
}

# --------- Composer --------- #

install_composer() {
  if command -v composer >/dev/null 2>&1; then
    output "Composer already installed."
    return
  fi
  output "Installing Composer..."
  # Verify the installer against the upstream-published SHA-384 before running it.
  local expected actual
  expected=$(curl -fsSL https://composer.github.io/installer.sig)
  curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
  actual=$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")
  if [ "$expected" != "$actual" ]; then
    rm -f /tmp/composer-setup.php
    error "Composer installer checksum mismatch. Aborting for safety."
    exit 1
  fi
  php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
  rm -f /tmp/composer-setup.php
  success "Composer installed."
}

# --------- Download ClientXCMS --------- #

download_clientxcms() {
  output "Downloading ClientXCMS source into $INSTALL_DIR..."
  if [ -d "$INSTALL_DIR/.git" ]; then
    warning "$INSTALL_DIR already contains a git checkout; pulling latest."
    git -C "$INSTALL_DIR" pull --ff-only || true
  else
    mkdir -p "$INSTALL_DIR"
    if [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
      error "$INSTALL_DIR is not empty. Aborting to avoid overwriting data."
      exit 1
    fi
    git clone --branch "$CLIENTXCMS_BRANCH" --depth 1 "$CLIENTXCMS_REPO" "$INSTALL_DIR"
  fi
  success "ClientXCMS source ready."
}

install_composer_deps() {
  output "Installing Composer dependencies..."
  cd "$INSTALL_DIR"
  # Retry with backoff: GitHub dist downloads (codeload) flake intermittently
  # with HTTP 400/429, sometimes in bursts of several seconds.
  local attempt
  for attempt in 1 2 3 4 5; do
    if COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction; then
      success "Composer dependencies installed."
      return
    fi
    warning "composer install failed (attempt ${attempt}/5), retrying in $((attempt * 5))s..."
    sleep "$((attempt * 5))"
  done
  error "composer install failed after 5 attempts."
  exit 1
}

# --------- Environment --------- #

configure_environment() {
  output "Configuring environment (.env)..."
  cd "$INSTALL_DIR"
  [ -f .env ] || cp .env.example .env

  local app_url="http://$FQDN"
  { [ "$CONFIGURE_LETSENCRYPT" == true ] || [ "$ASSUME_SSL" == true ]; } && app_url="https://$FQDN"

  set_env APP_ENV "production"
  set_env APP_DEBUG "false"
  set_env APP_URL "$app_url"
  set_env APP_LOCALE "$APP_LOCALE"
  set_env APP_TIMEZONE "$timezone"

  set_env DB_CONNECTION "mysql"
  set_env DB_HOST "$DB_HOST"
  set_env DB_PORT "$DB_PORT"
  set_env DB_DATABASE "$MYSQL_DB"
  set_env DB_USERNAME "$MYSQL_USER"
  set_env DB_PASSWORD "$MYSQL_PASSWORD"

  if [ "$USE_REDIS" == true ]; then
    set_env CACHE_DRIVER "redis"
    set_env SESSION_DRIVER "redis"
    set_env QUEUE_CONNECTION "redis"
    set_env REDIS_HOST "127.0.0.1"
    set_env REDIS_PORT "6379"
  else
    set_env CACHE_DRIVER "file"
    set_env SESSION_DRIVER "file"
    set_env QUEUE_CONNECTION "database"
  fi

  # Generate the Laravel application key
  COMPOSER_ALLOW_SUPERUSER=1 php artisan key:generate --force
  success "Environment configured."
}

# --------- Database --------- #

setup_database() {
  # Grant host MUST match .env DB_HOST (127.0.0.1): a 'user'@'localhost' account
  # only authenticates Unix-socket logins, while Laravel/PDO connects over TCP.
  create_db_user "$MYSQL_USER" "$MYSQL_PASSWORD" "127.0.0.1"
  create_db "$MYSQL_DB" "$MYSQL_USER" "127.0.0.1"

  output "Running migrations and seeders..."
  cd "$INSTALL_DIR"
  php artisan migrate --force --seed
  php artisan storage:link
  success "Database ready."
}

# --------- Assets (Node build) --------- #

build_assets() {
  output "Building front-end assets (npm install + build)..."
  cd "$INSTALL_DIR"
  # Retry with backoff on transient registry/network failures.
  local attempt
  for attempt in 1 2 3 4 5; do
    npm install --no-audit --no-fund && break
    [ "$attempt" = 5 ] && error "npm install failed after 5 attempts." && exit 1
    warning "npm install failed (attempt ${attempt}/5), retrying in $((attempt * 5))s..."
    sleep "$((attempt * 5))"
  done
  npm run build
  success "Assets built."
}

# --------- Permissions --------- #

set_permissions() {
  output "Setting file permissions for $WEBUSER..."
  chown -R "$WEBUSER":"$WEBUSER" "$INSTALL_DIR"
  chmod -R 775 "$INSTALL_DIR/storage" "$INSTALL_DIR/bootstrap/cache"
  # .env holds the DB password and APP_KEY: readable by the web user only.
  chmod 640 "$INSTALL_DIR/.env"
  success "Permissions set."
}

# --------- Cron --------- #

insert_cronjob() {
  output "Installing the scheduler cron job..."
  local cron_line="* * * * * php $INSTALL_DIR/artisan schedule:run >> /dev/null 2>&1"
  ( crontab -u "$WEBUSER" -l 2>/dev/null | grep -v -F "$INSTALL_DIR/artisan schedule:run"; echo "$cron_line" ) | crontab -u "$WEBUSER" -
  success "Cron job installed."
}

# --------- Queue worker (systemd) --------- #

install_worker() {
  [ "$CONFIGURE_WORKER" != true ] && return
  output "Installing the queue worker systemd service..."
  curl -fsSL -o /etc/systemd/system/clientxcms-worker.service "$GITHUB_URL"/configs/clientxcms-worker.service
  sed -i -e "s@<user>@${WEBUSER}@g" /etc/systemd/system/clientxcms-worker.service
  sed -i -e "s@<install_dir>@${INSTALL_DIR}@g" /etc/systemd/system/clientxcms-worker.service
  local php_bin
  php_bin=$(command -v php)
  sed -i -e "s@<php_bin>@${php_bin}@g" /etc/systemd/system/clientxcms-worker.service
  systemctl daemon-reload
  systemctl enable --now clientxcms-worker.service
  success "Queue worker installed."
}

# --------- Nginx --------- #

configure_nginx() {
  output "Configuring Nginx..."
  local dl_file conf_avail conf_enabled

  # Let's Encrypt starts from the plain HTTP vhost; certbot --nginx injects TLS.
  # Only a pre-existing certificate (ASSUME_SSL) uses the SSL template directly.
  if [ "$ASSUME_SSL" == true ]; then
    dl_file="nginx_ssl.conf"
  else
    dl_file="nginx.conf"
  fi

  case "$OS" in
  ubuntu | debian)
    conf_avail="/etc/nginx/sites-available"
    conf_enabled="/etc/nginx/sites-enabled"
    rm -f "$conf_enabled"/default
    ;;
  rocky | almalinux)
    conf_avail="/etc/nginx/conf.d"
    conf_enabled="$conf_avail"
    ;;
  esac

  curl -fsSL -o "$conf_avail"/clientxcms.conf "$GITHUB_URL"/configs/"$dl_file"
  sed -i -e "s@<domain>@${FQDN}@g" "$conf_avail"/clientxcms.conf
  sed -i -e "s@<php_socket>@${PHP_SOCKET}@g" "$conf_avail"/clientxcms.conf
  sed -i -e "s@<install_dir>@${INSTALL_DIR}@g" "$conf_avail"/clientxcms.conf

  case "$OS" in
  ubuntu | debian)
    ln -sf "$conf_avail"/clientxcms.conf "$conf_enabled"/clientxcms.conf
    ;;
  esac

  # Validate the configuration before (re)starting
  nginx -t
  # For the SSL config we wait until certbot has issued the certificate
  if [ "$CONFIGURE_LETSENCRYPT" == false ]; then
    systemctl restart nginx
  fi
  success "Nginx configured."
}

# --------- Firewall --------- #

configure_firewall() {
  [ "$CONFIGURE_FIREWALL" != true ] && return
  install_firewall
  output "Opening ports 22, 80, 443..."
  firewall_allow_ports "22 80 443"
  success "Firewall configured."
}

# --------- Let's Encrypt --------- #

configure_letsencrypt() {
  [ "$CONFIGURE_LETSENCRYPT" != true ] && return
  output "Requesting Let's Encrypt certificate for $FQDN..."

  systemctl start nginx
  local failed=false
  certbot --nginx --redirect --no-eff-email --agree-tos --email "$email" -d "$FQDN" || failed=true

  if [ ! -d "/etc/letsencrypt/live/$FQDN/" ] || [ "$failed" == true ]; then
    warning "Failed to obtain a Let's Encrypt certificate. The site stays on HTTP."
    warning "Once DNS/ports are fixed, re-run: certbot --nginx -d $FQDN"
  else
    systemctl restart nginx
    success "Let's Encrypt certificate installed."
  fi
}

# --------- Final message --------- #

final_message() {
  local proto="http"
  [ "$CONFIGURE_LETSENCRYPT" == true ] && [ -d "/etc/letsencrypt/live/$FQDN/" ] && proto="https"

  print_brake 70
  success "ClientXCMS stack installed!"
  output "Next step: finish the installation in your browser."
  output ""
  output "  1. Open: ${proto}://${FQDN}"
  output "  2. Follow the web installer (settings -> license -> admin account)."
  output "  3. Enter your OAuth Client ID/Secret from:"
  output "     https://clientxcms.com/client/services/"
  output ""
  output "Useful info:"
  output "  Install path : $INSTALL_DIR"
  output "  Database     : $MYSQL_DB (user: $MYSQL_USER)"
  output "  Web user     : $WEBUSER"
  [ "$CONFIGURE_WORKER" == true ] && output "  Queue worker : systemctl status clientxcms-worker"
  output ""
  # Print the password to the real terminal only, never to the teed log file.
  if [ -e /dev/tty ]; then
    printf '*   DB password  : %s\n' "$MYSQL_PASSWORD" >/dev/tty
  fi
  warning "The database password is also stored in $INSTALL_DIR/.env (chmod 640)."
  print_brake 70
}

# --------------- Main --------------- #

perform_install() {
  output "Starting ClientXCMS installation. This might take a while!"
  dep_install
  configure_firewall
  install_composer
  download_clientxcms
  install_composer_deps
  configure_environment
  setup_database
  build_assets
  set_permissions
  install_worker
  insert_cronjob
  configure_nginx
  configure_letsencrypt
  final_message
  return 0
}

perform_install
