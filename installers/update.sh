#!/bin/bash

set -e

#############################################################################
#                                                                           #
# clientxcms-installer - update module.                                    #
#                                                                           #
# Updates a Git-based ClientXCMS install to the latest version, following   #
# the official upgrade procedure: maintenance mode, DB backup, git pull,    #
# composer, migrations, cache clear, asset rebuild, post-update hooks.      #
# NOT affiliated with the official ClientXCMS project.                      #
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

# composer/git/npm need HOME in headless contexts.
export HOME="${HOME:-/root}"

INSTALL_DIR="${INSTALL_DIR:-/var/www/clientxcms}"
CLIENTXCMS_BRANCH="${CLIENTXCMS_BRANCH:-master}"
SKIP_BACKUP="${SKIP_BACKUP:-false}"

WEBUSER="www-data"
case "$OS" in
rocky | almalinux) WEBUSER="nginx" ;;
esac

# ----------------- Preflight ----------------- #

if [ ! -d "$INSTALL_DIR/.git" ]; then
  error "No Git checkout found at $INSTALL_DIR. This updater only handles Git installs."
  exit 1
fi
if ! command -v php >/dev/null 2>&1; then
  error "php not found - is ClientXCMS installed on this server?"
  exit 1
fi

cd "$INSTALL_DIR"

current_rev=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
output "Updating ClientXCMS in $INSTALL_DIR (current: $current_rev, branch: $CLIENTXCMS_BRANCH)."

# ----------------- Maintenance --------------- #

output "Enabling maintenance mode..."
php artisan down || true
# Always try to lift maintenance, even if a later step fails.
trap 'php artisan up >/dev/null 2>&1 || true' EXIT

# ----------------- DB backup ----------------- #

backup_database() {
  [ "$SKIP_BACKUP" == true ] && { warning "Skipping database backup (SKIP_BACKUP=true)."; return; }
  local db dir file ts
  db=$(grep -E '^DB_DATABASE=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
  [ -z "$db" ] && { warning "Could not read DB_DATABASE from .env; skipping backup."; return; }
  dir="$INSTALL_DIR/storage/backups"
  mkdir -p "$dir"
  ts=$(date +%Y%m%d-%H%M%S)
  file="$dir/db-${db}-${ts}.sql.gz"
  output "Backing up database '$db'..."
  if mariadb_dump -u root --single-transaction --quick "$db" 2>/dev/null | gzip >"$file"; then
    success "Database backed up to $file"
  else
    rm -f "$file"
    warning "Database backup failed. Re-run with SKIP_BACKUP=true to proceed without one,"
    warning "or back up manually before updating. Aborting to stay safe."
    exit 1
  fi
}
backup_database

# ----------------- Pull code ----------------- #

output "Fetching the latest code..."
git fetch --all --prune
git checkout "$CLIENTXCMS_BRANCH"
git pull --ff-only origin "$CLIENTXCMS_BRANCH"

# ----------------- Dependencies -------------- #

output "Installing Composer dependencies..."
attempt=1
while true; do
  if COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction; then
    break
  fi
  [ "$attempt" -ge 5 ] && error "composer install failed after 5 attempts." && exit 1
  warning "composer install failed (attempt ${attempt}/5), retrying in $((attempt * 5))s..."
  sleep "$((attempt * 5))"
  attempt=$((attempt + 1))
done

# ----------------- Migrations ---------------- #

output "Running migrations and extension updates..."
php artisan migrate --force --seed
php artisan clientxcms:db-extension --all || true

# ----------------- Caches -------------------- #

output "Clearing caches..."
php artisan cache:clear || true
php artisan view:clear || true
php artisan route:clear || true
php artisan config:clear || true

# ----------------- Assets -------------------- #

output "Rebuilding front-end assets..."
attempt=1
while true; do
  npm install --no-audit --no-fund && break
  [ "$attempt" -ge 5 ] && error "npm install failed after 5 attempts." && exit 1
  warning "npm install failed (attempt ${attempt}/5), retrying in $((attempt * 5))s..."
  sleep "$((attempt * 5))"
  attempt=$((attempt + 1))
done
npm run build

# ----------------- Permissions --------------- #

output "Fixing permissions for $WEBUSER..."
chown -R "$WEBUSER":"$WEBUSER" "$INSTALL_DIR"
chmod -R 775 "$INSTALL_DIR/storage" "$INSTALL_DIR/bootstrap/cache"

# ----------------- Finish -------------------- #

php artisan up || true
php artisan clientxcms:on-update || true
trap - EXIT

new_rev=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
print_brake 70
success "ClientXCMS updated ($current_rev -> $new_rev)."
output "Maintenance mode is off; the site is live again."
print_brake 70
