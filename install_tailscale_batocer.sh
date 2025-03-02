#!/bin/bash

# --- Configuration ---
AUTH_KEY="${1:-}"  # Use $1 if provided, otherwise prompt
TAILSCALE_VERSION="${2:-1.80.2}"  # Default to 1.80.2

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Functions ---
validate_subnet() {
    if [[ ! "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo -e "${RED}ERROR: Invalid subnet format.${NC}"
        exit 1
    fi
}

# --- Start ---
echo -e "${YELLOW}🚀 Tailscale Installer for Batocera - Raspberry Pi 5${NC}"

# --- Root Check ---
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}⚠️ Must run as root.${NC}"
    exit 1
fi

# --- Confirmation ---
read -r -p "Install Tailscale on Batocera? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo -e "${RED}❌ Cancelled.${NC}"
    exit 1
fi

# --- Subnet ---
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
if [[ -z "$GATEWAY_IP" ]]; then
    echo -e "${YELLOW}WARNING: Subnet detection failed.${NC}"
    read -r -p "Enter subnet (e.g., 192.168.1.0/24): " SUBNET
    validate_subnet "$SUBNET"
else
    SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    echo -e "${GREEN}✅ Detected subnet: $SUBNET${NC}"
    read -r -p "Is this correct? (yes/no): " SUBNET_CONFIRM
    if [[ "$SUBNET_CONFIRM" != "yes" ]]; then
        read -r -p "Enter subnet (e.g., 192.168.1.0/24): " SUBNET
        validate_subnet "$SUBNET"
    fi
fi

# --- Hostname ---
DEFAULT_HOSTNAME="batocera-1"
echo -e "${YELLOW}Set Tailscale hostname:${NC}"
read -r -p "Enter hostname (default: $DEFAULT_HOSTNAME): " HOSTNAME
HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}
echo -e "${GREEN}✅ Using hostname: $HOSTNAME${NC}"

# --- Auth Key ---
if [[ -z "$AUTH_KEY" ]]; then
    echo -e "${YELLOW}🔑 Generate a REUSABLE auth key:${NC}"
    echo "   https://login.tailscale.com/admin/settings/keys"
    echo "   - Reusable: ENABLED (required)"
    echo "   - Ephemeral: Optional"
    echo "   - Tags: tag:ssh-batocera-1"
    read -r -p "Enter auth key (tskey-auth-...): " AUTH_KEY
fi
if [ -z "$AUTH_KEY" ] || ! echo "$AUTH_KEY" | grep -q '^tskey-auth-'; then
    echo -e "${RED}❌ Invalid auth key format.${NC}"
    exit 1
fi

# --- Install ---
echo -e "${GREEN}📥 Installing Tailscale...${NC}"
mkdir -p /userdata/system/tailscale/bin /userdata/system/tailscale
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
cp /userdata/system/tailscale/authkey /userdata/system/tailscale/authkey.bak
chmod 600 /userdata/system/tailscale/authkey
echo -e "${GREEN}✅ Auth key stored.${NC}"

wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz" || {
    echo -e "${RED}ERROR: Download failed.${NC}"
    exit 1
}
tar -xf /tmp/tailscale.tgz -C /tmp || {
    echo -e "${RED}ERROR: Extraction failed.${NC}"
    exit 1
}
mv /tmp/tailscale_*_arm64/tailscale /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/
rm -rf /tmp/tailscale_*_arm64 /tmp/tailscale.tgz
chmod +x /userdata/system/tailscale/bin/*

# --- TUN Device ---
mkdir -p /dev/net
if ! [ -c /dev/net/tun ]; then
    echo -e "${YELLOW}Creating TUN device...${NC}"
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi
if ! grep -q '^modules-load=tun$' /boot/batocera-boot.conf; then
    echo -e "${YELLOW}➕ Adding 'tun' to batocera-boot.conf...${NC}"
    mount -o remount,rw /boot
    echo 'modules-load=tun' >> /boot/batocera-boot.conf
    mount -o remount,ro /boot
fi
modprobe tun || echo -e "${YELLOW}WARNING: TUN not loaded now.${NC}"

# --- IP Forwarding ---
if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv6.conf.all.forwarding = 1" /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
fi
sysctl -p >/dev/null

# --- Startup Script ---
echo -e "${YELLOW}Configuring autostart...${NC}"
cat <<EOF > /userdata/system/custom.sh
#!/bin/sh
LOG="/userdata/system/tailscale/tailscale.log"
if ! pgrep -f "/userdata/system/tailscale/bin/tailscaled" > /dev/null; then
    echo "Starting tailscaled at \$(date)" >> \$LOG
    /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state >> \$LOG 2>&1 &
    sleep 5
    if [ ! -f /userdata/system/tailscale/authkey ]; then
        cp /userdata/system/tailscale/authkey.bak /userdata/system/tailscale/authkey
    fi
    /userdata/system/tailscale/bin/tailscale up \\
        --advertise-routes=$SUBNET \\
        --snat-subnet-routes=false \\
        --accept-routes \\
        --authkey="\$(cat /userdata/system/tailscale/authkey)" \\
        --hostname="$HOSTNAME" \\
        --advertise-tags=tag:ssh-batocera-1 >> \$LOG 2>&1
    if [ \$? -ne 0 ]; then
        echo "Tailscale failed to start at \$(date). Check key validity." >> \$LOG
        exit 1
    fi
    echo "Tailscale started successfully at \$(date)" >> \$LOG
fi
EOF
chmod +x /userdata/system/custom.sh

# --- Start Tailscale ---
echo -e "${GREEN}Starting Tailscale...${NC}"
/bin/sh /userdata/system/custom.sh &

# --- Verification ---
echo -e "${GREEN}------------------------------------------------------------------------${NC}"
echo -e "${GREEN}Verifying Tailscale...${NC}"
echo -e "${GREEN}------------------------------------------------------------------------${NC}"
echo -e "${YELLOW}Waiting for Tailscale...${NC}"
for i in {1..12}; do
    if /userdata/system/tailscale/bin/tailscale status >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Tailscale is running!${NC}"
        /userdata/system/tailscale/bin/tailscale status
        break
    fi
    echo -e "${YELLOW}Waiting... (attempt $i/12)${NC}"
    sleep $(( i < 6 ? 5 : 10 ))
    if [ $i -eq 12 ]; then
        echo -e "${RED}ERROR: Tailscale failed within 60 seconds. Check /userdata/system/tailscale/tailscale.log${NC}"
        cat /userdata/system/tailscale/tailscale.log
        exit 1
    fi
done

TAILSCALE_IP=$(/userdata/system/tailscale/bin/tailscale ip -4)
if [[ -z "$TAILSCALE_IP" ]]; then
    echo -e "${RED}ERROR: No Tailscale IP.${NC}"
    exit 1
fi
echo -e "${GREEN}Tailscale IP: $TAILSCALE_IP${NC}"
echo -e "${YELLOW}Try SSH: ssh root@$TAILSCALE_IP${NC}"
read -r -p "Did SSH work? (yes/no): " SSH_WORKED
if [[ "$SSH_WORKED" != "yes" ]]; then
    echo -e "${RED}ERROR: SSH failed. Do not save.${NC}"
    exit 1
fi

# --- Save and Reboot ---
echo -e "${GREEN}------------------------------------------------------------------------${NC}"
echo -e "${GREEN}Tailscale and SSH verified!${NC}"
read -r -p "Save and reboot? (yes/no): " SAVE_CHANGES
if [[ "$SAVE_CHANGES" == "yes" ]]; then
    echo -e "${YELLOW}💾 Saving overlay...${NC}"
    batocera-save-overlay || {
        echo -e "${RED}ERROR: Save failed.${NC}"
        exit 1
    }
    echo -e "${GREEN}✅ Saved. Rebooting in 5 seconds...${NC}"
    sleep 5
    reboot
else
    echo -e "${YELLOW}Not saved. Exiting.${NC}"
    exit 0
fi
