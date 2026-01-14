#!/usr/bin/env bash
# Proxmox LXC: n8n via Docker Compose (SQLite)
# - No npm / Node install
# - Avahi mDNS: n8n.local
# - Proxmox Notes with URLs + secrets
# - Robust IP detection
# - Fix secure cookie warning by setting N8N_SECURE_COOKIE=false (for HTTP)

export SSH_CLIENT="${SSH_CLIENT:-}"
export SSH_TTY="${SSH_TTY:-}"
export SSH_CONNECTION="${SSH_CONNECTION:-}"

set -euo pipefail
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="n8n-docker"
var_tags="${var_tags:-docker;n8n;automation;mdns;sqlite}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_hostname="${var_hostname:-n8n}"

HOST_PORT="${HOST_PORT:-5678}"
MDNS_BASE="${MDNS_BASE:-${var_hostname}}"
ENABLE_MDNS="${ENABLE_MDNS:-1}"
RAND_LEN="${RAND_LEN:-48}"
N8N_IMAGE="${N8N_IMAGE:-n8nio/n8n:latest}"

# Important for your situation (HTTP without TLS)
N8N_SECURE_COOKIE="${N8N_SECURE_COOKIE:-false}"

header_info "$APP"
variables
color
catch_errors

rand_pw() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "${RAND_LEN}"
  else
    dd if=/dev/urandom bs=128 count=2 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "${RAND_LEN}"
  fi
}
strip_ansi(){ sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g'; }
first_ipv4(){ grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1; }

detect_lxc_ip() {
  local raw ip
  raw="$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -n1" 2>/dev/null || true)"
  ip="$(printf '%s' "$raw" | strip_ansi | first_ipv4 || true)"
  if [[ -z "${ip}" ]]; then
    raw="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)"
    ip="$(printf '%s' "$raw" | strip_ansi | first_ipv4 || true)"
  fi
  [[ -z "${ip}" ]] && ip="(unknown)"
  printf '%s' "$ip"
}

msg_info "Generating credentials"
ROOT_PASS="$(rand_pw)"
N8N_ENCRYPTION_KEY="$(rand_pw)"
msg_ok "Credentials generated"

start
build_container
description

msg_info "Installing Docker + Compose plugin (self-managed)"
pct exec "$CTID" -- bash -lc '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi
  apt-get install -y docker-compose-plugin
  systemctl enable docker --now
' >/dev/null
msg_ok "Docker ready"

if [[ "${ENABLE_MDNS}" == "1" ]]; then
  msg_info "Installing & configuring Avahi (mDNS: ${MDNS_BASE}.local)"
  pct exec "$CTID" -- bash -lc '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y avahi-daemon
    systemctl enable avahi-daemon --now
  ' >/dev/null

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
  " >/dev/null
  msg_ok "mDNS configured"
fi

msg_info "Setting container root password"
pct exec "$CTID" -- bash -lc "echo root:${ROOT_PASS} | chpasswd" >/dev/null
msg_ok "Root password set"

msg_info "Writing compose project (SQLite) + starting n8n"

pct exec "$CTID" -- bash -lc "
  set -e
  mkdir -p /opt/n8n
  cat > /opt/n8n/.env <<EOF
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_HOST=${MDNS_BASE}.local
N8N_PORT=5678
N8N_PROTOCOL=http
WEBHOOK_URL=http://${MDNS_BASE}.local:${HOST_PORT}/
N8N_SECURE_COOKIE=${N8N_SECURE_COOKIE}
N8N_IMAGE=${N8N_IMAGE}
HOST_PORT=${HOST_PORT}
EOF
" >/dev/null

pct exec "$CTID" -- bash -s <<'REMOTE' >/dev/null
set -e
cat > /opt/n8n/docker-compose.yml <<'EOF'
services:
  n8n:
    image: ${N8N_IMAGE}
    container_name: n8n
    restart: unless-stopped
    ports:
      - "${HOST_PORT}:5678"
    environment:
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_HOST: ${N8N_HOST}
      N8N_PORT: ${N8N_PORT}
      N8N_PROTOCOL: ${N8N_PROTOCOL}
      WEBHOOK_URL: ${WEBHOOK_URL}
      N8N_SECURE_COOKIE: ${N8N_SECURE_COOKIE}
      DB_TYPE: sqlite
      DB_SQLITE_VACUUM_ON_STARTUP: "true"
    volumes:
      - n8n_data:/home/node/.n8n
volumes:
  n8n_data:
EOF
REMOTE

pct exec "$CTID" -- bash -lc "docker compose -f /opt/n8n/docker-compose.yml --env-file /opt/n8n/.env up -d" >/dev/null
msg_ok "n8n started"

msg_info "Detecting IP and writing Proxmox Notes"
LXC_IP="$(detect_lxc_ip)"
URL_IP="http://${LXC_IP}:${HOST_PORT}"
URL_DNS="http://${MDNS_BASE}.local:${HOST_PORT}"

DESC="$(
cat <<EOF
n8n via Docker in LXC (SQLite) (CTID ${CTID})

Access:
- URL (IP): ${URL_IP}
- URL (mDNS): ${URL_DNS}

HTTP mode:
- N8N_SECURE_COOKIE=${N8N_SECURE_COOKIE}
(If you later enable HTTPS via reverse proxy, set this to true.)

mDNS:
- Hostname: ${MDNS_BASE}
- mDNS: ${MDNS_BASE}.local
- Avahi enabled: ${ENABLE_MDNS}

Docker:
- Compose: /opt/n8n/docker-compose.yml
- Env: /opt/n8n/.env
- Container: n8n
- Data volume: n8n_data -> /home/node/.n8n

Commands:
- docker logs -f n8n
- docker compose -f /opt/n8n/docker-compose.yml --env-file /opt/n8n/.env restart

Secrets:
- LXC root password: ${ROOT_PASS}
- N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
EOF
)"
pct set "$CTID" --description "$DESC" >/dev/null
msg_ok "Notes written"

msg_ok "Completed successfully!"
echo -e "${INFO}${YW}Access (IP):${CL} ${URL_IP}"
if [[ "${ENABLE_MDNS}" == "1" ]]; then
  echo -e "${INFO}${YW}Access (mDNS):${CL} ${URL_DNS}"
fi
