#!/bin/bash

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# --- Instructions for Auth Key Generation ---
echo "----------------------------------------------------------------------------------------"
echo "Before proceeding, you need to generate a Tailscale REUSABLE auth key."
echo "Follow these steps CAREFULLY:"
echo "1. Go to https://login.tailscale.com/admin/settings/keys in your web browser."
echo "2. Click the 'Generate auth key...' button."
echo "3. Select the following options:"
echo "   - Reusable: ENABLED (checked)"
echo "   - Ephemeral: ENABLED (checked) - Recommended for better security and cleanup."
echo "   - Description: Enter a description (e.g., 'Batocera Pi - Reusable')."
echo "   - Expiration: Choose your desired expiration (e.g., 90 days).  Set a reminder!"
echo "   - Tags:  Enter 'tag:ssh-batocera-1' (This is VERY important for SSH access control)."
echo "4. Click 'Generate key'."
echo "5. IMMEDIATELY copy the *FULL* key (INCLUDING the 'tskey-auth-' prefix)."
echo "   The key will only be displayed ONCE.  Treat it like a password."
echo "----------------------------------------------------------------------------------------"
read -r -p "Press Enter when you have generated and copied the key..." </dev/tty

# --- Configuration (Prompt for user input) ---

# Auth Key
read -r -p "Enter your Tailscale reusable auth key (with tskey-auth- prefix): " AUTH_KEY
if [[ -z "$AUTH_KEY" ]]; then
  echo "ERROR: Auth key is required.  Exiting."
  exit 1
fi
if [[ ! "$AUTH_KEY" =~ ^tskey-auth-[a-zA-Z0-9-]+$ ]]; then
  echo "ERROR: Invalid auth key format.  It should start with 'tskey-auth-'. Exiting."
  exit 1
fi

# --- Automatic Subnet Detection ---

# Get the default gateway IP address
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')

if [[ -z "$GATEWAY_IP" ]]; then
    echo "ERROR: Could not automatically determine your local network subnet."
    echo "       You will need to enter it manually."
    read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
    # Validate subnet
    if [[ ! "$SUBNET" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
      echo "ERROR: Invalid subnet format. Exiting."
      exit 1
    fi
else
  # Extract the subnet from the gateway IP (assuming a /24 subnet mask)
  SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
  echo "Detected local subnet: $SUBNET"
fi

# --- Check for Internet Connectivity ---
echo "Checking for internet connectivity..."
if ! ping -c 1 google.com >/dev/null 2>&1; then
  echo "ERROR: No internet connection detected. Exiting."
  exit 1
fi

# --- Installation Steps ---

echo "Starting Tailscale installation..."

# Create directories
mkdir -p /userdata/system/tailscale
mkdir -p /userdata/system/scripts
mkdir -p /root/.ssh # Ensures that this is made *before* the grep.

# Download Tailscale
cd /userdata/system
if command_exists wget; then
    wget -O tailscale.tgz https://pkgs.tailscale.com/stable/tailscale_1.80.2_arm64.tgz
elif command_exists curl; then
    curl -L -o tailscale.tgz https://pkgs.tailscale.com/stable/tailscale_1.80.2_arm64.tgz
else
    echo "ERROR: Neither wget nor curl is installed. Cannot download Tailscale."
    exit 1
fi


# Extract Tailscale
tar -xf tailscale.tgz -C /userdata/system/tailscale --strip-components=1
if [ $? -ne 0 ]; then
  echo "ERROR: Failed to extract Tailscale. Exiting."
  exit 1
fi
rm tailscale.tgz

# --- Store Auth Key Persistently ---
echo "$AUTH_KEY" > /userdata/system/tailscale/auth_key
chmod 600 /userdata/system/tailscale/auth_key

# --- SSH Key Setup ---
echo "Setting up SSH key-based authentication..."

# Add the *provided* public key to authorized_keys, but only if it's not already there.
if ! grep -q "batocera-tailscale" /root/.ssh/authorized_keys; then
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINPlPUBLrsea+vOb4E5aGwiBKDYAnoytPJHhZio76jeQ batocera-tailscale" >> /root/.ssh/authorized_keys
fi
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
# --- End of SSH Key Setup ---


# Create the startup script
cat <<EOF > /userdata/system/scripts/tailscale_start.sh
#!/bin/bash

# Stop any running instance
pkill tailscaled

# Ensure /dev/net directory exists
mkdir -p /dev/net

# Ensure the TUN device exists
if [ ! -c /dev/net/tun ]; then
  mknod /dev/net/tun c 10 200
  chmod 600 /dev/net/tun
fi

# Enable IP forwarding (Persistent) using /userdata/system/sysctl.conf.  Already done in main script.

# Start Tailscale, capturing output for debugging (to persistent location)
/userdata/system/tailscale/tailscaled --statedir=/userdata/system/tailscale > /userdata/system/tailscale/tailscaled.log 2>&1 &
PID=\$!

echo "Waiting for tailscaled to start (PID: \$PID)..."
sleep 5

# Check if tailscaled is running
if ! ps -p "\$PID" > /dev/null; then
    echo "ERROR: tailscaled failed to start. Check /userdata/system/tailscale/tailscaled.log"
    exit 1
fi

# Load stored auth key
AUTH_KEY=\$(cat /userdata/system/tailscale/auth_key)

# Run tailscale up with retries
for i in {1..5}; do
    /userdata/system/tailscale/tailscale up --advertise-routes=\$SUBNET --accept-routes --authkey=\$AUTH_KEY --advertise-tags=tag:ssh-batocera-1 --ssh
    if [ \$? -eq 0 ]; then
        echo "Tailscale successfully started."
        exit 0
    fi
    echo "Retrying tailscale up in 5 seconds..."
    sleep 5
done

echo "ERROR: tailscale up failed after multiple attempts."
exit 1
EOF

# Make the scripts executable
chmod +x /userdata/system/scripts/tailscale_start.sh

# --- Add Startup Script to custom.sh (Avoiding Duplicates) ---
# Ensure custom.sh exists before grepping it
touch /userdata/system/custom.sh
if ! grep -q "/userdata/system/scripts/tailscale_start.sh &" /userdata/system/custom.sh; then
    echo "/userdata/system/scripts/tailscale_start.sh &" >> /userdata/system/custom.sh
fi
chmod +x /userdata/system/custom.sh

# --- Verification Steps (Before Reboot) ---
echo "------------------------------------------------------------------------"
echo "Tailscale installation completed.  Performing verification checks..."
echo "------------------------------------------------------------------------"

# Check Tailscale Status
/userdata/system/tailscale/tailscale status
if [ $? -ne 0 ]; then
  echo "ERROR: Tailscale status check failed.  Tailscale may not be running."
  echo "       Do NOT save the overlay or reboot until this is resolved."
  exit 1
fi

# Check for tailscale0 interface
ip a | grep tailscale0
if [ $? -ne 0 ]; then
  echo "ERROR: tailscale0 interface not found. Tailscale may not be configured correctly."
  echo "       Do NOT save the overlay or reboot until this is resolved."
  exit 1
fi

#Check /dev/net/tun
ls -l /dev/net/tun
if [ $? -ne 0 ]; then
  echo "ERROR: /dev/net/tun not created properly"
    echo "       Do NOT save the overlay or reboot until this is resolved."
  exit 1
fi

#Check IP Forwarding using the Batocera-specific path, and create it if it doesn't exist
if [ ! -f /userdata/system/sysctl.conf ]; then
    touch /userdata/system/sysctl.conf
fi

if ! grep -q "net.ipv4.ip_forward = 1" /userdata/system/sysctl.conf; then
    echo 'net.ipv4.ip_forward = 1' >> /userdata/system/sysctl.conf
    echo "ERROR: ipv4 forwarding not enabled.  It has been enabled now, but may not be active until reboot."
fi
if ! grep -q "net.ipv6.conf.all.forwarding = 1" /userdata/system/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding = 1' >> /userdata/system/sysctl.conf
    echo "ERROR: ipv6 forwarding not enabled. It has been enabled now, but may not be active until reboot."
fi
sysctl -p /userdata/system/sysctl.conf

# Check custom.sh
if [ ! -f /userdata/system/custom.sh ] || [ ! -x /userdata/system/custom.sh ];
then
    echo "ERROR: /userdata/system/custom.sh is missing or is not executable."
    echo "       Do NOT save the overlay or reboot until this is resolved."
    exit 1
fi
if ! grep -q "/userdata/system/scripts/tailscale_start.sh &" /userdata/system/custom.sh;
then
     echo "ERROR: /userdata/system/custom.sh does not include the startup command."
     echo "       Do NOT save the overlay or reboot until this is resolved."
     exit 1
fi

# Check tailscale_start.sh
if [ ! -f /userdata/system/scripts/tailscale_start.sh ] || [ ! -x /userdata/system/scripts/tailscale_start.sh ];
then
    echo "ERROR: /userdata/system/scripts/tailscale_start.sh is missing or is not executable."
    echo "       Do NOT save the overlay or reboot until this is resolved."
    exit 1
fi

# --- Instructions for Using the Private Key---
echo "------------------------------------------------------------------------"
echo "All checks passed. Tailscale appears to be installed and running correctly."
echo "It is now safe to save the overlay and reboot."
echo ""
echo "IMPORTANT: You have already generated an SSH key pair on your Windows PC."
echo "          You will use the PRIVATE key from that pair to connect via SSH."
echo ""
echo "To connect via SSH from your Windows PC, use the following command:"
echo ""
TAILSCALE_IP=$(/userdata/system/tailscale/tailscale ip -4)
if [[ -z "$TAILSCALE_IP" ]]; then
  echo "ERROR: Could not determine Tailscale IP. Check manually in Tailscale Admin Console."
else
  echo "  ssh -i C:\\Users\\<your_username>\\.ssh\\id_ed25519 root@${TAILSCALE_IP}"
fi
echo ""
echo "Replace '<your_username>' with your actual Windows username."

echo "------------------------------------------------------------------------"

read -r -p "Have you generated the SSH key on your Windows PC and do you understand how to use it (yes/no)? " KEY_READY

if [[ "$KEY_READY" != "yes" ]]; then
  echo "ERROR: You MUST generate and understand how to use the SSH key before rebooting."
  echo "       Exiting without saving the overlay or rebooting."
  exit 1
fi

# --- Save Overlay and Reboot (Only if Key Downloaded) ---

echo "------------------------------------------------------------------------"
echo "Saving overlay and rebooting in 10 seconds..."
echo "------------------------------------------------------------------------"
batocera-save-overlay
sleep 10
reboot
