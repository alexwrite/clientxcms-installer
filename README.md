# clientxcms-installer

Unofficial one-command installer for [ClientXCMS](https://clientxcms.com), the
CMS/billing platform for hosting companies. It turns a fresh Linux server into a
ready-to-use ClientXCMS stack (PHP 8.3, MariaDB, Nginx, Redis, Node 20) in a few
minutes.

> This is a community script. It is **not** affiliated with the official
> ClientXCMS project. Use at your own risk and always review a script before
> piping it into a root shell.

## Quick start

```bash
bash <(curl -sSL https://raw.githubusercontent.com/alexwrite/clientxcms-installer/main/install.sh)
```

The script must run as **root** (or via `sudo`). It will ask a handful of
questions, print a summary, and then install everything.

## What it does

| Step | Detail |
|------|--------|
| Dependencies | PHP 8.3 + extensions (Sury on Debian, ondrej PPA on Ubuntu, Remi on Rocky/Alma), MariaDB, Nginx, Redis, Node 20 (NodeSource), Composer, Git, Supervisor |
| Source | `git clone` of the official ClientXCMS repository into `/var/www/clientxcms` |
| App build | `composer install --no-dev`, `npm install && npm run build` |
| Environment | Writes `.env`, generates `APP_KEY`, wires DB + (optional) Redis drivers |
| Database | Creates DB + user, runs `php artisan migrate --force --seed`, `storage:link` |
| Services | Nginx vhost, scheduler cron (`schedule:run`), optional systemd queue worker |
| Security | Optional UFW/firewalld rules, optional Let's Encrypt certificate via certbot |

## Supported systems

| Distribution | Versions |
|--------------|----------|
| Ubuntu | 20.04, 22.04, 24.04 |
| Debian | 11, 12, 13 |
| Rocky Linux / AlmaLinux | 8, 9 |

Architectures: `x86_64` and `arm64`. Minimum 2 GB RAM, 25 GB disk
(per the [official requirements](https://docs.clientxcms.com/docs/installation/requis)).

## After the script: finish in the browser

ClientXCMS finalises its installation through a **web wizard** that activates
your license online. The script cannot do this headless, so once it finishes:

1. Open `http(s)://your-domain`.
2. Follow the wizard: settings -> license -> admin account.
3. Provide your **OAuth Client ID / Secret** from
   [clientxcms.com/client/services](https://clientxcms.com/client/services/).

A valid **Community** (or higher) license is required.

## Repository layout

```
install.sh                  Entrypoint: menu, downloads modules, dispatches
lib/lib.sh                  Shared helpers (OS detect, input, DB, firewall)
ui/clientxcms.sh            Interactive questions, then runs the installer
installers/clientxcms.sh    Full installation logic
installers/uninstall.sh     Removal logic
configs/                    Nginx vhosts, systemd worker, php-fpm pool
.github/workflows/          ShellCheck CI
Vagrantfile                 Multi-distro test boxes
```

The entrypoint downloads each module from `GITHUB_BASE_URL` at runtime, so a
fork only needs to host these files and set `GITHUB_BASE_URL` accordingly.

## Configuration via environment

Override defaults by exporting variables before running (handy for unattended
installs or forks):

| Variable | Default | Purpose |
|----------|---------|---------|
| `GITHUB_BASE_URL` | `.../alexwrite/clientxcms-installer` | Raw base URL for the modules |
| `CLIENTXCMS_REPO` | official GitHub repo | ClientXCMS source repository |
| `CLIENTXCMS_BRANCH` | `master` | Branch to clone |
| `INSTALL_DIR` | `/var/www/clientxcms` | Install location |
| `PHP_VERSION` | `8.3` | PHP version |
| `NODE_VERSION` | `20` | Node.js major version |

## Uninstall

Run the entrypoint and pick the uninstall option, or directly:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/alexwrite/clientxcms-installer/main/installers/uninstall.sh)
```

It removes the app directory, vhost, cron and worker. It keeps PHP/MariaDB/Nginx
(they may serve other sites) and asks before dropping the database.

## Testing

```bash
shellcheck -e SC1090 -e SC1091 install.sh lib/*.sh ui/*.sh installers/*.sh
vagrant up debian12 && vagrant ssh debian12 -c 'sudo bash /vagrant/install.sh'
```

## License

GPL-3.0. See [LICENSE](LICENSE). ClientXCMS itself is distributed under its own
[proprietary EULA](https://clientxcms.com/eula); this installer only automates
its deployment.
