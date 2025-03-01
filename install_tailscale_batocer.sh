#!/bin/bash

# --- Configuration ---
AUTH_KEY="${1:-}"  # Allow passing auth key as argument
TAILSCALE_VERSION="${2:-1.80.2}"  # Allow passing version as argument
INSTALL_DIR="/userdata/system/tailscale"

# --- Functions ---
error_exit() {
    echo "❌ ERROR: $1"
    exit 1
}

# --- Check if running as root ---
if [[ $EUID -ne 0 ]]; then
   error_exit "This script must be run as root."
fi

# --- Ensure TUN Module is Loaded ---
echo ">>> Loading tun module..."
if ! lsmod | grep -q "^tun"; then
    modprobe tun
    if ! lsmod | grep -q "^tun"; then
        error_exit "Failed to load tun module."
    fi
fi

# --- Enable IP Forwarding ---
echo ">>> Enabling IPv4 forwarding..."
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.conf
sysctl -p

# --- Detect Local Network Subnet ---
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
if [[ -z "$GATEWAY_IP" ]]; then
    error_exit "Could not determine local subnet. Please enter manually."
fi

SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
echo "Detected subnet: $SUBNET"

# --- Confirm Subnet ---
read -r -p "Is this subnet correct? (yes/no): " CONFIRM_SUBNET
if [[ "$CONFIRM_SUBNET" != "yes" ]]; then
    read -r -p "Enter your local subnet (e.g., 192.168.50.0/24): " SUBNET
fi

# --- Request Tailscale Auth Key ---
if [[ -z "$AUTH_KEY" ]]; then
    echo ">>> Please provide your Tailscale auth key (from https://tailscale.com/login)"
    read -r -p "Auth Key: " AUTH_KEY
fi
if [[ -z "$AUTH_KEY" || ! "$AUTH_KEY" =~ ^tskey-auth- ]]; then
    error_exit "Invalid or missing auth key."
fi

# --- Download and Install Tailscale ---
echo ">>> Downloading Tailscale ${TAILSCALE_VERSION} for arm64..."
mkdir -p "$INSTALL_DIR/bin"
wget -q -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz" || error_exit "Failed to download Tailscale."
tar -xf /tmp/tailscale.tgz -C /tmp || error_exit "Failed to extract Tailscale."
mv /tmp/tailscale_*_arm64/tailscale /tmp/tailscale_*_arm64/tailscaled "$INSTALL_DIR/bin/"
rm -rf /tmp/tailscale*

# --- Setup Custom Startup Script ---
echo ">>> Configuring startup script..."
cat <<EOF > /userdata/system/custom.sh
#!/bin/sh
if ! pgrep -f "$INSTALL_DIR/bin/tailscaled" > /dev/null; then
  $INSTALL_DIR/bin/tailscaled --state=$INSTALL_DIR/tailscaled.state &
  sleep 10
  $INSTALL_DIR/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey=$AUTH_KEY --hostname=batocera-1 --advertise-tags=tag:ssh-batocera-1
fi
EOF
chmod +x /userdata/system/custom.sh

# --- Start Tailscale Now ---
echo ">>> Starting Tailscale..."
/userdata/system/custom.sh

# --- Verify Installation ---
echo ">>> Checking Tailscale status..."
sleep 5
if ! $INSTALL_DIR/bin/tailscale status; then
    error_exit "Tailscale failed to start."
fi

# --- Final Confirmation Before Saving ---
echo ">>> Tailscale is running! Your Tailscale IP is:"
$INSTALL_DIR/bin/tailscale ip -4

read -r -p "Do you want to save changes and reboot? (yes/no): " SAVE_CHANGES
if [[ "$SAVE_CHANGES" == "yes" ]]; then
    echo "Saving overlay..."
    batocera-save-overlay
    echo "Rebooting in 5 seconds..."
    sleep 5
    reboot
else
    echo "Installation complete. Please reboot manually."
fi
