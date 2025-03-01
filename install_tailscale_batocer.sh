#!/bin/bash

# --- Configuration ---
TAILSCALE_VERSION="1.80.2"  # Update if needed.
AUTH_KEY=""  # If empty, user will be prompted.

# --- Functions ---

# Function to validate subnet in CIDR notation
validate_subnet() {
    if [[ ! "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid subnet format. Exiting."
        exit 1
    fi
}

# --- Detect Local Subnet Automatically ---
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
if [[ -z "$GATEWAY_IP" ]]; then
    echo "ERROR: Could not automatically detect subnet."
    read -r -p "Enter your local subnet (e.g., 192.168.1.0/24): " SUBNET
    validate_subnet "$SUBNET"
else
    SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    echo "Detected subnet: $SUBNET"
fi

# --- Check for Auth Key ---
if [[ -z "$AUTH_KEY" ]]; then
    echo "Tailscale requires an authentication key."
    echo "Generate one at: https://login.tailscale.com/admin/settings/keys"
    read -r -p "Enter your Tailscale auth key (starts with tskey-auth-): " AUTH_KEY
    [[ -z "$AUTH_KEY" ]] && { echo "Auth key is required. Exiting."; exit 1; }
fi

# --- Ensure Directories Exist ---
mkdir -p /userdata/system/tailscale/bin
mkdir -p /userdata/system/tailscale
mkdir -p /run/tailscale

# --- Store Auth Key Securely ---
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
chmod 600 /userdata/system/tailscale/authkey

# --- Download & Install Tailscale ---
DOWNLOAD_URL="https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
MAX_RETRIES=3
for ((i=1; i<=MAX_RETRIES; i++)); do
    echo "Downloading Tailscale... Attempt $i"
    wget -O /tmp/tailscale.tgz "$DOWNLOAD_URL" && break
    [[ "$i" -eq "$MAX_RETRIES" ]] && { echo "Download failed after $MAX_RETRIES attempts. Exiting."; exit 1; }
    sleep 5
done

# Extract and Move Binaries
tar -xf /tmp/tailscale.tgz -C /tmp
mv /tmp/tailscale_*_arm64/tailscale /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/
rm -rf /tmp/tailscale*

# --- Ensure TUN Module is Loaded at Boot ---
mkdir -p /dev/net
if [[ ! -c /dev/net/tun ]]; then
    echo "Creating TUN device..."
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# --- Ensure IP Forwarding is Enabled ---
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# --- Configure Persistent Startup Script (/userdata/system/custom.sh) ---
cat <<EOF > /userdata/system/custom.sh
#!/bin/sh
# Start Tailscale at boot

# Ensure TUN exists
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# Kill any previous Tailscale processes
pkill -f tailscaled 2>/dev/null

# Start tailscaled
nohup /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state >/dev/null 2>&1 &

# Wait for Tailscale Daemon to Start
sleep 15

# Restore authkey if missing
if [ ! -f /userdata/system/tailscale/authkey ]; then
    cp /userdata/system/tailscale/authkey.bak /userdata/system/tailscale/authkey
fi

# Start Tailscale with correct settings
TS_AUTHKEY=\$(cat /userdata/system/tailscale/authkey)
/userdata/system/tailscale/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey=\$TS_AUTHKEY --hostname=batocera-1 --advertise-tags=tag:ssh-batocera-1 >> /userdata/system/tailscale/tailscale_up.log 2>&1
EOF

chmod +x /userdata/system/custom.sh

# --- Run Script Immediately ---
/bin/bash /userdata/system/custom.sh

# --- Verification Before Overlay Save ---
echo "Verifying Tailscale startup..."
sleep 5
if ! /userdata/system/tailscale/bin/tailscale status &>/dev/null; then
    echo "ERROR: Tailscale failed to start. Exiting."
    exit 1
fi

TAILSCALE_IP=$(/userdata/system/tailscale/bin/tailscale ip -4)
echo "Your Tailscale IP: $TAILSCALE_IP"
echo "Try connecting via SSH: ssh root@$TAILSCALE_IP"

# --- Save Firewall Rules ---
iptables-save | grep -v "100.64.0.0/10" | iptables-restore
iptables-save > /userdata/system/iptables.rules

# --- Create Persistent Firewall Restore ---
mkdir -p /userdata/system/services
cat <<EOF > /userdata/system/services/iptablesload.sh
#!/bin/bash
iptables-restore < /userdata/system/iptables.rules
EOF
chmod +x /userdata/system/services/iptablesload.sh
batocera-services enable iptablesload

# --- Prompt Before Saving Overlay & Rebooting ---
read -r -p "Save overlay and reboot now? (yes/no): " CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    batocera-save-overlay
    echo "Rebooting in 10 seconds..."
    sleep 10
    reboot
else
    echo "Setup complete. Reboot manually when ready."
fi
