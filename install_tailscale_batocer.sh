#!/bin/bash

# --- Configuration ---
TAILSCALE_VERSION="${2:-1.80.2}"  # Default to 1.80.2 if not specified

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Prompt for Tailscale Auth Key ---
if [[ -z "$1" ]]; then
    echo -e "${YELLOW}>>> Please provide your Tailscale auth key (from https://tailscale.com/login)${NC}"
    read -r -p "Auth Key: " AUTH_KEY
else
    AUTH_KEY="$1"
fi

if [[ -z "$AUTH_KEY" ]] || ! echo "$AUTH_KEY" | grep -q '^tskey-auth-'; then
    echo -e "${RED}❌ ERROR: Invalid or missing auth key.${NC}"
    exit 1
fi

# --- Detect Local Subnet ---
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')

echo -e "${GREEN}Detected subnet: $SUBNET${NC}"
read -r -p "Is this correct? (yes/no): " SUBNET_CONFIRM
if [[ "$SUBNET_CONFIRM" != "yes" ]]; then
    read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
fi

# --- Start Installation ---
echo -e "${GREEN}>>> Loading tun module...${NC}"
modprobe tun
if ! lsmod | grep -q tun; then
    echo "tun" >> /etc/modules
    batocera-save-overlay
    modprobe tun
fi

echo -e "${GREEN}>>> Enabling IPv4 forwarding...${NC}"
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.conf
sysctl -p

echo -e "${GREEN}>>> Downloading Tailscale $TAILSCALE_VERSION for arm64...${NC}"
wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
tar -xf /tmp/tailscale.tgz -C /tmp
mv /tmp/tailscale_*_arm64/tailscale /userdata/system/tailscale/bin/
mv /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/
chmod +x /userdata/system/tailscale/bin/*

# --- Store Auth Key ---
mkdir -p /userdata/system/tailscale
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
chmod 600 /userdata/system/tailscale/authkey

# --- Create Startup Script ---
cat <<EOF > /userdata/system/custom.sh
#!/bin/sh
if ! pgrep -f "/userdata/system/tailscale/bin/tailscaled" > /dev/null; then
    /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale &
    sleep 10
    /userdata/system/tailscale/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey=\$(cat /userdata/system/tailscale/authkey) --hostname=batocera-1 --advertise-tags=tag:ssh-batocera-1
fi
EOF
chmod +x /userdata/system/custom.sh

# --- Start Tailscale Now ---
echo -e "${GREEN}>>> Starting Tailscale...${NC}"
/userdata/system/custom.sh

# --- Verification ---
echo -e "${GREEN}>>> Verifying Tailscale setup...${NC}"
sleep 10
if /userdata/system/tailscale/bin/tailscale status; then
    echo -e "${GREEN}✅ Tailscale is running!${NC}"
else
    echo -e "${RED}❌ ERROR: Tailscale failed to start.${NC}"
    exit 1
fi

# --- Save Overlay & Reboot ---
read -r -p "Save overlay and reboot? (yes/no): " REBOOT_CONFIRM
if [[ "$REBOOT_CONFIRM" == "yes" ]]; then
    echo -e "${GREEN}>>> Saving overlay and rebooting...${NC}"
    batocera-save-overlay
    sleep 5
    reboot
else
    echo -e "${YELLOW}>>> Installation complete. Please manually reboot to apply changes.${NC}"
fi
