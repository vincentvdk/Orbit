#!/usr/bin/env bash

set -euo pipefail

# Configuration
SOURCE_REGISTRY="${SOURCE_REGISTRY:-registry.k8s.io}"
DEST_REGISTRY="${ZOT_REGISTRY:-localhost:5000}"
DEST_USER="${ZOT_USER:-admin}"
DEST_PASS="${ZOT_PASS:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    if ! command -v skopeo &> /dev/null; then
        log_error "skopeo is not installed. Please install it first."
        log_info ""
        log_info "Install via package manager (recommended):"
        log_info "  Debian/Ubuntu: sudo apt-get install skopeo"
        log_info "  Fedora/RHEL:   sudo dnf install skopeo"
        log_info "  Arch Linux:    sudo pacman -S skopeo"
        log_info ""
        log_info "Or run via container:"
        log_info "  alias skopeo='podman run --rm quay.io/skopeo/stable:latest'"
        exit 1
    fi
}

copy_image() {
    local source_image="$1"
    local dest_image="${2:-$source_image}"

    local source_ref="docker://${SOURCE_REGISTRY}/${source_image}"
    local dest_ref="docker://${DEST_REGISTRY}/${dest_image}"

    log_info "Copying: ${source_image} -> ${dest_image}"

    local skopeo_cmd=(
        skopeo copy
        --all
        --retry-times 3
        --src-tls-verify=true
        --dest-tls-verify=true
        --format=oci
    )

    # Add destination credentials if provided
    if [[ -n "${DEST_PASS}" ]]; then
        skopeo_cmd+=(--dest-creds "${DEST_USER}:${DEST_PASS}")
    fi

    skopeo_cmd+=("${source_ref}" "${dest_ref}")

    if "${skopeo_cmd[@]}"; then
        log_info "✓ Successfully copied: ${source_image}"
        return 0
    else
        log_error "✗ Failed to copy: ${source_image}"
        return 1
    fi
}

sync_images() {
    local failed_images=()
    local success_count=0
    local fail_count=0

    # Common Kubernetes images to sync
    # Add or modify this list based on your needs
    local images=(
        # Core Kubernetes components
        "kube-apiserver:v1.31.2"
        "kube-controller-manager:v1.31.2"
        "kube-scheduler:v1.31.2"
        "kube-proxy:v1.31.2"
        "etcd:3.5.16-0"
        "coredns/coredns:v1.11.3"
        "pause:3.10"

        # Common add-ons
        "metrics-server/metrics-server:v0.7.2"
        "ingress-nginx/controller:v1.11.3"

        # Add more images as needed
    )

    log_info "Starting sync of ${#images[@]} images from ${SOURCE_REGISTRY}"
    log_info "Destination: ${DEST_REGISTRY}"
    echo ""

    for image in "${images[@]}"; do
        if copy_image "${image}"; then
            ((success_count++))
        else
            ((fail_count++))
            failed_images+=("${image}")
        fi
        echo ""
    done

    # Summary
    echo "================================"
    log_info "Sync complete!"
    log_info "Success: ${success_count}"
    if [[ ${fail_count} -gt 0 ]]; then
        log_error "Failed: ${fail_count}"
        echo ""
        log_error "Failed images:"
        for img in "${failed_images[@]}"; do
            echo "  - ${img}"
        done
        exit 1
    fi
}

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [IMAGE...]

Sync container images from a source registry to your zot registry.

OPTIONS:
    -h, --help              Show this help message
    -s, --source ADDR       Source registry (default: registry.k8s.io)
    -r, --registry ADDR     Destination registry (default: localhost:5000)
    -u, --user USER         Destination registry username (default: admin)
    -p, --password PASS     Destination registry password
    --list                  Use predefined list of common k8s images
    --insecure              Use plain HTTP for destination registry

ENVIRONMENT VARIABLES:
    SOURCE_REGISTRY         Source registry address
    ZOT_REGISTRY            Destination registry address
    ZOT_USER                Destination registry username
    ZOT_PASS                Destination registry password

EXAMPLES:
    # Sync predefined list of k8s images
    $0 --list

    # Sync specific images from registry.k8s.io
    $0 kube-apiserver:v1.31.2 etcd:3.5.16-0

    # Sync from a different source registry
    $0 -s ghcr.io grafana/grafana:latest

    # Sync with custom destination registry
    $0 -r registry.example.com:5000 -u admin -p secret kube-proxy:v1.31.2

    # Using environment variables
    export SOURCE_REGISTRY=gcr.io
    export ZOT_REGISTRY=registry.example.com:5000
    export ZOT_PASS=secret
    $0 google-containers/pause:3.10

EOF
}

main() {
    local use_list=false
    local custom_images=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                print_usage
                exit 0
                ;;
            -s|--source)
                SOURCE_REGISTRY="$2"
                shift 2
                ;;
            -r|--registry)
                DEST_REGISTRY="$2"
                shift 2
                ;;
            -u|--user)
                DEST_USER="$2"
                shift 2
                ;;
            -p|--password)
                DEST_PASS="$2"
                shift 2
                ;;
            --list)
                use_list=true
                shift
                ;;
            *)
                custom_images+=("$1")
                shift
                ;;
        esac
    done

    check_dependencies

    if [[ ${use_list} == true ]]; then
        sync_images
    elif [[ ${#custom_images[@]} -gt 0 ]]; then
        log_info "Syncing ${#custom_images[@]} custom images"
        local failed=0
        for img in "${custom_images[@]}"; do
            if ! copy_image "${img}"; then
                ((failed++))
            fi
        done

        if [[ ${failed} -gt 0 ]]; then
            log_error "${failed} images failed to copy"
            exit 1
        else
            log_info "All images copied successfully!"
        fi
    else
        log_error "No images specified. Use --list or provide image names."
        echo ""
        print_usage
        exit 1
    fi
}

main "$@"
