#!/bin/bash

set -e

#############################################################################
#                                                                           #
# Project 'clientxcms-installer'                                            #
#                                                                           #
# Unofficial installation script for ClientXCMS (https://clientxcms.com).   #
# Released under the GNU GPL v3 license. NOT affiliated with the official    #
# ClientXCMS project.                                                       #
#                                                                           #
# Entrypoint. Run with:                                                      #
#   bash <(curl -sSL https://raw.githubusercontent.com/alexwrite/\          #
#   clientxcms-installer/main/install.sh)                                    #
#                                                                           #
#############################################################################

export GITHUB_SOURCE="main"
export SCRIPT_RELEASE="v1.0.0"
export GITHUB_BASE_URL="https://raw.githubusercontent.com/alexwrite/clientxcms-installer"

LOG_PATH="/var/log/clientxcms-installer.log"

# curl is required to bootstrap the library
if ! [ -x "$(command -v curl)" ]; then
  echo "* curl is required in order for this script to work."
  echo "* install it using apt (Debian/Ubuntu) or dnf (Rocky/AlmaLinux)."
  exit 1
fi

# Always fetch a fresh copy of the shared library
[ -f /tmp/lib.sh ] && rm -rf /tmp/lib.sh
curl -sSL -o /tmp/lib.sh "$GITHUB_BASE_URL"/"$GITHUB_SOURCE"/lib/lib.sh
# shellcheck source=lib/lib.sh
source /tmp/lib.sh

execute() {
  # The log may capture command output; keep it readable by root only.
  touch "$LOG_PATH" && chmod 600 "$LOG_PATH"
  echo -e "\n\n* clientxcms-installer $(date) \n\n" >>"$LOG_PATH"

  [[ "$1" == *"canary"* ]] && export GITHUB_SOURCE="main" && export SCRIPT_RELEASE="canary"
  update_lib_source
  local action="${1//_canary/}"
  # Uninstall has no interactive UI layer; run the installer module directly.
  if [ "$action" == "uninstall" ]; then
    run_installer uninstall |& tee -a "$LOG_PATH"
  else
    run_ui "$action" |& tee -a "$LOG_PATH"
  fi
}

welcome

done=false
while [ "$done" == false ]; do
  options=(
    "Install ClientXCMS (full stack: PHP, MariaDB, Nginx, assets)"
    "Uninstall ClientXCMS"
    "Install ClientXCMS using the canary script (main branch, may be unstable)"
  )

  actions=(
    "clientxcms"
    "uninstall"
    "clientxcms_canary"
  )

  output "What would you like to do?"
  for i in "${!options[@]}"; do
    output "[$i] ${options[$i]}"
  done

  echo -n "* Input 0-$((${#actions[@]} - 1)): "
  read -r action

  [ -z "$action" ] && error "Input is required" && continue

  if ! [[ "$action" =~ ^[0-9]+$ ]] || ((action < 0 || action >= ${#actions[@]})); then
    error "Invalid option"
    continue
  fi

  done=true && execute "${actions[$action]}"
done

# Drop the cached library so the next run always fetches the newest version.
rm -rf /tmp/lib.sh
