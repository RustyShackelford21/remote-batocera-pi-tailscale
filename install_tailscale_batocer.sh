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

# Configuration (can be overridden via environment variables)
TAILSCALE_VERSION="${TAILSCALE_VERSION:-1.80.2}"  # Default if not set
AUTH_KEY="${AUTH_KEY:-}"  # Empty default prompts user

echo -e "${YELLOW}🚀 Tailscale Installer for Batocera${NC}"

# Root check
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}⚠️ Must run as root.${NC}"
    exit 1
fi

# User confirmation
read -p "⚠️ Install Tailscale? (yes/no): " CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo -e "${RED}❌ Cancelled.${NC}"
    exit 1
fi

# TUN module (Batocera doesn’t use /etc/modules; load directly)
echo -e "${GREEN}🔧 Ensuring TUN module...${NC}"
modprobe tun || { echo -e "${RED}❌ Failed to load TUN.${NC}"; exit 1; }

# Subnet detection
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
if [ -z "$GATEWAY_IP" ]; then
    echo -e "${YELLOW}⚠️ No subnet detected.${NC}"
    read -p "Enter subnet (e.g., 192.168.1.0/24): " SUBNET
else
    SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    echo -e "${GREEN}✅ Detected subnet: $SUBNET${NC}"
    read -p "Correct? (y/n): " SUBNET_CONFIRM
    [ "$SUBNET_CONFIRM" != "y" ] && read -p "Enter subnet: " SUBNET
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
mkdir -p bin  # Ensure bin directory exists
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
rm -rf tailscale.tgz "tailscale_${TAILSCALE_VERSION}_arm
