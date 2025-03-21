#!/bin/bash
# Ultimate SSH Key & Tailscale Setup for Batocera
# Version: 12.23 - Refined SCP, Config Emphasis, Samba iOS Read/Write, Subnet Routing
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log() {
    echo -e "${1}[$(date '+%Y-%m-%d %H:%M:%S')] ${2}${NC} ${MAGENTA}⚡${NC}"
}

TAILSCALE_VERSION="1.80.2"
INSTALL_DIR="/userdata/system/tailscale"
SSH_DIR="/userdata/system/.ssh"
KEYS_DIR="$INSTALL_DIR/keys"
LOCAL_SSH_PORT="22"

banner() {
    local text="$1"
    local width=60
    local border=$(printf "%${width}s" '' | tr ' ' '=')
    echo -e "${BLUE}${border}${NC}"
    printf "${MAGENTA}%${width}s\n${NC}" "$text" | tr ' ' '.'
    echo -e "${BLUE}${border}${NC}"
}

progress_indicator() {
    local duration=$1
    local message="$2"
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    echo -ne "${CYAN}${message}...${NC} "
    for ((t=0; t<duration*10; t++)); do
        printf "\b${spin[i]}"
        i=$(( (i+1) % 10 ))
        sleep 0.1
    done
    echo -e "\b${GREEN}✓${NC}"
}

clear
banner "Batocera Tailscale & SSH Key Setup (v12.23)"
echo -e "${CYAN}Sets up Tailscale, SSH key auth, Samba read/write, and subnet routing.${NC}"

[ "$(id -u)" -ne 0 ] && { log "$RED" "ERROR: Run as root."; exit 1; }

log "$BLUE" "Ensuring TUN device..."
progress_indicator 2 "Initializing TUN"
modprobe tun >/dev/null 2>&1
mkdir -p /dev/net >/dev/null 2>&1
[ ! -c /dev/net/tun ] && mknod /dev/net/tun c 10 200 && chmod 600 /dev/net/tun >/dev/null 2>&1

echo
log "$YELLOW" "Let's get some info..."
read -rp "Tailscale auth key (https://login.tailscale.com/admin/settings/keys): " AUTH_KEY
[[ -z "$AUTH_KEY" ]] && { log "$RED" "ERROR: Auth key required."; exit 1; }
[[ ! "$AUTH_KEY" =~ ^tskey-auth- ]] && { log "$RED" "ERROR: Invalid auth key."; exit 1; }
DEFAULT_HOSTNAME=$(hostname | cut -d'.' -f1)
read -rp "Hostname (default: $DEFAULT_HOSTNAME): " USER_HOSTNAME
HOSTNAME="${USER_HOSTNAME:-$DEFAULT_HOSTNAME}"
DEFAULT_TAG="tag:ssh-batocera"
read -rp "Use default tag '$DEFAULT_TAG'? (yes/no): " TAG_CONFIRM
if [[ "$TAG_CONFIRM" =~ ^[Yy]es$ ]]; then
    TAG="$DEFAULT_TAG"
else
    read -rp "Custom Tailscale tag: " TAG
    [[ -z "$TAG" ]] && { log "$RED" "ERROR: Tag required."; exit 1; }
fi
log "$GREEN" "✅ Hostname: $HOSTNAME"
log "$GREEN" "✅ Tag: $TAG"

# Subnet Detection
log "$BLUE" "Detecting network subnet..."
progress_indicator 1
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
if [[ -z "$GATEWAY_IP" ]]; then
    log "$YELLOW" "WARNING: Could not detect subnet"
    read -rp "Enter your local network subnet (e.g., 192.168.50.0/24): " SUBNET
else
    SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    log "$GREEN" "✅ Detected local subnet: $SUBNET"
    echo -e "${YELLOW}Note: If another device advertises this subnet in Tailscale, only one can be active${NC}"
    read -rp "Is this subnet correct? (yes/no): " SUBNET_CONFIRM
    [[ "$SUBNET_CONFIRM" != "yes" ]] && read -rp "Enter your subnet: " SUBNET
fi
[[ ! "$SUBNET" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]] && { log "$RED" "Invalid subnet format"; exit 1; }

LOCAL_IP=$(ip -4 addr show | grep -oE "inet [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $2}' | grep -v "127.0.0.1" | head -n 1)
[[ -z "$LOCAL_IP" ]] && { log "$RED" "ERROR: Local IP not found."; LOCAL_IP="<LOCAL_IP>"; } || log "$BLUE" "Local IP: $LOCAL_IP"

mkdir -p "$SSH_DIR" "$KEYS_DIR" /etc/dropbear /etc/samba
chmod 700 "$SSH_DIR" "$KEYS_DIR" /etc/dropbear /etc/samba

DROPBEAR_KEY="$SSH_DIR/id_dropbear"
OPENSSH_KEY="$KEYS_DIR/id_ed25519_batocera"
if [ ! -f "$DROPBEAR_KEY" ]; then
    log "$GREEN" "🔑 Generating SSH key..."
    progress_indicator 3 "Forging key"
    dropbearkey -t ed25519 -f "$DROPBEAR_KEY" || { log "$RED" "Key gen failed"; exit 1; }
    chmod 600 "$DROPBEAR_KEY"
    dropbearkey -y -f "$DROPBEAR_KEY" | grep "^ssh-ed25519" > /etc/dropbear/authorized_keys || { log "$RED" "Pubkey failed"; exit 1; }
    chmod 600 /etc/dropbear/authorized_keys
else
    log "$YELLOW" "⚠️ Reusing key."
    dropbearkey -y -f "$DROPBEAR_KEY" | grep "^ssh-ed25519" > /etc/dropbear/authorized_keys || { log "$RED" "Pubkey failed"; exit 1; }
    chmod 600 /etc/dropbear/authorized_keys
fi
dropbearconvert dropbear openssh "$DROPBEAR_KEY" "$OPENSSH_KEY" || { log "$RED" "Key conversion failed"; exit 1; }
chmod 600 "$OPENSSH_KEY"

log "$BLUE" "Configuring Dropbear..."
DROPBEAR_CONF="/etc/dropbear/dropbear.conf"
touch "$DROPBEAR_CONF"
[[ ! -w "$DROPBEAR_CONF" ]] && { log "$RED" "ERROR: Cannot write $DROPBEAR_CONF"; exit 1; }
sed -i '/^PasswordAuth/d' "$DROPBEAR_CONF" 2>/dev/null || true

log "$BLUE" "Configuring Samba for iOS read/write..."
cat > /etc/samba/smb.conf <<EOF
[global]
workgroup = WORKGROUP
server string = Batocera Share
server min protocol = SMB2
vfs objects = fruit streams_xattr
fruit:locking = none
fruit:resource = file
fruit:metadata = stream
security = user
map to guest = Bad User
[share]
path = /userdata
writeable = yes
guest ok = yes
create mask = 0666
directory mask = 0777
force user = root
EOF
pkill -f smbd
smbd -D -s /etc/samba/smb.conf || { log "$RED" "Samba start failed"; exit 1; }

log "$BLUE" "Saving overlay..."
progress_indicator 2 "Saving overlay"
batocera-save-overlay || { log "$RED" "Overlay failed"; exit 1; }

log "$BLUE" "Installing Tailscale..."
progress_indicator 5 "Downloading Tailscale"
mkdir -p "$INSTALL_DIR/bin"
wget -q -O "$INSTALL_DIR/tailscale.tgz" "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz" || { log "$RED" "Download failed."; exit 1; }
tar -xzf "$INSTALL_DIR/tailscale.tgz" -C "$INSTALL_DIR/bin" --strip-components=1 || { log "$RED" "Extraction failed."; exit 1; }
rm "$INSTALL_DIR/tailscale.tgz"
chmod +x "$INSTALL_DIR/bin/tailscale" "$INSTALL_DIR/bin/tailscaled"

log "$BLUE" "Starting Tailscale..."
progress_indicator 3 "Starting Tailscale"
pkill -f "tailscaled" || true
mkdir -p /var/run/tailscale
ln -sf "$INSTALL_DIR/tailscaled.sock" /var/run/tailscale/tailscaled.sock
"$INSTALL_DIR/bin/tailscaled" --state="$INSTALL_DIR/tailscaled.state" --socket="$INSTALL_DIR/tailscaled.sock" --tun=userspace-networking --verbose=1 > /tmp/tailscaled.log 2>&1 &
sleep 10
"$INSTALL_DIR/bin/tailscale" --socket="$INSTALL_DIR/tailscaled.sock" up --authkey="$AUTH_KEY" --hostname="$HOSTNAME" --advertise-tags="$TAG" --advertise-routes="$SUBNET" --accept-routes > /tmp/tailscaled.log 2>&1 || { log "$RED" "Tailscale failed:"; cat /tmp/tailscaled.log; exit 1; }
sleep 5

log "$BLUE" "Waiting for Tailscale IP..."
TRIES=0
TAILSCALE_IP=""
while [[ -z "$TAILSCALE_IP" && $TRIES -lt 10 ]]; do
    sleep 3
    TAILSCALE_IP=$("$INSTALL_DIR/bin/tailscale" --socket="$INSTALL_DIR/tailscaled.sock" ip -4 2>/dev/null)
    ((TRIES++))
done
[[ -z "$TAILSCALE_IP" ]] && { log "$YELLOW" "⚠️ No Tailscale IP."; TAILSCALE_IP="$LOCAL_IP"; } || log "$GREEN" "✅ Tailscale IP: $TAILSCALE_IP"

banner "Key Download and Testing"
echo -e "${CYAN}Download and test your SSH key—follow these steps EXACTLY:${NC}"
log "$YELLOW" "1. Open a NEW terminal (PowerShell: Win + T, 'powershell'; Linux/macOS: any terminal):"
log "$BLUE" "Starting Dropbear on 2222 (password mode)..."
pkill -f "dropbear.*2222" || true
/usr/sbin/dropbear -p 2222 || { log "$RED" "Dropbear failed on 2222."; exit 1; }
sleep 5
log "$YELLOW" "2. Download the SSH key—copy-paste this in your new terminal:"
echo "scp -P 2222 root@$LOCAL_IP:/userdata/system/tailscale/keys/id_ed25519_batocera \"C:\\\\Users\\\\\$(powershell.exe -NoProfile -Command 'Write-Output \$env:USERNAME')\\\\.ssh\\\\id_ed25519_batocera\""
log "$CYAN" "   - Windows: Auto-detects username."
log "$CYAN" "   - Password: 'linux' (type it when prompted)."
log "$CYAN" "   - Manual alternative: scp -P 2222 root@$LOCAL_IP:/userdata/system/tailscale/keys/id_ed25519_batocera C:\\Users\\<YourUsername>\\.ssh\\id_ed25519_batocera"
log "$CYAN" "   - Linux/macOS: scp -P 2222 root@$LOCAL_IP:/userdata/system/tailscale/keys/id_ed25519_batocera ~/.ssh/id_ed25519_batocera"
log "$CYAN" "   - iOS: Use Termius: scp -P 2222 root@$LOCAL_IP:/userdata/system/tailscale/keys/id_ed25519_batocera <destination>; save in Files."
log "$YELLOW" "3. Fix key permissions (Windows only—copy-paste this):"
echo "icacls \"C:\\\\Users\\\\\$(powershell.exe -NoProfile -Command 'Write-Output \$env:USERNAME')\\\\.ssh\\\\id_ed25519_batocera\" /inheritance:r /grant:r \"\$(powershell.exe -NoProfile -Command 'Write-Output \$env:USERNAME'):F\""
log "$YELLOW" "4. Set up SSH config—REQUIRED for easy access (create/edit C:\\Users\\<YourUsername>\\.ssh\\config):"
echo "Host batocera-tailscale $TAILSCALE_IP"
echo "    HostName $TAILSCALE_IP"
echo "    User root"
echo "    IdentityFile C:\\Users\\<YourUsername>\\.ssh\\id_ed25519_batocera"
log "$CYAN" "   - Replace <YourUsername> with your username (e.g., 'Willi')."
log "$CYAN" "   - Linux/macOS: Use ~/.ssh/ instead of C:\\Users\\<YourUsername>\\.ssh\\"
log "$CYAN" "   - iOS: In Termius, set key from Files, IP ($TAILSCALE_IP), user (root)—no config needed."
log "$CYAN" "   - IMPORTANT: This lets you run 'ssh batocera-tailscale' or 'ssh root@$TAILSCALE_IP' without flags."
log "$CYAN" "   - Steps: Open notepad, paste the above (replace <YourUsername>), save as 'config' in ~/.ssh/"
log "$YELLOW" "5. Test SSH—copy-paste this in your new terminal:"
echo "ssh -i \"C:\\\\Users\\\\\$(powershell.exe -NoProfile -Command 'Write-Output \$env:USERNAME')\\\\.ssh\\\\id_ed25519_batocera\" root@$LOCAL_IP -p 2222"
log "$CYAN" "   - Manual: ssh -i C:\\Users\\<YourUsername>\\.ssh\\id_ed25519_batocera root@$LOCAL_IP -p 2222"
log "$CYAN" "   - Linux/macOS: ssh -i ~/.ssh/id_ed25519_batocera root@$LOCAL_IP -p 2222"
log "$CYAN" "   - iOS: In Termius, use key, IP ($LOCAL_IP), port 2222."
log "$CYAN" "   - NOTE: If using local IP and Tailscale runs on your device, exit Tailscale first."
log "$YELLOW" "6. If you see 'root@BATOCERA', type 'yes' below:"
read -rp "Did SSH work on 2222? (yes/no): " KEY_WORKS

if [[ "$KEY_WORKS" =~ ^[Yy]es$ ]]; then
    log "$GREEN" "✅ Key confirmed!"
    echo "PasswordAuth no" > /etc/dropbear/dropbear.conf
    log "$BLUE" "Locking to key auth on 22..."
    progress_indicator 2 "Locking SSH"
    if ! pgrep -f "dropbear.*-p 22" > /dev/null; then
        pkill -f "dropbear" || true
        sleep 1
        /usr/sbin/dropbear -s -p 22 || { log "$RED" "Dropbear failed!"; /usr/sbin/dropbear -p 22 || exit 1; }
    fi
else
    log "$RED" "❌ Key failed—troubleshoot."
    pkill -f "dropbear.*2222" || true
    exit 1
fi

log "$YELLOW" "Final test—confirm SSH works before reboot:"
echo "ssh -i \"C:\\\\Users\\\\\$(powershell.exe -NoProfile -Command 'Write-Output \$env:USERNAME')\\\\.ssh\\\\id_ed25519_batocera\" root@$LOCAL_IP"
log "$CYAN" "   - Manual: ssh -i C:\\Users\\<YourUsername>\\.ssh\\id_ed25519_batocera root@$LOCAL_IP"
log "$CYAN" "   - Linux/macOS: ssh -i ~/.ssh/id_ed25519_batocera root@$LOCAL_IP"
log "$CYAN" "   - iOS: In Termius, use key, IP ($LOCAL_IP), port 22."
log "$CYAN" "   - With config: ssh batocera-tailscale OR ssh root@$TAILSCALE_IP"
read -rp "Did SSH work? (yes/no): " SSH_WORKS
[[ "$SSH_WORKS" =~ ^[Nn]o$ ]] && { log "$RED" "❌ SSH failed—reboot canceled."; exit 1; }

log "$BLUE" "Setting persistence..."
progress_indicator 3 "Saving state"
cat > /userdata/system/custom.sh <<EOF
#!/bin/sh
mkdir -p /dev/net
[ ! -c /dev/net/tun ] && mknod /dev/net/tun c 10 200 && chmod 600 /dev/net/tun
ip link set wlan0 up
iptables -F INPUT
iptables -P INPUT ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 445 -j ACCEPT
iptables -A INPUT -p udp --dport 137-139 -j ACCEPT
if ! pgrep -f "dropbear.*-p 22" > /dev/null; then
    pkill -f dropbear || true
    sleep 1
    /usr/sbin/dropbear -s -p 22 || echo "Dropbear failed" >> /tmp/custom.log
fi
mkdir -p /var/run/tailscale
ln -sf $INSTALL_DIR/tailscaled.sock /var/run/tailscale/tailscaled.sock
if ! pgrep -f "$INSTALL_DIR/bin/tailscaled" > /dev/null; then
    $INSTALL_DIR/bin/tailscaled --state=$INSTALL_DIR/tailscaled.state --socket=$INSTALL_DIR/tailscaled.sock --tun=userspace-networking --verbose=1 > /tmp/tailscaled.log 2>&1 &
    sleep 10
    [ -f "$INSTALL_DIR/tailscaled.state" ] && $INSTALL_DIR/bin/tailscale --socket=$INSTALL_DIR/tailscaled.sock up --hostname="$HOSTNAME" --advertise-tags="$TAG" --advertise-routes="$SUBNET" --accept-routes > /tmp/tailscaled.log 2>&1
fi
sleep 15
pkill -f smbd || true
smbd -D -s /etc/samba/smb.conf || echo "Samba failed" >> /tmp/custom.log
EOF
chmod +x /userdata/system/custom.sh
[ -f /userdata/system/custom.sh ] || { log "$RED" "ERROR: custom.sh failed"; exit 1; }

log "$BLUE" "Saving overlay..."
batocera-save-overlay && log "$GREEN" "✅ Overlay saved." || { log "$RED" "Overlay failed"; exit 1; }

banner "Installation Complete!"
log "$GREEN" "✅ Setup complete!"
log "$YELLOW" "SSH commands (if config not set):"
echo "ssh -i C:\\Users\\<YourUsername>\\.ssh\\id_ed25519_batocera root@$LOCAL_IP"
echo "ssh -i C:\\Users\\<YourUsername>\\.ssh\\id_ed25519_batocera root@$TAILSCALE_IP"
log "$CYAN" "   - With config (recommended): ssh batocera-tailscale OR ssh root@$TAILSCALE_IP"
log "$YELLOW" "Samba access (read/write):"
log "$CYAN" "   - Windows: \\\\$LOCAL_IP\\share or \\\\$TAILSCALE_IP\\share"
log "$CYAN" "   - iOS: In Files app, 'Connect to Server': smb://$LOCAL_IP/share or smb://$TAILSCALE_IP/share—copy ROMs to /roms."
log "$CYAN" "   - Optional agent (Windows): powershell.exe -Command \"Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent; ssh-add C:\\\\Users\\\\\$(powershell.exe -NoProfile -Command 'Write-Output \$env:USERNAME')\\\\.ssh\\\\id_ed25519_batocera\""
log "$CYAN" "   - Linux/macOS: eval \$(ssh-agent -s); ssh-add ~/.ssh/id_ed25519_batocera"
log "$GREEN" "Rebooting in 5..."
sleep 5
sync
reboot -f || reboot
