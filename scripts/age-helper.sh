#!/bin/bash
# Helper script for encrypting/decrypting files with age for zot config sync
# Usage:
#   ./age-helper.sh encrypt <file> <public-key>
#   ./age-helper.sh decrypt <file.age> <private-key-file>

set -euo pipefail

COMMAND="${1:-}"
FILE="${2:-}"
KEY="${3:-}"

usage() {
    cat << EOF
Age Encryption Helper for Zot Config Sync

Usage:
  $0 encrypt <file> <public-key>          Encrypt a file with age
  $0 decrypt <file.age> <private-key>     Decrypt an age file
  $0 generate                             Generate a new age key pair

Examples:
  # Generate key pair
  $0 generate

  # Encrypt credentials
  $0 encrypt credentials.env age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p

  # Decrypt credentials
  $0 decrypt credentials.env.age /etc/zot/age-key.txt

Common workflow:
  1. On server: $0 generate (save the public key)
  2. Locally: $0 encrypt credentials.env <public-key>
  3. Commit credentials.env.age to git
  4. Server auto-decrypts using private key

EOF
    exit 1
}

if ! command -v age >/dev/null 2>&1; then
    echo "Error: age command not found"
    echo "Install age:"
    echo "  macOS: brew install age"
    echo "  Linux: apt install age / dnf install age"
    echo "  Windows: https://github.com/FiloSottile/age/releases"
    exit 1
fi

case "$COMMAND" in
    encrypt)
        if [ -z "$FILE" ] || [ -z "$KEY" ]; then
            echo "Error: Missing file or public key"
            usage
        fi

        if [ ! -f "$FILE" ]; then
            echo "Error: File not found: $FILE"
            exit 1
        fi

        OUTPUT="${FILE}.age"
        echo "Encrypting: $FILE -> $OUTPUT"
        age -r "$KEY" -o "$OUTPUT" "$FILE"
        echo "Success! Encrypted file: $OUTPUT"
        echo ""
        echo "Next steps:"
        echo "  1. Add to git: git add $OUTPUT"
        echo "  2. Add to .gitignore: echo '$FILE' >> .gitignore"
        echo "  3. Commit: git commit -m 'Encrypt $FILE'"
        echo "  4. Push: git push"
        ;;

    decrypt)
        if [ -z "$FILE" ] || [ -z "$KEY" ]; then
            echo "Error: Missing encrypted file or private key"
            usage
        fi

        if [ ! -f "$FILE" ]; then
            echo "Error: File not found: $FILE"
            exit 1
        fi

        if [ ! -f "$KEY" ]; then
            echo "Error: Private key not found: $KEY"
            exit 1
        fi

        OUTPUT="${FILE%.age}"
        echo "Decrypting: $FILE -> $OUTPUT"
        age -d -i "$KEY" "$FILE" > "$OUTPUT"
        echo "Success! Decrypted file: $OUTPUT"
        ;;

    generate)
        echo "Generating new age key pair..."
        KEY_FILE="age-key.txt"
        age-keygen -o "$KEY_FILE"
        chmod 600 "$KEY_FILE"
        echo ""
        echo "Key pair generated: $KEY_FILE"
        echo ""
        echo "Public key (use this for encryption):"
        grep "# public key:" "$KEY_FILE"
        echo ""
        echo "Private key location: $KEY_FILE"
        echo ""
        echo "Next steps:"
        echo "  1. Copy private key to server: scp $KEY_FILE root@YOUR_SERVER:/etc/zot/age-key.txt"
        echo "  2. Set permissions on server: ssh root@YOUR_SERVER 'chmod 600 /etc/zot/age-key.txt'"
        echo "  3. Save the public key for encrypting files"
        echo "  4. Keep $KEY_FILE secure (backup recommended)"
        ;;

    *)
        usage
        ;;
esac
