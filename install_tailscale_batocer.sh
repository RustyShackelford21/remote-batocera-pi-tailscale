#!/bin/bash
# Tailscale installer for Batocera
# This script downloads Tailscale, sets up auto-start, and configures routing.

set -e  # exit on error

echo ">>> Loading tun module..."
modprobe tun || true  # Load TUN driver (ignore if already built-in or loaded)

echo ">>> Enabling IPv4 forwarding..."
# Enable IP forwarding now and persist via custom.sh
sysctl -w net.ipv4.ip_forward=1

# Determine system architecture for Tailscale download
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)   ARCH="amd64"   ;;  # 64-bit x86
    i?86)     ARCH="386"     ;;  # 32-bit x86 (IA-32)
    armv7*)   ARCH="arm"     ;;  # 32-bit ARM
    armv6*)   ARCH="arm"     ;;  # 32-bit ARM (older)
    aarch64)  ARCH="arm64"   ;;  # 64-bit ARM
    *) 
        echo "Unsupported architecture: $ARCH"
        exit 1 
        ;;
esac

# Download the latest stable Tailscale static binary for this arch
VERSION="1.80.2"  # you can update this to the latest version if needed
URL="https://pkgs.tailscale.com/stable/tailscale_${VERSION}_${ARCH}.tgz"
echo ">>> Downloading Tailscale ${VERSION} for ${ARCH}..."
if command -v curl >/dev/null 2>&1; then
    curl -L -o /tmp/tailscale.tgz "$URL"
elif command -v wget >/dev/null 2>&1; then
    wget -O /tmp/tailscale.tgz "$URL"
else
    echo "Error: neither curl nor wget is available to fetch Tailscale."
    exit 1
fi

echo ">>> Installing Tailscale binaries..."
mkdir -p /userdata/tailscale
tar xzf /tmp/tailscale.tgz -C /userdata/tailscale --strip-components=1
chmod +x /userdata/tailscale/tailscale /userdata/tailscale/tailscaled
rm -f /tmp/tailscale.tgz

# Prompt for Tailscale auth key (required for headless setup)
if [ -z "$TS_AUTH_KEY" ]; then
    echo ">>> Please provide your Tailscale auth key (from https://tailscale.com/login)"
    read -p "Auth key: " TS_AUTH_KEY
fi

# Optional: ask for hostname to use in Tailscale (or use default)
read -p "Desired Tailscale device name (leave blank to use default hostname): " TS_HOSTNAME
if [ -n "$TS_HOSTNAME" ]; then
    HOSTNAME_FLAG="--hostname=${TS_HOSTNAME}"
else
    HOSTNAME_FLAG=""
fi

# Optional: ask if user wants to advertise their LAN or be an exit node
ADVERTISE_FLAGS=""
EXIT_FLAG=""
# Determine local LAN subnet (if any) from default route (for advertise-routes)
DEFAULT_IF=$(ip route | awk '/^default/ {print $5; exit}')
if ip route show dev "$DEFAULT_IF" | grep -q "proto kernel"; then
    LAN_SUBNET=$(ip route show dev "$DEFAULT_IF" proto kernel | awk '{print $1; exit}')
else
    LAN_SUBNET=""
fi
if [ -n "$LAN_SUBNET" ]; then
    read -p "Advertise this device's LAN subnet $LAN_SUBNET to tailnet? [y/N]: " ADV
    if [[ "$ADV" =~ ^[Yy] ]]; then
        ADVERTISE_FLAGS="--advertise-routes=${LAN_SUBNET}"
    fi
fi
read -p "Allow this device to act as an exit node (share internet)? [y/N]: " EX
if [[ "$EX" =~ ^[Yy] ]]; then
    EXIT_FLAG="--advertise-exit-node"
fi

echo ">>> Writing startup script (/userdata/system/custom.sh)..."
mkdir -p /userdata/system
cat > /userdata/system/custom.sh <<EOF
#!/bin/bash
# Custom startup script for Batocera - Tailscale
if [ "\$1" != "start" ]; then
    exit 0
fi

# Load TUN module and enable IP forwarding
modprobe tun || true
sysctl -w net.ipv4.ip_forward=1

# Wait for network connectivity (max 30s)
for i in \$(seq 1 30); do
    ping -c1 -W1 1.1.1.1 &>/dev/null && break
    sleep 1
done

# Start Tailscale daemon
/userdata/tailscale/tailscaled -state /userdata/tailscale/state \\
    > /userdata/tailscale/tailscaled.log 2>&1 &

# Give tailscaled a moment to initialize
sleep 5

# Bring up tailscale interface (without auth key, uses stored state)
/userdata/tailscale/tailscale up --accept-dns=false --accept-routes=false \\
    $HOSTNAME_FLAG $ADVERTISE_FLAGS $EXIT_FLAG

# Configure iptables for Tailscale routing
iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE
iptables -A FORWARD -i tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -o tailscale0 -j ACCEPT
EOF

# If exit node was chosen, add MASQUERADE rule for internet traffic
if [[ "$EXIT_FLAG" == "--advertise-exit-node" && -n "$DEFAULT_IF" ]]; then
    echo "iptables -t nat -A POSTROUTING -o $DEFAULT_IF -s 100.64.0.0/10 -j MASQUERADE" >> /userdata/system/custom.sh
    echo "# (Forwarding rules above already cover exit-node traffic routing)" >> /userdata/system/custom.sh
fi

chmod +x /userdata/system/custom.sh

echo ">>> Starting Tailscale and logging in with auth key..."
# Start tailscaled now (in background) and perform initial login using the auth key
/userdata/tailscale/tailscaled -state /userdata/tailscale/state > /userdata/tailscale/tailscaled.log 2>&1 &
sleep 5
/userdata/tailscale/tailscale up --accept-dns=false --accept-routes=false $HOSTNAME_FLAG $ADVERTISE_FLAGS $EXIT_FLAG --auth-key $TS_AUTH_KEY

# Apply iptables rules now (so changes take effect immediately without reboot)
echo ">>> Applying iptables rules..."
iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE
iptables -A FORWARD -i tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -o tailscale0 -j ACCEPT
if [[ "$EXIT_FLAG" == "--advertise-exit-node" && -n "$DEFAULT_IF" ]]; then
    iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -s 100.64.0.0/10 -j MASQUERADE
fi

echo ">>> Tailscale should be up and running. Verifying status..."
/userdata/tailscale/tailscale status || echo "(If status fails, check logs at /userdata/tailscale/tailscaled.log)"

echo ">>> Installation complete. Tailscale is now configured to start on boot."
echo ">>> You can reboot the system now to test that everything comes up automatically."
