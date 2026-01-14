#!/usr/bin/env bash
# Based on community-scripts/ProxmoxVE ct/docker.sh style (build.func framework)
# Adds: GOWA deployment, random root password, random basic-auth, and Proxmox Notes summary.

set -euo pipefail

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# Clean setting
: "${SSH_CLIENT:=}"
: "${SSH_TTY:=}"
: "${SSH_CONNECTION:=}"


# App metadata for the helper framework
APP="GOWA (go-whatsapp-web-multidevice)"
var_tags="${var_tags:-docker;gowa;whatsapp}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

# Network: community build scripts are interactive; for DHCP you can keep defaults.
# If you want static IP, set it in the advanced settings prompts (or adapt build.func usage).

# GOWA settings
HOST_PORT="${HOST_PORT:-3000}"                 # LAN exposed port
GOWA_USER="${GOWA_USER:-admin}"
# Passwords: generated, then stored in CT Notes as requested
RAND_LEN="${RAND_LEN:-24}"

header_info "$APP"
variables
color
catch_errors

# --- helpers ---
rand_pw() {
  # Robust random generator (host-side), avoids /dev/urandom|tr|head hangs in some shells.
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${RAND_LEN}"
  else
    dd if=/dev/urandom bs=64 count=2 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "${RAND_LEN}"
  fi
}

msg_info "Generating credentials"
ROOT_PASS="$(rand_pw)"
GOWA_PASS="$(rand_pw)"
msg_ok "Credentials generated"

# --- create CT + install Docker (using the framework) ---
start
build_container
description

# Ensure Docker is installed (docker.sh normally does it, but we enforce to be safe)
msg_info "Ensuring Docker + Compose are installed in CT ${CTID}"
pct exec "$CTID" -- bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl git
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
apt-get install -y docker-compose-plugin
systemctl enable docker --now
'
msg_ok "Docker ready"

# Set container root password (container root, not Proxmox host root)
msg_info "Setting container root password (random)"
pct set "$CTID" --password "$ROOT_PASS" >/dev/null
msg_ok "Container root password set"

# Clone GOWA repo
msg_info "Cloning GOWA repository"
pct exec "$CTID" -- bash -lc '
set -e
mkdir -p /opt/gowa
cd /opt/gowa
if [ ! -d go-whatsapp-web-multidevice ]; then
  git clone https://github.com/aldinokemal/go-whatsapp-web-multidevice
fi
'
msg_ok "Repository cloned"

# Write docker-compose.yml (image-based, reliable) and start
msg_info "Writing docker-compose.yml + starting GOWA"
pct exec "$CTID" -- bash -lc "set -e
cd /opt/gowa/go-whatsapp-web-multidevice
cat > docker-compose.yml <<EOF
services:
  whatsapp:
    image: aldinokemal2104/go-whatsapp-web-multidevice
    container_name: whatsapp
    restart: always
    ports:
      - \"${HOST_PORT}:3000\"
    volumes:
      - whatsapp:/app/storages
    environment:
      - APP_BASIC_AUTH=${GOWA_USER}:${GOWA_PASS}
      - APP_PORT=3000
      - APP_DEBUG=true
      - APP_OS=Chrome
      - APP_ACCOUNT_VALIDATION=false
volumes:
  whatsapp:
EOF
docker compose up -d
docker compose ps
"
msg_ok "GOWA started"

# Get IPs
msg_info "Detecting IP addresses"
LXC_IP="$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1" | tr -d '\r' || true)"
if [[ -z "${LXC_IP}" ]]; then
  sleep 2
  LXC_IP="$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1" | tr -d '\r' || true)"
fi
DOCKER_IP="$(pct exec "$CTID" -- bash -lc "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' whatsapp 2>/dev/null" | tr -d '\r' || true)"
GOWA_URL="http://${LXC_IP}:${HOST_PORT}"
msg_ok "IP detection complete"

# Write Proxmox Notes/Description
msg_info "Writing Proxmox CT Notes/Description"
DESC="$(cat <<EOF
GOWA (go-whatsapp-web-multidevice) deployed via Docker Compose

LXC:
- CTID: ${CTID}
- IP: ${LXC_IP}
- Root password: ${ROOT_PASS}

GOWA (LAN):
- URL: ${GOWA_URL}
- Exposed port: ${HOST_PORT}

GOWA (Docker internal):
- Container name: whatsapp
- Docker IP: ${DOCKER_IP}
- Service port: 3000

Auth (Basic):
- Username: ${GOWA_USER}
- Password: ${GOWA_PASS}

Paths:
- Repo/compose: /opt/gowa/go-whatsapp-web-multidevice
- Data volume: docker volume 'whatsapp' -> /app/storages
EOF
)"
pct set "$CTID" --description "$DESC" >/dev/null
msg_ok "Notes updated"

msg_ok "Completed successfully!\n"
echo -e "${INFO}${YW}Open:${CL} ${GOWA_URL}"
echo -e "${INFO}${YW}Credentials are stored in CT Notes/Description for CTID ${CTID}.${CL}"
