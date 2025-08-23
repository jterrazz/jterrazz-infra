#!/bin/bash

# JTerrazz Infrastructure - Common Library
# Shared utilities, logging, and state management functions

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Configuration with sensible defaults for private network access via Tailscale
readonly DOMAIN_NAME="${DOMAIN_NAME:-manager.jterrazz.com}"
readonly PORTAINER_VERSION="${PORTAINER_VERSION:-latest}"

# State management
readonly STATE_DIR="/var/lib/jterrazz-infra"
readonly STATE_FILE="${STATE_DIR}/state"

# Ensure state directory exists
init_state() {
    mkdir -p "$STATE_DIR"
    touch "$STATE_FILE"
}

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}" >&2
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}" >&2
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" >&2
    return 1
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}" >&2
}

# State management functions
mark_step_completed() {
    local step="$1"
    init_state
    echo "$step" >> "$STATE_FILE"
    log "✓ Step '$step' completed"
}

is_step_completed() {
    local step="$1"
    init_state
    grep -q "^$step$" "$STATE_FILE" 2>/dev/null
}

skip_step() {
    local step="$1"
    warn "⏭ Skipping step '$step' (already completed)"
}

# Execute step with state tracking
run_step() {
    local step="$1"
    local step_function="$2"
    
    if is_step_completed "$step"; then
        skip_step "$step"
        return 0
    fi
    
    log "🚀 Running step: $step"
    if $step_function; then
        mark_step_completed "$step"
        return 0
    else
        error "Step '$step' failed. Fix the issue and run the command again."
        return 1
    fi
}

# Reset state for a specific step
reset_step() {
    local step="$1"
    init_state
    sed -i "/^$step$/d" "$STATE_FILE" 2>/dev/null || true
    log "Reset state for step: $step"
}

# Show completed steps
show_completed_steps() {
    init_state
    if [[ -s "$STATE_FILE" ]]; then
        echo -e "${BLUE}Completed steps:${NC}"
        cat "$STATE_FILE" | sed 's/^/  ✓ /'
    else
        echo "No steps completed yet."
    fi
}

# Clear all state
clear_state() {
    init_state
    > "$STATE_FILE"
    log "Cleared all state"
}

# System validation functions
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This operation requires root privileges"
        return 1
    fi
    return 0
}

check_os() {
    if ! command -v apt &> /dev/null; then
        error "This script requires a Debian/Ubuntu system with apt package manager"
        return 1
    fi
    return 0
}

# Service management
is_service_running() {
    local service="$1"
    systemctl is-active --quiet "$service" 2>/dev/null
}

is_service_enabled() {
    local service="$1"
    systemctl is-enabled --quiet "$service" 2>/dev/null
}

# Docker utilities
is_docker_installed() {
    command -v docker &> /dev/null
}

is_container_running() {
    local container="$1"
    docker ps --format 'table {{.Names}}' | grep -q "^$container$" 2>/dev/null
}

# Network utilities
is_port_open() {
    local port="$1"
    netstat -tuln 2>/dev/null | grep -q ":$port " || ss -tuln 2>/dev/null | grep -q ":$port "
}

test_domain_resolution() {
    local domain="$1"
    nslookup "$domain" &>/dev/null
}

# Tailscale utilities
is_tailscale_installed() {
    command -v tailscale &> /dev/null
}

is_tailscale_connected() {
    if ! is_tailscale_installed; then
        return 1
    fi
    
    local status
    status=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null)
    [[ "$status" == "Running" ]]
}

get_tailscale_ip() {
    if ! is_tailscale_connected; then
        return 1
    fi
    
    tailscale ip -4 2>/dev/null | head -1
}

# SSL utilities
has_valid_ssl_cert() {
    local domain="$1"
    local cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
    [[ -f "$cert_path" ]]
}

get_cert_expiry_days() {
    local domain="$1"
    local cert_path="/etc/letsencrypt/live/$domain/cert.pem"
    
    if [[ ! -f "$cert_path" ]]; then
        echo "0"
        return 1
    fi
    
    local expiry_date
    expiry_date=$(openssl x509 -in "$cert_path" -noout -enddate | cut -d= -f2)
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s)
    local current_epoch
    current_epoch=$(date +%s)
    local days_until_expiry=$(( (expiry_epoch - current_epoch) / 86400 ))
    
    echo "$days_until_expiry"
}

# Display utilities
print_header() {
    local title="$1"
    echo
    echo -e "${BLUE}═══ $title ═══${NC}"
    echo
}

print_section() {
    local title="$1"
    echo
    echo -e "${BLUE}▸ $title${NC}"
}

# Configuration validation
validate_config() {
    # Validate domain name format
    if [[ ! "$DOMAIN_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        error "Invalid domain name format: $DOMAIN_NAME"
        return 1
    fi
    

    return 0
}

# Cleanup functions
cleanup_on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        error "Command failed with exit code $exit_code"
        echo "You can run the same command again to resume from where it left off."
    fi
    exit $exit_code
}

# Set up exit trap
trap cleanup_on_exit EXIT

# Initialize on source
validate_config
