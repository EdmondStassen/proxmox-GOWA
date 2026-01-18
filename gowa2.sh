#!/usr/bin/env bash
# ProxmoxVE LXC helper (build.func framework)
# Deploys 2x GOWA/WhatsMeow instances via Docker image + Compose
# + DHCP hostname publishing include (prompt + apply)

set -euo pipefail

: "${SSH_CLIENT:=}"
: "${SSH_TTY:=}"
: "${SSH_CONNECTION:=}"

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# ------------------------------------------------------------------
# Notes helper include
# ------------------------------------------------------------------
SOURCEURL="https://raw.githubusercontent.com/EdmondStassen/proxmox-scripts/refs/heads/main/proxmox_notes.include.sh"
source <(curl -fsSL "$SOURCEURL")
unset SOURCEURL

# ------------------------------------------------------------------
# DHCP Hostname Publisher include
# ------------------------------------------------------------------
SOURCEURL="https://raw.githubusercontent.com/EdmondStassen/proxmox-scripts/main/debian_dhcp-hostname.include.sh"
source <(curl -fsSL "$SOURCEURL")
unset SOURCEURL

# ------------------------------------------------------------------
# Proxmox / LXC defaults
# ------------------------------------------------------------------
APP="GOWA"

var_tags="${var_tags:-docker;gowa;whatsapp;whatsmeow}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"
# Let DHCP include prompt for hostname unless caller already set var_hostname
# var_hostname="${var_hostname:-gowa}"

header_info "$APP"
variables
var_install="docker-install"

color
catch_errors

# ------------------------------------------------------------------
# Create container
# ------------------------------------------------------------------
start

# Prompt for hostname to publish via DHCP (before build_container)
dhcp_hostname::prompt

# Create container (CTID assigned here)
build_container

# Configure hostname + DHCP publishing inside the container (after build_container)
dhcp_hostname::apply

description

# ------------------------------------------------------------------
# Proxmox Notes: initialize (clean once)
# ------------------------------------------------------------------
notes::init "Provisioning notes for ${APP} (CTID ${CTID})"

# Helper: append notes safely (works whether function expects arg or reads NOTE_MSG)
notes_append() {
  if declare -F notes::append_msg >/dev/null 2>&1; then
    if notes::append_msg "test" >/dev/null 2>&1; then
      notes::append_msg "$1" >/dev/null 2>&1 || true
    else
      NOTE_MSG="$1"
      notes::append_msg >/dev/null 2>&1 || true
    fi
  fi
}

# ------------------------------------------------------------------
# Credentials + root password
# ------------------------------------------------------------------
RAND_LEN="${RAND_LEN:-24}"

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
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"
[[ -z "$WEBHOOK_SECRET" ]] && WEBHOOK_SECRET="$(rand_pw)"
msg_ok "Credentials generated"

msg_info "Setting container root password"
pct exec "$CTID" -- bash -lc "echo root:${ROOT_PASS} | chpasswd"
msg_ok "Root password set"

notes_append "$(cat <<EOF
Generated credentials:
- Root password: ${ROOT_PASS}
- Basic Auth password: ${GOWA_PASS}
- Webhook secret: ${WEBHOOK_SECRET}

Hostname:
- Published via DHCP: ${var_hostname}
EOF
)"

# ------------------------------------------------------------------
# Docker + Docker Compose installation
# ------------------------------------------------------------------
msg_info "Installing Docker and Docker Compose"
pct exec "$CTID" -- bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y ca-certificates curl

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

apt-get install -y docker-compose-plugin
systemctl enable docker --now
'
msg_ok "Docker and Docker Compose ready"

# ------------------------------------------------------------------
# GOWA Docker Compose projects (2 instances)
# ------------------------------------------------------------------
HOST_PORT_1="${HOST_PORT_1:-${HOST_PORT:-3000}}"
HOST_PORT_2="${HOST_PORT_2:-3001}"
GOWA_USER="${GOWA_USER:-admin}"

WEBHOOK_URL_1="${WEBHOOK_URL_1:-http://whatsapp-bot:8080/webhook}"
WEBHOOK_URL_2="${WEBHOOK_URL_2:-http://whatsapp-bot:8080/webhook}"

WEBHOOK_EVENTS_1="${WEBHOOK_EVENTS_1:-message,message.ack}"
WEBHOOK_EVENTS_2="${WEBHOOK_EVENTS_2:-message,message.ack}"

msg_info "Creating Docker Compose projects"
pct exec "$CTID" -- env \
  BASIC_AUTH_PASS="$GOWA_PASS" \
  GOWA_USER="$GOWA_USER" \
  HOST_PORT_1="$HOST_PORT_1" \
  HOST_PORT_2="$HOST_PORT_2" \
  WEBHOOK_URL_1="$WEBHOOK_URL_1" \
  WEBHOOK_URL_2="$WEBHOOK_URL_2" \
  WEBHOOK_EVENTS_1="$WEBHOOK_EVENTS_1" \
  WEBHOOK_EVENTS_2="$WEBHOOK_EVENTS_2" \
  WEBHOOK_SECRET="$WEBHOOK_SECRET" \
  bash -lc '
set -e

mkdir -p /opt/gowa/instance1 /opt/gowa/instance2

cat > /opt/gowa/instance1/docker-compose.yml <<EOF
services:
  whatsapp1:
    image: aldinokemal2104/go-whatsapp-web-multidevice
    container_name: gowa1
    restart: always
    network_mode: host
    command: ["rest", "--port=${HOST_PORT_1}"]
    volumes:
      - whatsapp1:/app/storages
    environment:
      APP_BASIC_AUTH: "${GOWA_USER}:${BASIC_AUTH_PASS}"
      APP_PORT: "${HOST_PORT_1}"
      APP_DEBUG: "true"
      APP_OS: "Chrome"
      APP_ACCOUNT_VALIDATION: "false"
      WHATSAPP_WEBHOOK: "${WEBHOOK_URL_1}"
      WHATSAPP_WEBHOOK_EVENTS: "${WEBHOOK_EVENTS_1}"
      WHATSAPP_WEBHOOK_SECRET: "${WEBHOOK_SECRET}"

volumes:
  whatsapp1:
EOF

cat > /opt/gowa/instance2/docker-compose.yml <<EOF
services:
  whatsapp2:
    image: aldinokemal2104/go-whatsapp-web-multidevice
    container_name: gowa2
    restart: always
    network_mode: host
    command: ["rest", "--port=${HOST_PORT_2}"]
    volumes:
      - whatsapp2:/app/storages
    environment:
      APP_BASIC_AUTH: "${GOWA_USER}:${BASIC_AUTH_PASS}"
      APP_PORT: "${HOST_PORT_2}"
      APP_DEBUG: "true"
      APP_OS: "Chrome"
      APP_ACCOUNT_VALIDATION: "false"
      WHATSAPP_WEBHOOK: "${WEBHOOK_URL_2}"
      WHATSAPP_WEBHOOK_EVENTS: "${WEBHOOK_EVENTS_2}"
      WHATSAPP_WEBHOOK_SECRET: "${WEBHOOK_SECRET}"

volumes:
  whatsapp2:
EOF

cd /opt/gowa/instance1 && docker compose up -d
cd /opt/gowa/instance2 && docker compose up -d
'
msg_ok "GOWA instances started"

notes_append "$(cat <<EOF
OK: GOWA deployed (2 instances)

Instance 1:
- Container: gowa1
- Port: ${HOST_PORT_1}

Instance 2:
- Container: gowa2
- Port: ${HOST_PORT_2}

Basic Auth:
- Username: ${GOWA_USER}
- Password: ${GOWA_PASS}

Instance 1 webhook:
- URL: ${WEBHOOK_URL_1}
- Secret: ${WEBHOOK_SECRET}
- Events: ${WEBHOOK_EVENTS_1}

Instance 2 webhook:
- URL: ${WEBHOOK_URL_2}
- Secret: ${WEBHOOK_SECRET}
- Events: ${WEBHOOK_EVENTS_2}
EOF
)"

# ------------------------------------------------------------------
# Networking info
# ------------------------------------------------------------------
strip_ansi() { sed -E 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g'; }
first_ipv4() { grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1; }

msg_info "Detecting LXC IP address"

LXC_IP_RAW="$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null || true)"
LXC_IP="$(printf '%s' "$LXC_IP_RAW" | strip_ansi | first_ipv4 || true)"

if [[ -z "$LXC_IP" ]]; then
  LXC_IP_RAW="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)"
  LXC_IP="$(printf '%s' "$LXC_IP_RAW" | strip_ansi | first_ipv4 || true)"
fi

[[ -z "$LXC_IP" ]] && LXC_IP="(unknown)"

GOWA_URL_1_IP="http://${LXC_IP}:${HOST_PORT_1}"
GOWA_URL_2_IP="http://${LXC_IP}:${HOST_PORT_2}"

# Hostname-based URLs (DHCP name)
GOWA_URL_1_DNS="http://${var_hostname}:${HOST_PORT_1}"
GOWA_URL_2_DNS="http://${var_hostname}:${HOST_PORT_2}"

msg_ok "IP detection complete"

notes_append "$(cat <<EOF
Networking:
- LXC IP: ${LXC_IP}
- Hostname (DHCP): ${var_hostname}

Clickable URLs (via hostname):
- Instance 1: ${GOWA_URL_1_DNS}
- Instance 2: ${GOWA_URL_2_DNS}

Fallback URLs (via IP):
- Instance 1: ${GOWA_URL_1_IP}
- Instance 2: ${GOWA_URL_2_IP}
EOF
)"

# ------------------------------------------------------------------
# Final output
# ------------------------------------------------------------------
echo -e "${INFO}${YW}Hostname:${CL} ${var_hostname}"
echo -e "${INFO}${YW}Instance 1 (hostname):${CL} ${GOWA_URL_1_DNS}"
echo -e "${INFO}${YW}Instance 2 (hostname):${CL} ${GOWA_URL_2_DNS}"
echo -e "${INFO}${YW}Instance 1 (IP):${CL} ${GOWA_URL_1_IP}"
echo -e "${INFO}${YW}Instance 2 (IP):${CL} ${GOWA_URL_2_IP}"
echo -e "${INFO}${YW}All details stored in Proxmox Notes (CTID ${CTID}).${CL}"
