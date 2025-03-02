cat > install_tailscale_batocer.sh << 'EOF'
#!/bin/bash
#
# Batocera Tailscale Installer Script - Optimized Hybrid Version
# Installs the latest Tailscale version on Batocera for Raspberry Pi 5 with persistence and autostart
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

# Fetch the latest stable Tailscale version
print_message "Fetching latest Tailscale version..."
LATEST_VERSION=$(wget -qO- https://pkgs.tailscale.com/stable/ | grep -oP 'tailscale_\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [[ -z "$LATEST_VERSION" ]]; then
    print_error "Failed to determine latest Tailscale version."
fi
print_success "Latest Tailscale version detected: $LATEST_VERSION"

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
    if [[ ! "$AUTH_KEY" =~ ^tskey-auth-[a-zA-Z0-9-]{40,50}$ ]]; then
        print_warning "Invalid auth key format. It should start with 'tskey-auth-' and be 40-50 characters long (e.g., tskey-auth-kNNstZW4Sk11CNTRL-oybwJJqrr7PRH9vDewqP7PNiCv8Ug6pEV)."
        AUTH_KEY=""
    fi
done
print_success "Auth key validated successfully."

# Store the auth key securely
mkdir -p /userdata/system/tailscale || print_error "Failed to create Tailscale directory."
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey || print_error "Failed to save auth key."
chmod 600 /userdata/system/tailscale/authkey || print_error "Failed to set auth key permissions."
print_success "Auth key stored securely."

# Ensure internet connection before downloading
print_message "Checking internet connectivity..."
wget -q --spider https://pkgs.tailscale.com || print_error "No internet connection detected."

# Download latest Tailscale version
print_message "Downloading Tailscale $LATEST_VERSION for $ARCH..."
wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${LATEST_VERSION}_${ARCH}.tgz" || print_error "Failed to download Tailscale."

# Extract and install Tailscale
print_message "Extracting Tailscale..."
tar -xf /tmp/tailscale.tgz -C /tmp || print_error "Failed to extract Tailscale."
mkdir -p /userdata/system/tailscale/bin || print_error "Failed to create bin directory."
mv /tmp/tailscale_${LATEST_VERSION}_*/tailscale /tmp/tailscale_${LATEST_VERSION}_*/tailscaled /userdata/system/tailscale/bin/ || print_error "Failed to install Tailscale binaries."
rm -rf /tmp/tailscale_${LATEST_VERSION}_* /tmp/tailscale.tgz
chmod +x /userdata/system/tailscale/bin/*
print_success "Tailscale $LATEST_VERSION installed successfully."

# Create startup script
print_message "Creating Tailscale startup script..."
cat > /userdata/system/tailscale_start.sh << EOF
#!/bin/sh
LOG="/userdata/system/tailscale-debug.log"
echo "Running tailscale_start.sh at \$(date)" >> \$LOG

# Ensure TUN device exists
mkdir -p /dev/net
if ! [ -c /dev/net/tun ]; then
    echo "Creating TUN device..." >> \$LOG
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# Wait for network with timeout (120 seconds)
COUNT=0
MAX=24  # 24 * 5s = 120s
until ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; do
    COUNT=\$((COUNT + 1))
    if [ \$COUNT -ge \$MAX ]; then
        echo "Network timeout after 120 seconds" >> \$LOG
        exit 1
    fi
    echo "Waiting for network... (attempt \$COUNT/\$MAX)" >> \$LOG
    sleep 5
done
echo "Network available" >> \$LOG

# Start tailscaled in the background
/userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state >> \$LOG 2>&1 &

# Wait for Tailscale daemon to initialize
sleep 5

# Connect to Tailscale
/userdata/system/tailscale/bin/tailscale up --authkey=\$(cat /userdata/system/tailscale/authkey) \
    --hostname=$HOSTNAME --advertise-routes=$SUBNET --snat-subnet-routes=false \
    --accept-routes --advertise-tags=tag:ssh-batocera-1 >> \$LOG 2>&1

if [ \$? -eq 0 ]; then
    echo "Tailscale started successfully at \$(date)" >> \$LOG
else
    echo "Tailscale failed to start" >> \$LOG
    exit 1
fi
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

# Verify status with dynamic polling
print_message "Verifying Tailscale status..."
for i in {1..12}; do
    if /userdata/system/tailscale/bin/tailscale status >/dev/null 2>&1; then
        print_success "Tailscale is running!"
        /userdata/system/tailscale/bin/tailscale status
        break
    fi
    print_message "Waiting for Tailscale to start... (attempt $i/12)"
    sleep $(( i < 6 ? 5 : 10 ))  # 5s for first 6 tries, 10s for last 6
    if [ $i -eq 12 ]; then
        print_warning "Tailscale failed to start within 60 seconds. Check /userdata/system/tailscale-debug.log."
    fi
done

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
EOF
chmod +x install_tailscale_batocer.sh
./install_tailscale_batocer.sh
