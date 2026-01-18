#!/usr/bin/env bash
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

# --- Added: Prompt for hostname (used by build.func/build_container) ---
if [[ -z "${var_hostname:-}" ]]; then
  echo -e "\nEnter a hostname for this Debian LXC (letters/numbers/hyphens; 1-63 chars; no spaces)."
  read -r -p "Hostname: " var_hostname
fi

# sanitize: lowercase, strip invalid chars, trim leading/trailing hyphens
var_hostname="$(echo "${var_hostname}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]//g; s/^-+//; s/-+$//')"

# validate
if [[ -z "${var_hostname}" ]]; then
  msg_error "Hostname cannot be empty after sanitizing. Re-run and enter a valid hostname."
  exit 1
fi
if [[ "${#var_hostname}" -gt 63 ]]; then
  msg_error "Hostname '${var_hostname}' is too long (${#var_hostname} chars). Max is 63."
  exit 1
fi

export var_hostname
# --- End Added ---

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
  msg_ok "Updated successfully!"
  exit
}

start
build_container

# --- Added: Ensure Debian publishes hostname via DHCP (UniFi learns it) ---
# Runs on the Proxmox host, inside the newly created container.
if [[ -n "${CTID:-}" ]]; then
  msg_info "Configuring hostname/DHCP hostname publishing inside CT ${CTID}"

  if ! pct exec "$CTID" -- bash -lc "
set -e

HN='${var_hostname}'

# Determine primary interface (fallback to eth0)
IFACE=\$(ip route 2>/dev/null | awk '/^default/ {print \$5; exit}')
[ -n \"\$IFACE\" ] || IFACE=eth0

# Persistently set hostname
if command -v hostnamectl >/dev/null 2>&1; then
  hostnamectl set-hostname \"\$HN\" || true
fi
echo \"\$HN\" > /etc/hostname
hostname \"\$HN\" || true

# Ensure /etc/hosts has a sensible entry
if grep -qE '^127\\.0\\.1\\.1\\s+' /etc/hosts; then
  sed -i -E \"s/^127\\.0\\.1\\.1\\s+.*/127.0.1.1\\t\$HN/\" /etc/hosts
else
  echo -e \"127.0.1.1\\t\$HN\" >> /etc/hosts
fi

# 1) dhclient: ensure hostname is sent in DHCP
if [ -f /etc/dhcp/dhclient.conf ]; then
  if ! grep -qE '^\\s*send\\s+host-name\\s*=\\s*gethostname\\(\\);' /etc/dhcp/dhclient.conf; then
    echo 'send host-name = gethostname();' >> /etc/dhcp/dhclient.conf
  fi
fi

# 2) systemd-networkd: ensure SendHostname + Hostname are set
if systemctl is-enabled systemd-networkd >/dev/null 2>&1 || systemctl is-active systemd-networkd >/dev/null 2>&1; then
  mkdir -p /etc/systemd/network

  # If there is already a network file that matches the iface, add DHCP hostname settings via a drop-in.
  # Otherwise create a minimal network file for the primary iface.
  MATCHING_FILE=\$(grep -RIl \"^Name=\$IFACE\\b\" /etc/systemd/network 2>/dev/null | head -n1 || true)

  if [ -z \"\$MATCHING_FILE\" ]; then
    cat > /etc/systemd/network/10-\${IFACE}.network <<EOF
[Match]
Name=\$IFACE

[Network]
DHCP=yes

[DHCPv4]
SendHostname=yes
Hostname=\$HN
EOF
  else
    # Create drop-in for safety (does not rewrite existing file)
    DROPIN_DIR=\"/etc/systemd/network/\$(basename \"\$MATCHING_FILE\").d\"
    mkdir -p \"\$DROPIN_DIR\"
    cat > \"\$DROPIN_DIR/10-hostname.conf\" <<EOF
[DHCPv4]
SendHostname=yes
Hostname=\$HN
EOF
  fi
fi

# 3) ifupdown (/etc/network/interfaces): add hostname directive for dhcp stanza if present
if [ -f /etc/network/interfaces ]; then
  if grep -qE '^\\s*iface\\s+'\"\$IFACE\"'\\s+inet\\s+dhcp\\b' /etc/network/interfaces; then
    # Only insert if there isn't already a hostname line in that stanza
    if ! awk '
      BEGIN{in=0; found=0}
      \$0 ~ \"^\\s*iface\\s+'\"\$IFACE\"'\\s+inet\\s+dhcp\" {in=1}
      in==1 && \$0 ~ \"^\\s*hostname\\s+\" {found=1}
      in==1 && \$0 ~ \"^\\s*iface\\s+\" && \$0 !~ \"^\\s*iface\\s+'\"\$IFACE\"'\\s+inet\\s+dhcp\" {in=0}
      END{exit(found?0:1)}
    ' /etc/network/interfaces; then
      # insert hostname line right after the iface stanza line
      sed -i -E \"/^\\s*iface\\s+\"\"\$IFACE\"\"\\s+inet\\s+dhcp\\b/a\\    hostname \$HN\" /etc/network/interfaces
    fi
  fi
fi

# Trigger DHCP renewal / service restart to advertise hostname immediately
if command -v dhclient >/dev/null 2>&1; then
  dhclient -r \"\$IFACE\" >/dev/null 2>&1 || true
  dhclient \"\$IFACE\" >/dev/null 2>&1 || true
elif systemctl is-active systemd-networkd >/dev/null 2>&1; then
  systemctl restart systemd-networkd >/dev/null 2>&1 || true
elif systemctl is-active networking >/dev/null 2>&1; then
  systemctl restart networking >/dev/null 2>&1 || true
fi

exit 0
"; then
    msg_ok "Hostname/DHCP configuration applied"
  else
    msg_error "Failed to configure hostname/DHCP hostname publishing inside CT ${CTID}"
  fi
fi
# --- End Added ---

description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
