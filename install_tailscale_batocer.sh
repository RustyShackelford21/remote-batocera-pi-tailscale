#!/bin/sh
# Tailscale Automated Installer for Batocera - Subnet Router
# Author: RustyShackelford21
# GitHub: https://github.com/RustyShackelford21/remote-batocera-pi-tailscale
# Date: February 28, 2025

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
TAILSCALE_VERSION="${TAILSCALE_VERSION:-1.80.2}"  # Default if not set

echo -e "${YELLOW}🚀 Tailscale Installer for Batocera${NC}"

# Root check
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}⚠️ Must run as root.${NC}"
    exit 1
fi

# User confirmation
read -p "⚠️ Install Tailscale on your Batocera system? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo -e "${RED}❌ Cancelled.${NC}"
    exit 1
fi

# TUN module
echo -e "${GREEN}🔧 Ensuring TUN module...${NC}"
modprobe tun || { echo -e "${RED}❌ Failed to load TUN.${NC}"; exit 1; }

# Subnet detection
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
if [ -z "$GATEWAY_IP" ]; then
    echo -e "${YELLOW}⚠️ No subnet detected.${NC}"
    read -p "Enter subnet to advertise (e.g., 192.168.1.0/24): " SUBNET
else
    SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    echo -e "${GREEN}✅ Detected subnet to advertise: $SUBNET${NC}"
    read -p "Correct? (y/n): " SUBNET_CONFIRM
    [ "$SUBNET_CONFIRM" != "y" ] && read -p "Enter subnet to advertise: " SUBNET
fi
if ! echo "$SUBNET" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'; then
    echo -e "${RED}❌ Invalid subnet.${NC}"
    exit 1
fi

# Auth key prompt
echo -e "${YELLOW}🔑 Generate a reusable auth key:${NC}"
echo "  https://login.tailscale.com/admin/settings/keys"
echo "  - Reusable: Enabled"
echo "  - Ephemeral: Disabled"
echo "  - Tags: tag:ssh-batocera-1"
read -p "Enter your Tailscale auth key (tskey-auth-...): " AUTH_KEY
if [ -z "$AUTH_KEY" ] || ! echo "$AUTH_KEY" | grep -q '^tskey-auth-'; then
    echo -e "${RED}❌ Invalid or missing auth key.${NC}"
    exit 1
fi
mkdir -p /userdata/system/tailscale
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
cp /userdata/system/tailscale/authkey /userdata/system/tailscale/authkey.bak
chmod 600 /userdata/system/tailscale/authkey

# Install Tailscale
echo -e "${GREEN}📥 Installing Tailscale...${NC}"
cd /userdata/system/tailscale || { echo -e "${RED}❌ Directory error.${NC}"; exit 1; }
mkdir -p bin
if command -v wget >/dev/null; then
    wget -O tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz" || { echo -e "${RED}❌ Download failed.${NC}"; exit 1; }
elif command -v curl >/dev/null; then
    curl -L -o tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz" || { echo -e "${RED}❌ Download failed.${NC}"; exit 1; }
else
    echo -e "${RED}❌ Neither wget nor curl found.${NC}"
    exit 1
fi
tar xzf tailscale.tgz || { echo -e "${RED}❌ Extraction failed.${NC}"; exit 1; }
mv "tailscale_${TAILSCALE_VERSION}_arm64/tailscale" "tailscale_${TAILSCALE_VERSION}_arm64/tailscaled" bin/ || { echo -e "${RED}❌ Move failed.${NC}"; exit 1; }
rm -rf tailscale.tgz "tailscale_${TAILSCALE_VERSION}_arm64"
chmod +x bin/tailscale bin/tailscaled

# IP forwarding
echo -e "${GREEN}🔧 Enabling IP forwarding...${NC}"
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || echo -e "${YELLOW}⚠️ IPv4 forwarding may not persist.${NC}"
sysctl -w net.ipv6.conf.all.forwarding=1 2>/dev/null || echo -e "${YELLOW}⚠️ IPv6 forwarding may not persist.${NC}"

# Startup script
echo -e "${GREEN}⚙️ Setting up startup...${NC}"
cat > /userdata/system/tailscale_start.sh << 'EOF'
#!/bin/sh
echo "Starting Tailscale: $(date)" >> /userdata/system/tailscale/tailscale_up.log
[ ! -c /dev/net/tun ] && { mkdir -p /dev/net; mknod /dev/net/tun c 10 200; chmod 600 /dev/net/tun; }
[ -f /userdata/system/tailscale/authkey ] || cp /userdata/system/tailscale/authkey.bak /userdata/system/tailscale/authkey
if ! pgrep -f "tailscaled" >/dev/null; then
    /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state &>> /userdata/system/tailscale/tailscale_up.log &
fi
sleep 10
TRIES=3
for i in $(seq 1 $TRIES); do
    /userdata/system/tailscale/bin/tailscale up --advertise-routes="$SUBNET" --snat-subnet-routes=false --accept-routes --authkey=$(cat /userdata/system/tailscale/authkey) --hostname=batocera-1 --advertise-tags=tag:ssh-batocera-1 &>> /userdata/system/tailscale/tailscale_up.log && break
    echo "Retry $i/$TRIES failed" >> /userdata/system/tailscale/tailscale_up.log
    sleep 5
done
EOF
chmod +x /userdata/system/tailscale_start.sh

cat > /userdata/system/custom.sh << 'EOF'
#!/bin/sh
nohup /userdata/system/tailscale_start.sh &
EOF
chmod +x /userdata/system/custom.sh

# Initial setup
echo -e "${GREEN}🔄 Starting Tailscale...${NC}"
/userdata/system/tailscale_start.sh
sleep 5

# Verification
echo -e "${GREEN}------------------------------------------------------------------------${NC}"
echo -e "${GREEN}🔍 Verifying Tailscale...${NC}"
echo -e "${GREEN}------------------------------------------------------------------------${NC}"
for i in $(seq 1 30); do
    if /userdata/system/tailscale/bin/tailscale status >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Tailscale running.${NC}"
        TAILSCALE_IP=$(/userdata/system/tailscale/bin/tailscale ip -4)
        if [ -n "$TAILSCALE_IP" ]; then
            echo -e "${GREEN}Tailscale IP: $TAILSCALE_IP${NC}"
            break
        fi
    fi
    sleep 2
done
if [ -z "$TAILSCALE_IP" ] || ! ip a | grep -q tailscale0; then
    echo -e "${RED}❌ Tailscale failed. Check /userdata/system/tailscale/tailscale_up.log${NC}"
    exit 1
fi
echo -e "${YELLOW}IMPORTANT: Test SSH now before saving:${NC}"
echo -e "${YELLOW}Run: ssh root@$TAILSCALE_IP from another device.${NC}"
while true; do
    read -p "Did SSH work? (yes/retry/no): " SSH_WORKED
    if [ "$SSH_WORKED" = "yes" ]; then
        break
    elif [ "$SSH_WORKED" = "retry" ]; then
        echo "Retrying SSH check..."
        /userdata/system/tailscale/bin/tailscale status
    else
        echo -e "${RED}❌ SSH failed. Exiting without saving.${NC}"
        exit 1
    fi
done

# Verify subnet routing
echo -e "${YELLOW}🔍 Verifying subnet routing...${NC}"
SUBNET_CHECK=$(/userdata/system/tailscale/bin/tailscale status | grep "$SUBNET")
if [ -n "$SUBNET_CHECK" ]; then
    echo -e "${GREEN}✅ Subnet $SUBNET is being advertised.${NC}"
else
    echo -e "${RED}❌ Subnet $SUBNET not advertised. Check Tailscale admin console or logs.${NC}"
    exit 1
fi

# iptables cleanup
echo -e "${YELLOW}🔧 Adjusting iptables...${NC}"
iptables-save | grep -v "100.64.0.0/10" | iptables-restore 2>/dev/null || echo -e "${YELLOW}⚠️ iptables adjustment failed.${NC}"
iptables-save > /userdata/system/iptables.rules 2>/dev/null || echo -e "${YELLOW}⚠️ iptables persistence may need manual setup.${NC}"

# Save and reboot
echo -e "${GREEN}------------------------------------------------------------------------${NC}"
echo -e "${GREEN}Tailscale and SSH verified! Ready to save changes.${NC}"
read -p "💾 Save changes and reboot? (y/n): " SAVE_CHANGES
if [ "$SAVE_CHANGES" = "y" ]; then
    echo -e "${YELLOW}Saving overlay...${NC}"
    batocera-save-overlay || { echo -e "${RED}❌ Save failed.${NC}"; exit 1; }
    echo -e "${GREEN}✅ Overlay saved.${NC}"
    echo -e "${GREEN}♻️ Rebooting in 5 seconds...${NC}"
    sleep 5
    reboot
else
    echo -e "${GREEN}✅ Done! Reboot manually to apply changes.${NC}"
fi
