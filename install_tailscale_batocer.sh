#!/bin/bash
# Version: 1.0.1 - March 2, 2025

# --- Configuration ---
AUTH_KEY="${1:-}"  # Use $1 (first argument) if provided, otherwise prompt
TAILSCALE_VERSION="${2:-1.80.2}"  # Use $2 if provided, otherwise default
HOSTNAME="${3:-batocera-1}"  # Use $3 if provided, otherwise default

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Functions ---
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

# --- Check for batocera-save-overlay ---
if ! command -v batocera-save-overlay &> /dev/null; then
    echo -e "${RED}ERROR: batocera-save-overlay command not found. Overlay changes cannot be saved.${NC}"
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

# Create directories
mkdir -p /userdata/system/tailscale/bin /run/tailscale /userdata/system/tailscale

# Store Auth Key Immediately
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
cp /userdata/system/tailscale/authkey /userdata/system/tailscale/authkey.bak
chmod 600 /userdata/system/tailscale/authkey
echo -e "${GREEN}✅ Auth key successfully stored.${NC}"

# Download Tailscale (prefer wget, fallback to curl)
if command -v wget &> /dev/null; then
    wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
elif command -v curl &> /dev/null; then
    curl -L -o /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
else
    echo -e "${RED}ERROR: Neither wget nor curl are installed. Cannot download Tailscale.${NC}"
    exit 1
fi
if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Failed to download Tailscale. Exiting.${NC}"
    exit 1
fi

# Extract Tailscale with gunzip workaround for Batocera's tar
gunzip -c /tmp/tailscale.tgz > /tmp/tailscale.tar || { echo -e "${RED}ERROR: Failed to decompress Tailscale archive.${NC}"; exit 1; }
tar -xf /tmp/tailscale.tar -C /tmp || { echo -e "${RED}ERROR: Failed to extract Tailscale tarball.${NC}"; exit 1; }
rm /tmp/tailscale.tgz /tmp/tailscale.tar

# Move Tailscale binaries
mv /tmp/tailscale_*_arm64/tailscale /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/ || { echo -e "${RED}ERROR: Failed to move Tailscale binaries.${NC}"; exit 1; }
rm -rf /tmp/tailscale_*_arm64
chmod +x /userdata/system/tailscale/bin/* || { echo -e "${RED}ERROR: Failed to set executable permissions.${NC}"; exit 1; }

# Ensure 'tun' Module is Loaded at Boot
if ! grep -q '^modules-load=tun$' /boot/batocera-boot.conf; then
    echo -e "${YELLOW}➕ Adding 'tun' module to batocera-boot.conf for persistent loading...${NC}"
    mount -o remount,rw /boot || { echo -e "${RED}ERROR: Failed to remount /boot as writable.${NC}"; exit 1; }
    echo 'modules-load=tun' >> /boot/batocera-boot.conf
    mount -o remount,ro /boot || { echo -e "${RED}ERROR: Failed to remount /boot as read-only.${NC}"; exit 1; }
fi
modprobe tun || { echo -e "${RED}ERROR: Failed to load tun module.${NC}"; exit 1; }

# Enable IP forwarding
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
#!/bin/sh
# Ensure /run/tailscale directory exists (Batocera cleans /run on boot)
mkdir -p /run/tailscale

if ! pgrep -f "/userdata/system/tailscale/bin/tailscaled" > /dev/null; then
    /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock &
    sleep 10  # Give it time to initialize
    # Restore authkey if missing (shouldn't happen, but good to have)
    if [ ! -f /userdata/system/tailscale/authkey ]; then
        cp /userdata/system/tailscale/authkey.bak /userdata/system/tailscale/authkey
    fi
    export TS_AUTHKEY=\$(cat /userdata/system/tailscale/authkey)
    /userdata/system/tailscale/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey="\$TS_AUTHKEY" --hostname="$HOSTNAME" --advertise-tags=tag:ssh-$HOSTNAME >> /userdata/system/tailscale/tailscale_up.log 2>&1
    if [ \$? -ne 0 ]; then
        echo "Tailscale failed to start. Check log file." >> /userdata/system/tailscale/tailscale_up.log
        cat /userdata/system/tailscale/tailscale_up.log
        exit 1
    fi
fi
EOF
chmod +x /tmp/tailscale_custom.sh || { echo -e "${RED}ERROR: Failed to set custom.sh permissions.${NC}"; exit 1; }
mv /tmp/tailscale_custom.sh /userdata/system/custom.sh || { echo -e "${RED}ERROR: Failed to move custom.sh.${NC}"; exit 1; }

echo -e "${YELLOW}Starting Tailscale now—SSH may drop briefly. Reconnect if needed.${NC}"
sleep 5
/bin/bash /userdata/system/custom.sh &

# --- Verification and Prompt Before Reboot ---
echo -e "${GREEN}------------------------------------------------------------------------${NC}"
echo -e "${GREEN}Tailscale installation completed. Performing verification checks...${NC}"
echo -e "${GREEN}------------------------------------------------------------------------${NC}"

echo -e "${YELLOW}Waiting for Tailscale to start...${NC}"
for i in {1..30}; do
    if /userdata/system/tailscale/bin/tailscale status &>/dev/null; then
        echo -e "${GREEN}✅ Tailscale is running!${NC}"
        break
    fi
    sleep 2
done
/userdata/system/tailscale/bin/tailscale status
TAILSCALE_STATUS_EXIT_CODE=$?

ip a | grep tailscale0
IP_A_EXIT_CODE=$?

echo -e "${GREEN}------------------------------------------------------------------------${NC}"
if [ "$TAILSCALE_STATUS_EXIT_CODE" -ne 0 ] || [ "$IP_A_EXIT_CODE" -ne 0 ]; then
    echo -e "${RED}ERROR: Tailscale verification failed. Check the output above for errors.${NC}"
    echo -e "${RED}       Do NOT save the overlay or reboot until this is resolved.${NC}"
    echo -e "${RED}       You may need to run the tailscale up command manually.${NC}"
    exit 1
else
    echo -e "${GREEN}Tailscale appears to be running correctly.${NC}"
    echo ""
    TAILSCALE_IP=$(/userdata/system/tailscale/bin/tailscale ip -4)
    if [[ -z "$TAILSCALE_IP" ]]; then
        echo -e "${RED}ERROR: Could not retrieve Tailscale IP. Check 'tailscale status'.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Your Tailscale IP is: $TAILSCALE_IP${NC}"
    echo -e "${YELLOW}IMPORTANT: Try connecting via Tailscale SSH *NOW*, before saving the overlay.${NC}"
    echo -e "${YELLOW}Run this command from another device on your Tailscale network:${NC}"
    echo ""
    echo -e "${YELLOW}    ssh root@$TAILSCALE_IP${NC}"
    echo ""
    while true; do
        read -r -p "Did Tailscale SSH work correctly? (yes/retry/no): " SSH_WORKED
        if [[ "$SSH_WORKED" == "yes" ]]; then
            break
        elif [[ "$SSH_WORKED" == "retry" ]]; then
            echo "Retrying SSH check..."
            /userdata/system/tailscale/bin/tailscale status
        else
            echo -e "${RED}ERROR: Tailscale SSH did not work. Do NOT save the overlay or reboot.${NC}"
            exit 1
        fi
    done

    echo -e "${GREEN}------------------------------------------------------------------------${NC}"
    echo -e "${GREEN}Tailscale and SSH verification successful! It is now safe to save changes.${NC}"
    read -r -p "Do you want to save changes and reboot? THIS IS IRREVERSIBLE (yes/no): " SAVE_CHANGES

    if [[ "$SAVE_CHANGES" == "yes" ]]; then
        iptables-save | grep -v "100.64.0.0/10" | iptables-restore || { echo -e "${RED}ERROR: Failed to update iptables rules.${NC}"; exit 1; }
        iptables-save > /userdata/system/iptables.rules
        mkdir -p /userdata/system/services
        cat <<EOF > /userdata/system/services/iptablesload.sh
#!/bin/bash
iptables-restore < /userdata/system/iptables.rules
EOF
        chmod +x /userdata/system/services/iptablesload.sh
        if command -v batocera-services &> /dev/null; then
            batocera-services enable iptablesload
        else
            echo -e "${YELLOW}WARNING: batocera-services not found. iptables rules may not persist across reboots.${NC}"
        fi

        echo ""
        echo -e "${YELLOW}💾 Saving overlay...${NC}"
        batocera-save-overlay || { echo -e "${RED}ERROR: Failed to save overlay.${NC}"; exit 1; }
        echo -e "${GREEN}✅ Overlay saved successfully.${NC}"
        echo -e "${GREEN}♻️ Rebooting in 10 seconds...${NC}"
        sleep 10
        reboot
    else
        echo "Changes not saved. Exiting without rebooting."
        exit 1
    fi
fi
