#!/usr/bin/env bash
# Debian LXC Helper (lazy-loaded Proxmox Notes)

# ------------------------------------------------------------------
# Debian LXC
# ------------------------------------------------------------------

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

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /var ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  msg_info "Updating $APP LXC"
  $STD apt update
  $STD apt -y upgrade
  msg_ok "Updated $APP LXC"
  exit
}

start

# ------------------------------------------------------------------
# Helper: safe include (download -> source)
# ------------------------------------------------------------------
include::source_url() {
  local url="$1"
  local tmp
  tmp="$(mktemp)" || {
    msg_error "mktemp failed"
    exit 1
  }

  if ! curl -fsSL "$url" -o "$tmp"; then
    msg_error "Include kon niet worden gedownload (URL bestaat niet of geen toegang): $url"
    rm -f "$tmp"
    exit 1
  fi

  # Optional sanity check: file should look like shell (not HTML)
  if head -n 1 "$tmp" | grep -qiE '<!doctype html|<html'; then
    msg_error "Include lijkt HTML (mogelijk 404/redirect pagina), niet bash: $url"
    rm -f "$tmp"
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
}

# ------------------------------------------------------------------
# DNS hostname publishing (FULLY SELF-CONTAINED BLOCK)
# ------------------------------------------------------------------
SOURCEURL="https://raw.githubusercontent.com/EdmondStassen/proxmox-scripts/refs/heads/main/proxmox_notes.include.sh"
include::source_url "$SOURCEURL"
unset SOURCEURL

dhcp_hostname::prompt            # Prompt for hostname
build_container                  # Create the container (CTID assigned here)

# ------------------------------------------------------------------
# Proxmox Notes (lazy include on first use)
# ------------------------------------------------------------------
SOURCEURL="https://raw.githubusercontent.com/EdmondStassen/proxmox-scripts/main/includes/notes.include.sh"
include::source_url "$SOURCEURL"
unset SOURCEURL

notes::init "Provisioning notes for ${APP} (CTID ${CTID})" # Clean notes once

# NOTES
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
notes::append "$NOTES_BLOCK"
unset NOTES_BLOCK

# Configure hostname + DHCP publishing inside the container
dhcp_hostname::apply

# NOTES
NOTES_BLOCK="$(cat <<EOF
Networking:
- Hostname: ${var_hostname:-unknown}
- CTID: ${CTID}
EOF
)"
notes::append "$NOTES_BLOCK"
unset NOTES_BLOCK

# ------------------------------------------------------------------

description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
