#!/bin/bash
# Version: 1.0.18 - March 3, 2025

# --- Configuration ---
AUTH_KEY="${1:-}"  # Use $1 if provided, otherwise prompt
TAILSCALE_VERSION="${2:-1.80.2}"  # Use $2 if provided, otherwise default

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
    read -r -p "This script will install and configure Tailscale on your Batocera system with local SSH access. Continue? (yes/no): " CONFIRM
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
    echo -e "${YELLOW}Note: If another device (e.g., batocera-2) uses this subnet, only one can advertise it in Tailscale.${NC}"
    read -r -p "Is this subnet correct? (yes/no): " SUBNET_CONFIRM
    if [[ "$SUBNET_CONFIRM" != "yes" ]]; then
        read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
        validate_subnet "$SUBNET"
    fi
fi

# --- Hostname Prompt (Mandatory) ---
HOSTNAME="${3:-}"
while [[ -z "$HOSTNAME" ]]; do
    read -r -p "Enter a hostname for this device (e.g., batocera-test): " HOSTNAME
    if [[ -z "$HOSTNAME" ]]; then
        echo -e "${RED}ERROR: Hostname cannot be empty. Please provide a hostname.${NC}"
    fi
done
echo -e "${GREEN}✅ Using hostname: $HOSTNAME${NC}"

# --- Check for Auth Key ---
if [[ -z "$AUTH_KEY" ]]; then
    echo -e "${YELLOW}🔑 Please generate a Tailscale REUSABLE and EPHEMERAL auth key:${NC}"
    echo "   Go to: https://login.tailscale.com/admin/settings/keys"
    echo "   - Reusable: ENABLED"
    echo "   - Ephemeral: ENABLED"
    echo "   - Tag: tag:ssh-batocera-1 (default, enter custom tag if needed during setup)"
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

gunzip -c /tmp/tailscale.tgz > /tmp/tailscale.tar || { echo -e "${RED}ERROR: Failed to decompress Tailscale archive.${NC}"; exit 1; }
tar -xf /tmp/tailscale.tar -C /tmp || { echo -e "${RED}ERROR: Failed to extract Tailscale tarball.${NC}"; exit 1; }
rm /tmp/tailscale.tgz /tmp/tailscale.tar
mv /tmp/tailscale_*_arm64/tailscale /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/ || { echo -e "${RED}ERROR: Failed to move Tailscale binaries.${NC}"; exit 1; }
rm -rf /tmp/tailscale_*_arm64
chmod +x /userdata/system/tailscale/bin/* || { echo -e "${RED}ERROR: Failed to set executable permissions.${NC}"; exit 1; }

if ! grep -q '^modules-load=tun$' /boot/batocera-boot.conf; then
    echo -e "${YELLOW}➕ Adding 'tun' module to batocera-boot.conf...${NC}"
    mount -o remount,rw /boot || { echo -e "${RED}ERROR: Failed to remount /boot as writable.${NC}"; exit 1; }
    echo 'modules-load=tun' >> /boot/batocera-boot.conf
    mount -o remount,ro /boot || { echo -e "${RED}ERROR: Failed to remount /boot as read-only.${NC}"; exit 1; }
fi
modprobe tun || { echo -e "${RED}ERROR: Failed to load tun module.${NC}"; exit 1; }

mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

touch /etc/sysctl.conf
if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv6.conf.all.forwarding = 1" /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
fi
sysctl -p || true

# --- Start Tailscale Directly ---
echo -e "${YELLOW}Starting Tailscale...${NC}"
rm -f /userdata/system/tailscale/boot.log /userdata/system/tailscale/tailscale_up.log

# Start tailscaled with timeout
timeout 30s /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock >> /userdata/system/tailscale/boot.log 2>&1 &
sleep 15  # Give tailscaled time to start
if ! pgrep -f "/userdata/system/tailscale/bin/tailscaled" > /dev/null; then
    echo -e "${RED}ERROR: tailscaled failed to start. Check logs:${NC}"
    cat /userdata/system/tailscale/boot.log
    exit 1
fi
echo -e "${GREEN}✅ tailscaled started successfully${NC}"

# Initial tailscale up attempt with default tag
timeout 30s /userdata/system/tailscale/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey="$AUTH_KEY" --hostname="$HOSTNAME" --advertise-tags=tag:ssh-batocera-1 >> /userdata/system/tailscale/tailscale_up.log 2>&1
if [ $? -ne 0 ]; then
    sleep 5  # Allow logs to settle
    if grep -q "requested tags.*are invalid or not permitted" /userdata/system/tailscale/tailscale_up.log; then
        echo -e "${YELLOW}Tag 'tag:ssh-batocera-1' failed - auth key may require a different tag.${NC}"
        read -r -p "Enter the correct tag (e.g., tag:ssh-custom, or leave blank for no tags): " USER_TAG
        /userdata/system/tailscale/bin/tailscale down 2>/dev/null
        sleep 5
        if [ -n "$USER_TAG" ]; then
            timeout 30s /userdata/system/tailscale/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey="$AUTH_KEY" --hostname="$HOSTNAME" --advertise-tags="$USER_TAG" >> /userdata/system/tailscale/tailscale_up.log 2>&1
        else
            timeout 30s /userdata/system/tailscale/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey="$AUTH_KEY" --hostname="$HOSTNAME" >> /userdata/system/tailscale/tailscale_up.log 2>&1
        fi
    fi
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: Tailscale failed to start. Check logs:${NC}"
        if [ -f /userdata/system/tailscale/tailscale_up.log ]; then
            cat /userdata/system/tailscale/tailscale_up.log
        else
            echo "No tailscale_up.log found."
        fi
        if [ -f /userdata/system/tailscale/boot.log ]; then
            cat /userdata/system/tailscale/boot.log
        else
            echo "No boot.log found."
        fi
        exit 1
    fi
fi
echo -e "${GREEN}✅ Tailscale up command executed${NC}"

# Fetch IP after startup
TAILSCALE_IP=$(/userdata/system/tailscale/bin/tailscale ip -4 2>/dev/null)
if [ -z "$TAILSCALE_IP" ]; then
    echo -e "${RED}ERROR: Could not fetch Tailscale IP. Check logs:${NC}"
    if [ -f /userdata/system/tailscale/tailscale_up.log ]; then
        cat /userdata/system/tailscale/tailscale_up.log
    else
        echo "No tailscale_up.log found."
    fi
    if [ -f /userdata/system/tailscale/boot.log ]; then
        cat /userdata/system/tailscale/boot.log
    else
        echo "No boot.log found."
    fi
    exit 1
fi

# --- Enable Local SSH ---
echo -e "${YELLOW}Configuring local SSH access...${NC}"
iptables -F  # Clear existing rules to avoid conflicts
iptables -A INPUT -i wlan0 -p tcp --dport 22 -j ACCEPT
iptables-save > /userdata/system/iptables.rules

# --- Verify Tailscale is Running ---
echo -e "${GREEN}------------------------------------------------------------------------${NC}"
echo -e "${GREEN}Verifying Tailscale installation...${NC}"
echo -e "${GREEN}------------------------------------------------------------------------${NC}"
echo -e "${GREEN}Tailscale is running with IP: $TAILSCALE_IP${NC}"

# Check status and interface for debug
/userdata/system/tailscale/bin/tailscale status
ip a | grep tailscale0

echo -e "${YELLOW}Test SSH now via Tailscale IP from another device:${NC}"
echo -e "${YELLOW}    ssh root@$TAILSCALE_IP${NC}"
echo -e "${YELLOW}Then, from a device on the same LAN (192.168.50.x), test local SSH:${NC}"
echo -e "${YELLOW}    ssh root@192.168.50.5${NC}"
while true; do
    read -r -p "Did both SSH tests work? (yes/no): " SSH_CONFIRM
    if [[ "$SSH_CONFIRM" == "yes" ]]; then
        break
    elif [[ "$SSH_CONFIRM" == "no" ]]; then
        echo -e "${RED}ERROR: SSH failed. Check Tailscale status and logs:${NC}"
        /userdata/system/tailscale/bin/tailscale status
        if [ -f /userdata/system/tailscale/tailscale_up.log ]; then
            cat /userdata/system/tailscale/tailscale_up.log
        else
            echo "No tailscale_up.log found."
        fi
        if [ -f /userdata/system/tailscale/boot.log ]; then
            cat /userdata/system/tailscale/boot.log
        else
            echo "No boot.log found."
        fi
        echo -e "${RED}Resolve issues before saving.${NC}"
        exit 1
    else
        echo "Please enter 'yes' or 'no'."
    fi
done

# --- Write custom.sh for reboot persistence ---
cat <<EOF > /userdata/system/custom.sh
#!/bin/sh
# Ensure /dev/net and /dev/net/tun exist
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi
# Ensure /run/tailscale exists
mkdir -p /run/tailscale
echo "Starting Tailscale at \$(date)" >> /userdata/system/tailscale/boot.log

if ! pgrep -f "/userdata/system/tailscale/bin/tailscaled" > /dev/null; then
    /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock >> /userdata/system/tailscale/boot.log 2>&1 &
    sleep 15  # Give tailscaled time to start
    if [ ! -f /userdata/system/tailscale/authkey ]; then
        cp /userdata/system/tailscale/authkey.bak /userdata/system/tailscale/authkey
    fi
    export TS_AUTHKEY=\$(cat /userdata/system/tailscale/authkey)
    /userdata/system/tailscale/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey="\$TS_AUTHKEY" --hostname="$HOSTNAME" --advertise-tags=tag:ssh-batocera-1 >> /userdata/system/tailscale/tailscale_up.log 2>&1
    if [ \$? -ne 0 ]; then
        echo "Tailscale failed to start at \$(date). Check log file." >> /userdata/system/tailscale/tailscale_up.log
        cat /userdata/system/tailscale/tailscale_up.log >> /userdata/system/tailscale/boot.log
        exit 1
    else
        echo "Tailscale started successfully at \$(date)" >> /userdata/system/tailscale/boot.log
    fi
fi
EOF
chmod +x /userdata/system/custom.sh || { echo -e "${RED}ERROR: Failed to set custom.sh permissions.${NC}"; exit 1; }

echo -e "${GREEN}------------------------------------------------------------------------${NC}"
echo -e "${GREEN}Tailscale and local SSH installation verified!${NC}"
read -r -p "Save changes and reboot? THIS IS IRREVERSIBLE (yes/no): " SAVE_CHANGES
if [[ "$SAVE_CHANGES" == "yes" ]]; then
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

    echo -e "${YELLOW}💾 Saving overlay...${NC}"
    batocera-save-overlay || { echo -e "${RED}ERROR: Failed to save overlay.${NC}"; exit 1; }
    echo -e "${GREEN}✅ Overlay saved successfully.${NC}"
    echo -e "${GREEN}♻️ Rebooting now...${NC}"
    reboot
else
    echo -e "${YELLOW}Changes not saved. Exiting without rebooting.${NC}"
    echo -e "${YELLOW}Run '/bin/bash /userdata/system/custom.sh' to restart Tailscale if needed.${NC}"
    exit 0
fi
