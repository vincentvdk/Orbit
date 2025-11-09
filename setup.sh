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

# Generate custom cloud-init file
OUTPUT_FILE="cloud-init-custom.yaml"

# Get script directory to find config files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CADDYFILE_PATH="$SCRIPT_DIR/Caddyfile"
ZOT_CONFIG_PATH="$SCRIPT_DIR/zot-config.json"

# Check if config files exist
if [ ! -f "$CADDYFILE_PATH" ]; then
    echo "Error: Caddyfile not found at $CADDYFILE_PATH"
    exit 1
fi

if [ ! -f "$ZOT_CONFIG_PATH" ]; then
    echo "Error: zot-config.json not found at $ZOT_CONFIG_PATH"
    exit 1
fi

echo ""
echo "Generating customized cloud-init file..."

# Create the config with substituted values
cat > "$OUTPUT_FILE" << 'OUTER_EOF'
#cloud-config

# Zot Registry Bootstrap Script for Hetzner Cloud
# Compatible with: Debian 12 (Bookworm), Debian 11 (Bullseye)
# This script automatically configures a Hetzner VM to run zot as a systemd service

OUTER_EOF

# Add SSH key section
echo "" >> "$OUTPUT_FILE"
echo "# SSH Keys" >> "$OUTPUT_FILE"
echo "ssh_authorized_keys:" >> "$OUTPUT_FILE"
echo "  - $SSH_KEY" >> "$OUTPUT_FILE"

# Continue with cloud-init configuration
cat >> "$OUTPUT_FILE" << 'OUTER_EOF'

package_update: true
package_upgrade: true

packages:
  - podman
  - apache2-utils
  - curl
  - ca-certificates

OUTER_EOF

# Add write_files section with Caddyfile and zot-config.json from external files
echo "write_files:" >> "$OUTPUT_FILE"
echo "  # Caddyfile - single source of truth for Caddy configuration" >> "$OUTPUT_FILE"
echo "  - path: /etc/caddy/Caddyfile" >> "$OUTPUT_FILE"
echo "    owner: root:root" >> "$OUTPUT_FILE"
echo "    permissions: '0644'" >> "$OUTPUT_FILE"
echo "    content: |" >> "$OUTPUT_FILE"

# Read and indent Caddyfile content, replacing :80 with domain name
while IFS= read -r line; do
    # Replace :80 with the domain name for automatic HTTPS
    line="${line//:80 \{/$DOMAIN_NAME \{}"
    echo "      $line" >> "$OUTPUT_FILE"
done < "$CADDYFILE_PATH"

# Add zot configuration
echo "" >> "$OUTPUT_FILE"
echo "  # Zot configuration - single source of truth for zot registry config" >> "$OUTPUT_FILE"
echo "  - path: /etc/zot/config.json" >> "$OUTPUT_FILE"
echo "    owner: root:root" >> "$OUTPUT_FILE"
echo "    permissions: '0644'" >> "$OUTPUT_FILE"
echo "    content: |" >> "$OUTPUT_FILE"

# Read and indent zot-config.json content with placeholders replaced
while IFS= read -r line; do
    # Replace placeholders in the config as we read it
    line="${line//\$\{HETZNER_BUCKET_NAME\}/BUCKET_NAME_PLACEHOLDER}"
    line="${line//\$\{HETZNER_S3_REGION\}/BUCKET_REGION_PLACEHOLDER}"
    echo "      $line" >> "$OUTPUT_FILE"
done < "$ZOT_CONFIG_PATH"

# Continue with runcmd section
cat >> "$OUTPUT_FILE" << 'OUTER_EOF'

runcmd:
  # Download and install Caddy binary from official GitHub releases
  - mkdir -p /usr/local/bin
  - mkdir -p /etc/caddy
  - mkdir -p /var/log/caddy
  - mkdir -p /var/lib/caddy

  # Download latest Caddy binary from GitHub API
  - |
    CADDY_VERSION=$(curl -fsSL https://api.github.com/repos/caddyserver/caddy/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
    CADDY_VERSION_NUM=${CADDY_VERSION#v}
    curl -L "https://github.com/caddyserver/caddy/releases/download/${CADDY_VERSION}/caddy_${CADDY_VERSION_NUM}_linux_amd64.tar.gz" -o /tmp/caddy.tar.gz

  # Extract and install
  - tar -xzf /tmp/caddy.tar.gz -C /tmp
  - mv /tmp/caddy /usr/local/bin/caddy
  - chmod +x /usr/local/bin/caddy
  - rm /tmp/caddy.tar.gz

  # Create caddy user and group
  - groupadd --system caddy
  - useradd --system --gid caddy --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy

  # Set ownership
  - chown -R caddy:caddy /etc/caddy
  - chown -R caddy:caddy /var/log/caddy
  - chown -R caddy:caddy /var/lib/caddy

  # Create zot directories (config.json deployed via write_files)
  - mkdir -p /etc/zot
  - mkdir -p /var/log/zot
  - mkdir -p /var/lib/zot

  - htpasswd -Bbn admin changeme > /etc/zot/htpasswd

  - |
    cat > /etc/zot/credentials.env << 'EOF'
    AWS_ACCESS_KEY_ID=ACCESS_KEY_PLACEHOLDER
    AWS_SECRET_ACCESS_KEY=SECRET_KEY_PLACEHOLDER
    EOF

  - chmod 600 /etc/zot/credentials.env
  - chmod 644 /etc/zot/config.json
  - chmod 644 /etc/zot/htpasswd

  - |
    cat > /etc/systemd/system/zot.service << 'EOF'
    [Unit]
    Description=Zot OCI Registry
    Documentation=https://zotregistry.dev
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=notify
    NotifyAccess=all
    Restart=always
    RestartSec=10
    TimeoutStartSec=0
    EnvironmentFile=/etc/zot/credentials.env
    Environment="PODMAN_SYSTEMD_UNIT=%n"

    ExecStartPre=-/usr/bin/podman pull ghcr.io/project-zot/zot:latest
    ExecStartPre=-/usr/bin/podman stop zot
    ExecStartPre=-/usr/bin/podman rm zot

    ExecStart=/usr/bin/podman run \
      --name zot \
      --sdnotify=conmon \
      --label io.containers.autoupdate=registry \
      --publish 5000:5000 \
      --volume /etc/zot/config.json:/etc/zot/config.json:ro,Z \
      --volume /etc/zot/htpasswd:/etc/zot/htpasswd:ro,Z \
      --volume /var/lib/zot:/var/lib/zot:Z \
      --volume /var/log/zot:/var/log/zot:Z \
      --env AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
      --env AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
      ghcr.io/project-zot/zot:latest serve /etc/zot/config.json

    ExecStop=/usr/bin/podman stop -t 10 zot

    [Install]
    WantedBy=multi-user.target
    EOF

  # Set proper permissions for Caddy directories (Caddyfile deployed via write_files)
  - chown -R caddy:caddy /etc/caddy
  - chown -R caddy:caddy /var/log/caddy

  # Create Caddy systemd service
  - |
    cat > /etc/systemd/system/caddy.service << 'EOF'
    [Unit]
    Description=Caddy Web Server
    Documentation=https://caddyserver.com/docs/
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=notify
    User=caddy
    Group=caddy
    ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
    ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
    TimeoutStopSec=5s
    LimitNOFILE=1048576
    PrivateTmp=true
    ProtectSystem=full
    AmbientCapabilities=CAP_NET_BIND_SERVICE

    [Install]
    WantedBy=multi-user.target
    EOF

  - podman pull ghcr.io/project-zot/zot:latest

  - systemctl daemon-reload
  - systemctl enable zot.service
  - systemctl start zot.service

  - systemctl enable podman-auto-update.timer
  - systemctl start podman-auto-update.timer

  - systemctl enable caddy
  - systemctl restart caddy

  - ufw allow 22/tcp
  - ufw allow 80/tcp
  - ufw allow 443/tcp
  - echo "y" | ufw enable

final_message: |
  Zot registry deployed successfully!
  Access at: http://YOUR_SERVER_IP
  Default credentials: admin / changeme

  Podman auto-update enabled and runs daily at midnight.
  Check timer: systemctl status podman-auto-update.timer
  Manual update: podman auto-update --dry-run

  For automatic HTTPS:
  1. Edit /etc/caddy/Caddyfile and replace :80 with your-domain.com
  2. Restart Caddy: systemctl restart caddy
  3. Caddy will automatically obtain SSL certificates!

  Next steps:
  1. Change admin password: htpasswd -Bbn user pass > /etc/zot/htpasswd
  2. Check status: systemctl status zot.service
OUTER_EOF

# Now replace the placeholders
sed -i "s/BUCKET_NAME_PLACEHOLDER/$BUCKET_NAME/g" "$OUTPUT_FILE"
sed -i "s/BUCKET_REGION_PLACEHOLDER/$BUCKET_REGION/g" "$OUTPUT_FILE"
sed -i "s/ACCESS_KEY_PLACEHOLDER/$ACCESS_KEY/g" "$OUTPUT_FILE"
sed -i "s/SECRET_KEY_PLACEHOLDER/$SECRET_KEY/g" "$OUTPUT_FILE"

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
echo "  3. Choose Debian 12 (Bookworm) or Debian 11 (Bullseye)"
echo "  4. Paste contents of $OUTPUT_FILE into Cloud config"
echo "  5. Create server and wait 2-3 minutes"
echo ""
echo "Option 2: Hetzner CLI"
echo "  hcloud server create \\"
echo "    --name zot-registry \\"
echo "    --type cx23 \\"
echo "    --image debian-12 \\"
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
