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
TAILSCALE_VERSION="1.80.2"  # Update: https://pkgs.tailscale.com/stable/
AUTH_KEY=""  # Pre-fill or leave blank

echo -e "<span class="math-inline">\{YELLOW\}🚀 Tailscale Installer for Batocera</span>{NC}"

# Root check
if [ "<span class="math-inline">\(id \-u\)" \-ne 0 \]; then
echo \-e "</span>{RED}⚠️ Must run as root.${NC}"
    exit 1
fi

# User confirmation
read -p "⚠️ Install Tailscale? (yes/no): " CONFIRM
if [ "<span class="math-inline">CONFIRM" \!\= "yes" \]; then
echo \-e "</span>{RED}❌ Cancelled.<span class="math-inline">\{NC\}"
exit 1
fi
\# TUN module
echo \-e "</span>{GREEN}🔧 Ensuring TUN module...<span class="math-inline">\{NC\}"
if \! grep \-q '^tun</span>' /etc/modules; then
    mount -o remount,rw /  # Make root filesystem writable
    echo 'tun' >> /etc/modules
    mount -o remount,ro /
    batocera-save-overlay || { echo -e "<span class="math-inline">\{RED\}❌ Failed to save modules\.</span>{NC}"; exit 1; }
fi
modprobe tun || { echo -e "<span class="math-inline">\{RED\}❌ Failed to load TUN\.</span>{NC}"; exit 1; }

# Subnet detection
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
if [ -z "<span class="math-inline">GATEWAY\_IP" \]; then
echo \-e "</span>{YELLOW}⚠️ No subnet detected.<span class="math-inline">\{NC\}"
read \-p "Enter subnet \(e\.g\., 192\.168\.1\.0/24\)\: " SUBNET
else
SUBNET\=</span>(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."<span class="math-inline">3"\.0/24"\}'\)
echo \-e "</span>{GREEN}✅ Detected subnet: <span class="math-inline">SUBNET</span>{NC}"
    read -p "Correct? (yes/no): " SUBNET_CONFIRM
    [ "$SUBNET_CONFIRM" != "yes" ] && read -p "Enter subnet: " SUBNET
fi
if ! echo "<span class="math-inline">SUBNET" \| grep \-qE '^\[0\-9\]\{1,3\}\\\.\[0\-9\]\{1,3\}\\\.\[0\-9\]\{1,3\}\\\.\[0\-9\]\{1,3\}/\[0\-9\]\{1,2\}</span>'; then
    echo -e "<span class="math-inline">\{RED\}❌ Invalid subnet\.</span>{NC}"
    exit 1
fi

# Auth key
if [ -z "<span class="math-inline">AUTH\_KEY" \]; then
echo \-e "</span>{YELLOW}🔑 Generate a reusable auth key:${NC}"
    echo "  https://login.tailscale.com/admin/settings/keys"
    echo "  - Reusable: Enabled"
    echo "  - Ephemeral: Enabled"
    echo "  - Tags: tag:ssh-batocera-1"
    read -p "Enter key (tskey-auth-...): " AUTH_KEY
fi
if [ -z "$AUTH_KEY" ] || ! echo "<span class="math-inline">AUTH\_KEY" \| grep \-q '^tskey\-auth\-'; then
echo \-e "</span>{RED}❌ Invalid auth key.${NC}"
    exit 1
fi
mkdir -p /userdata/system/tailscale
echo "<span class="math-inline">AUTH\_KEY" \> /userdata/system/tailscale/authkey
cp /userdata/system/tailscale/authkey /userdata/system/tailscale/authkey\.bak
chmod 600 /userdata/system/tailscale/authkey
\# Install Tailscale
echo \-e "</span>{GREEN}📥 Installing Tailscale...<span class="math-inline">\{NC\}"
mkdir \-p /userdata/system/tailscale/bin \# Ensure bin directory exists \*before\* download
if command \-v wget \>/dev/null; then
wget \-qO\- "https\://pkgs\.tailscale\.com/stable/tailscale\_</span>{TAILSCALE_VERSION}_arm64.tgz" -O /tmp/tailscale.tgz || { echo -e "<span class="math-inline">\{RED\}❌ Download failed\.</span>{NC}"; exit 1; }
elif command -v curl >/dev/null; then
    curl -L "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz" -o /tmp/tailscale.tgz || { echo -e "<span class="math-inline">\{RED\}❌ Download failed\.</span>{NC}"; exit 1; }
else
    echo -e "<span class="math-inline">\{RED\}❌ Neither wget nor curl found\.</span>{NC}"
    exit 1
fi
tar xzf /tmp/tailscale.tgz -C /tmp || { echo -e "<span class="math-inline">\{RED\}❌ Extraction failed\.</span>{NC}"; exit 1; }
mv /tmp/tailscale_*_arm64/tailscale /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/
rm -rf /tmp/tailscale.tgz /tmp/tailscale_*_arm64
chmod +x /userdata/system/tailscale/bin/*

# IP forwarding
if [ ! -f /etc/sysctl.conf ]; then
    touch /etc/sysctl.conf
fi

if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
    mount -o remount,rw /
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    mount -o remount,ro /
fi
if ! grep -q '^net.ipv6.conf.all.forwarding=1' /etc/sysctl.conf; then
    mount -o remount,rw /
    echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
     mount -o remount,ro /
fi
sysctl -p 2>/dev/null || echo -e "<span class="math-inline">\{YELLOW\}⚠️ Forwarding may need reboot\.</span>{NC}"

# Startup script
echo -e "<span class="math-inline">\{GREEN\}⚙️ Setting up startup\.\.\.</span>{NC}"
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
    /userdata/system/tailscale/bin/tailscale up --advertise-routes="<span class="math-inline">SUBNET" \-\-snat\-subnet\-routes\=false \-\-accept\-routes \-\-authkey\=</span>(cat /userdata/system/tailscale/authkey) --hostname=batocera-1 --advertise-tags=tag:ssh-batocera-1 &>> /userdata/system/tailscale/tailscale_up.log && break
    echo "Retry $i/<span class="math-inline">TRIES failed" \>\> /userdata/system/tailscale/tailscale\_up\.log
sleep 5
done
EOF
chmod \+x /userdata/system/tailscale\_start\.sh
cat \> /userdata/system/custom\.sh << 'EOF'
\#\!/bin/sh
nohup /userdata/system/tailscale\_start\.sh &
EOF
chmod \+x /userdata/system/custom\.sh
\# Initial setup
echo \-e "</span>{GREEN}🔄 Starting Tailscale...<span class="math-inline">\{NC\}"
/userdata/system/tailscale\_start\.sh
sleep 5
\# Verification
echo \-e "</span>{GREEN}🔍 Verifying Tailscale...${NC}"
for i in <span class="math-inline">\(seq 1 30\); do
if /userdata/system/tailscale/bin/tailscale status \>/dev/null 2\>&1; then
echo \-e "</span>{GREEN}✅ Tailscale running.<span class="math-inline">\{NC\}"
TAILSCALE\_IP\=</span>(/userdata/system/tailscale/bin/tailscale ip -4)
        if [ -n "$TAILSCALE_IP" ]; then
            echo "Tailscale IP: $TAILSCALE_IP"
            break
        fi
    fi
    sleep 2
done
if [ -z "<span class="math-inline">TAILSCALE\_IP" \] \|\| \! ip a \| grep \-q tailscale0; then
echo \-e "</span>{RED}❌ Tailscale failed. Check /userdata/system/tailscale/tailscale_up.log${NC}"
    exit 1
fi
echo -e "<span class="math-inline">\{YELLOW\}⚠️ Test SSH now\:</span>{NC} ssh root@$TAILSCALE_IP"
while true; do
    read -p "Did SSH work? (yes/retry/no): " SSH_WORKED
    case "<span class="math-inline">SSH\_WORKED" in
yes\) break ;;
retry\) /userdata/system/tailscale/bin/tailscale status ;;
\*\) echo \-e "</span>{RED}❌ SSH failed. Exiting without saving.<span class="math-inline">\{NC\}"; exit 1 ;;
esac
done
\# iptables cleanup
echo \-e "</span>{YELLOW}🔧 Adjusting iptables...<span class="math-inline">\{NC\}"
iptables\-save \| grep \-v "100\.64\.0\.0/10" \| iptables\-restore 2\>/dev/null \|\| echo \-e "</span>{YELLOW}⚠️ iptables adjustment failed.<span class="math-inline">\{NC\}"
iptables\-save \> /etc/iptables/rules\.v4 2\>/dev/null \|\| echo \-e "</span>{YELLOW}⚠️ iptables persistence may need manual setup.<span class="math-inline">\{NC\}"
\# Save and reboot
echo \-e "</span>{YELLOW}💾 Saving changes...<span class="math-inline">\{NC\}"
batocera\-save\-overlay \|\| \{ echo \-e "</span>{RED}❌ Save failed.${NC}"; exit 1; }
read -p "🔄 Reboot now? (y/n): " REBOOT
if [ "$REBOOT"
