Whatsapp bridge:
bash -c "$(curl -fsSL https://raw.githubusercontent.com/EdmondStassen/proxmox-scripts/refs/heads/main/create-gowa-lxc.sh)"

n8n:
bash -c "$(curl -fsSL https://raw.githubusercontent.com/EdmondStassen/proxmox-scripts/refs/heads/main/create-n8n-lxc.sh)"

deb lxc with hostname: 
bash -c "$(curl -fsSL https://raw.githubusercontent.com/EdmondStassen/proxmox-scripts/refs/heads/main/create-debian-lxc-dnshostname.sh)"


Include scripts:

<b>DNS HOSTNAME </b>
'''markdown
# ------------------------------------------------------------------
# DNS hostname publishing (FULLY SELF-CONTAINED BLOCK)
# ------------------------------------------------------------------
SOURCEURL="https://raw.githubusercontent.com/EdmondStassen/proxmox-scripts/main/debian_dhcp-hostname.include.sh"
source <(curl -fsSL "$SOURCEURL")
unset SOURCEURL

# Prompt for hostname
dhcp_hostname::prompt

# Create the container (CTID assigned here)
build_container

# Configure hostname + DHCP publishing inside the container
dhcp_hostname::apply
# ------------------------------------------------------------------
'''
