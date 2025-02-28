#!/bin/bash

# --- Configuration ---
# !! IMPORTANT !! Replace with your actual AUTH KEY or leave blank to be prompted.
AUTH_KEY=""
# !! IMPORTANT !! Check https://pkgs.tailscale.com/stable/ for the latest arm64 version!
TAILSCALE_VERSION="1.80.2"

# --- Automatic Subnet Detection ---
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
if [[ -z "$GATEWAY_IP" ]]; then
    echo "ERROR: Could not determine your local network subnet."
    read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
else
    SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    echo "Detected local subnet: $SUBNET"
    read -r -p "Is this subnet correct? (yes/no): " SUBNET_CONFIRM
    if [[ "$SUBNET_CONFIRM" != "yes" ]]; then
        read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
    fi
fi

# --- Check for Auth Key ---
if [[ -z "$AUTH_KEY" ]]; then
    echo "----------------------------------------------------------------------------------------"
    echo "Before proceeding, generate a Tailscale REUSABLE auth key."
    echo "Visit: https://login.tailscale.com/admin/settings/keys"
    echo "----------------------------------------------------------------------------------------"
    read -r -p "Enter your Tailscale auth key (with tskey-auth- prefix): " AUTH_KEY
fi

# --- Installation ---
mkdir -p /userdata/system/tailscale/bin /run/tailscale /userdata/system/tailscale
wget -O /tmp/tailscale.tgz https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz
tar -xf /tmp/tailscale.tgz -C /tmp
rm /tmp/tailscale.tgz
mv /tmp/tailscale_*_arm64/tailscale /userdata/system/tailscale/bin/
mv /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
chmod 600 /userdata/system/tailscale/authkey

# Create systemd service
cat << EOF > /usr/lib/systemd/system/tailscaled.service
[Unit]
Description=Tailscale node agent
Wants=network-online.target
After=network-online.target
[Service]
ExecStart=/userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port 41641
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

sysctl -w net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
systemctl daemon-reload
if ! systemctl enable tailscaled &>/dev/null; then
    echo "WARNING: Systemctl failed. Using custom.sh as fallback."
    cat <<EOF > /userdata/system/custom.sh
#!/bin/bash
if ! pgrep -f "tailscaled" > /dev/null; then
  /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state &
  sleep 5
  /userdata/system/tailscale/bin/tailscale up --authkey=\$(cat /userdata/system/tailscale/authkey) --advertise-routes=$SUBNET --accept-routes --hostname=batocera-1 &
fi
EOF
    chmod +x /userdata/system/custom.sh
fi
systemctl start tailscaled

# --- Verification Before Reboot ---
TAILSCALE_IP=$(/userdata/system/tailscale/bin/tailscale ip -4)
if [[ -z "$TAILSCALE_IP" ]]; then
    echo "ERROR: Could not retrieve Tailscale IP. Check 'tailscale status'."
    exit 1
fi

echo "------------------------------------------------------------------------"
echo "Tailscale appears to be running correctly."
echo "Your Tailscale IP is: $TAILSCALE_IP"
echo "Try connecting via Tailscale SSH NOW before saving the overlay."
echo "Run this command from another device: ssh root@$TAILSCALE_IP"
echo "------------------------------------------------------------------------"

# Allow user to retry SSH check
while true; do
    read -r -p "Did Tailscale SSH work correctly? (yes/retry/no): " SSH_WORKED
    if [[ "$SSH_WORKED" == "yes" ]]; then
        break
    elif [[ "$SSH_WORKED" == "retry" ]]; then
        echo "Retrying SSH check..."
        /userdata/system/tailscale/bin/tailscale status
    else
        echo "ERROR: Tailscale SSH did not work. Do NOT save the overlay or reboot."
        exit 1
    fi
done

# Cleanup and save overlay
iptables-save | grep -v "100.64.0.0/10" | iptables-restore
iptables-save > /userdata/system/iptables.rules

echo "Saving overlay..."
batocera-save-overlay

echo "------------------------------------------------------------------------"
echo "Overlay has been saved successfully!"
echo "IMPORTANT: You must manually reboot Batocera to complete the installation."
echo "You can reboot now or later using the command: reboot"
echo "------------------------------------------------------------------------"

read -r -p "Would you like to reboot now? (yes/no): " REBOOT_NOW
if [[ "$REBOOT_NOW" == "yes" ]]; then
    echo "Rebooting..."
    reboot
else
    echo "Reboot skipped. Please remember to reboot later for changes to take effect."
fi
