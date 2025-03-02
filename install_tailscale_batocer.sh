#!/bin/bash
#
# Batocera Tailscale Installer - Optimized Final Version
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

# Ensure internet connection before downloading
print_message "Checking internet connectivity..."
wget -q --spider https://pkgs.tailscale.com || print_error "No internet connection detected."

# Download the exact tarball
print_message "Downloading Tailscale $LATEST_VERSION for $ARCH..."
wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/$LATEST_TARBALL" || print_error "Failed to download Tailscale static binary."

# Extract and install Tailscale
print_message "Extracting Tailscale..."
tar -xf /tmp/tailscale.tgz -C /tmp || print_error "Failed to extract Tailscale."
mkdir -p /userdata/system/tailscale/bin || print_error "Failed to create bin directory."
mv /tmp/tailscale_${LATEST_VERSION}_*/tailscale /tmp/tailscale_${LATEST_VERSION}_*/tailscaled /userdata/system/tailscale/bin/ || print_error "Failed to install Tailscale binaries."
rm -rf /tmp/tailscale_${LATEST_VERSION}_* /tmp/tailscale.tgz
chmod +x /userdata/system/tailscale/bin/*
print_success "Tailscale $LATEST_VERSION installed successfully."

# Enable IP forwarding (IPv4 + IPv6) initially
print_message "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 || print_warning "Failed to enable IPv4 forwarding."
sysctl -w net.ipv6.conf.all.forwarding=1 || print_warning "Failed to enable IPv6 forwarding."

# Configure TUN device initially
print_message "Configuring TUN device..."
mkdir -p /dev/net
if ! [ -c /dev/net/tun ]; then
    print_message "Creating TUN device..."
    mknod /dev/net/tun c 10 200 && chmod 600 /dev/net/tun || print_error "Failed to create TUN device."
fi
modprobe tun || print_error "TUN module failed to load. Tailscale will not work."

# Store subnet and hostname persistently
mkdir -p /userdata/system/tailscale
echo "SUBNET=$SUBNET" > /userdata/system/tailscale/config
echo "HOSTNAME=$HOSTNAME" >> /userdata/system/tailscale/config
chmod 600 /userdata/system/tailscale/config
print_success "Network settings stored successfully."

# Create startup script
print_message "Creating Tailscale startup script..."
cat > /userdata/system/tailscale_start.sh << EOF
#!/bin/sh
LOG="/userdata/system/tailscale-debug.log"
echo "Running tailscale_start.sh at \$(date)" >> \$LOG

# Load config
source /userdata/system/tailscale/config

# Enable IP forwarding on boot
sysctl -w net.ipv4.ip_forward=1 >> \$LOG 2>&1
sysctl -w net.ipv6.conf.all.forwarding=1 >> \$LOG 2>&1

# Ensure TUN device exists
mkdir -p /dev/net
if ! [ -c /dev/net/tun ]; then
    echo "Creating TUN device..." >> \$LOG
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# Load tun module
modprobe tun || echo "Warning: TUN module failed to load; Tailscale may not work." >> \$LOG

# Start tailscaled
echo "Starting tailscaled..." >> \$LOG
/userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state >> \$LOG 2>&1 &

# Wait for network with timeout (120 seconds)
COUNT=0
MAX=24
until ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; do
    COUNT=\$((COUNT + 1))
    if [ \$COUNT -ge \$MAX ]; then
        echo "Network timeout after 120 seconds" >> \$LOG
        exit 1
    fi
    echo "Waiting for network... (attempt \$COUNT/\$MAX)" >> \$LOG
    sleep 5
done

# Connect to Tailscale
echo "Running Tailscale up..." >> \$LOG
/userdata/system/tailscale/bin/tailscale up --authkey=\$(cat /userdata/system/tailscale/authkey) \
    --hostname=\$HOSTNAME --advertise-routes=\$SUBNET --snat-subnet-routes=false \
    --accept-routes --advertise-tags=tag:ssh-batocera-1 >> \$LOG 2>&1
EOF
chmod +x /userdata/system/tailscale_start.sh
print_success "Startup script created successfully."

# Configure autostart
print_message "Configuring autostart..."
echo "nohup /userdata/system/tailscale_start.sh >> /userdata/system/tailscale-debug.log 2>&1 &" >> /userdata/system/custom.sh
chmod +x /userdata/system/custom.sh
print_success "Autostart configured."

# Start Tailscale now
print_message "Starting Tailscale..."
/bin/sh /userdata/system/tailscale_start.sh >> /userdata/system/tailscale-debug.log 2>&1 &

# Save overlay and reboot
print_message "Setup complete!"
read -p "Save changes and reboot? (yes/no): " SAVE_CHANGES
if [[ "$SAVE_CHANGES" == "yes" ]]; then
    print_message "Saving overlay..."
    batocera-save-overlay || print_error "Failed to save overlay."
    print_success "Overlay saved successfully. Rebooting now."
    reboot
else
    print_warning "Changes will not persist after reboot unless you run 'batocera-save-overlay' manually."
fi
