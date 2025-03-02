#!/bin/bash
set -e

# ... (Configuration, Colors, Functions unchanged) ...

# --- Script Start ---
echo -e "${YELLOW}🚀 Tailscale Installer for Batocera - Raspberry Pi 5${NC}"

# --- Root Check ---
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}⚠️ This script must be run as root (or with sudo).${NC}"
    exit 1
fi

# --- Check for batocera-save-overlay ---
if ! command -v batocera-save-overlay &> /dev/null; then
    echo -e "${RED}ERROR: batocera-save-overlay command not found. Overlay changes cannot be saved.${NC}"
    exit 1
fi

# --- Check for Existing Tailscale Installation ---
if command -v tailscale &> /dev/null && [ -f /var/lib/tailscale/tailscaled.state ]; then
    echo -e "${YELLOW}⚠️ Tailscale appears to be already installed and configured. Continuing may overwrite the existing configuration.${NC}"
    read -r -p "Proceed with installation? (yes/no): " PROCEED
    if [[ "$PROCEED" != "yes" ]]; then
        echo -e "${RED}❌ Installation cancelled.${NC}"
        exit 1
    fi
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

# --- Hostname Prompt ---
if [[ -z "$HOSTNAME" ]]; then
    read -r -p "Enter the desired hostname for this device (default: batocera-1): " HOSTNAME
fi
HOSTNAME=${HOSTNAME:-"batocera-1"}
echo -e "${GREEN}✅ Using hostname: $HOSTNAME${NC}"

# --- Check for Auth Key ---
if [[ -z "$AUTH_KEY" ]]; then
    echo -e "${YELLOW}🔑 Please generate a Tailscale REUSABLE and EPHEMERAL auth key:${NC}"
    echo "   Go to: https://login.tailscale.com/admin/settings/keys"
    echo "   - Reusable: ENABLED"
    echo "   - Ephemeral: ENABLED"
    echo "   - Tags: tag:ssh-$HOSTNAME"
    read -r -p "Enter your Tailscale auth key (tskey-auth-...): " AUTH_KEY
fi
if [ -z "$AUTH_KEY" ] || ! echo "$AUTH_KEY" | grep -q '^tskey-auth-'; then
    echo -e "${RED}❌ Invalid or missing auth key.${NC}"
    exit 1
fi

# --- Installation Steps ---
echo -e "${GREEN}📥 Installing Tailscale...${NC}"

mkdir -p /userdata/system/tailscale/bin /run/tailscale /userdata/system/tailscale
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
cp /userdata/system/tailscale/authkey /userdata/system/tailscale/authkey.bak
chmod 600 /userdata/system/tailscale/authkey
echo -e "${GREEN}✅ Auth key successfully stored.${NC}"

if ! wget --spider -q "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz" 2>/dev/null; then
    if ! curl -f -s -o /dev/null "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"; then
        echo -e "${RED}ERROR: Neither wget nor curl could download Tailscale. Please ensure either wget or curl is available, and that your internet connection is working.${NC}"
        exit 1
    fi
fi

if command -v wget &> /dev/null; then
    wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
elif command -v curl &> /dev/null; then
    curl -L -o /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
else
    echo -e "${RED}ERROR: Neither wget nor curl are installed. Cannot download Tailscale.${NC}"
    exit 1
fi
tar -xf /tmp/tailscale.tgz -C /tmp || { echo -e "${RED}ERROR: Failed to extract Tailscale.${NC}"; exit 1; }
rm /tmp/tailscale.tgz
mv /tmp/tailscale_*_arm64/tailscale /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/
rm -rf /tmp/tailscale_*_arm64
chmod +x /userdata/system/tailscale/bin/*

if ! grep -q '^modules-load=tun$' /boot/batocera-boot.conf; then
    echo -e "${YELLOW}➕ Adding 'tun' module to batocera-boot.conf...${NC}"
    mount -o remount,rw /boot
    echo 'modules-load=tun' >> /boot/batocera-boot.conf
    mount -o remount,ro /boot
fi
modprobe tun

touch /etc/sysctl.conf
if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv6.conf.all.forwarding = 1" /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
fi
sysctl -p || true

# --- Startup (custom.sh) ---
rm -f /tmp/tailscale_custom.sh
cat <<EOF > /tmp/tailscale_custom.sh
