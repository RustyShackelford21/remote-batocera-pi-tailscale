#!/bin/bash

# --- Configuration ---
AUTH_KEY=""  # Replace with your actual AUTH KEY or leave blank
TAILSCALE_VERSION="1.80.2"  # UPDATE IF NEEDED

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

LOG_FILE="/userdata/system/tailscale/tailscale_install.log"

echo "Starting installation..." | tee -a $LOG_FILE

# --- Ensure 'tun' module is loaded ---
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    echo "Creating TUN device..." | tee -a $LOG_FILE
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# Load tun module
modprobe tun 2>/dev/null
if ! lsmod | grep -q tun; then
    echo -e "${RED}ERROR: Failed to load 'tun' module. Manual intervention required.${NC}" | tee -a $LOG_FILE
    exit 1
fi

# --- Persist 'tun' module ---
mount -o remount,rw /
if ! grep -q '^tun$' /etc/modules; then
    echo "Persisting 'tun' module to /etc/modules..." | tee -a $LOG_FILE
    echo 'tun' >> /etc/modules
fi
mount -o remount,ro /

# --- Get Local Subnet ---
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')

echo "Detected local subnet: $SUBNET" | tee -a $LOG_FILE
read -r -p "Is this subnet correct? (yes/no): " SUBNET_CONFIRM
if [[ "$SUBNET_CONFIRM" != "yes" ]]; then
    read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
fi

# --- Get Auth Key ---
if [[ -z "$AUTH_KEY" ]]; then
    read -r -p "Enter your Tailscale auth key (tskey-auth-...): " AUTH_KEY
fi
if [ -z "$AUTH_KEY" ] || ! echo "$AUTH_KEY" | grep -q '^tskey-auth-'; then
    echo -e "${RED}Invalid or missing auth key. Exiting.${NC}" | tee -a $LOG_FILE
    exit 1
fi

# --- Install Tailscale ---
mkdir -p /userdata/system/tailscale/bin
wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
tar -xf /tmp/tailscale.tgz -C /tmp
mv /tmp/tailscale_*_arm64/tailscale /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/
rm /tmp/tailscale.tgz

# --- Store Auth Key ---
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
chmod 600 /userdata/system/tailscale/authkey

# --- Startup Script ---
cat <<EOF > /userdata/system/custom.sh
#!/bin/sh
if ! pgrep -f "/userdata/system/tailscale/bin/tailscaled" > /dev/null; then
  /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale &
  sleep 10
  /userdata/system/tailscale/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey=\$(cat /userdata/system/tailscale/authkey) --hostname=batocera-1 --advertise-tags=tag:ssh-batocera-1
fi
EOF
chmod +x /userdata/system/custom.sh

# --- Start Tailscale ---
/bin/bash /userdata/system/custom.sh
sleep 5

# --- Verify Installation ---
echo "Verifying Tailscale..." | tee -a $LOG_FILE
if ! /userdata/system/tailscale/bin/tailscale status &>/dev/null; then
    echo -e "${RED}ERROR: Tailscale did not start correctly. Exiting.${NC}" | tee -a $LOG_FILE
    exit 1
fi

# Get Tailscale IP
TAILSCALE_IP=$(/userdata/system/tailscale/bin/tailscale ip -4)
echo "Your Tailscale IP: $TAILSCALE_IP" | tee -a $LOG_FILE

# Prompt user to verify SSH
echo "Try SSHing: ssh root@$TAILSCALE_IP" | tee -a $LOG_FILE
read -r -p "Did SSH work? (yes/no): " SSH_WORKED
if [[ "$SSH_WORKED" != "yes" ]]; then
    echo -e "${RED}ERROR: Tailscale SSH did not work. Exiting.${NC}" | tee -a $LOG_FILE
    exit 1
fi

# --- Save Overlay & Reboot ---
read -r -p "Do you want to save and reboot? (yes/no): " SAVE_CHANGES
if [[ "$SAVE_CHANGES" == "yes" ]]; then
    batocera-save-overlay
    echo "Rebooting in 10 seconds..." | tee -a $LOG_FILE
    sleep 10
    reboot
fi
