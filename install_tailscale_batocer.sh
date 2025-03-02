#!/bin/bash
#
# Batocera Tailscale Installer - Final Optimized Version
# Installs latest Tailscale version on Batocera for Raspberry Pi 5 with persistence and autostart
#

# Set up colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root."
fi

# Prompt for confirmation
print_message "This script will install Tailscale on your Batocera system."
read -p "Continue? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    print_error "Installation cancelled."
fi

# Detect architecture dynamically
ARCH=$(uname -m)
case $ARCH in
    aarch64) ARCH="arm64" ;;
    arm*) ARCH="arm" ;;
    x86_64) ARCH="amd64" ;;
    *) print_error "Unsupported architecture: $ARCH" ;;
esac
print_message "Detected architecture: $ARCH"

# Fetch the latest stable Tailscale version for the specific architecture
print_message "Fetching latest Tailscale version for $ARCH..."
LATEST_TARBALL=$(wget -qO- https://pkgs.tailscale.com/stable/ | grep -oP "tailscale_[0-9]+\.[0-9]+\.[0-9]+_${ARCH}\.tgz" | head -1)
if [[ -z "$LATEST_TARBALL" ]]; then
    print_error "Failed to find a static binary for $ARCH on the stable channel."
fi
LATEST_VERSION=$(echo "$LATEST_TARBALL" | grep -oP 'tailscale_\K[0-9]+\.[0-9]+\.[0-9]+')
print_success "Latest Tailscale version detected: $LATEST_VERSION for $ARCH"

# Automatically detect subnet with fallback
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
if [[ -z "$GATEWAY_IP" ]]; then
    print_warning "Could not detect subnet automatically."
    read -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
else
    SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    print_message "Detected subnet: $SUBNET"
    read -p "Is this subnet correct? (yes/no): " SUBNET_CONFIRM
    if [[ "$SUBNET_CONFIRM" != "yes" ]]; then
        read -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
    fi
fi
print_success "Using subnet: $SUBNET"

# Prompt for hostname
DEFAULT_HOSTNAME="batocera-1"
print_message "Setting up device hostname."
read -p "Enter a hostname (default: $DEFAULT_HOSTNAME): " HOSTNAME
HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}
print_success "Hostname set to: $HOSTNAME"

# Prompt for Tailscale auth key
while [[ -z "$AUTH_KEY" ]]; do
    print_message "Generate a REUSABLE auth key at: https://login.tailscale.com/admin/settings/keys"
    read -p "Enter your Tailscale auth key: " AUTH_KEY
    if [[ ! "$AUTH_KEY" =~ ^tskey-auth-[a-zA-Z0-9]{24,32}$ ]]; then
        print_warning "Invalid auth key format. It should start with 'tskey-auth-'."
        AUTH_KEY=""
    fi
done
print_success "Auth key validated successfully."

# Store configuration securely
mkdir -p /userdata/system/tailscale || print_error "Failed to create Tailscale directory."
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey || print_error "Failed to save auth key."
chmod 600 /userdata/system/tailscale/authkey
echo "SUBNET=$SUBNET" > /userdata/system/tailscale/config
echo "HOSTNAME=$HOSTNAME" >> /userdata/system/tailscale/config
chmod 600 /userdata/system/tailscale/config
print_success "Auth key and config stored securely."

# Enable IP forwarding (IPv4 + IPv6)
print_message "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 || print_warning "Failed to enable IPv4 forwarding."
sysctl -w net.ipv6.conf.all.forwarding=1 || print_warning "Failed to enable IPv6 forwarding."

# Setup TUN device before first start
print_message "Configuring TUN device..."
mkdir -p /dev/net
if ! [ -c /dev/net/tun ]; then
    print_message "Creating TUN device..."
    mknod /dev/net/tun c 10 200 && chmod 600 /dev/net/tun || print_error "Failed to create TUN device."
fi
modprobe tun || print_warning "TUN module may not be loaded immediately."

# Create startup script
print_message "Creating Tailscale startup script..."
cat > /userdata/system/tailscale_start.sh << EOF
#!/bin/sh
LOG="/userdata/system/tailscale-debug.log"
echo "Running tailscale_start.sh at \$(date)" >> \$LOG

# Load configuration
source /userdata/system/tailscale/config

# Ensure TUN device exists
mkdir -p /dev/net
if ! [ -c /dev/net/tun ]; then
    echo "Creating TUN device..." >> \$LOG
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# Load TUN module
modprobe tun || echo "Warning: TUN module may not be loaded" >> \$LOG

# Enable IP forwarding on boot
sysctl -w net.ipv4.ip_forward=1 >> \$LOG 2>&1
sysctl -w net.ipv6.conf.all.forwarding=1 >> \$LOG 2>&1

# Wait for network
COUNT=0
until ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; do
    COUNT=\$((COUNT + 1))
    if [ \$COUNT -ge 24 ]; then
        echo "Network timeout after 120 seconds" >> \$LOG
        exit 1
    fi
    echo "Waiting for network... (attempt \$COUNT/24)" >> \$LOG
    sleep 5
done

# Start Tailscale
/userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state >> \$LOG 2>&1 &
sleep 5
/userdata/system/tailscale/bin/tailscale up --authkey=\$(cat /userdata/system/tailscale/authkey) \
    --hostname=\$HOSTNAME --advertise-routes=\$SUBNET --snat-subnet-routes=false \
    --accept-routes --advertise-tags=tag:ssh-batocera-1 >> \$LOG 2>&1
EOF
chmod +x /userdata/system/tailscale_start.sh
print_success "Startup script created successfully."

# Autostart configuration
echo "nohup /userdata/system/tailscale_start.sh >> /userdata/system/tailscale-debug.log 2>&1 &" >> /userdata/system/custom.sh
chmod +x /userdata/system/custom.sh
print_success "Autostart configured."

# Save overlay and reboot
print_message "Saving overlay..."
batocera-save-overlay || print_error "Failed to save overlay."
print_success "Overlay saved successfully. Rebooting now."
reboot
