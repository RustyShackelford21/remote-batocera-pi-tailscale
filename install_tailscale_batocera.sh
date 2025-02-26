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
echo "   The key will only be displayed ONCE.  Treat it like a password."
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

# --- Check if Tailscale is already installed ---
#Since we are in /tmp, we are going to skip this part.
#if command_exists /userdata/system/tailscale/tailscaled; then
#  echo "Tailscale appears to be already installed in /userdata/system/tailscale."
#  echo "If you want to reinstall, please remove that directory first."
#  exit 0
#fi

# --- Installation Steps ---

echo "Starting Tailscale installation..."

# Create directories
mkdir -p /userdata/system/tailscale
mkdir -p /userdata/system/scripts
mkdir -p /root/.ssh # Ensures that this is made.

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

# --- SSH Key Setup (Modified) ---
echo "Setting up SSH key-based authentication..."

# Add the *provided* public key to authorized_keys.
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINPlPUBLrsea+vOb4E5aGwiBKDYAnoytPJHhZio76jeQ batocera-tailscale" >> /root/.ssh/authorized_keys

chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
# --- End of SSH Key Setup ---


# Create the startup script
cat <<EOF > /userdata/system/scripts/tailscale_start.sh
#!/bin/bash

# Ensure /dev/net directory exists
mkdir -p /dev/net

# Ensure the TUN device exists
if [ ! -c /dev/net/tun ]; then
  mknod /dev/net/tun c 10 200
  chmod 600 /dev/net/tun
fi

# Enable IP forwarding (check before adding)
if ! grep -q "net.ipv4.ip_forward = 1" /userdata/system/sysctl.conf; then
    echo 'net.ipv4.ip_forward = 1' | tee -a /userdata/system/sysctl.conf
fi
if ! grep -q "net.ipv6.conf.all.forwarding = 1" /userdata/system/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /userdata/system/sysctl.conf
fi
sysctl -p /userdata/system/sysctl.conf

# Start Tailscale, capturing output for debugging
/userdata/system/tailscale/tailscaled --statedir=/userdata/system/tailscale > /tmp/tailscale_test/tailscaled.log 2>&1 &
#                                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Redirect output to a log file
PID=$!  # Get the PID of tailscaled

echo "Waiting for tailscaled to start (PID: $PID)..."
sleep 10  # Increased sleep for more reliable startup

# Check if tailscaled is still running
if ! ps -p "$PID" > /dev/null; then
    echo "ERROR: tailscaled failed to start."
    echo "Check /tmp/tailscale_test/tailscaled.log for details." # Tell the user where to find the log
    exit 1
fi
/userdata/system/tailscale/tailscale up --advertise-routes=$SUBNET --accept-routes --authkey=$AUTH_KEY --advertise-tags=tag:ssh-batocera-1 --ssh

exit 0
EOF

# Make the scripts executable
chmod +x /userdata/system/scripts/tailscale_start.sh

# Add to custom.sh
cat <<EOF > /userdata/system/custom.sh
/userdata/system/scripts/tailscale_start.sh &
EOF
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

#Check IP Forwarding
if ! grep -q "net.ipv4.ip_forward = 1" /userdata/system/sysctl.conf; then
    echo "ERROR: ipv4 forwarding not enabled"
    echo "       Do NOT save the overlay or reboot until this is resolved."
    exit 1
fi

if ! grep -q "net.ipv6.conf.all.forwarding = 1" /userdata/system/sysctl.conf; then
    echo "ERROR: ipv6 forwarding not enabled"
    echo "       Do NOT save the overlay or reboot until this is resolved."
    exit 1
fi

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
TAILSCALE_IP=$ (/userdata/system/tailscale/tailscale status | grep -oP '^\s*\d+\.\d+\.\d+\.\d+' | head -n 1)
if [[ -z "$TAILSCALE_IP" ]]; then
  echo "ERROR: Could not determine Tailscale IP address.  Manual key download required."
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
