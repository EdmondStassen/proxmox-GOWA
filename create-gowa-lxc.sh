#!/usr/bin/env bash
set -euo pipefail

# =======================
# GOWA on Proxmox LXC - script
# - Default: DHCP
# - To use a static IP:
#     export IP_CIDR="192.168.1.50/24"
#     export GATEWAY="192.168.1.1"
#   Then run the script again.
# =======================

# ====== AANPASSEN (optioneel) ======
CTID="${CTID:-120}"                      # Uniek container ID
HOSTNAME="${HOSTNAME:-gowa}"
DISK_GB="${DISK_GB:-8}"                  # 8-16GB is meestal genoeg
MEM_MB="${MEM_MB:-1024}"                 # 512-1024MB vaak OK
CORES="${CORES:-2}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"          # jouw Proxmox storage
TEMPLATE="${TEMPLATE:-local:vztmpl/debian-12-standard_12.0-1_amd64.tar.zst}"

# Netwerk (standaard DHCP)
IP_CIDR="${IP_CIDR:-dhcp}"               # "dhcp" of bijv. "192.168.1.50/24"
GATEWAY="${GATEWAY:-}"                   # bij statisch IP: bijv. "192.168.1.1"

# Poort mapping naar LAN
HOST_PORT="${HOST_PORT:-3000}"
# ===================================

# Random password generator (URL-safe-ish)
rand_pw() {
  # 24 chars base64-ish zonder lastige tekens
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

ROOT_PASS="$(rand_pw)"
GOWA_USER="admin"
GOWA_PASS="$(rand_pw)"

if [[ "$IP_CIDR" != "dhcp" && -z "$GATEWAY" ]]; then
  echo "ERROR: bij statische IP moet GATEWAY gezet zijn. (bijv. export GATEWAY=192.168.1.1)"
  exit 1
fi

NET0="name=eth0,bridge=${BRIDGE},ip=${IP_CIDR}"
if [[ "$IP_CIDR" != "dhcp" ]]; then
  NET0="${NET0},gw=${GATEWAY}"
fi

echo "[1/8] LXC aanmaken (CTID=$CTID, hostname=$HOSTNAME, ip=$IP_CIDR)"
pct create "$CTID" "$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$MEM_MB" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "$NET0" \
  --unprivileged 1 \
  --features "nesting=1,keyctl=1" \
  --onboot 1 \
  --start 1

echo "[2/8] Container root password instellen (random)"
pct set "$CTID" --password "$ROOT_PASS" >/dev/null

echo "[3/8] Docker + Compose installeren in container"
pct exec "$CTID" -- bash -lc '
set -e
apt update
apt upgrade -y
apt install -y ca-certificates curl git
curl -fsSL https://get.docker.com | sh
apt install -y docker-compose-plugin
systemctl enable docker --now
'

echo "[4/8] GOWA repo clonen"
pct exec "$CTID" -- bash -lc '
set -e
mkdir -p /opt/gowa
cd /opt/gowa
if [ ! -d go-whatsapp-web-multidevice ]; then
  git clone https://github.com/aldinokemal/go-whatsapp-web-multidevice
fi
'

echo "[5/8] docker-compose.yml klaarzetten (poort ${HOST_PORT} open op LAN + basic auth aan)"
# Let op: we gebruiken een compose die altijd werkt (image-based),
# maar laten de repo staan zodat je later vanuit source kunt werken.
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
"

echo "[6/8] GOWA starten"
pct exec "$CTID" -- bash -lc '
set -e
cd /opt/gowa/go-whatsapp-web-multidevice
docker compose up -d
docker compose ps
'

echo "[7/8] IP-adres(sen) ophalen (LXC + Docker container)"
# LXC IP (eerste IPv4 op eth0)
LXC_IP="$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1" | tr -d '\r' || true)"

# Docker container IP (bridge network)
DOCKER_IP="$(pct exec "$CTID" -- bash -lc "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' whatsapp 2>/dev/null" | tr -d '\r' || true)"

if [[ -z "${LXC_IP}" ]]; then
  # DHCP kan soms nét wat later komen, probeer nog 1x
  sleep 2
  LXC_IP="$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1" | tr -d '\r' || true)"
fi

GOWA_URL="http://${LXC_IP}:${HOST_PORT}"

echo "[8/8] Proxmox Notes/Description vullen met summary info"
DESC="$(cat <<EOF
GOWA (go-whatsapp-web-multidevice) deployed via Docker Compose

LXC:
- Hostname: ${HOSTNAME}
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

# Zet in Proxmox "Notes"
pct set "$CTID" --description "$DESC" >/dev/null

echo "Klaar ✅"
echo "LXC IP: ${LXC_IP}"
echo "GOWA URL: ${GOWA_URL}"
echo "Root password + Basic Auth staan nu ook in Proxmox Notes (CT ${CTID})."
