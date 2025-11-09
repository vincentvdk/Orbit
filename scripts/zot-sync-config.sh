#!/bin/bash
# Git-based configuration sync script for zot registry
# This script pulls configuration updates from git and applies them automatically
# Supports age encryption for sensitive files

set -euo pipefail

# Configuration
REPO_DIR="/opt/zot-config"
REPO_URL="${CONFIG_REPO_URL:-}"
BRANCH="${CONFIG_BRANCH:-main}"
AGE_KEY_FILE="${AGE_KEY_FILE:-/etc/zot/age-key.txt}"

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# Decrypt age-encrypted file
decrypt_age_file() {
    local encrypted_file="$1"
    local output_file="$2"

    if [ ! -f "$AGE_KEY_FILE" ]; then
        error "Age key file not found at $AGE_KEY_FILE"
        return 1
    fi

    if ! command -v age >/dev/null 2>&1; then
        error "age command not found, cannot decrypt files"
        return 1
    fi

    log "Decrypting $encrypted_file with age"
    if age -d -i "$AGE_KEY_FILE" "$encrypted_file" > "$output_file" 2>/dev/null; then
        return 0
    else
        error "Failed to decrypt $encrypted_file"
        return 1
    fi
}

# Initialize repository if it doesn't exist
if [ ! -d "$REPO_DIR/.git" ]; then
    if [ -z "$REPO_URL" ]; then
        error "CONFIG_REPO_URL not set and repository not initialized"
        exit 1
    fi

    log "Initializing repository from $REPO_URL"
    git clone "$REPO_URL" "$REPO_DIR"
    cd "$REPO_DIR"
    git checkout "$BRANCH"

    # First time setup - apply all configs
    log "First time setup - applying all configurations"
    INITIAL_SETUP=true
else
    cd "$REPO_DIR"
    INITIAL_SETUP=false
fi

# Fetch updates
log "Fetching updates from origin/$BRANCH"
git fetch origin "$BRANCH"

# Check if there are changes
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse "origin/$BRANCH")

if [ "$LOCAL" = "$REMOTE" ] && [ "$INITIAL_SETUP" = false ]; then
    log "No changes detected, configs are up to date"
    exit 0
fi

log "Changes detected, updating from $LOCAL to $REMOTE"

# Get list of changed files before pulling
CHANGED_FILES=$(git diff --name-only HEAD "origin/$BRANCH" || echo "")

# Pull changes
git pull origin "$BRANCH"

log "Changed files: $CHANGED_FILES"

# Track if any service needs restart
RESTART_ZOT=false
RELOAD_CADDY=false

# Apply configuration changes based on which files changed
if echo "$CHANGED_FILES" | grep -q "Caddyfile" || [ "$INITIAL_SETUP" = true ]; then
    if [ -f "$REPO_DIR/Caddyfile" ]; then
        log "Updating Caddyfile"
        cp "$REPO_DIR/Caddyfile" /etc/caddy/Caddyfile

        # Validate Caddyfile syntax
        if caddy validate --config /etc/caddy/Caddyfile; then
            log "Caddyfile validation successful"
            RELOAD_CADDY=true
        else
            error "Caddyfile validation failed, not applying changes"
        fi
    fi
fi

if echo "$CHANGED_FILES" | grep -q "zot-config.json" || [ "$INITIAL_SETUP" = true ]; then
    if [ -f "$REPO_DIR/zot-config.json" ]; then
        log "Updating zot-config.json template"
        cp "$REPO_DIR/zot-config.json" /etc/zot/config.json.template
        RESTART_ZOT=true
    fi
fi

if echo "$CHANGED_FILES" | grep -q "zot.env" || [ "$INITIAL_SETUP" = true ]; then
    # Check for encrypted version first
    if [ -f "$REPO_DIR/zot.env.age" ]; then
        log "Updating zot.env (encrypted)"
        if decrypt_age_file "$REPO_DIR/zot.env.age" /etc/zot/zot.env; then
            chmod 600 /etc/zot/zot.env
            RESTART_ZOT=true
        fi
    elif [ -f "$REPO_DIR/zot.env" ]; then
        log "Updating zot.env (plaintext)"
        cp "$REPO_DIR/zot.env" /etc/zot/zot.env
        chmod 600 /etc/zot/zot.env
        RESTART_ZOT=true
    fi
fi

if echo "$CHANGED_FILES" | grep -q "htpasswd" || [ "$INITIAL_SETUP" = true ]; then
    # Check for encrypted version first
    if [ -f "$REPO_DIR/htpasswd.age" ]; then
        log "Updating htpasswd (encrypted)"
        if decrypt_age_file "$REPO_DIR/htpasswd.age" /etc/zot/htpasswd; then
            chmod 600 /etc/zot/htpasswd
            RESTART_ZOT=true
        fi
    elif [ -f "$REPO_DIR/htpasswd" ]; then
        log "Updating htpasswd (plaintext)"
        cp "$REPO_DIR/htpasswd" /etc/zot/htpasswd
        chmod 600 /etc/zot/htpasswd
        RESTART_ZOT=true
    fi
fi

# Reload/restart services as needed
if [ "$RELOAD_CADDY" = true ]; then
    log "Reloading Caddy"
    systemctl reload caddy || systemctl restart caddy
fi

if [ "$RESTART_ZOT" = true ]; then
    log "Restarting zot service"
    systemctl restart zot.service
fi

log "Configuration sync completed successfully"
