#!/bin/bash

# --- Configuration ---
# Get auth key from argument 1, or prompt if not provided
AUTH_KEY="${1:-}"  # Use $1 (first argument) if provided, otherwise empty string.
# !! IMPORTANT !! Check https://pkgs.tailscale.com/stable/ for the latest arm64 version!
TAILSCALE_VERSION="${2:-1.80.2}"  # Use $2 (second arg) if provided, otherwise default.

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Functions ---

# Function to validate a subnet in CIDR notation
validate_subnet() {
    if [[ ! "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo -e "${RED}ERROR: Invalid subnet format. Exiting.${NC}"
        exit 1
    fi
}

# --- Script Start ---

echo -e "${YELLOW}🚀 Tailscale Installer for Batocera - Raspberry Pi 5${NC}"

# --- Root Check ---
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}⚠️ This script must be run as root (or with sudo).${NC}"
    exit 1
fi

# --- User Confirmation ---
if [ -z "$CONFIRM_INSTALL" ] || [ "$CONFIRM_INSTALL" != "yes" ]; then
    read -r -p "This script will install and configure Tailscale on your Batocera system. Continue? (yes/no): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        echo -e "${RED}❌ Installation cancelled by user.${NC}"
        exit 1
    fi
fi

# --- Automatic Subnet Detection ---
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
if [[ -z "$GATEWAY_IP" ]]; then
    echo -e "${YELLOW}WARNING: Could not automatically determine your local network subnet.${NC}"
    read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
    validate_subnet "$SUBNET"
else
    SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    echo -e "${GREEN}✅ Detected local subnet: $SUBNET${NC}"
    read -r -p "Is this subnet correct? (yes/no): " SUBNET_CONFIRM
    if [[ "$SUBNET_CONFIRM" != "yes" ]]; then
        read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
        validate_subnet "$SUBNET"
    fi
fi

# --- Check for Auth Key ---
if [[ -z "$AUTH_KEY" ]]; then
    echo -e "${YELLOW}🔑 Please generate a Tailscale REUSABLE and EPHEMERAL auth key:${NC}"
    echo "   Go to: https://login.tailscale.com/admin/settings/keys"
    echo "   - Reusable: ENABLED"
    echo "   - Ephemeral: ENABLED"
    echo "   - Tags: tag:ssh-batocera-1"
    read -r -p "Enter your Tailscale auth key (tskey-auth-...): " AUTH_KEY
fi
if [ -z "$AUTH_KEY" ] || ! echo "$AUTH_KEY" | grep -q '^tskey-auth-'; then
    echo -e "${RED}❌ Invalid or missing auth key.${NC}"
    exit 1
fi

# --- Installation Steps ---

echo -e "${GREEN}📥 Installing Tailscale...${NC}"

# Create directories
mkdir -p /userdata/system/tailscale/bin
mkdir -p /run/tailscale
mkdir -p /userdata/system/tailscale

# Store auth key
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
cp /userdata/system/tailscale/authkey /userdata/system/tailscale/authkey.bak
chmod 600 /userdata/system/tailscale/authkey
echo -e "${GREEN}✅ Auth key successfully stored.${NC}"

# Download Tailscale (prefer wget, fallback to curl)
if command -v wget &> /dev/null; then
    wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz" || {
        echo -e "${RED}ERROR: Failed to download Tailscale. Exiting.${NC}"
        exit 1
    }
elif command -v curl &> /dev/null; then
    curl -L -o /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz" || {
        echo -e "${RED}ERROR: Failed to download Tailscale. Exiting.${NC}"
        exit 1
    }
else
    echo -e "${RED}ERROR: Neither wget nor curl are installed. Cannot download Tailscale.${NC}"
    exit 1
fi

# Extract and install Tailscale
tar -xf /tmp/tailscale.tgz -C /tmp || {
    echo -e "${RED}ERROR: Failed to extract Tailscale. Exiting.${NC}"
    exit 1
}
mv /tmp/tailscale_*_arm64/tailscale /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/
rm -rf /tmp/tailscale_*_arm64 /tmp/tailscale.tgz
chmod +x /userdata/system/tailscale/bin/*

# Ensure TUN device and module
mkdir -p /dev/net
if ! [ -c /dev/net/tun ]; then
    echo -e "${YELLOW}Creating TUN device...${NC}"
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi
if ! grep -q '^modules-load=tun$' /boot/batocera-boot.conf; then
    echo -e "${YELLOW}➕ Adding 'tun' module to batocera-boot.conf...${NC}"
    mount -o remount,rw /boot
    echo 'modules-load=tun' >> /boot/batocera-boot.conf
    mount -o remount,ro /boot
fi
modprobe tun || echo -e "${YELLOW}WARNING: TUN module not loaded immediately; will attempt on boot.${NC}"

# Enable IP forwarding
if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv6.conf.all.forwarding = 1" /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
fi
sysctl -p >/dev/null

# Startup script
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
        --hostname=batocera-1 \\
        --advertise-tags=tag:ssh-batocera-1 >> \$LOG 2>&1
    if [ \$? -ne 0 ]; then
        echo "Tailscale failed to start at \$(date)" >> \$LOG
        exit 1
    fi
    echo "Tailscale started successfully at \$(date)" >> \$LOG
fi
EOF
chmod +x /userdata/system/custom.sh

# Start Tailscale now
echo -e "${GREEN}Starting Tailscale...${NC}"
/bin/sh /userdata/system/custom.sh &

# Verification
echo -e "${GREEN}------------------------------------------------------------------------${NC}"
echo -e "${GREEN}Tailscale installation completed. Performing verification checks...${NC}"
echo -e "${GREEN}------------------------------------------------------------------------${NC}"
echo -e "${YELLOW}Waiting for Tailscale to start...${NC}"
for i in {1..12}; do
    if /userdata/system/tailscale/bin/tailscale status >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Tailscale is running!${NC}"
        /userdata/system/tailscale/bin/tailscale status
        break
    fi
    echo -e "${YELLOW}Waiting... (attempt $i/12)${NC}"
    sleep $(( i < 6 ? 5 : 10 ))
    if [ $i -eq 12 ]; then
        echo -e "${RED}ERROR: Tailscale failed to start within 60 seconds. Check /userdata/system/tailscale/tailscale.log${NC}"
        cat /userdata/system/tailscale/tailscale.log
        exit 1
    fi
done

TAILSCALE_IP=$(/userdata/system/tailscale/bin/tailscale ip -4)
if [[ -z "$TAILSCALE_IP" ]]; then
    echo -e "${RED}ERROR: Could not retrieve Tailscale IP. Check logs.${NC}"
    exit 1
fi
echo -e "${GREEN}Your Tailscale IP is: $TAILSCALE_IP${NC}"
echo -e "${YELLOW}Try SSH now: ssh root@$TAILSCALE_IP${NC}"

read -r -p "Did Tailscale SSH work? (yes/no): " SSH_WORKED
if [[ "$SSH_WORKED" != "yes" ]]; then
    echo -e "${RED}ERROR: SSH failed. Do not save or reboot.${NC}"
    exit 1
fi

# Save and reboot
echo -e "${GREEN}------------------------------------------------------------------------${NC}"
echo -e "${GREEN}Tailscale and SSH verified! Safe to save changes.${NC}"
read -r -p "Save changes and reboot? (yes/no): " SAVE_CHANGES
if [[ "$SAVE_CHANGES" == "yes" ]]; then
    echo -e "${YELLOW}💾 Saving overlay...${NC}"
    batocera-save-overlay || {
        echo -e "${RED}ERROR: Failed to save overlay.${NC}"
        exit 1
    }
    echo -e "${GREEN}✅ Overlay saved. Rebooting in 5 seconds...${NC}"
    sleep 5
    reboot
else
    echo -e "${YELLOW}Changes not saved. Exiting without reboot.${NC}"
    exit 0
fi
