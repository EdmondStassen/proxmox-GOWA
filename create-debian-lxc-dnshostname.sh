#!/usr/bin/env bash
# Debian LXC Helper (lazy-loaded Proxmox Notes)

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 tteck
# Author: tteck (tteckster)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://www.debian.org/

APP="Debian"
var_tags="${var_tags:-os}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-512}"
var_disk="${var_disk:-2}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /var ]]; then msg_error "No ${APP} Installation Found!"; exit; fi
  msg_info "Updating $APP LXC"
  $STD apt update
  $STD apt -y upgrade
  msg_ok "Updated $APP LXC"
  exit
}

start

# DNS hostname publishing
SOURCEURL="https://raw.githubusercontent.com/EdmondStassen/proxmox-scripts/refs/heads/main/proxmox_notes.include.sh"
source <(curl -fsSL "$SOURCEURL")
unset SOURCEURL

dhcp_hostname::prompt
build_container

# Proxmox Notes
SOURCEURL="https://raw.githubusercontent.com/EdmondStassen/proxmox-scripts/main/includes/notes.include.sh"
source <(curl -fsSL "$SOURCEURL")
unset SOURCEURL

notes::init "Provisioning notes for ${APP} (CTID ${CTID})"

NOTES_BLOCK="$(cat <<EOF
System:
- OS: ${var_os}
- Version: ${var_version}
- Unprivileged: ${var_unprivileged}

Resources:
- CPU: ${var_cpu}
- RAM: ${var_ram} MB
- Disk: ${var_disk} GB
EOF
)"
notes::append "$NOTES_BLOCK"; unset NOTES_BLOCK

dhcp_hostname::apply

NOTES_BLOCK="$(cat <<EOF
Networking:
- Hostname: ${var_hostname:-unknown}
- CTID: ${CTID}
EOF
)"
notes::append "$NOTES_BLOCK"; unset NOTES_BLOCK

description
msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
