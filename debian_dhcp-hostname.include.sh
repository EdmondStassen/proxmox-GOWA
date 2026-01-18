#!/usr/bin/env bash
#
# ------------------------------------------------------------
#  DHCP Hostname Publisher – Proxmox Helper Include
# ------------------------------------------------------------
#
#  Purpose:
#    - Prompt for an LXC hostname (optional)
#    - Set the hostname inside the container
#    - Ensure the hostname is sent via IPv4 DHCP so gateways like
#      UniFi can learn it and publish it in local DNS
#
#  Scope / Limitations:
#    - Designed for Debian/Ubuntu LXC containers
#    - Assumes bridged networking + IPv4 DHCP addressing
#    - Does NOT configure DHCPv6 hostname publishing
#    - Safe no-op on unsupported setups
#
#  Requirements:
#    - build.func must already be sourced in the calling script
#    - dhcp_hostname::prompt must run BEFORE build_container
#    - dhcp_hostname::apply must run AFTER build_container (needs CTID)
#
#  Minimal usage in a helper script:
#
#    source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
#    source /path/to/dhcp-hostname.include.sh
#
#    header_info "$APP"
#    variables
#    color
#    catch_errors
#
#    dhcp_hostname::prompt
#
#    start
#    build_container
#    dhcp_hostname::apply
#
# ------------------------------------------------------------

dhcp_hostname::prompt() {
  # Allow non-interactive usage by pre-setting var_hostname in the parent script/environment
  if [[ -n "${var_hostname:-}" ]]; then
    export var_hostname
    return 0
  fi

  echo -e "\nEnter a hostname for this container (letters/numbers/hyphens; 1–63 chars)."
  read -r -p "Hostname: " var_hostname

  # sanitize + validate
  var_hostname="$(echo "${var_hostname}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]//g; s/^-+//; s/-+$//')"

  if [[ -z "${var_hostname}" ]]; then
    msg_error "Hostname cannot be empty after sanitizing."
    exit 1
  fi
  if [[ "${#var_hostname}" -gt 63 ]]; then
    msg_error "Hostname '${var_hostname}' is too long (${#var_hostname} chars). Max is 63."
    exit 1
  fi

  export var_hostname
}

dhcp_hostname::apply() {
  # Must have CTID from build_container
  if [[ -z "${CTID:-}" ]]; then
    msg_error "CTID not set; run build_container before dhcp_hostname::apply"
    return 1
  fi

  # Must have hostname from prompt or caller
  if [[ -z "${var_hostname:-}" ]]; then
    msg_error "var_hostname not set; run dhcp_hostname::prompt before dhcp_hostname::apply"
    return 1
  fi

  msg_info "Configuring DHCP hostname publishing inside CT ${CTID}"

  # Run robust config inside CT (no quoting hazards)
  if pct exec "$CTID" -- env HN="$var_hostname" bash -s <<'EOF'
set -euo pipefail

# Validate hostname (Debian label rules)
HN="${HN,,}"
HN="$(echo "$HN" | sed -E 's/[^a-z0-9-]//g; s/^-+//; s/-+$//')"
if [ -z "$HN" ] || [ "${#HN}" -gt 63 ]; then
  echo "Skipping: invalid hostname after sanitizing." >&2
  exit 0
fi

# Debian/Ubuntu guard
if [ -f /etc/os-release ]; then
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *)
      echo "Skipping: unsupported OS ID '${ID:-unknown}' (expected debian/ubuntu)." >&2
      exit 0
      ;;
  esac
fi

# Determine primary interface (fallback to eth0)
IFACE="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
[ -n "${IFACE:-}" ] || IFACE="eth0"

# Only proceed if there is IPv4 on the interface (assumes IPv4 DHCP scope)
if ! ip -4 addr show "$IFACE" 2>/dev/null | grep -q 'inet '; then
  echo "Skipping: no IPv4 address on ${IFACE}; likely not using IPv4 DHCP." >&2
  exit 0
fi

# Set hostname persistently
if command -v hostnamectl >/dev/null 2>&1; then
  hostnamectl set-hostname "$HN" || true
fi
echo "$HN" > /etc/hostname
hostname "$HN" || true

# Ensure /etc/hosts entry exists/updated
if grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
  sed -i -E "s/^127\.0\.1\.1\s+.*/127.0.1.1\t$HN/" /etc/hosts
else
  echo -e "127.0.1.1\t$HN" >> /etc/hosts
fi

# dhclient: ensure hostname is sent (if dhclient is used)
if [ -f /etc/dhcp/dhclient.conf ]; then
  grep -qE '^\s*send\s+host-name\s*=\s*gethostname\(\);' /etc/dhcp/dhclient.conf \
    || echo 'send host-name = gethostname();' >> /etc/dhcp/dhclient.conf
fi

# systemd-networkd: ensure DHCP client sends hostname (common in minimal Debian)
if systemctl is-active systemd-networkd >/dev/null 2>&1; then
  mkdir -p /etc/systemd/network
  cat > "/etc/systemd/network/99-${IFACE}-hostname.network" <<NET
[Match]
Name=$IFACE

[Network]
DHCP=yes

[DHCPv4]
SendHostname=yes
Hostname=$HN
NET
fi

# Trigger DHCP renewal / restart networking so router sees hostname quickly
if command -v dhclient >/dev/null 2>&1; then
  dhclient -r "$IFACE" >/dev/null 2>&1 || true
  dhclient "$IFACE" >/dev/null 2>&1 || true
elif systemctl is-active systemd-networkd >/dev/null 2>&1; then
  systemctl restart systemd-networkd >/dev/null 2>&1 || true
elif systemctl is-active networking >/dev/null 2>&1; then
  systemctl restart networking >/dev/null 2>&1 || true
fi

exit 0
EOF
  then
    msg_ok "DHCP hostname publishing configured (CT ${CTID}: ${var_hostname})"
  else
    msg_error "Failed to configure DHCP hostname publishing inside CT ${CTID}"
    return 1
  fi
}
