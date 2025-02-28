#!/bin/bash

# --- Configuration ---
# !! IMPORTANT !! Replace with your actual AUTH KEY or leave blank to be prompted.
AUTH_KEY=""
# !! IMPORTANT !! Check https://pkgs.tailscale.com/stable/ for the latest arm64 version!
TAILSCALE_VERSION="1.80.2"

# --- Automatic Subnet Detection ---

# Get the default gateway IP address
GATEWAY_IP=$(ip route show default | awk '/default/ {print $3}')

if [[ -z "$GATEWAY_IP" ]]; then
    echo "ERROR: Could not automatically determine your local network subnet."
    echo "       You will need to enter it manually."
    read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
    # Validate subnet
    if [[ ! "$SUBNET" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
      echo "ERROR: Invalid subnet format. Exiting."
      exit 1
    fi
else
  # Extract the subnet from the gateway IP (assuming a /24 subnet mask)
  SUBNET=$(echo "$GATEWAY_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
  echo "Detected local subnet: $SUBNET"

  # --- Subnet Confirmation ---
  read -r -p "Is this subnet correct? (yes/no): " SUBNET_CONFIRM
  if [[ "$SUBNET_CONFIRM" != "yes" ]]; then
      read -r -p "Enter your local network subnet (e.g., 192.168.1.0/24): " SUBNET
      # Validate subnet
      if [[ ! "$SUBNET" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid subnet format. Exiting."
        exit 1
      fi
  fi
fi

# --- Check for Auth Key ---
if [[ -z "$AUTH_KEY" ]]; then
    echo "----------------------------------------------------------------------------------------"
    echo "Before proceeding, you need to generate a Tailscale REUSABLE auth key."
    echo "Follow these steps CAREFULLY:"
    echo "1. Go to https://login.tailscale.com/admin/settings/keys in your web browser."
    echo "2. Click the 'Generate auth key...' button."
    echo "3. Select the following options:"
    echo "   - Reusable: ENABLED (checked)"
    echo "   - Ephemeral: ENABLED (checked) - Recommended for better security and cleanup."
    echo "   - Description: Enter a description (e.g., 'Batocera Pi - Reusable')."
    echo "   - Expiration: Choose your desired expiration (e.g., 90 days).  Set a reminder!"
    echo "   - Tags:  Enter 'tag:ssh-batocera-1' (This is VERY important for SSH access control)."
    echo "4. Click 'Generate key'."
    echo "5. IMMEDIATELY copy the *FULL* key (INCLUDING the 'tskey-auth-' prefix)."
    echo "   The key will only be displayed ONCE.  Treat it like a password."
    echo "----------------------------------------------------------------------------------------"
    read -r -p "Enter your Tailscale reusable auth key (with tskey-auth- prefix): " AUTH_KEY
    if [[ -z "$AUTH_KEY" ]]; then
        echo "ERROR: Auth key is required.  Exiting."
        exit 1
    fi
    if [[ ! "$AUTH_KEY" =~ ^tskey-auth-[a-zA-Z0-9-]+$ ]]; then
        echo "ERROR: Invalid auth key format.  It should start with 'tskey-auth-'. Exiting."
        exit 1
    fi
fi

# --- Installation Steps ---

echo "Starting Tailscale installation..."

# Create directories
mkdir -p /userdata/system/tailscale/bin
mkdir -p /run/tailscale
mkdir -p /userdata/system/tailscale

# --- Store Auth Key Immediately! ---
echo "$AUTH_KEY" > /userdata/system/tailscale/authkey
cp /userdata/system/tailscale/authkey /userdata/system/tailscale/authkey.bak
chmod 600 /userdata/system/tailscale/authkey
echo "✅ Auth key successfully stored."

# Download Tailscale
wget -O /tmp/tailscale.tgz https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_arm64.tgz
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to download Tailscale. Exiting."
    exit 1
fi

# Extract Tailscale
tar -xf /tmp/tailscale.tgz -C /tmp
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to extract Tailscale. Exiting."
    exit 1
fi
rm /tmp/tailscale.tgz

# Move Tailscale binaries (to /userdata/system/tailscale/bin)
mv /tmp/tailscale_*_arm64/tailscale /userdata/system/tailscale/bin/
mv /tmp/tailscale_*_arm64/tailscaled /userdata/system/tailscale/bin/

# Enable IP forwarding (check before adding)
if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
fi
if ! grep -q "net.ipv6.conf.all.forwarding = 1" /etc/sysctl.conf; then
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
fi
sysctl -p

# --- Ensure 'tun' Module is Loaded at Boot ---
if ! grep -q '^tun$' /etc/modules; then
  echo "Adding 'tun' module to /etc/modules for persistent loading..."
  echo 'tun' >> /etc/modules
  batocera-save-overlay  # Ensure persistence of /etc/modules change!
fi

# --- Startup (custom.sh) ---
# Use a temporary file to avoid issues with quotes and variable expansion.
rm -f /tmp/tailscale_custom.sh #Remove any left over temp file.
cat <<EOF > /tmp/tailscale_custom.sh
#!/bin/bash
if ! pgrep -f "/userdata/system/tailscale/bin/tailscaled" > /dev/null; then
  /userdata/system/tailscale/bin/tailscaled --state=/userdata/system/tailscale/tailscaled.state &
  sleep 5
  /userdata/system/tailscale/bin/tailscale up --advertise-routes=$SUBNET --snat-subnet-routes=false --accept-routes --authkey=$(cat /userdata/system/tailscale/authkey) --hostname=batocera-1 >> /userdata/system/tailscale/tailscale_up.log 2>&1
    if [ $? -ne 0 ]; then
      echo "Tailscale failed to start. Check log file." >> /userdata/system/tailscale/tailscale_up.log
      cat /userdata/system/tailscale/tailscale_up.log
      exit 1
    fi
fi
EOF
chmod +x /tmp/tailscale_custom.sh
mv /tmp/tailscale_custom.sh /userdata/system/custom.sh

# --- Run custom.sh IMMEDIATELY for initial setup ---
/bin/bash /userdata/system/custom.sh


# --- Verification and Prompt Before Reboot ---
echo "------------------------------------------------------------------------"
echo "Tailscale installation completed.  Performing verification checks..."
echo "------------------------------------------------------------------------"

# Check Tailscale Status (Give it a few seconds to start)
echo "Waiting for Tailscale to start..."
for i in {1..30}; do
    if /userdata/system/tailscale/bin/tailscale status &>/dev/null; then
        echo "✅ Tailscale is running!"
        break
    fi
    sleep 2
done
/userdata/system/tailscale/bin/tailscale status
TAILSCALE_STATUS_EXIT_CODE=$?

# Check for tailscale0 interface
ip a | grep tailscale0
IP_A_EXIT_CODE=$?

echo "------------------------------------------------------------------------"
if [ "$TAILSCALE_STATUS_EXIT_CODE" -ne 0 ] || [ "$IP_A_EXIT_CODE" -ne 0 ]; then
    echo "ERROR: Tailscale verification failed.  Check the output above for errors."
    echo "       Do NOT save the overlay or reboot until this is resolved."
    echo "       You may need to run the tailscale up command manually."
    exit 1
else
    echo "Tailscale appears to be running correctly."
    echo ""
    # Fetch the Tailscale IP automatically
    TAILSCALE_IP=$(/userdata/system/tailscale/bin/tailscale ip -4)
    if [[ -z "$TAILSCALE_IP" ]]; then
        echo "ERROR: Could not retrieve Tailscale IP. Check 'tailscale status'."
        exit 1
    fi
    echo "Your Tailscale IP is: $TAILSCALE_IP"
    echo "IMPORTANT: Try connecting via Tailscale SSH *NOW*, before saving the overlay."
    echo "Run this command from another device on your Tailscale network:"
    echo ""
    echo "    ssh root@$TAILSCALE_IP"
    echo ""
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

    echo "-------------------------------------------------------------------------"
    echo "Tailscale and SSH verification successful! It is now safe to save changes."
     read -r -p "Do you want to save changes and reboot? THIS IS IRREVERSIBLE (yes/no) " SAVE_CHANGES

    if [[ "$SAVE_CHANGES" == "yes" ]]; then
        #Remove potentially conflicting iptables rules.
        iptables-save | grep -v "100.64.0.0/10" | iptables-restore
        iptables-save > /userdata/system/iptables.rules
        cat <<EOF > /userdata/system/services/iptablesload.sh
#!/bin/bash
iptables-restore < /userdata/system/iptables.rules
EOF
        chmod +x /userdata/system/services/iptablesload.sh
        batocera-services enable iptablesload

        echo ""
        echo "Saving overlay..."
        batocera-save-overlay
        echo "Rebooting in 10 seconds..."
        sleep 10
        reboot
    else
       echo "Changes not saved. Exiting without rebooting."
       exit 1
    fi
fi
