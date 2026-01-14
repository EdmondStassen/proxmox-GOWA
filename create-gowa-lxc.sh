#!/usr/bin/env bash
# ProxmoxVE LXC helper (build.func framework)
# Deploys 2x GOWA/WhatsMeow instances via Docker image + Compose
# - No git clone (image-based)
# - Separate volumes per instance (separate WhatsApp sessions)
# - Shared Basic Auth + shared webhook config
# - Adds LAN DNS name via mDNS/Avahi: e.g. gowa.local -> LXC IP
# - Adds per-instance "friendly" DNS names (also via Avahi): gowa1.local and gowa2.local -> same LXC IP
#   (Ports still distinguish them, but names are convenient for calls and bookmarks)

set -euo pipefail

# Prevent "unbound variable" errors in Proxmox shell
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
# Base name: gowa.local
MDNS_BASE="${MDNS_BASE:-${var_hostname}}"

# Per-instance names (also advertised via Avahi; both point to the same LXC IP)
# Convenient for using in calls/bookmarks. Ports still apply.
MDNS_1="${MDNS_1:-${MDNS_BASE}1}"   # gowa1.local
MDNS_2="${MDNS_2:-${MDNS_BASE}2}"   # gowa2.local

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

# ---------------- set CT hostname (base .local name) ----------------
# Avahi will advertise the system hostname as <hostname>.local
msg_info "Configuring base mDNS hostname (${MDNS_BASE}.local)"
pct exec "$CTID" -- bash -lc "
set -e
echo '${MDNS_BASE}' > /etc/hostname
hostnamectl set-hostname '${MDNS_BASE}' || true
# Ensure Debian-style hostname mapping exists
if ! grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
  echo '127.0.1.1 ${MDNS_BASE}' >> /etc/hosts
else
  sed -i -E 's/^127\.0\.1\.1\s+.*/127.0.1.1 ${MDNS_BASE}/' /etc/hosts
fi
systemctl restart avahi-daemon
"
msg_ok "Base mDNS hostname configured"

# ---------------- add per-instance mDNS aliases via Avahi service files ----------------
# These create additional .local names that point to the same host.
# Note: mDNS doesn't do "A records" centrally; Avahi answers for these names on this host.
msg_info "Adding per-instance mDNS aliases (${MDNS_1}.local, ${MDNS_2}.local)"
pct exec "$CTID" -- bash -lc "
set -e
mkdir -p /etc/avahi/services

cat > /etc/avahi/services/${MDNS_1}.service <<EOF
<?xml version=\"1.0\" standalone=\"no\"?>
<!DOCTYPE service-group SYSTEM \"avahi-service.dtd\">
<service-group>
  <name replace-wildcards=\"no\">${MDNS_1}</name>
  <service>
    <type>_http._tcp</type>
    <port>${HOST_PORT}</port>
  </service>
</service-group>
EOF

cat > /etc/avahi/services/${MDNS_2}.service <<EOF
<?xml version=\"1.0\" standalone=\"no\"?>
<!DOCTYPE service-group SYSTEM \"avahi-service.dtd\">
<service-group>
  <name replace-wildcards=\"no\">${MDNS_2}</name>
  <service>
    <type>_http._tcp</type>
    <port>${HOST_PORT_2}</port>
  </service>
</service-group>
EOF

systemctl restart avahi-daemon
"
msg_ok "mDNS aliases added"

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
    ports:
      - "'"${HOST_PORT}"':3000"
    volumes:
      - whatsapp1:/app/storages
    environment:
      - APP_BASIC_AUTH='"${GOWA_USER}:${GOWA_PASS}"'
      - APP_PORT=3000
      - APP_DEBUG=true
      - APP_OS=Chrome
      - APP_ACCOUNT_VALIDATION=false
      - WEBHOOK_URL='"${WEBHOOK_URL}"'
      - WEBHOOK_EVENTS='"${WEBHOOK_EVENTS}"'
      - WEBHOOK_SECRET='"${WEBHOOK_SECRET}"'
volumes:
  whatsapp1:
EOF

cat > /opt/gowa/instance2/docker-compose.yml <<EOF
services:
  whatsapp2:
    image: aldinokemal2104/go-whatsapp-web-multidevice
    container_name: gowa-wa2
    restart: always
    ports:
      - "'"${HOST_PORT_2}"':3000"
    volumes:
      - whatsapp2:/app/storages
    environment:
      - APP_BASIC_AUTH='"${GOWA_USER}:${GOWA_PASS}"'
      - APP_PORT=3000
      - APP_DEBUG=true
      - APP_OS=Chrome
      - APP_ACCOUNT_VALIDATION=false
      - WEBHOOK_URL='"${WEBHOOK_URL}"'
      - WEBHOOK_EVENTS='"${WEBHOOK_EVENTS}"'
      - WEBHOOK_SECRET='"${WEBHOOK_SECRET}"'
volumes:
  whatsapp2:
EOF

cd /opt/gowa/instance1 && docker compose up -d
cd /opt/gowa/instance2 && docker compose up -d
'
msg_ok "GOWA instances started"

# ---------------- Networking info ----------------
msg_info "Detecting IP addresses"
LXC_IP="$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1" | tr -d "\r" || true)"

DOCKER_IP_1="$(pct exec "$CTID" -- bash -lc "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gowa-wa1 2>/dev/null" | tr -d "\r" || true)"
DOCKER_IP_2="$(pct exec "$CTID" -- bash -lc "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gowa-wa2 2>/dev/null" | tr -d "\r" || true)"

GOWA_URL_1_IP="http://${LXC_IP}:${HOST_PORT}"
GOWA_URL_2_IP="http://${LXC_IP}:${HOST_PORT_2}"

GOWA_URL_BASE_DNS="http://${MDNS_BASE}.local"
GOWA_URL_1_DNS="http://${MDNS_1}.local:${HOST_PORT}"
GOWA_URL_2_DNS="http://${MDNS_2}.local:${HOST_PORT_2}"

msg_ok "IP detection complete"

# ---------------- Proxmox Notes ----------------
msg_info "Writing Proxmox Notes"
DESC="$(cat <<EOF
GOWA / WhatsMeow – dual instance deployment + mDNS (.local)

LXC:
- CTID: ${CTID}
- IP: ${LXC_IP}
- Base mDNS hostname: ${MDNS_BASE}.local
- Instance mDNS aliases: ${MDNS_1}.local, ${MDNS_2}.local
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
- Base (same host): ${GOWA_URL_BASE_DNS}:${HOST_PORT} and :${HOST_PORT_2}
- Instance 1: ${GOWA_URL_1_DNS}
- Instance 2: ${GOWA_URL_2_DNS}

Paths:
- Base: /opt/gowa
EOF
)"
pct set "$CTID" --description "$DESC" >/dev/null
msg_ok "Notes written"

echo -e "${INFO}${YW}Instance 1 (DNS):${CL} ${GOWA_URL_1_DNS}"
echo -e "${INFO}${YW}Instance 2 (DNS):${CL} ${GOWA_URL_2_DNS}"
echo -e "${INFO}${YW}Credentials stored in Proxmox Notes (CTID ${CTID}).${CL}"
