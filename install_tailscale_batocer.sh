#!/bin/bash

# --- Configuration ---
# Get auth key from argument 1, or prompt if not provided
AUTH_KEY="${1:-}"  # Use $1 (first argument) if provided, otherwise empty string.
# !! IMPORTANT !! Check https://pkgs.tailscale.com/stable/ for the latest arm64 version!
TAILSCALE_VERSION="${2:-1.80.2}"  # Use $2 (second arg) if provided, otherwise default.

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Functions ---

# Function to validate a subnet in CIDR notation
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
    echo -e "${RED}⚠️  This script must be run as root (or with sudo).${NC}"
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

# Get the default gateway IP address
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')

if [[ -z "$GATEWAY_IP" ]]; then
    echo -e "${YELLOW}WARNING: Could not automatically determine your local network subnet.${NC}"
    read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
    validate_subnet "$SUBNET"
else
    # Extract the subnet from the gateway IP (assuming a /24 subnet mask)
    SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    echo -e "${GREEN}✅ Detected local subnet: $SUBNET${NC}"

    # --- Subnet Confirmation ---
    read -r -p "Is this subnet correct? (yes/no): " SUBNET_CONFIRM
    if [[ "$SUBNET_CONFIRM" != "yes" ]]; then
        read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
        validate_subnet "$SUBNET"
    fi
fi

# --- Check for Auth Key ---
if [[ -z "$AUTH_KEY" ]]; then
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
    read -r -p "Enter your Tailscale reusable auth key (with tskey-auth- prefix): " AUTH_KEY
    if [[ -z "$AUTH_KEY" ]]; then
        echo "ERROR: Auth key is required.  Exiting."
        exit 1
    fi
    if [[ ! "$AUTH_KEY" =~ ^tskey-auth-[a-zA-Z0-9-]+$ ]]; then
        echo "ERROR: Invalid auth key format.  It should start with 'tskey-auth-'. Exiting."
        exit 1
    fi
fi

# --- Installation Steps ---

echo -e "${GREEN}📥 Installing Tailscale...${NC}"

# Create directories
mkdir -p /userdata/system/tailscale/bin
mkdir -p /run/tailscale
mkdir -p /userdata/system/tailscale

# --- Store Auth Key Immediately! ---
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
cp /userdata/system/tailscale/authkey /userdata/system/tailscale/authkey.bak  # Create backup
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

# Extract Tailscale
tar -xf /tmp/tailscale.tgz -C /tmp
if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Failed to extract Tailscale. Exiting.${NC}"
    exit 1
fi
rm /tmp/tailscale.tgz

# Move Tailscale binaries (to /userdata/system/tailscale/bin)
mv /tmp/tailscale_*_arm64/tailscale /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/
rm -rf /tmp/tailscale_*_arm64  # Clean up the extracted directory

# --- Ensure 'tun' Module is Loaded at Boot ---
if ! grep -q '^tun$' /etc/modules; then
  echo -e "${YELLOW}➕ Adding 'tun' module to /etc/modules for persistent loading...${NC}"
  mount -o remount,rw /  # Make the root filesystem writable
  echo 'tun' >> /etc/modules
  mount -o remount,ro /  # Remount as read-only
  batocera-save-overlay  # Ensure persistence of /etc/modules change!
fi
modprobe tun # Load immediately

# Enable IP forwarding (check before adding to avoid duplicates)
if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
fi
if ! grep -q "net.ipv6.conf.all.forwarding = 1" /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
fi
sysctl -p

# --- Startup (custom.sh) ---
# Use a temporary file to avoid issues with quotes and variable expansion.
rm -f /tmp/tailscale_custom.sh #Remove any left over temp file.
cat <<EOF > /tmp/tailscale_custom.sh
#!/bin/sh
if ! pgrep -f "/userdata/system/tailscale/bin/tailscaled" > /dev/null; then
  /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale &
  sleep 10
  # Restore authkey if missing
  if [ ! -f /userdata/system/tailscale/authkey ]; then
    cp /userdata/system/tailscale/authkey.bak /userdata/system/tailscale/authkey
  fi
  export TS_AUTHKEY=$(cat /userdata/system/tailscale/authkey)
  /userdata/system/tailscale/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey=\$TS_AUTHKEY --hostname=batocera-1 --advertise-tags=tag:ssh-batocera-1 >> /userdata/system/tailscale/tailscale_up.log 2>&1
    if [ $? -ne 0 ]; then
      echo "Tailscale failed to start. Check log file." >> /userdata/system/tailscale/tailscale_up.log
      cat /userdata/system/tailscale/tailscale_up.log
      exit 1
    fi
fi
EOF
chmod +x /tmp/tailscale_custom.sh
mv /tmp/tailscale_custom.sh /userdata/system/custom.sh
/bin/bash /userdata/system/custom.sh

# --- Verification and Prompt Before Reboot ---
echo -e "${GREEN}------------------------------------------------------------------------${NC}"
echo -e "${GREEN}Tailscale installation completed.  Performing verification checks...${NC}"
echo -e "${GREEN}------------------------------------------------------------------------${NC}"

# Check Tailscale Status (Give it a few seconds to start)
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

# Check for tailscale0 interface
ip a | grep tailscale0
IP_A_EXIT_CODE=$?

echo -e "${GREEN}------------------------------------------------------------------------${NC}"
if [ "$TAILSCALE_STATUS_EXIT_CODE" -ne 0 ] || [ "$IP_A_EXIT_CODE" -ne 0 ]; then
    echo -e "${RED}ERROR: Tailscale verification failed.  Check the output above for errors.${NC}"
    echo -e "${RED}       Do NOT save the overlay or reboot until this is resolved.${NC}"
    echo -e "${RED}       You may need to run the tailscale up command manually.${NC}"
    exit 1
else
    echo -e "${GREEN}Tailscale appears to be running correctly.${NC}"
    echo ""
    # Fetch the Tailscale IP automatically
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

    echo -e "${GREEN}-------------------------------------------------------------------------${NC}"
    echo -e "${GREEN}Tailscale and SSH verification successful! It is now safe to save changes.${NC}"
    read -r -p "Do you want to save changes and reboot? THIS IS IRREVERSIBLE (yes/no) " SAVE_CHANGES

    if [[ "$SAVE_CHANGES" == "yes" ]]; then
        #Remove potentially conflicting iptables rules.
        iptables-save | grep -v "100.64.0.0/10" | iptables-restore
        iptables-save > /userdata/system/iptables.rules
        cat <<EOF > /userdata/system/services/iptablesload.sh
#!/bin/bash
iptables-restore < /userdata/system/iptables.rules
EOF
        chmod +x /userdata/system/services/iptablesload.sh
        batocera-services enable iptablesload

        echo ""
        echo -e "${YELLOW}💾 Saving overlay...${NC}"
        batocera-save-overlay
        echo -e "${GREEN}✅ Overlay saved successfully.${NC}"
        echo -e "${GREEN}♻️ Rebooting in 10 seconds...${NC}"
        sleep 10
        reboot
    else
       echo "Changes not saved. Exiting without rebooting."
       exit 1
    fi
fi
