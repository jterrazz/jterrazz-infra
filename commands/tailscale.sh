#!/bin/bash

# JTerrazz Infrastructure - Tailscale Command
# Setup and manage Tailscale VPN for secure private network access

# Source required libraries (paths set by main infra script)
# If running standalone, set up paths
if [[ -z "${LIB_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
    source "$LIB_DIR/common.sh"
fi

# Install Tailscale
install_tailscale() {
    log "Installing Tailscale..."
    
    # Check if already installed
    if command -v tailscale &> /dev/null; then
        warn "Tailscale is already installed"
        tailscale version
        return 0
    fi
    
    # Add Tailscale's package signing key and repository
    if ! curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs).noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null; then
        error "Failed to add Tailscale GPG key"
        return 1
    fi
    
    if ! curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs).tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list; then
        error "Failed to add Tailscale repository"
        return 1
    fi
    
    # Update package list and install
    if ! apt update; then
        error "Failed to update package lists for Tailscale"
        return 1
    fi
    
    if ! apt install -y tailscale; then
        error "Failed to install Tailscale"
        return 1
    fi
    
    # Enable and start tailscaled service
    if ! systemctl enable tailscaled; then
        error "Failed to enable Tailscale daemon"
        return 1
    fi
    
    if ! systemctl start tailscaled; then
        error "Failed to start Tailscale daemon"
        return 1
    fi
    
    log "Tailscale installed and service started successfully"
    tailscale version
    return 0
}

# Connect to Tailscale network
connect_tailscale() {
    local auth_key="$1"
    local advertise_routes="$2"
    local accept_routes="${3:-true}"
    local advertise_exit_node="${4:-false}"
    
    log "Connecting to Tailscale network..."
    
    if is_tailscale_connected; then
        warn "Already connected to Tailscale network"
        show_tailscale_status
        return 0
    fi
    
    # Build tailscale up command
    local up_cmd="tailscale up"
    
    # Add auth key if provided
    if [[ -n "$auth_key" ]]; then
        up_cmd="$up_cmd --auth-key=$auth_key"
    fi
    
    # Add route advertisement
    if [[ -n "$advertise_routes" ]]; then
        up_cmd="$up_cmd --advertise-routes=$advertise_routes"
    fi
    
    # Accept routes from other nodes
    if [[ "$accept_routes" == "true" ]]; then
        up_cmd="$up_cmd --accept-routes"
    fi
    
    # Exit node capability
    if [[ "$advertise_exit_node" == "true" ]]; then
        up_cmd="$up_cmd --advertise-exit-node"
    fi
    
    # Enable SSH access through Tailscale
    up_cmd="$up_cmd --ssh"
    
    log "Running: $up_cmd"
    
    if [[ -n "$auth_key" ]]; then
        # Non-interactive mode with auth key
        if ! $up_cmd; then
            error "Failed to connect to Tailscale with auth key"
            return 1
        fi
    else
        # Interactive mode - user needs to authenticate
        echo
        echo -e "${YELLOW}🔗 Tailscale Authentication Required${NC}"
        echo "Please follow the authentication URL that will be displayed."
        echo "You can also pre-generate an auth key from the Tailscale admin console:"
        echo "https://login.tailscale.com/admin/settings/keys"
        echo
        
        if ! $up_cmd; then
            error "Failed to connect to Tailscale"
            return 1
        fi
    fi
    
    # Wait for connection to establish
    log "Waiting for Tailscale connection to establish..."
    local retries=30
    while [[ $retries -gt 0 ]] && ! is_tailscale_connected; do
        sleep 2
        ((retries--))
    done
    
    if is_tailscale_connected; then
        log "Successfully connected to Tailscale network"
        show_tailscale_connection_info
    else
        warn "Connection may still be establishing"
    fi
    
    return 0
}

# Disconnect from Tailscale
disconnect_tailscale() {
    log "Disconnecting from Tailscale network..."
    
    if ! is_tailscale_connected; then
        warn "Not connected to Tailscale network"
        return 0
    fi
    
    if ! tailscale down; then
        error "Failed to disconnect from Tailscale"
        return 1
    fi
    
    log "Disconnected from Tailscale network"
    return 0
}

# Check if Tailscale is connected
is_tailscale_connected() {
    if ! command -v tailscale &> /dev/null; then
        return 1
    fi
    
    local status
    status=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null)
    [[ "$status" == "Running" ]]
}

# Get Tailscale IP address
get_tailscale_ip() {
    if ! is_tailscale_connected; then
        return 1
    fi
    
    tailscale ip -4 2>/dev/null | head -1
}

# Show Tailscale status
show_tailscale_status() {
    print_section "Tailscale Status"
    
    # Check if installed
    if ! command -v tailscale &> /dev/null; then
        echo "❌ Tailscale is not installed"
        echo "   Run: infra tailscale --install"
        return 1
    fi
    
    # Show version
    echo "Version: $(tailscale version | head -1)"
    
    # Check daemon status
    if is_service_running tailscaled; then
        echo "✅ Tailscale daemon is running"
    else
        echo "❌ Tailscale daemon is not running"
        return 1
    fi
    
    # Check connection status
    if is_tailscale_connected; then
        echo "✅ Connected to Tailscale network"
        
        # Show connection details
        show_tailscale_connection_info
        
        # Show network peers
        show_tailscale_peers
        
    else
        echo "❌ Not connected to Tailscale network"
        echo "   Run: infra tailscale --connect"
    fi
}

# Show detailed connection information
show_tailscale_connection_info() {
    echo
    echo "Connection Information:"
    
    # Get Tailscale IP
    local ts_ip
    ts_ip=$(get_tailscale_ip)
    if [[ -n "$ts_ip" ]]; then
        echo "  🔗 Tailscale IP: $ts_ip"
    fi
    
    # Show status details
    if command -v jq &> /dev/null; then
        local status_json
        status_json=$(tailscale status --json 2>/dev/null)
        
        if [[ -n "$status_json" ]]; then
            # Extract key information
            local hostname machine_name
            hostname=$(echo "$status_json" | jq -r '.Self.HostName // empty')
            machine_name=$(echo "$status_json" | jq -r '.Self.DNSName // empty')
            
            [[ -n "$hostname" ]] && echo "  🖥️  Hostname: $hostname"
            [[ -n "$machine_name" ]] && echo "  📡 Machine name: $machine_name"
            
            # Check if routes are advertised
            local advertised_routes
            advertised_routes=$(echo "$status_json" | jq -r '.Self.PrimaryRoutes[]? // empty' 2>/dev/null)
            if [[ -n "$advertised_routes" ]]; then
                echo "  🛣️  Advertised routes:"
                echo "$advertised_routes" | sed 's/^/     /'
            fi
        fi
    fi
    
    # Show public endpoint if available
    local public_ip
    public_ip=$(tailscale status --json 2>/dev/null | jq -r '.Self.Addrs[0] // empty' 2>/dev/null)
    if [[ -n "$public_ip" ]]; then
        echo "  🌐 Public endpoint: $public_ip"
    fi
}

# Show Tailscale network peers
show_tailscale_peers() {
    echo
    echo "Network Peers:"
    
    # Simple peer listing
    local peers
    peers=$(tailscale status --peers=false 2>/dev/null | tail -n +2)
    
    if [[ -n "$peers" ]]; then
        echo "$peers" | while IFS= read -r line; do
            [[ -n "$line" ]] && echo "  $line"
        done
    else
        echo "  No other peers visible"
    fi
}

# Configure Tailscale for subnet routing
configure_subnet_router() {
    local subnet="$1"
    
    if [[ -z "$subnet" ]]; then
        # Auto-detect local subnet
        subnet=$(ip route | grep "$(ip route | awk '/default/ {print $5}' | head -1)" | grep -E '192\.168\.|10\.|172\.' | head -1 | awk '{print $1}')
        
        if [[ -z "$subnet" ]]; then
            error "Could not auto-detect subnet. Please specify manually."
            return 1
        fi
        
        log "Auto-detected subnet: $subnet"
    fi
    
    log "Configuring as subnet router for: $subnet"
    
    # Enable IP forwarding
    echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
    sysctl -p
    
    # Reconnect with subnet advertisement
    if is_tailscale_connected; then
        tailscale down
    fi
    
    connect_tailscale "" "$subnet" "true" "false"
    
    log "Subnet router configuration completed"
    echo "⚠️  Remember to approve subnet routes in the Tailscale admin console:"
    echo "   https://login.tailscale.com/admin/machines"
    
    return 0
}

# Set up Tailscale SSH
configure_tailscale_ssh() {
    log "Configuring Tailscale SSH access..."
    
    if ! is_tailscale_connected; then
        error "Must be connected to Tailscale first"
        return 1
    fi
    
    # Reconnect with SSH enabled
    tailscale down
    connect_tailscale "" "" "true" "false"
    
    log "Tailscale SSH configured"
    echo "You can now SSH using Tailscale machine names:"
    echo "  ssh user@machine-name"
    
    return 0
}

# Update Tailscale to latest version
update_tailscale() {
    log "Updating Tailscale to latest version..."
    
    if ! command -v tailscale &> /dev/null; then
        error "Tailscale is not installed"
        return 1
    fi
    
    # Update package lists and upgrade
    apt update
    apt upgrade -y tailscale
    
    # Restart daemon to use new version
    systemctl restart tailscaled
    
    log "Tailscale updated successfully"
    tailscale version
    return 0
}



# Generate Tailscale auth key (requires tailscale CLI authenticated)
generate_auth_key() {
    log "Generating Tailscale auth key..."
    
    if ! command -v tailscale &> /dev/null; then
        error "Tailscale is not installed"
        return 1
    fi
    
    if ! is_tailscale_connected; then
        error "Must be connected to Tailscale to generate auth keys"
        return 1
    fi
    
    # This requires the tailscale CLI to be authenticated with admin access
    local auth_key
    if auth_key=$(tailscale up --authkey-only 2>/dev/null); then
        echo "Generated auth key: $auth_key"
        echo
        echo "⚠️  This key can be used to connect other machines:"
        echo "   infra tailscale --connect --auth-key=$auth_key"
        echo
        echo "🔒 Keep this key secure - it provides access to your network!"
    else
        error "Failed to generate auth key"
        echo "Generate keys from the admin console: https://login.tailscale.com/admin/settings/keys"
        return 1
    fi
    
    return 0
}

# Main tailscale command
cmd_tailscale() {
    local action="status"
    local auth_key=""
    local subnet=""
    local advertise_exit_node=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --install|-i)
                action="install"
                shift
                ;;
            --connect|-c)
                action="connect"
                shift
                ;;
            --disconnect|-d)
                action="disconnect"
                shift
                ;;
            --subnet-router)
                action="subnet-router"
                subnet="$2"
                [[ -n "$2" ]] && shift
                shift
                ;;
            --ssh)
                action="ssh"
                shift
                ;;
            --update|-u)
                action="update"
                shift
                ;;
            --uninstall)
                action="uninstall"
                shift
                ;;
            --generate-key)
                action="generate-key"
                shift
                ;;
            --auth-key)
                auth_key="$2"
                if [[ -z "$auth_key" ]]; then
                    error "Auth key value required"
                    exit 1
                fi
                shift 2
                ;;
            --exit-node)
                advertise_exit_node=true
                shift
                ;;
            --status|-s)
                action="status"
                shift
                ;;
            --help|-h)
                show_tailscale_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_tailscale_help
                exit 1
                ;;
        esac
    done
    
    # Validate system for non-status operations
    if [[ "$action" != "status" && "$action" != "help" ]]; then
        check_root || exit 1
        check_os || exit 1
    fi
    
    # Execute action
    case "$action" in
        install)
            print_header "Tailscale Installation"
            run_step "tailscale_installation" "install_tailscale" || exit 1
            echo
            log "🎉 Tailscale installed successfully!"
            echo
            echo "Next steps:"
            echo "  1. infra tailscale --connect    # Connect to your network"
            echo "  2. infra tailscale --status     # Check connection status"
            ;;
        connect)
            print_header "Tailscale Connection"
            
            if ! command -v tailscale &> /dev/null; then
                error "Tailscale is not installed. Run: infra tailscale --install"
                exit 1
            fi
            
            connect_tailscale "$auth_key" "" "true" "$advertise_exit_node" || exit 1
            ;;
        disconnect)
            print_header "Tailscale Disconnection"
            disconnect_tailscale || exit 1
            ;;
        subnet-router)
            print_header "Tailscale Subnet Router Setup"
            configure_subnet_router "$subnet" || exit 1
            ;;
        ssh)
            print_header "Tailscale SSH Configuration"
            configure_tailscale_ssh || exit 1
            ;;
        update)
            print_header "Tailscale Update"
            update_tailscale || exit 1
            ;;
        uninstall)
            print_header "Tailscale Complete Uninstallation"
            echo
            echo "This will completely remove Tailscale and all its data:"
            echo "  • Stop and disable Tailscale service"
            echo "  • Remove Tailscale package"
            echo "  • Delete all configuration and state files"
            echo "  • Remove firewall rules"
            echo "  • Clean up system configurations"
            echo
            read -p "Are you sure you want to completely uninstall Tailscale? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                uninstall_tailscale_complete || exit 1
            else
                log "Uninstallation cancelled"
            fi
            ;;
        generate-key)
            print_header "Tailscale Auth Key Generation"
            generate_auth_key || exit 1
            ;;
        status)
            show_tailscale_status
            ;;
    esac
}

# Complete uninstallation of Tailscale
uninstall_tailscale_complete() {
    log "Starting complete Tailscale uninstallation..."
    
    # Stop and disable Tailscale service
    if systemctl is-active --quiet tailscaled 2>/dev/null; then
        log "Stopping Tailscale service..."
        systemctl stop tailscaled || warn "Failed to stop tailscaled service"
    fi
    
    if systemctl is-enabled --quiet tailscaled 2>/dev/null; then
        log "Disabling Tailscale service..."
        systemctl disable tailscaled || warn "Failed to disable tailscaled service"
    fi
    
    # Disconnect from Tailscale network
    if command -v tailscale &> /dev/null; then
        log "Disconnecting from Tailscale network..."
        tailscale logout 2>/dev/null || true
        tailscale down 2>/dev/null || true
    fi
    
    # Remove Tailscale package
    log "Removing Tailscale package..."
    if command -v apt &> /dev/null; then
        apt remove --purge -y tailscale 2>/dev/null || warn "Failed to remove Tailscale package"
        apt autoremove -y 2>/dev/null || true
    fi
    
    # Remove repository and GPG key
    log "Cleaning up Tailscale repository..."
    rm -f /etc/apt/sources.list.d/tailscale.list 2>/dev/null || true
    rm -f /usr/share/keyrings/tailscale-archive-keyring.gpg 2>/dev/null || true
    
    # Remove configuration and state files
    log "Removing Tailscale configuration and data..."
    rm -rf /var/lib/tailscale 2>/dev/null || true
    rm -rf /etc/default/tailscaled 2>/dev/null || true
    rm -rf /etc/systemd/system/tailscaled.service 2>/dev/null || true
    rm -rf /run/tailscale 2>/dev/null || true
    
    # Remove any user configuration
    for user_home in /home/*/; do
        if [[ -d "$user_home" ]]; then
            rm -rf "${user_home}.config/tailscale" 2>/dev/null || true
        fi
    done
    rm -rf /root/.config/tailscale 2>/dev/null || true
    
    # Remove firewall rules
    log "Cleaning up firewall rules..."
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        # Remove common Tailscale ports
        ufw delete allow 41641/udp 2>/dev/null || true
        ufw delete allow from 100.64.0.0/10 2>/dev/null || true
        ufw delete allow to 100.64.0.0/10 2>/dev/null || true
        log "Removed Tailscale UFW firewall rules"
    fi
    
    # Clean up IP forwarding if it was enabled for subnet routing
    if [[ -f /etc/sysctl.d/99-tailscale.conf ]]; then
        log "Removing IP forwarding configuration..."
        rm -f /etc/sysctl.d/99-tailscale.conf
        sysctl -p 2>/dev/null || true
    fi
    
    # Remove any systemd reload
    systemctl daemon-reload 2>/dev/null || true
    
    # Clean up package cache
    apt update 2>/dev/null || true
    
    # Remove Tailscale state from our tracking
    if [[ -f /var/lib/jterrazz-infra/state ]]; then
        sed -i '/tailscale_installation/d' /var/lib/jterrazz-infra/state 2>/dev/null || true
    fi
    
    log "✅ Tailscale completely uninstalled"
    log "All Tailscale components, configurations, and data have been removed"
    log "You can reinstall with: infra tailscale --install"
    
    return 0
}

# Show tailscale command help
show_tailscale_help() {
    echo "Usage: infra tailscale [action] [options]"
    echo
    echo "Setup and manage Tailscale VPN for secure private network access"
    echo
    echo "Actions:"
    echo "  --install, -i          Install Tailscale"
    echo "  --connect, -c          Connect to Tailscale network"
    echo "  --disconnect, -d       Disconnect from Tailscale network"
    echo "  --subnet-router [subnet] Configure as subnet router"
    echo "  --ssh                  Enable SSH access through Tailscale"
    echo "  --update, -u           Update Tailscale to latest version"
    echo "  --uninstall            Complete uninstallation (removes all data and configs)"
    echo "  --generate-key         Generate auth key for other machines"
    echo "  --status, -s           Show Tailscale status (default)"
    echo "  --help, -h             Show this help message"
    echo
    echo "Options:"
    echo "  --auth-key <key>       Use auth key for non-interactive connection"
    echo "  --exit-node            Advertise as exit node (use with --connect)"
    echo
    echo "Examples:"
    echo "  infra tailscale --install                    # Install Tailscale"
    echo "  infra tailscale --connect                    # Connect interactively"
    echo "  infra tailscale --connect --auth-key=xyz123  # Connect with key"
    echo "  infra tailscale --subnet-router              # Auto-detect and route local subnet"
    echo "  infra tailscale --subnet-router 192.168.1.0/24 # Route specific subnet"
    echo "  infra tailscale --status                     # Show connection status"
}
