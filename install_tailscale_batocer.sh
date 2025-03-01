#!/bin/bash

echo "------------------------------------------------------------"
echo " 🏁 Welcome to the Batocera Tailscale Installer"
echo "------------------------------------------------------------"

# --- Prompt for Tailscale Auth Key ---
echo "To continue, you need a Tailscale auth key."
echo "Generate one here: https://login.tailscale.com/admin/settings/keys"
echo "Make sure to enable:"
echo " - ✅ Reusable"
echo " - ✅ Ephemeral"
echo " - 🏷️  Tags: 'tag:ssh-batocera-1'"
echo ""
read -r -p "Enter your Tailscale auth key: " AUTH_KEY
AUTH_KEY=$(echo "$AUTH_KEY" | tr -d '[:space:]')  # Trim accidental spaces/newlines

# Ensure the key is valid
if [[ -z "$AUTH_KEY" ]] || [[ ! "$AUTH_KEY" =~ ^tskey-auth-[a-zA-Z0-9-]+$ ]]; then
    echo "❌ ERROR: Invalid or missing auth key. Exiting."
    exit 1
fi

# --- Define variables ---
TAILSCALE_VERSION="1.80.2"
INSTALL_DIR="/userdata/system/tailscale"
BIN_DIR="$INSTALL_DIR/bin"
STATE_DIR="$INSTALL_DIR/state"
CUSTOM_SCRIPT="/userdata/system/custom.sh"

echo "✅ Auth key captured successfully."

# --- Install Dependencies & Prepare System ---
echo ">>> Loading TUN module..."
modprobe tun
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    echo "Creating TUN device..."
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

echo ">>> Enabling IPv4 forwarding..."
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

# --- Detect Subnet Automatically ---
SUBNET=$(ip route | awk '/default/ {print $3}' | awk -F. '{print $1"."$2"."$3".0/24"}')
echo "Detected subnet: $SUBNET"

# --- Download & Install Tailscale ---
echo ">>> Downloading Tailscale $TAILSCALE_VERSION for ARM64..."
mkdir -p "$BIN_DIR"
wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
tar -xzf /tmp/tailscale.tgz -C /tmp
mv /tmp/tailscale_*_arm64/tailscale /tmp/tailscale_*_arm64/tailscaled "$BIN_DIR"
chmod +x "$BIN_DIR/tailscale" "$BIN_DIR/tailscaled"
rm -rf /tmp/tailscale_*

# --- Store Auth Key ---
echo "$AUTH_KEY" > "$INSTALL_DIR/authkey"
chmod 600 "$INSTALL_DIR/authkey"

# --- Create Startup Script (/userdata/system/custom.sh) ---
echo ">>> Creating startup script..."
cat <<EOF > "$CUSTOM_SCRIPT"
#!/bin/sh
if ! pgrep -f "$BIN_DIR/tailscaled" > /dev/null; then
  "$BIN_DIR/tailscaled" --state=$STATE_DIR &  
  sleep 10  
  "$BIN_DIR/tailscale" up --advertise-routes=$SUBNET --authkey=\$(cat $INSTALL_DIR/authkey) --hostname=batocera-1 --advertise-tags=tag:ssh-batocera-1
fi
EOF
chmod +x "$CUSTOM_SCRIPT"

# --- Start Tailscale Immediately ---
echo ">>> Starting Tailscale now..."
"$BIN_DIR/tailscaled" --state=$STATE_DIR &
sleep 10
"$BIN_DIR/tailscale" up --advertise-routes=$SUBNET --authkey="$AUTH_KEY" --hostname=batocera-1 --advertise-tags=tag:ssh-batocera-1

# --- Check if Tailscale Started Successfully ---
sleep 5
if "$BIN_DIR/tailscale" status | grep -q "online"; then
    echo "✅ Tailscale is running successfully!"
else
    echo "❌ ERROR: Tailscale did not start correctly. Check logs."
    exit 1
fi

# --- Save Changes & Prompt for Reboot ---
echo ">>> Saving changes to Batocera overlay..."
batocera-save-overlay

echo "🎉 Setup complete!"
echo "You can now SSH into this device using your Tailscale IP."
echo "Run this command from another device:"
echo "   ssh root@$( "$BIN_DIR/tailscale" ip -4 )"
echo ""
read -r -p "Reboot now to apply all changes? (yes/no): " REBOOT
if [[ "$REBOOT" == "yes" ]]; then
    echo "Rebooting in 5 seconds..."
    sleep 5
    reboot
else
    echo "You must reboot manually to complete setup."
fi
