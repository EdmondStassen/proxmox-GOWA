#!/usr/bin/env bash
# ProxmoxVE LXC helper (build.func framework)
# Deploys n8n via Docker + Compose inside an LXC (SQLite backend)
# - Avahi/mDNS: n8n.local (configurable)
# - Robust IP detection (ANSI stripping + IPv4 regex)
# - Generates N8N_ENCRYPTION_KEY and stores in /opt/n8n/.env + Proxmox Notes
# - Sets random LXC root password and writes to Notes

set -euo pipefail
: "${SSH_CLIENT:=}"
: "${SSH_TTY:=}"
: "${SSH_CONNECTION:=}"

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="n8n"
var_tags="${var_tags:-docker;n8n;automation;mdns;sqlite}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_hostname="${var_hostname:-n8n}"

# Important for Docker-in-LXC (matches the GOWA script approach)
var_install="docker-install"

# ---------------- Settings ----------------
HOST_PORT="${HOST_PORT:-5678}"

# mDNS (Avahi)
MDNS_BASE="${MDNS_BASE:-${var_hostname}}"
ENABLE_MDNS="${ENABLE_MDNS:-1}"

# Secrets length (alnum)
RAND_LEN="${RAND_LEN:-48}"

# Docker image
N8N_IMAGE="${N8N_IMAGE:-n8nio/n8n:latest}"

header_info "$APP"
variables
color
catch_errors

# ---------------- helpers ----------------
rand_pw() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "${RAND_LEN}"
  else
    dd if=/dev/urandom bs=128 count=2 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "${RAND_LEN}"
  fi
}

strip_ansi() {
  sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g'
}

first_ipv4() {
  grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1
}

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

# ---------------- generate credentials ----------------
msg_info "Generating credentials"
ROOT_PASS="$(rand_pw)"
N8N_ENCRYPTION_KEY="$(rand_pw)"
msg_ok "Credentials generated"

# ---------------- create CT ----------------
start
build_container
description

# ---------------- install Docker + compose (+ optional Avahi) ----------------
msg_info "Installing Docker + Compose (+ optional Avahi for mDNS .local)"
pct exec "$CTID" -- bash -lc '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl

  # Docker engine
  command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
  apt-get install -y docker-compose-plugin
  systemctl enable docker --now
' >/dev/null

if [[ "${ENABLE_MDNS}" == "1" ]]; then
  pct exec "$CTID" -- bash -lc '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y avahi-daemon
    systemctl enable avahi-daemon --now
  ' >/dev/null
fi
msg_ok "Docker stack ready"

# ---------------- set CT hostname (mDNS base name) ----------------
if [[ "${ENABLE_MDNS}" == "1" ]]; then
  msg_info "Configuring mDNS hostname (${MDNS_BASE}.local)"
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
  msg_ok "mDNS configured: ${MDNS_BASE}.local"
fi

# ---------------- set root password ----------------
msg_info "Setting container root password"
pct exec "$CTID" -- bash -lc "echo root:${ROOT_PASS} | chpasswd" >/dev/null
msg_ok "Root password set"

# ---------------- Compose project (n8n + SQLite) ----------------
msg_info "Creating Docker Compose project (SQLite)"
pct exec "$CTID" -- bash -lc "
  set -e
  mkdir -p /opt/n8n

  # Compose env
  cat > /opt/n8n/.env <<EOF
# n8n (SQLite)
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_HOST=${MDNS_BASE}.local
N8N_PORT=5678
N8N_PROTOCOL=http
WEBHOOK_URL=http://${MDNS_BASE}.local:${HOST_PORT}/

# Image
N8N_IMAGE=${N8N_IMAGE}
HOST_PORT=${HOST_PORT}
EOF

  # Compose file
  cat > /opt/n8n/docker-compose.yml <<'EOF'
services:
  n8n:
    image: ${N8N_IMAGE}
    container_name: n8n
    restart: unless-stopped
    ports:
      - "${HOST_PORT}:5678"
    environment:
      # Core
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_HOST: ${N8N_HOST}
      N8N_PORT: ${N8N_PORT}
      N8N_PROTOCOL: ${N8N_PROTOCOL}
      WEBHOOK_URL: ${WEBHOOK_URL}

      # SQLite is default in n8n; we keep it explicit for clarity
      DB_TYPE: sqlite
      DB_SQLITE_VACUUM_ON_STARTUP: "true"
    volumes:
      - n8n_data:/home/node/.n8n

volumes:
  n8n_data:
EOF

  docker compose -f /opt/n8n/docker-compose.yml --env-file /opt/n8n/.env up -d
" >/dev/null
msg_ok "n8n started (SQLite)"

# ---------------- IP detection ----------------
msg_info "Detecting IP"
LXC_IP="$(detect_lxc_ip)"
N8N_URL_IP="http://${LXC_IP}:${HOST_PORT}"
N8N_URL_DNS="http://${MDNS_BASE}.local:${HOST_PORT}"
msg_ok "IP detection complete"

# ---------------- Proxmox Notes ----------------
msg_info "Writing Proxmox Notes"
DESC="$(
  cat <<EOF
n8n via Docker in LXC (SQLite) (CTID ${CTID})

Access:
- URL (IP): ${N8N_URL_IP}
- URL (mDNS): ${N8N_URL_DNS}

mDNS:
- Hostname: ${MDNS_BASE}
- mDNS name: ${MDNS_BASE}.local
- Avahi enabled: ${ENABLE_MDNS}

Docker:
- Compose: /opt/n8n/docker-compose.yml
- Env: /opt/n8n/.env
- Container: n8n
- Data volume: n8n_data -> /home/node/.n8n (inside container)
- Commands:
  - docker ps
  - docker logs -f n8n
  - docker compose -f /opt/n8n/docker-compose.yml --env-file /opt/n8n/.env pull
  - docker compose -f /opt/n8n/docker-compose.yml --env-file /opt/n8n/.env up -d

Database:
- SQLite (in Docker volume n8n_data)

Secrets / credentials:
- LXC root password: ${ROOT_PASS}
- N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}

Notes:
- If you change mDNS name, update /opt/n8n/.env (N8N_HOST + WEBHOOK_URL) and restart compose.
EOF
)"
pct set "$CTID" --description "$DESC" >/dev/null
msg_ok "Notes written"

msg_ok "Completed successfully!"
echo -e "${CREATING}${GN}${APP} (Docker/SQLite) setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access (IP):${CL}"
echo -e "${TAB}${GATEWAY}${BGN}${N8N_URL_IP}${CL}"
if [[ "${ENABLE_MDNS}" == "1" ]]; then
  echo -e "${INFO}${YW} Access (mDNS):${CL}"
  echo -e "${TAB}${GATEWAY}${BGN}${N8N_URL_DNS}${CL}"
fi
echo -e "${INFO}${YW}Secrets stored in Proxmox Notes (CTID ${CTID}).${CL}"
