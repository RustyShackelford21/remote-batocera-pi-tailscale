#!/bin/sh
# Tailscale Automated Installer for Batocera
# Author: [Your Name]
# GitHub: [Your Repo Link]
# Date: February 28, 2025

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
TAILSCALE_VERSION="1.80.2"  # Update: https://pkgs.tailscale.com/stable/
AUTH_KEY=""  # Pre-fill or leave blank

echo -e "${YELLOW}🚀 Tailscale Installer for Batocera${NC}"

# Root check
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}⚠️ Must run as root.${NC}"
    exit 1
fi

# User confirmation
read -p "⚠️ Install Tailscale? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo -e "${RED}❌ Cancelled.${NC}"
    exit 1
fi

# TUN module
echo -e "${GREEN}🔧 Ensuring TUN module...${NC}"
if ! grep -q '^tun$' /etc/modules; then
    echo 'tun' >> /etc/modules
    batocera-save-overlay || { echo -e "${RED}❌ Failed to save modules.${NC}"; exit 1; }
fi
modprobe tun || { echo -e "${RED}❌ Failed to load TUN.${NC}"; exit 1; }

# Subnet detection
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
if [ -z "$GATEWAY_IP" ]; then
    echo -e "${YELLOW}⚠️ No subnet detected.${NC}"
    read -p "Enter subnet (e.g., 192.168.1.0/24): " SUBNET
else
    SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    echo -e "${GREEN}✅ Detected subnet: $SUBNET${NC}"
    read -p "Correct? (yes/no): " SUBNET_CONFIRM
    [ "$SUBNET_CONFIRM" != "yes" ] && read -p "Enter subnet: " SUBNET
fi
if ! echo "$SUBNET" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'; then
    echo -e "${RED}❌ Invalid subnet.${NC}"
    exit 1
fi

# Auth key
if [ -z "$AUTH_KEY" ]; then
    echo -e "${YELLOW}🔑 Generate a reusable auth key:${NC}"
    echo "  https://login.tailscale.com/admin/settings/keys"
    echo "  - Reusable: Enabled"
    echo "  - Ephemeral: Disabled"
    echo "  - Tags: tag:ssh-batocera-1"
    read -p "Enter key (tskey-auth-...): " AUTH_KEY
fi
if [ -z "$AUTH_KEY" ] || ! echo "$AUTH_KEY" | grep -q '^tskey-auth-'; then
    echo -e "${RED}❌ Invalid auth key.${NC}"
    exit 1
fi
mkdir -p /userdata/system/tailscale
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
cp /userdata/system/tailscale/authkey /userdata/system/tailscale/authkey.bak
chmod 600 /userdata/system/tailscale/authkey

# Install Tailscale
echo -e "${GREEN}📥 Installing Tailscale...${NC}"
cd /userdata/system/tailscale || { echo -e "${RED}❌ Directory error.${NC}"; exit 1; }
if command -v wget >/dev/null; then
    wget -O tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz" || { echo -e "${RED}❌ Download failed.${NC}"; exit 1; }
elif command -v curl >/dev/null; then
    curl -L -o tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz" || { echo -e "${RED}❌ Download failed.${NC}"; exit 1; }
else
    echo -e "${RED}❌ Neither wget nor curl found.${NC}"
    exit 1
fi
tar xzf tailscale.tgz || { echo -e "${RED}❌ Extraction failed.${NC}"; exit 1; }
mv "tailscale_${TAILSCALE_VERSION}_arm64/tailscale" "tailscale_${TAILSCALE_VERSION}_arm64/tailscaled" bin/
rm -rf tailscale.tgz "tailscale_${TAILSCALE_VERSION}_arm64"
chmod +x bin/*

# IP forwarding
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
if ! grep -q '^net.ipv6.conf.all.forwarding=1' /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
fi
sysctl -p 2>/dev/null || echo -e "${YELLOW}⚠️ Forwarding may need reboot.${NC}"

# Startup script
echo -e "${GREEN}⚙️ Setting up startup...${NC}"
cat > /userdata/system/tailscale_start.sh << 'EOF'
#!/bin/sh
echo "Starting Tailscale: $(date)" >> /userdata/system/tailscale-debug.log
[ ! -c /dev/net/tun ] && { mkdir -p /dev/net; mknod /dev/net/tun c 10 200; chmod 600 /dev/net/tun; }
[ -f /userdata/system/tailscale/authkey ] || cp /userdata/system/tailscale/authkey.bak /userdata/system/tailscale/authkey
if ! pgrep -f "tailscaled" >/dev/null; then
    /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state &>> /userdata/system/tailscale-debug.log &
fi
sleep 10
TRIES=3
for i in $(seq 1 $TRIES); do
    /userdata/system/tailscale/bin/tailscale up --advertise-routes="$SUBNET" --snat-subnet-routes=false --accept-routes --authkey=$(cat /userdata/system/tailscale/authkey) --hostname=batocera-1 --advertise-tags=tag:ssh-batocera-1 &>> /userdata/system/tailscale-debug.log && break
    echo "Retry $i/$TRIES failed" >> /userdata/system/tailscale-debug.log
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
echo -e "${GREEN}🔍 Verifying Tailscale...${NC}"
for i in $(seq 1 30); do
    if /userdata/system/tailscale/bin/tailscale status >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Tailscale running.${NC}"
        TAILSCALE_IP=$(/userdata/system/tailscale/bin/tailscale ip -4)
        if [ -n "$TAILSCALE_IP" ]; then
            echo "Tailscale IP: $TAILSCALE_IP"
            break
        fi
    fi
    sleep 2
done
if [ -z "$TAILSCALE_IP" ] || ! ip a | grep -q tailscale0; then
    echo -e "${RED}❌ Tailscale failed. Check /userdata/system/tailscale-debug.log${NC}"
    exit 1
fi
echo -e "${YELLOW}⚠️ Test SSH now:${NC} ssh root@$TAILSCALE_IP"
while true; do
    read -p "Did SSH work? (yes/retry/no): " SSH_WORKED
    case "$SSH_WORKED" in
        yes) break ;;
        retry) /userdata/system/tailscale/bin/tailscale status ;;
        *) echo -e "${RED}❌ SSH failed. Exiting without saving.${NC}"; exit 1 ;;
    esac
done

# iptables cleanup
echo -e "${YELLOW}🔧 Adjusting iptables...${NC}"
iptables-save | grep -v "100.64.0.0/10" | iptables-restore 2>/dev/null || echo -e "${YELLOW}⚠️ iptables adjustment failed.${NC}"
iptables-save > /etc/iptables/rules.v4 2>/dev/null || echo -e "${YELLOW}⚠️ iptables persistence may need manual setup.${NC}"

# Save and reboot
echo -e "${YELLOW}💾 Saving changes...${NC}"
batocera-save-overlay || { echo -e "${RED}❌ Save failed.${NC}"; exit 1; }
read -p "🔄 Reboot now? (y/n): " REBOOT
if [ "$REBOOT" = "y" ]; then
    echo -e "${GREEN}♻️ Rebooting...${NC}"
    reboot
else
    echo -e "${GREEN}✅ Done! Reboot manually.${NC}"
fi
