#!/bin/bash

# --- Configuration ---
# !! IMPORTANT !! The user should ideally pre-fill AUTH_KEY, but the script will prompt if it's empty.
AUTH_KEY=""  # REPLACE WITH YOUR AUTH KEY (or leave blank to be prompted)
TAILSCALE_VERSION="1.80.2"  #  UPDATE THIS IF NEEDED

# --- Functions ---

# Function to validate a subnet in CIDR notation
validate_subnet() {
    if [[ ! "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid subnet format. Exiting."
        exit 1
    fi
}

# --- Ensure TUN Device Exists ---
echo "Checking for /dev/net/tun..."
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    echo "Creating TUN device..."
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
else
    echo "TUN device already exists."
fi

# --- Ensure 'tun' Module is Loaded ---
echo "Loading 'tun' kernel module..."
if ! lsmod | grep -q tun; then
    modprobe tun
    if ! lsmod | grep -q tun; then
        echo "ERROR: Failed to load 'tun' module. Manual intervention may be required."
        exit 1
    fi
fi

# --- Persist TUN Module Across Reboots ---
if ! grep -q '^tun$' /etc/modules; then
    echo "Adding 'tun' module to /etc/modules for persistent loading..."
    echo 'tun' >> /etc/modules
    batocera-save-overlay  # Save changes immediately to ensure persistence
fi

# --- Automatic Subnet Detection ---

# Get the default gateway IP address
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')

if [[ -z "$GATEWAY_IP" ]]; then
    echo "ERROR: Could not automatically determine your local network subnet."
    read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
    validate_subnet "$SUBNET"
else
    # Extract the subnet from the gateway IP
    SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    echo "Detected local subnet: $SUBNET"
    
    read -r -p "Is this subnet correct? (yes/no): " SUBNET_CONFIRM
    if [[ "$SUBNET_CONFIRM" != "yes" ]]; then
        read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
        validate_subnet "$SUBNET"
    fi
fi

# --- Check for Auth Key ---
if [[ -z "$AUTH_KEY" ]]; then
    echo "----------------------------------------------------------------------------------------"
    echo "Generate a Tailscale REUSABLE, EPHEMERAL auth key:"
    echo "1. Go to https://login.tailscale.com/admin/settings/keys"
    echo "2. Click 'Generate auth key...'"
    echo "3. Enable 'Reusable' and 'Ephemeral', and set an expiration time."
    echo "4. Copy the *FULL* key (including 'tskey-auth-')."
    echo "----------------------------------------------------------------------------------------"
    read -r -p "Enter your Tailscale reusable auth key: " AUTH_KEY
    if [[ -z "$AUTH_KEY" ]]; then
        echo "ERROR: Auth key is required. Exiting."
        exit 1
    fi
fi

# --- Installation Steps ---
echo "Starting Tailscale installation..."

mkdir -p /userdata/system/tailscale/bin /userdata/system/tailscale

# Store Auth Key
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
chmod 600 /userdata/system/tailscale/authkey

# Download and Install Tailscale
wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
tar -xf /tmp/tailscale.tgz -C /tmp
rm /tmp/tailscale.tgz
mv /tmp/tailscale_*_arm64/tailscale /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/

# --- Startup Script (custom.sh) ---
cat <<EOF > /userdata/system/custom.sh
#!/bin/sh
if ! pgrep -f "/userdata/system/tailscale/bin/tailscaled" > /dev/null; then
  /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale & 
  sleep 10
  export TS_AUTHKEY=$(cat /userdata/system/tailscale/authkey)
  /userdata/system/tailscale/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey=\$TS_AUTHKEY --hostname=batocera-1 --advertise-tags=tag:ssh-batocera-1
fi
EOF
chmod +x /userdata/system/custom.sh

# --- Run custom.sh to start immediately
/bin/bash /userdata/system/custom.sh

# --- Verification ---
echo "Verifying Tailscale installation..."
for i in {1..30}; do
    if /userdata/system/tailscale/bin/tailscale status &>/dev/null; then
        echo "✅ Tailscale is running!"
        break
    fi
    sleep 2
done

# Get Tailscale IP Address
TAILSCALE_IP=$(/userdata/system/tailscale/bin/tailscale ip -4)
if [[ -z "$TAILSCALE_IP" ]]; then
    echo "ERROR: Could not retrieve Tailscale IP. Check 'tailscale status'."
    exit 1
fi

echo "Your Tailscale IP is: $TAILSCALE_IP"
echo "Try SSHing via Tailscale: ssh root@$TAILSCALE_IP"

# --- Save Overlay and Reboot ---
read -r -p "Tailscale and SSH verification successful! Do you want to save and reboot? (yes/no): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Saving overlay..."
    batocera-save-overlay
    echo "Rebooting in 10 seconds..."
    sleep 10
    reboot
else
    echo "Changes not saved. Exiting."
    exit 1
fi
