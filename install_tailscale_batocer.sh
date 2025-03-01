#!/bin/bash

# --- Configuration ---
# !! IMPORTANT !! Check https://pkgs.tailscale.com/stable/ for the latest arm64 version!
TAILSCALE_VERSION="${1:-1.80.2}"  # Get version from first argument, default to 1.62.0

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Script Start ---

echo -e "${YELLOW}🚀 Tailscale Installer for Batocera (DEBUG MODE) - Raspberry Pi 5${NC}"

# --- Root Check ---
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}⚠️  This script must be run as root (or with sudo).${NC}"
    exit 1
fi

# --- User Confirmation ---
if [ -z "$CONFIRM_INSTALL" ] || [ "$CONFIRM_INSTALL" != "yes" ]; then
  read -r -p "This script will install Tailscale and configure it to start on boot (DEBUG MODE). Continue? (yes/no): " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo -e "${RED}❌ Installation cancelled by user.${NC}"
    exit 1
  fi
fi

# --- Automatic Subnet Detection ---
# Get the default gateway IP address
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')

if [[ -z "$GATEWAY_IP" ]]; then
    echo -e "${YELLOW}WARNING: Could not automatically determine your local network subnet.${NC}"
    read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
    validate_subnet "$SUBNET"
else
    # Extract the subnet from the gateway IP (assuming a /24 subnet mask)
    SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    echo -e "${GREEN}✅ Detected local subnet: $SUBNET${NC}"

    # --- Subnet Confirmation ---
    read -r -p "Is this subnet correct? (yes/no): " SUBNET_CONFIRM
    if [[ "$SUBNET_CONFIRM" != "yes" ]]; then
        read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
        validate_subnet "$SUBNET"
    fi
fi

# --- Auth Key Input ---
echo -e "${YELLOW}🔑 Please generate a Tailscale REUSABLE and EPHEMERAL auth key:${NC}"
echo "   Go to: https://login.tailscale.com/admin/settings/keys"
echo "   - Reusable: ENABLED"
echo "   - Ephemeral: ENABLED"
echo "   - Tags: tag:ssh-batocera-1"
read -r -p "Enter your Tailscale auth key (tskey-auth-...): " AUTH_KEY

if [ -z "$AUTH_KEY" ] || ! echo "$AUTH_KEY" | grep -q '^tskey-auth-'; then
    echo -e "${RED}❌ Invalid or missing auth key.${NC}"
    exit 1
fi

# --- Installation Steps ---

# Create directories
mkdir -p /userdata/system/tailscale/bin
mkdir -p /run/tailscale
mkdir -p /userdata/system/tailscale
mkdir -p /userdata/system/scripts

# Store Auth Key
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
cp /userdata/system/tailscale/authkey /userdata/system/tailscale/authkey.bak
chmod 600 /userdata/system/tailscale/authkey

# Download and Extract Tailscale
wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz" 2> /dev/null
if [ $? -ne 0 ]; then
  echo -e "${RED}❌ Failed to download Tailscale. Check your internet connection.${NC}"
  exit 1
fi

tar -xf /tmp/tailscale.tgz -C /tmp 2> /dev/null
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Failed to extract Tailscale.${NC}"
    exit 1
fi
rm /tmp/tailscale.tgz

mv /tmp/tailscale_*_arm64/tailscale /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/
rm -rf /tmp/tailscale_*_arm64
chmod +x /userdata/system/tailscale/bin/*

# --- Ensure 'tun' Module is Loaded at Boot ---
if ! grep -q '^tun$' /etc/modules; then
  echo -e "${YELLOW}➕ Adding 'tun' module to /etc/modules for persistent loading...${NC}"
  mount -o remount,rw /  # Make the root filesystem writable
  echo 'tun' >> /etc/modules
  mount -o remount,ro /  # Remount as read-only
fi
modprobe tun # Load immediately

# --- IP Forwarding ---
if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
fi
if ! grep -q "net.ipv6.conf.all.forwarding = 1" /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
fi
sysctl -p

# --- Create custom.sh (DEBUG MODE - ONLY tailscaled) ---
cat <<EOF > /userdata/system/custom.sh
#!/bin/sh

# Ensure /dev/net and /dev/net/tun exist
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# Start tailscaled (redirect output to a log file)
/userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale >> /userdata/system/tailscale/tailscaled.log 2>&1 &

# That's it! We're *NOT* running tailscale up here.
EOF
chmod +x /userdata/system/custom.sh

# --- Verification and Reboot ---

echo -e "${GREEN}------------------------------------------------------------------------${NC}"
echo -e "${GREEN}Tailscale installation (DEBUG MODE) completed.${NC}"
echo -e "${GREEN}The system will now reboot.  After reboot, connect via SSH and check:${NC}"
echo -e "${GREEN}  1. ps aux | grep tailscaled  (should show a tailscaled process)${NC}"
echo -e "${GREEN}  2. cat /userdata/system/tailscale/tailscaled.log (examine the log file)${NC}"
echo -e "${GREEN}  3. ls -l /dev/net/tun (verify the device node exists)${NC}"
echo -e "${YELLOW}If tailscaled is NOT running, or the log file shows errors, DO NOT proceed.${NC}"
echo -e "${YELLOW}Report the output of those commands for further debugging.${NC}"
echo -e "${GREEN}------------------------------------------------------------------------${NC}"

#Clean up old iptables
#Remove potentially conflicting iptables rules.
iptables-save | grep -v "100.64.0.0/10" | iptables-restore
iptables-save > /userdata/system/iptables.rules
cat <<EOF > /userdata/system/services/iptablesload.sh
#!/bin/bash
iptables-restore < /userdata/system/iptables.rules
EOF
chmod +x /userdata/system/services/iptablesload.sh
batocera-services enable iptablesload
batocera-save-overlay
sleep 5
reboot
