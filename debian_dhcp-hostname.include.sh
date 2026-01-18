#!/usr/bin/env bash
# DHCP Hostname Publisher - Proxmox Helper Include
#
# Usage:
#   source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
#   source <(curl -fsSL https://raw.githubusercontent.com/EdmondStassen/proxmox-scripts/main/includes/dhcp-hostname.include.sh)
#
#   dhcp_hostname::prompt   # before build_container
#   build_container
#   dhcp_hostname::apply    # after build_container


dhcp_hostname::prompt() {
  # If caller already set var_hostname, don't prompt
  if [[ -n "${var_hostname:-}" ]]; then
    export var_hostname
    return 0
  fi

  echo
  echo -e "${CREATING}DHCP Hostname Publishing${CL}"
  echo "Enter the hostname to publish via DHCP (letters, numbers, hyphens only)"
  echo "Example: web01, media-server"
  read -r -p "Hostname: " var_hostname
  echo

  # sanitize + validate
  var_hostname="$(
    echo "${var_hostname}" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/[^a-z0-9-]//g; s/^-+//; s/-+$//'
  )"

  if [[ -z "${var_hostname}" ]]; then
    msg_error "Hostname cannot be empty after sanitizing."
    exit 1
  fi

  if [[ "${#var_hostname}" -gt 63 ]]; then
    msg_error "Hostname '${var_hostname}' is too long (max 63 characters)."
    exit 1
  fi

  msg_ok "Using hostname: ${var_hostname}"
  export var_hostname
}


dhcp_hostname::apply() {
  if [[ -z "${CTID:-}" ]]; then
    msg_error "CTID not set; run build_container before dhcp_hostname::apply"
    return 1
  fi

  if [[ -z "${var_hostname:-}" ]]; then
    msg_error "var_hostname not set; run dhcp_hostname::prompt before dhcp_hostname::apply"
    return 1
  fi

  msg_info "Configuring DHCP hostname publishing inside CT ${CTID}"

  if pct exec "$CTID" -- env HN="$var_hostname" bash -s <<'DHCPEOF'
set -euo pipefail

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

# Determine primary interface
IFACE="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
[ -n "${IFACE:-}" ] || IFACE="eth0"

# Require IPv4 (DHCP)
if ! ip -4 addr show "$IFACE" 2>/dev/null | grep -q 'inet '; then
  echo "Skipping: no IPv4 address on ${IFACE}; likely not using IPv4 DHCP." >&2
  exit 0
fi

# Set hostname
if command -v hostnamectl >/dev/null 2>&1; then
  hostnamectl set-hostname "$HN" || true
fi
echo "$HN" > /etc/hostname
hostname "$HN" || true

# /etc/hosts entry
if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
  sed -i -E "s/^127\.0\.1\.1[[:space:]]+.*/127.0.1.1\t$HN/" /etc/hosts
else
  printf "127.0.1.1\t%s\n" "$HN" >> /etc/hosts
fi

# dhclient: send hostname
if [ -f /etc/dhcp/dhclient.conf ]; then
  grep -qE '^\s*send\s+host-name\s*=\s*gethostname\(\);' /etc/dhcp/dhclient.conf \
    || echo 'send host-name = gethostname();' >> /etc/dhcp/dhclient.conf
fi

# systemd-networkd: send hostname (IPv4)
if systemctl is-active systemd-networkd >/dev/null 2>&1; then
  mkdir -p /etc/systemd/network
  printf "%s\n" \
"[Match]" \
"Name=$IFACE" \
"" \
"[Network]" \
"DHCP=yes" \
"" \
"[DHCPv4]" \
"SendHostname=yes" \
"Hostname=$HN" \
> "/etc/systemd/network/99-${IFACE}-hostname.network"
fi

# Restart / renew DHCP so router learns hostname immediately
if command -v dhclient >/dev/null 2>&1; then
  dhclient -r "$IFACE" >/dev/null 2>&1 || true
  dhclient "$IFACE" >/dev/null 2>&1 || true
elif systemctl is-active systemd-networkd >/dev/null 2>&1; then
  systemctl restart systemd-networkd >/dev/null 2>&1 || true
elif systemctl is-active networking >/dev/null 2>&1; then
  systemctl restart networking >/dev/null 2>&1 || true
fi

exit 0
DHCPEOF
  then
    msg_ok "DHCP hostname '${var_hostname}' published (CT ${CTID})"
    return 0
  else
    msg_error "Failed to configure DHCP hostname publishing inside CT ${CTID}"
    return 1
  fi
}
