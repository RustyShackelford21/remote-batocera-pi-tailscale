#!/bin/bash
#
# Tailscale Installation Script for Batocera Linux on Raspberry Pi
# Version: 1.0.16 - Enhanced with Automation, Visual Feedback, and Reboot Countdown
# Hybrid with Configurable Hostname and Tag
#

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Logging Function ---
log() {
    local color=$1
    local message=$2
    echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] $message${NC}" | tee -a /userdata/system/tailscale_install.log
}

# --- Progress Bar Function ---
show_progress() {
    local duration=$1
    local steps=10
    local sleep_time=$(echo "$duration/$steps" | bc -l 2>/dev/null || echo "$duration/$steps" | awk '{print $1}')
    echo -ne "${CYAN}["
    for ((i=0; i<$steps; i++)); do
        sleep $sleep_time
        echo -ne "#"
    done
    echo -e "]${NC}"
}

# --- Configuration ---
AUTH_KEY="${1:-}"  # Use $1 if provided, otherwise prompt later
TAILSCALE_VERSION="1.80.2"  # Fixed to match 1.0.16's stable version
DEFAULT_TAG="tag:ssh-batocera-1"  # Default tag, configurable

# --- Script Start ---
clear
echo -e "${PURPLE}=========================================================${NC}"
echo -e "${PURPLE}    Tailscale Installation for Batocera Linux     ${NC}"
echo -e "${PURPLE}=========================================================${NC}"
echo ""
log "${BLUE}" "Starting Tailscale installation..."

# --- Root Check ---
if [ "$(id -u)" -ne 0 ]; then
    log "${RED}" "⚠️ This script must be run as root"
    exit 1
fi

# --- Check for batocera-save-overlay ---
if ! command -v batocera-save-overlay &> /dev/null; then
    log "${RED}" "ERROR: batocera-save-overlay not found"
    exit 1
fi

# --- Parse Command Line Arguments ---
AUTO_CONNECT=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --authkey=*) AUTH_KEY="${1#*=}"; AUTO_CONNECT=true; shift ;;
        --authkey) AUTH_KEY="$2"; AUTO_CONNECT=true; shift 2 ;;
        --auto-connect) AUTO_CONNECT=true; shift ;;
        --uninstall)
            log "${YELLOW}" "Uninstalling Tailscale..."
            pkill -f tailscaled 2>/dev/null && log "${GREEN}" "Stopped Tailscale daemon" || log "${YELLOW}" "No Tailscale daemon running"
            [ -f /userdata/system/custom.sh ] && sed -i '/tailscale/d' /userdata/system/custom.sh && log "${GREEN}" "Removed from custom.sh"
            rm -rf /userdata/system/tailscale && log "${GREEN}" "Removed Tailscale files"
            batocera-save-overlay && log "${GREEN}" "Overlay updated—reboot to complete uninstall" || log "${RED}" "Overlay save failed"
            reboot
            exit 0
            ;;
        *) log "${RED}" "Unknown option: $1"; exit 1 ;;
    esac
done

# --- User Confirmation ---
if [ "$AUTO_CONNECT" != "true" ]; then
    read -r -p "This script will install and configure Tailscale. Continue? (yes/no): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        log "${RED}" "❌ Installation cancelled by user"
        exit 1
    fi
fi

# --- Automatic Subnet Detection ---
log "${BLUE}" "Detecting network subnet..."
show_progress 1
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
if [[ -z "$GATEWAY_IP" ]]; then
    log "${YELLOW}" "WARNING: Could not detect subnet"
    read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
else
    SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    log "${GREEN}" "✅ Detected local subnet: $SUBNET"
    echo -e "${YELLOW}Note: If another device uses this subnet, only one can advertise it in Tailscale${NC}"
    if [ "$AUTO_CONNECT" != "true" ]; then
        read -r -p "Is this subnet correct? (yes/no): " SUBNET_CONFIRM
        [[ "$SUBNET_CONFIRM" != "yes" ]] && read -r -p "Enter your subnet: " SUBNET
    fi
fi
[[ ! "$SUBNET" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]] && { log "${RED}" "Invalid subnet format"; exit 1; }

# --- Hostname Prompt ---
unset HOSTNAME  # Clear any pre-existing hostname
while [[ -z "$HOSTNAME" ]]; do
    read -r -p "Enter a hostname (e.g., batocera-test): " HOSTNAME
    [[ -z "$HOSTNAME" ]] && log "${RED}" "ERROR: Hostname cannot be empty"
done
log "${GREEN}" "✅ Using hostname: $HOSTNAME"

# --- Tag Prompt ---
TAG="$DEFAULT_TAG"
if [ "$AUTO_CONNECT" != "true" ]; then
    read -r -p "Enter Tailscale tag (default: $DEFAULT_TAG, press Enter to accept): " USER_TAG
    [ -n "$USER_TAG" ] && TAG="$USER_TAG"
fi
log "${GREEN}" "✅ Using tag: $TAG"

# --- Check for Auth Key ---
if [[ -z "$AUTH_KEY" ]]; then
    log "${YELLOW}" "🔑 Generate a reusable, ephemeral Tailscale auth key at https://login.tailscale.com/admin/settings/keys"
    read -r -p "Enter your Tailscale auth key (tskey-auth-...): " AUTH_KEY
fi
[[ -z "$AUTH_KEY" || ! "$AUTH_KEY" =~ ^tskey-auth- ]] && { log "${RED}" "❌ Invalid or missing auth key"; exit 1; }

# --- Installation Steps ---
log "${BLUE}" "📥 Installing Tailscale..."
show_progress 2
mkdir -p /userdata/system/tailscale/bin /run/tailscale
wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz" || { log "${RED}" "Download failed"; exit 1; }
gunzip -c /tmp/tailscale.tgz > /tmp/tailscale.tar || { log "${RED}" "Decompress failed"; exit 1; }
tar -xf /tmp/tailscale.tar -C /tmp || { log "${RED}" "Extract failed"; exit 1; }
mv /tmp/tailscale_*_arm64/tailscale /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/ || { log "${RED}" "Move failed"; exit 1; }
rm -rf /tmp/tailscale_* /tmp/tailscale*
chmod +x /userdata/system/tailscale/bin/*

# --- Configure Network ---
log "${BLUE}" "Configuring network..."
show_progress 1
if ! grep -q '^modules-load=tun$' /boot/batocera-boot.conf; then
    mount -o remount,rw /boot || { log "${RED}" "Mount /boot failed"; exit 1; }
    echo 'modules-load=tun' >> /boot/batocera-boot.conf
    mount -o remount,ro /boot
fi
modprobe tun || { log "${RED}" "tun module failed"; exit 1; }
mkdir -p /dev/net
[ ! -c /dev/net/tun ] && mknod /dev/net/tun c 10 200 && chmod 600 /dev/net/tun
touch /etc/sysctl.conf
grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf || echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
grep -q "net.ipv6.conf.all.forwarding = 1" /etc/sysctl.conf || echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
sysctl -p || true

# --- Start Tailscale ---
log "${BLUE}" "Starting Tailscale..."
show_progress 2
timeout 30s /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock >> /userdata/system/tailscale/boot.log 2>&1 &
sleep 15
pgrep -f tailscaled || { log "${RED}" "tailscaled failed"; exit 1; }
log "${GREEN}" "✅ tailscaled started"
timeout 30s /userdata/system/tailscale/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey="$AUTH_KEY" --hostname="$HOSTNAME" --advertise-tags="$TAG" >> /userdata/system/tailscale/tailscale_up.log 2>&1 || { log "${RED}" "Tailscale up failed"; exit 1; }
log "${GREEN}" "✅ Tailscale up executed"

TAILSCALE_IP=$(/userdata/system/tailscale/bin/tailscale ip -4 2>/dev/null)
[ -z "$TAILSCALE_IP" ] && { log "${RED}" "No Tailscale IP"; exit 1; }

# --- Persistence ---
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
chmod 600 /userdata/system/tailscale/authkey
cat > /userdata/system/custom.sh <<EOF
#!/bin/sh
mkdir -p /dev/net
[ ! -c /dev/net/tun ] && mknod /dev/net/tun c 10 200 && chmod 600 /dev/net/tun
mkdir -p /run/tailscale
echo "Starting Tailscale at \$(date)" >> /userdata/system/tailscale/boot.log
if ! pgrep -f "/userdata/system/tailscale/bin/tailscaled" > /dev/null; then
    /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock >> /userdata/system/tailscale/boot.log 2>&1 &
    sleep 15
    export TS_AUTHKEY=\$(cat /userdata/system/tailscale/authkey)
    /userdata/system/tailscale/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey="\$TS_AUTHKEY" --hostname="$HOSTNAME" --advertise-tags="$TAG" >> /userdata/system/tailscale/tailscale_up.log 2>&1
    [ \$? -eq 0 ] && echo "Tailscale started successfully at \$(date)" >> /userdata/system/tailscale/boot.log || echo "Tailscale failed at \$(date)" >> /userdata/system/tailscale/boot.log
fi
EOF
chmod +x /userdata/system/custom.sh

# --- Verify ---
log "${BLUE}" "Verifying installation..."
show_progress 1
echo -e "${GREEN}Tailscale running at IP: $TAILSCALE_IP${NC}"
/userdata/system/tailscale/bin/tailscale status
ip a | grep tailscale0
echo -e "${YELLOW}Test SSH: ssh root@$TAILSCALE_IP${NC}"
if [ "$AUTO_CONNECT" != "true" ]; then
    while true; do read -r -p "Did SSH work? (yes/no): " SSH_CONFIRM; [[ "$SSH_CONFIRM" =~ ^(yes|no)$ ]] && break; echo "Please enter 'yes' or 'no'"; done
    [[ "$SSH_CONFIRM" == "no" ]] && { log "${RED}" "SSH failed—check logs"; exit 1; }
fi

# --- Save Overlay with Countdown ---
log "${BLUE}" "Saving overlay..."
show_progress 1
batocera-save-overlay || { log "${RED}" "Overlay save failed"; exit 1; }
log "${GREEN}" "✅ Installation complete—rebooting in 5 seconds..."
for i in 5 4 3 2 1; do
    echo -e "${YELLOW}Rebooting in $i...${NC}"
    sleep 1
done
reboot