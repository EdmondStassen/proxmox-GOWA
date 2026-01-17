#!/usr/bin/env bash
# ProxmoxVE LXC helper (build.func framework)
# Deploys 2x GOWA/WhatsMeow instances via Docker image + Compose
# - No git clone (image-based)
# - Separate volumes per instance (separate WhatsApp sessions)
# - Shared Basic Auth + shared webhook config
# - Adds LAN DNS name via mDNS/Avahi: e.g. gowa.local -> LXC IP
#
# Fix: IP detection/Notes were polluted by build.func colored output.
# We now read the IP using pct exec and ONLY accept a clean IPv4 via regex,
# plus we strip any ANSI escape codes from any captured output as a safety net.

set -euo pipefail

: "${SSH_CLIENT:=}"
: "${SSH_TTY:=}"
: "${SSH_CONNECTION:=}"

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="GOWA"
var_tags="${var_tags:-docker;gowa;whatsapp;whatsmeow;mdns}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"
var_hostname="${var_hostname:-gowa}"

# ---------------- Settings ----------------
HOST_PORT="${HOST_PORT:-3000}"
HOST_PORT_2="${HOST_PORT_2:-3001}"

# Shared Basic Auth
GOWA_USER="${GOWA_USER:-admin}"
RAND_LEN="${RAND_LEN:-24}"

# Webhook (optional; shared)
WEBHOOK_URL="${WEBHOOK_URL:-http://whatsapp-bot.local:8080/webhook}"
WEBHOOK_EVENTS="${WEBHOOK_EVENTS:-message,message.ack}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}" # if empty -> generated

# mDNS/DNS on LAN (Avahi .local)
MDNS_BASE="${MDNS_BASE:-${var_hostname}}"

header_info "$APP"
variables
var_install="docker-install"

color
catch_errors

# ---------------- helpers ----------------
rand_pw() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${RAND_LEN}"
  else
    dd if=/dev/urandom bs=64 count=2 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "${RAND_LEN}"
  fi
}

# Strip ANSI escape codes (defensive)
strip_ansi() {
  # Removes ESC[...m and similar sequences
  sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g'
}

# Extract first IPv4 from input (defensive)
first_ipv4() {
  grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1
}

msg_info "Generating credentials"
ROOT_PASS="$(rand_pw)"
GOWA_PASS="$(rand_pw)"
[[ -z "$WEBHOOK_SECRET" ]] && WEBHOOK_SECRET="$(rand_pw)"
msg_ok "Credentials generated"

# ---------------- create CT ----------------
start
build_container
description

# ---------------- Docker + Avahi (mDNS) ----------------
msg_info "Installing Docker + Avahi (mDNS .local)"
pct exec "$CTID" -- bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl

# Docker
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
apt-get install -y docker-compose-plugin
systemctl enable docker --now

# Avahi (mDNS/Bonjour)
apt-get install -y avahi-daemon
systemctl enable avahi-daemon --now
'
msg_ok "Docker + Avahi ready"


# ---------------- Avahi: force IPv4 only + disable AAAA ----------------
msg_info "Installing and configuring Avahi (IPv4 only, no AAAA)"

pct exec "$CTID" -- bash -lc "
  set -e

  apt-get update
  apt-get install -y --reinstall avahi-daemon avahi-utils

  mkdir -p /etc/avahi

  cat >/etc/avahi/avahi-daemon.conf <<'EOF'
[server]
use-ipv4=yes
use-ipv6=no
allow-interfaces=eth0
ratelimit-interval-usec=1000000
ratelimit-burst=1000

[wide-area]
enable-wide-area=yes

[publish]
publish-aaaa-on-ipv4=no
publish-a-on-ipv6=no
publish-hinfo=no
publish-workstation=no

EOF

  systemctl restart avahi-daemon
  systemctl enable avahi-daemon
"

msg_ok "Avahi configured for IPv4-only mDNS on eth0"


# ---------------- set CT hostname (base .local name) ----------------
msg_info "Configuring base mDNS hostname (${MDNS_BASE}.local)"
pct exec "$CTID" -- bash -lc "
set -e
echo '${MDNS_BASE}' > /etc/hostname
hostnamectl set-hostname '${MDNS_BASE}' || true
if ! grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
  echo '127.0.1.1 ${MDNS_BASE}' >> /etc/hosts
else
  sed -i -E 's/^127\.0\.1\.1\s+.*/127.0.1.1 ${MDNS_BASE}/' /etc/hosts
fi
systemctl restart avahi-daemon
"
msg_ok "Base mDNS hostname configured"

# ---------------- root password ----------------
msg_info "Setting container root password"
pct exec "$CTID" -- bash -lc "echo root:${ROOT_PASS} | chpasswd"
msg_ok "Root password set"

# ---------------- Compose projects (2 instances) ----------------
msg_info "Creating Docker Compose projects (instance1 + instance2)"
pct exec "$CTID" -- bash -lc '
set -e

mkdir -p /opt/gowa/instance1 /opt/gowa/instance2

cat > /opt/gowa/instance1/docker-compose.yml <<EOF
services:
  whatsapp1:
    image: aldinokemal2104/go-whatsapp-web-multidevice
    container_name: gowa-wa1
    restart: always
    network_mode: host
    command: ["rest", "-p", "${HOST_PORT}"]
    volumes:
      - whatsapp1:/app/storages
    environment:
      APP_BASIC_AUTH: "admin:${BASIC_AUTH_PASS}"
      APP_PORT: "${HOST_PORT}"
      APP_DEBUG: "true"
      APP_OS: "Chrome"
      APP_ACCOUNT_VALIDATION: "false"
      WHATSAPP_WEBHOOK: "${WEBHOOK_URL}"
      WHATSAPP_WEBHOOK_EVENTS: "message,message.ack"
      WHATSAPP_WEBHOOK_SECRET: "${WEBHOOK_SECRET}"

volumes:
  whatsapp1:
EOF


cat > /opt/gowa/instance2/docker-compose.yml <<EOF
services:
  whatsapp1:
    image: aldinokemal2104/go-whatsapp-web-multidevice
    container_name: gowa-wa2
    restart: always
    network_mode: host
    command: ["rest", "-p", "${HOST_PORT_2}"]
    volumes:
      - whatsapp2:/app/storages
    environment:
      APP_BASIC_AUTH: "admin:${BASIC_AUTH_PASS}"
      APP_PORT: "${HOST_PORT_2}"
      APP_DEBUG: "true"
      APP_OS: "Chrome"
      APP_ACCOUNT_VALIDATION: "false"
      WHATSAPP_WEBHOOK: "${WEBHOOK_URL}"
      WHATSAPP_WEBHOOK_EVENTS: "message,message.ack"
      WHATSAPP_WEBHOOK_SECRET: "${WEBHOOK_SECRET}"

volumes:
  whatsapp2:
EOF


cd /opt/gowa/instance1 && docker compose up -d
cd /opt/gowa/instance2 && docker compose up -d
'
msg_ok "GOWA instances started"

# ---------------- Networking info (FIXED) ----------------
msg_info "Detecting IP addresses (clean)"
# Get LXC IP: only accept the first clean IPv4 from eth0.
LXC_IP_RAW="$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null || true)"
LXC_IP="$(printf '%s' "$LXC_IP_RAW" | strip_ansi | first_ipv4 || true)"

# Fallback: try hostname -I
if [[ -z "${LXC_IP}" ]]; then
  LXC_IP_RAW="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)"
  LXC_IP="$(printf '%s' "$LXC_IP_RAW" | strip_ansi | first_ipv4 || true)"
fi

# Docker IPs (also sanitized)
DOCKER_IP_1_RAW="$(pct exec "$CTID" -- bash -lc "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gowa-wa1 2>/dev/null" || true)"
DOCKER_IP_2_RAW="$(pct exec "$CTID" -- bash -lc "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gowa-wa2 2>/dev/null" || true)"
DOCKER_IP_1="$(printf '%s' "$DOCKER_IP_1_RAW" | strip_ansi | first_ipv4 || true)"
DOCKER_IP_2="$(printf '%s' "$DOCKER_IP_2_RAW" | strip_ansi | first_ipv4 || true)"

# If still empty, mark clearly
[[ -z "${LXC_IP}" ]] && LXC_IP="(unknown)"
[[ -z "${DOCKER_IP_1}" ]] && DOCKER_IP_1="(unknown)"
[[ -z "${DOCKER_IP_2}" ]] && DOCKER_IP_2="(unknown)"

GOWA_URL_1_IP="http://${LXC_IP}:${HOST_PORT}"
GOWA_URL_2_IP="http://${LXC_IP}:${HOST_PORT_2}"
GOWA_URL_1_DNS="http://${MDNS_BASE}.local:${HOST_PORT}"
GOWA_URL_2_DNS="http://${MDNS_BASE}.local:${HOST_PORT_2}"
msg_ok "IP detection complete"

# ---------------- Proxmox Notes ----------------
msg_info "Writing Proxmox Notes"
DESC="$(cat <<EOF
GOWA / WhatsMeow – dual instance deployment + mDNS (.local)

LXC:
- CTID: ${CTID}
- IP: ${LXC_IP}
- mDNS hostname: ${MDNS_BASE}.local
- Root password: ${ROOT_PASS}

Bridge instance 1:
- URL (IP):  ${GOWA_URL_1_IP}
- URL (DNS): ${GOWA_URL_1_DNS}
- Container: gowa-wa1
- Docker IP: ${DOCKER_IP_1}
- Volume: whatsapp1 -> /app/storages
- Compose: /opt/gowa/instance1/docker-compose.yml

Bridge instance 2:
- URL (IP):  ${GOWA_URL_2_IP}
- URL (DNS): ${GOWA_URL_2_DNS}
- Container: gowa-wa2
- Docker IP: ${DOCKER_IP_2}
- Volume: whatsapp2 -> /app/storages
- Compose: /opt/gowa/instance2/docker-compose.yml

Basic Auth (shared):
- Username: ${GOWA_USER}
- Password: ${GOWA_PASS}

Webhook (shared):
- URL: ${WEBHOOK_URL}
- Secret: ${WEBHOOK_SECRET}
- Events: ${WEBHOOK_EVENTS}

LAN usage:
- Instance 1: http://${MDNS_BASE}.local:${HOST_PORT}
- Instance 2: http://${MDNS_BASE}.local:${HOST_PORT_2}
EOF
)"
pct set "$CTID" --description "$DESC" >/dev/null
msg_ok "Notes written"

echo -e "${INFO}${YW}Instance 1 (DNS):${CL} ${GOWA_URL_1_DNS}"
echo -e "${INFO}${YW}Instance 2 (DNS):${CL} ${GOWA_URL_2_DNS}"
echo -e "${INFO}${YW}Credentials stored in Proxmox Notes (CTID ${CTID}).${CL}"
