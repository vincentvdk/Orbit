#!/bin/bash

# Zot Registry Setup Script
# Generates a customized cloud-init.yaml with your credentials

set -e

echo "=========================================="
echo "Zot Registry Deployment Setup"
echo "=========================================="
echo ""

# Check if running with parameters
if [ "$#" -eq 6 ]; then
    SSH_KEY="$1"
    BUCKET_NAME="$2"
    BUCKET_REGION="$3"
    ACCESS_KEY="$4"
    SECRET_KEY="$5"
    DOMAIN_NAME="$6"
else
    # Interactive mode
    echo "This script will generate a customized cloud-init.yaml file"
    echo "with your SSH key, domain, and Hetzner Object Storage credentials."
    echo ""

    # Check for SSH keys in common locations
    DEFAULT_KEY_PATH=""
    if [ -f "$HOME/.ssh/id_ed25519_zot.pub" ]; then
        DEFAULT_KEY_PATH="$HOME/.ssh/id_ed25519_zot.pub"
    elif [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
        DEFAULT_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
    elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
        DEFAULT_KEY_PATH="$HOME/.ssh/id_rsa.pub"
    fi

    if [ -n "$DEFAULT_KEY_PATH" ]; then
        SSH_KEY=$(cat "$DEFAULT_KEY_PATH")
        echo "Found SSH key at $DEFAULT_KEY_PATH"
        read -p "Use this SSH key? (y/n): " USE_DEFAULT
        if [ "$USE_DEFAULT" != "y" ] && [ "$USE_DEFAULT" != "Y" ]; then
            read -p "Enter path to your SSH public key: " KEY_PATH
            SSH_KEY=$(cat "$KEY_PATH")
        fi
    else
        echo "No SSH key found. Generate one with:"
        echo "  ssh-keygen -t ed25519 -a 100 -f ~/.ssh/id_ed25519_zot -C \"zot-registry-admin\""
        echo ""
        read -p "Enter path to your SSH public key: " KEY_PATH
        SSH_KEY=$(cat "$KEY_PATH")
    fi

    echo ""
    # Gather information
    read -p "Enter your domain name (e.g., cr.example.com): " DOMAIN_NAME
    read -p "Enter your Hetzner Object Storage bucket name: " BUCKET_NAME
    read -p "Enter your bucket region (fsn1, nbg1, or hel1): " BUCKET_REGION
    read -p "Enter your S3 Access Key ID: " ACCESS_KEY
    read -sp "Enter your S3 Secret Access Key: " SECRET_KEY
    echo ""
fi

# Validate inputs
if [ -z "$SSH_KEY" ] || [ -z "$DOMAIN_NAME" ] || [ -z "$BUCKET_NAME" ] || [ -z "$BUCKET_REGION" ] || [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
    echo "Error: All fields are required!"
    exit 1
fi

# Get script directory to find config files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Generate custom cloud-init file in repo root
OUTPUT_FILE="$REPO_ROOT/cloud-init-custom.yaml"
CLOUD_INIT_TEMPLATE="$REPO_ROOT/cloud-init.yaml"

# Check if template exists
if [ ! -f "$CLOUD_INIT_TEMPLATE" ]; then
    echo "Error: cloud-init.yaml template not found at $CLOUD_INIT_TEMPLATE"
    exit 1
fi

echo ""
echo "Generating customized cloud-init file from template..."

# Copy the template and make replacements
cp "$CLOUD_INIT_TEMPLATE" "$OUTPUT_FILE"

# Replace placeholders with actual values
# SSH key replacement (placeholder format in cloud-init.yaml)
sed -i "s|ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPUBLIC_KEY_HERE your-email@example.com|$SSH_KEY|g" "$OUTPUT_FILE"

# Replace :80 with domain name for automatic HTTPS
sed -i "s|:80 {|$DOMAIN_NAME {|g" "$OUTPUT_FILE"

# Replace bucket configuration placeholders
sed -i "s|YOUR_ACCESS_KEY_HERE|$ACCESS_KEY|g" "$OUTPUT_FILE"
sed -i "s|YOUR_SECRET_KEY_HERE|$SECRET_KEY|g" "$OUTPUT_FILE"
sed -i "s|my-registry-storage|$BUCKET_NAME|g" "$OUTPUT_FILE"
sed -i "s|eu-central|$BUCKET_REGION|g" "$OUTPUT_FILE"

# Determine endpoint based on region
case "$BUCKET_REGION" in
    fsn1)
        ENDPOINT="fsn1.your-objectstorage.com"
        ;;
    nbg1)
        ENDPOINT="nbg1.your-objectstorage.com"
        ;;
    hel1)
        ENDPOINT="hel1.your-objectstorage.com"
        ;;
    *)
        ENDPOINT="${BUCKET_REGION}.your-objectstorage.com"
        ;;
esac

sed -i "s|fsn1.your-objectstorage.com|$ENDPOINT|g" "$OUTPUT_FILE"

echo ""
echo "✓ Customized cloud-init file created: $OUTPUT_FILE"
echo ""
echo "=========================================="
echo "Deployment Options:"
echo "=========================================="
echo ""
echo "Option 1: Hetzner Cloud Console"
echo "  1. Go to https://console.hetzner.cloud/"
echo "  2. Create a new server"
echo "  3. Choose Debian 13 (Trixie)"
echo "  4. Recommended: Select location matching Object Storage bucket ($BUCKET_REGION)"
echo "  5. Paste contents of $OUTPUT_FILE into Cloud config"
echo "  6. Create server and wait 2-3 minutes"
echo ""
echo "Option 2: Hetzner CLI"
echo "  hcloud server create \\"
echo "    --name zot-registry \\"
echo "    --type cx23 \\"
echo "    --image debian-13 \\"
echo "    --location $BUCKET_REGION \\"
echo "    --user-data-from-file $OUTPUT_FILE"
echo ""
echo "=========================================="
echo "DNS Configuration Required:"
echo "=========================================="
echo "Before creating the server, configure DNS:"
echo "1. Create an A record: $DOMAIN_NAME → (your server IP)"
echo "2. Wait for DNS propagation (2-5 minutes)"
echo "3. Verify with: dig +short $DOMAIN_NAME"
echo ""
echo "After server creation, Caddy will automatically:"
echo "  ✓ Obtain Let's Encrypt SSL certificate"
echo "  ✓ Configure HTTPS"
echo "  ✓ Redirect HTTP to HTTPS"
echo "  ✓ Auto-renew certificates"
echo ""
echo "Your registry will be available at: https://$DOMAIN_NAME"
echo ""
echo "=========================================="
echo "Security Reminder:"
echo "=========================================="
echo "⚠  Default password is 'changeme' - change it immediately!"
echo "⚠  Keep $OUTPUT_FILE secure - it contains your credentials"
echo ""
echo "=========================================="
echo "Optional: Git-Based Configuration Sync"
echo "=========================================="
echo "The deployed server includes git-based config sync."
echo "To enable it after deployment:"
echo ""
echo "1. SSH to your server: ssh root@YOUR_SERVER_IP"
echo "2. Generate age key: age-keygen -o /etc/zot/age-key.txt"
echo "3. Set permissions: chmod 600 /etc/zot/age-key.txt"
echo "4. Get public key: grep \"# public key:\" /etc/zot/age-key.txt"
echo "5. Edit /etc/zot/zot-config-sync.env and set CONFIG_REPO_URL"
echo "6. Restart timer: systemctl restart zot-config-sync.timer"
echo "7. View logs: journalctl -u zot-config-sync -f"
echo ""
echo "The sync runs every 5 minutes and supports age encryption."
echo "See README.md for detailed git sync setup instructions."
echo ""
