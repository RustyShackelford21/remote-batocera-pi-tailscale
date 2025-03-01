#!/bin/bash

# --- Configuration ---
# Get auth key from argument 1, or prompt if not provided
AUTH_KEY="${1:-}"  # Use <span class="math-inline">1 \(first argument\) if provided, otherwise empty string\.
\# \!\! IMPORTANT \!\! Check https\://pkgs\.tailscale\.com/stable/ for the latest arm64 version\!
TAILSCALE\_VERSION\="</span>{2:-1.80.2}"  # Use $2 (second arg) if provided, otherwise default.

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Functions ---

# Function to validate a subnet in CIDR notation
validate_subnet() {
    if [[ ! "<span class="math-inline">1" \=\~ ^\[0\-9\]\{1,3\}\\\.\[0\-9\]\{1,3\}\\\.\[0\-9\]\{1,3\}\\\.\[0\-9\]\{1,3\}/\[0\-9\]\{1,2\}</span> ]]; then
        echo -e "<span class="math-inline">\{RED\}ERROR\: Invalid subnet format\. Exiting\.</span>{NC}"
        exit 1
    fi
}

# --- Script Start ---

echo -e "<span class="math-inline">\{YELLOW\}🚀 Tailscale Installer for Batocera \- Raspberry Pi 5</span>{NC}"

# --- Root Check ---
if [ "<span class="math-inline">\(id \-u\)" \-ne 0 \]; then
echo \-e "</span>{RED}⚠️  This script must be run as root (or with sudo).${NC}"
    exit 1
fi

# --- User Confirmation ---
if [ -z "$CONFIRM_INSTALL" ] || [ "$CONFIRM_INSTALL" != "yes" ]; then
  read -r -p "This script will install and configure Tailscale on your Batocera system. Continue? (yes/no): " CONFIRM
  if [[ "<span class="math-inline">CONFIRM" \!\= "yes" \]\]; then
echo \-e "</span>{RED}❌ Installation cancelled by user.<span class="math-inline">\{NC\}"
exit 1
fi
fi
\# \-\-\- Automatic Subnet Detection \-\-\-
\# Get the default gateway IP address
GATEWAY\_IP\=</span>(ip route show default | awk '/default/ {print $3}')

if [[ -z "<span class="math-inline">GATEWAY\_IP" \]\]; then
echo \-e "</span>{YELLOW}WARNING: Could not automatically determine your local network subnet.${NC}"
    read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
    validate_subnet "<span class="math-inline">SUBNET"
else
\# Extract the subnet from the gateway IP \(assuming a /24 subnet mask\)
SUBNET\=</span>(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."<span class="math-inline">3"\.0/24"\}'\)
echo \-e "</span>{GREEN}✅ Detected local subnet: <span class="math-inline">SUBNET</span>{NC}"

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
    if [[ ! "<span class="math-inline">AUTH\_KEY" \=\~ ^tskey\-auth\-\[a\-zA\-Z0\-9\-\]\+</span> ]]; then
        echo "ERROR: Invalid auth key format.  It should start with 'tskey-auth-'. Exiting."
        exit 1
    fi
fi

# --- Installation Steps ---

echo -e "<span class="math-inline">\{GREEN\}📥 Installing Tailscale\.\.\.</span>{NC}"

# Create directories
mkdir -p /userdata/system/tailscale/bin
mkdir -p /run/tailscale
mkdir -p /userdata/system/tailscale

# --- Store Auth Key Immediately! ---
echo "<span class="math-inline">AUTH\_KEY" \> /userdata/system/tailscale/authkey
cp /userdata/system/tailscale/authkey /userdata/system/tailscale/authkey\.bak  \# Create backup
chmod 600 /userdata/system/tailscale/authkey
echo \-e "</span>{GREEN}✅ Auth key successfully stored.<span class="math-inline">\{NC\}"
\# Download Tailscale \(prefer wget, fallback to curl\)
if command \-v wget &\> /dev/null; then
wget \-O /tmp/tailscale\.tgz "https\://pkgs\.tailscale\.com/stable/tailscale\_</span>{TAILSCALE_VERSION}_arm64.tgz"
elif command -v curl &> /dev/null; then
    curl -L -o /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
else
    echo -e "<span class="math-inline">\{RED\}ERROR\: Neither wget nor curl are installed\. Cannot download Tailscale\.</span>{NC}"
    exit 1
fi

if [ <span class="math-inline">? \-ne 0 \]; then
echo \-e "</span>{RED}ERROR: Failed to download Tailscale. Exiting.${NC}"
    exit 1
fi

# Extract Tailscale
tar -xf /tmp/tailscale.tgz -C /tmp
if [ <span class="math-inline">? \-ne 0 \]; then
echo \-e "</span>{RED}ERROR: Failed to extract Tailscale. Exiting.<span class="math-inline">\{NC\}"
exit 1
fi
rm /tmp/tailscale\.tgz
\# Move Tailscale binaries \(to /userdata/system/tailscale/bin\)
mv /tmp/tailscale\_\*\_arm64/tailscale /tmp/tailscale\_\*\_arm64/tailscaled /userdata/system/tailscale/bin/
rm \-rf /tmp/tailscale\_\*\_arm64  \# Clean up the extracted directory
\# \-\-\- Ensure 'tun' Module is Loaded at Boot \-\-\-
if \! grep \-q '^tun</span>' /etc/modules; then
  echo -e "<span class="math-inline">\{YELLOW\}➕ Adding 'tun' module to /etc/modules for persistent loading\.\.\.</span>{NC}"
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
    if [ <span class="math-inline">? \-ne 0 \]; then
echo "Tailscale failed to start\. Check log file\." \>\> /userdata/system/tailscale/tailscale\_up\.log
cat /userdata/system/tailscale/tailscale\_up\.log
exit 1
fi
fi
EOF
chmod \+x /tmp/tailscale\_custom\.sh
mv /tmp/tailscale\_custom\.sh /userdata/system/custom\.sh
/bin/bash /userdata/system/custom\.sh
\# \-\-\- Verification and Prompt Before Reboot \-\-\-
echo \-e "</span>{GREEN}------------------------------------------------------------------------<span class="math-inline">\{NC\}"
echo \-e "</span>{GREEN}Tailscale installation completed.  Performing verification checks...${NC}"
