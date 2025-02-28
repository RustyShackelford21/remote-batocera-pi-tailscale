#!/bin/bash

# --- Configuration ---
AUTH_KEY=""
TAILSCALE_VERSION="1.80.2"

# --- Automatic Subnet Detection ---
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')
SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')

echo "Detected local subnet: $SUBNET"
read -r -p "Is this subnet correct? (yes/no): " SUBNET_CONFIRM
if [[ "$SUBNET_CONFIRM" != "yes" ]]; then
    read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
fi

# --- Check for Auth Key ---
if [[ -z "$AUTH_KEY" ]]; then
    read -r -p "Enter your Tailscale reusable auth key (with tskey-auth- prefix): " AUTH_KEY
    if [[ -z "$AUTH_KEY" ]]; then
        echo "ERROR: Auth key is required. Exiting."
        exit 1
    fi
fi

# --- ✅ Store Auth Key Immediately! ✅ ---
mkdir -p /userdata/system/tailscale
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
cp /userdata/system/tailscale/authkey /userdata/system/tailscale/authkey.bak
chmod 600 /userdata/system/tailscale/authkey

echo "✅ Auth key successfully stored."

# --- Installation Steps ---
echo "Starting Tailscale installation..."
mkdir -p /userdata/system/tailscale/bin /run/tailscale

wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz"
tar -xf /tmp/tailscale.tgz -C /tmp
mv /tmp/tailscale_*_arm64/tailscale /userdata/system/tailscale/bin/
mv /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/
rm /tmp/tailscale.tgz

# --- Enable IP Forwarding ---
echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
sysctl -p

# --- Create custom.sh ---
rm -f /tmp/tailscale_custom.sh
cat <<EOF > /tmp/tailscale_custom.sh
#!/bin/bash
if ! pgrep -f "/userdata/system/tailscale/bin/tailscaled" > /dev/null; then
  /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state &
  sleep 5
  # ✅ Restore authkey if missing ✅
  if [ ! -f /userdata/system/tailscale/authkey ]; then
    cp /userdata/system/tailscale/authkey.bak /userdata/system/tailscale/authkey
  fi
  export TS_AUTHKEY=\$(cat /userdata/system/tailscale/authkey)
  /userdata/system/tailscale/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey=\$TS_AUTHKEY --hostname=batocera-1 >> /userdata/system/tailscale/tailscale_up.log 2>&1
fi
EOF

chmod +x /tmp/tailscale_custom.sh
mv /tmp/tailscale_custom.sh /userdata/system/custom.sh

# --- ✅ Manually Run custom.sh Once to Verify It Works ✅ ---
echo "🔄 Running custom.sh to verify it executes correctly..."
bash /userdata/system/custom.sh
if [ $? -ne 0 ]; then
    echo "❌ ERROR: custom.sh execution failed. Check logs."
    exit 1
fi

# --- Verification ---
echo "------------------------------------------------------------------------"
echo "Tailscale installation completed. Performing verification checks..."
echo "------------------------------------------------------------------------"

for i in {1..30}; do
    if /userdata/system/tailscale/bin/tailscale status &>/dev/null; then
        echo "✅ Tailscale is running!"
        break
    fi
    sleep 2
done

TAILSCALE_STATUS_EXIT_CODE=$?
if [ "$TAILSCALE_STATUS_EXIT_CODE" -ne 0 ]; then
    echo "❌ ERROR: Tailscale verification failed. Check logs."
    exit 1
fi

echo "✅ Tailscale appears to be running correctly."
echo "Your Tailscale IP: $(/userdata/system/tailscale/bin/tailscale ip -4)"
