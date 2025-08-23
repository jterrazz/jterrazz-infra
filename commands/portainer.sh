#!/bin/bash

# JTerrazz Infrastructure - Portainer Command
# Setup and manage Portainer container manager

# Source required libraries (paths set by main infra script)
# If running standalone, set up paths
if [[ -z "${LIB_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
    source "$LIB_DIR/common.sh"
fi

# Create Portainer data volume
create_portainer_volume() {
    log "Creating Portainer data volume..."
    
    # Check if volume already exists
    if docker volume ls | grep -q portainer_data; then
        warn "Portainer data volume already exists, skipping creation"
        return 0
    fi
    
    if ! docker volume create portainer_data; then
        error "Failed to create Portainer data volume"
        return 1
    fi
    
    log "Portainer data volume created successfully"
    return 0
}

# Deploy Portainer container
deploy_portainer_container() {
    log "Deploying Portainer container..."
    
    # Stop and remove existing container if it exists
    if docker ps -a --format 'table {{.Names}}' | grep -q '^portainer$'; then
        warn "Existing Portainer container found, removing..."
        docker stop portainer 2>/dev/null || true
        docker rm portainer 2>/dev/null || true
    fi
    
    # Get Tailscale IP for private access
    local tailscale_ip=""
    if command -v tailscale &> /dev/null && tailscale status --json &>/dev/null; then
        tailscale_ip=$(tailscale ip -4 2>/dev/null)
    fi
    
    # Deploy Portainer for private Tailscale network access
    local bind_ip="127.0.0.1"
    if [[ -n "$tailscale_ip" ]]; then
        bind_ip="$tailscale_ip"
        log "Binding Portainer to Tailscale IP: $tailscale_ip"
    else
        log "Tailscale not connected, binding to localhost"
        warn "Portainer will only be accessible locally until Tailscale is configured"
    fi
    
    if ! docker run -d \
        -p ${bind_ip}:9443:9443 \
        --name portainer \
        --restart=always \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v portainer_data:/data \
        portainer/portainer-ce:${PORTAINER_VERSION}; then
        error "Failed to deploy Portainer container"
        return 1
    fi
    
    # Wait for container to be ready
    log "Waiting for Portainer to start..."
    local retries=30
    local check_url="https://${bind_ip}:9443"
    
    while [[ $retries -gt 0 ]]; do
        if curl -k -s "$check_url" &>/dev/null; then
            break
        fi
        sleep 2
        ((retries--))
    done
    
    if [[ $retries -eq 0 ]]; then
        warn "Portainer may not be fully ready yet (timeout reached)"
    else
        log "Portainer is responding on $check_url"
        if [[ -n "$tailscale_ip" ]]; then
            log "Access via Tailscale network: https://$DOMAIN_NAME:9443"
        fi
    fi
    
    log "Portainer container deployed successfully"
    return 0
}

# Update Portainer to latest version
update_portainer() {
    log "Updating Portainer to version: $PORTAINER_VERSION..."
    
    if ! is_container_running portainer; then
        error "Portainer container is not running. Deploy it first with: infra portainer --deploy"
        return 1
    fi
    
    # Pull latest image
    if ! docker pull portainer/portainer-ce:${PORTAINER_VERSION}; then
        error "Failed to pull Portainer image"
        return 1
    fi
    
    # Stop current container
    log "Stopping current Portainer container..."
    docker stop portainer
    
    # Remove old container
    docker rm portainer
    
    # Deploy updated container
    deploy_portainer_container
    
    log "Portainer updated successfully"
    return 0
}



# Show Portainer status and information
show_portainer_status() {
    print_section "Portainer Status"
    
    # Check container status
    if is_container_running portainer; then
        echo "✅ Portainer container is running"
        
        # Show container details
        echo
        echo "Container Information:"
        docker ps --filter name=portainer --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | tail -n +2 | sed 's/^/  /'
        
        # Show version
        local version
        version=$(docker inspect portainer --format '{{.Config.Image}}' 2>/dev/null | cut -d: -f2)
        echo "  Version: ${version:-unknown}"
        
        # Check accessibility
        echo
        echo "Accessibility:"
        if curl -k -s https://127.0.0.1:9443 &>/dev/null; then
            echo "  ✅ Local access: https://127.0.0.1:9443"
        else
            echo "  ❌ Local access: Not responding"
        fi
        
        # Check if nginx is configured
        if [[ -f "/etc/nginx/sites-enabled/portainer" ]]; then
            echo "  ✅ Nginx proxy: Configured"
            echo "  🌐 Public access: https://$DOMAIN_NAME"
        else
            echo "  ⚠️  Nginx proxy: Not configured"
            echo "     Run: infra nginx"
        fi
        
    else
        echo "❌ Portainer container is not running"
        
        # Check if container exists but stopped
        if docker ps -a --format 'table {{.Names}}' | grep -q '^portainer$'; then
            echo "  Container exists but is stopped"
            echo "  Run: docker start portainer"
        else
            echo "  Container not found"
            echo "  Run: infra portainer --deploy"
        fi
    fi
    
    # Check data volume
    echo
    echo "Data Volume:"
    if docker volume ls | grep -q portainer_data; then
        echo "  ✅ portainer_data volume exists"
        local volume_size
        volume_size=$(docker system df -v | grep portainer_data | awk '{print $3}' 2>/dev/null || echo "unknown")
        echo "  Size: $volume_size"
    else
        echo "  ❌ portainer_data volume not found"
    fi
}

# Backup Portainer data
backup_portainer() {
    local backup_dir="${1:-/backup/portainer}"
    
    if ! is_container_running portainer; then
        error "Portainer container is not running"
        return 1
    fi
    
    log "Creating Portainer backup..."
    
    # Create backup directory
    mkdir -p "$backup_dir"
    
    # Create backup filename with timestamp
    local backup_file="$backup_dir/portainer-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    
    # Stop container temporarily for consistent backup
    log "Stopping Portainer container for backup..."
    docker stop portainer
    
    # Create backup of volume
    if ! docker run --rm \
        -v portainer_data:/data \
        -v "$backup_dir":/backup \
        alpine:latest \
        tar -czf "/backup/$(basename "$backup_file")" -C /data .; then
        error "Failed to create backup"
        # Restart container even if backup failed
        docker start portainer
        return 1
    fi
    
    # Restart container
    log "Restarting Portainer container..."
    docker start portainer
    
    log "Backup created: $backup_file"
    return 0
}

# Restore Portainer data from backup
restore_portainer() {
    local backup_file="$1"
    
    if [[ ! -f "$backup_file" ]]; then
        error "Backup file not found: $backup_file"
        return 1
    fi
    
    log "Restoring Portainer from backup: $backup_file"
    
    # Stop container if running
    if is_container_running portainer; then
        log "Stopping Portainer container..."
        docker stop portainer
    fi
    
    # Remove existing volume
    if docker volume ls | grep -q portainer_data; then
        warn "Removing existing portainer_data volume..."
        docker volume rm portainer_data
    fi
    
    # Create new volume
    docker volume create portainer_data
    
    # Restore data
    local backup_dir
    backup_dir=$(dirname "$backup_file")
    local backup_name
    backup_name=$(basename "$backup_file")
    
    if ! docker run --rm \
        -v portainer_data:/data \
        -v "$backup_dir":/backup \
        alpine:latest \
        tar -xzf "/backup/$backup_name" -C /data; then
        error "Failed to restore backup"
        return 1
    fi
    
    # Start container
    if docker ps -a --format 'table {{.Names}}' | grep -q '^portainer$'; then
        log "Starting Portainer container..."
        docker start portainer
    else
        log "Deploying Portainer container..."
        deploy_portainer_container
    fi
    
    log "Portainer restored successfully from backup"
    return 0
}

# Main portainer command
cmd_portainer() {
    local action="status"
    local backup_path=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --deploy|-d)
                action="deploy"
                shift
                ;;
            --update|-u)
                action="update"
                shift
                ;;

            --backup|-b)
                action="backup"
                backup_path="${2:-/backup/portainer}"
                [[ -n "$2" ]] && shift
                shift
                ;;
            --restore)
                action="restore"
                backup_path="$2"
                if [[ -z "$backup_path" ]]; then
                    error "Restore requires backup file path"
                    exit 1
                fi
                shift 2
                ;;
            --status|-s)
                action="status"
                shift
                ;;
            --help|-h)
                show_portainer_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_portainer_help
                exit 1
                ;;
        esac
    done
    
    # Validate system for non-status operations
    if [[ "$action" != "status" ]]; then
        check_root || exit 1
        
        # Check Docker installation
        if ! is_docker_installed; then
            error "Docker is not installed. Run: infra install"
            exit 1
        fi
    fi
    
    # Execute action
    case "$action" in
        deploy)
            print_header "Portainer Deployment"
            run_step "portainer_volume" "create_portainer_volume" || exit 1
            run_step "portainer_container" "deploy_portainer_container" || exit 1
            
            print_section "Deployment Summary"
            log "Portainer deployed successfully"
            echo
            echo "🌐 Access Portainer at: https://127.0.0.1:9443"
            echo "⏱️  Initial setup timeout: 5 minutes"
            echo "🔧 Configure reverse proxy: infra nginx"
            ;;
        update)
            print_header "Portainer Update"
            update_portainer || exit 1
            ;;

        backup)
            print_header "Portainer Backup"
            backup_portainer "$backup_path" || exit 1
            ;;
        restore)
            print_header "Portainer Restore"
            restore_portainer "$backup_path" || exit 1
            ;;
        status)
            show_portainer_status
            ;;
    esac
}

# Show portainer command help
show_portainer_help() {
    echo "Usage: infra portainer [action] [options]"
    echo
    echo "Manage Portainer container manager"
    echo
    echo "Actions:"
    echo "  --deploy, -d           Deploy Portainer container"
    echo "  --update, -u           Update Portainer to latest version"
    echo "  --uninstall            Complete uninstallation (removes container, images, and optionally data)"
    echo "  --backup, -b [path]    Create backup of Portainer data"
    echo "  --restore <file>       Restore Portainer from backup"
    echo "  --status, -s           Show Portainer status (default)"
    echo "  --help, -h             Show this help message"
    echo
    echo "Examples:"
    echo "  infra portainer                      # Show status"
    echo "  infra portainer --deploy             # Deploy Portainer"
    echo "  infra portainer --backup             # Backup to /backup/portainer"
    echo "  infra portainer --backup /tmp        # Backup to /tmp"
    echo "  infra portainer --restore backup.tar.gz  # Restore from backup"
}

# Complete uninstallation of Portainer
uninstall_portainer_complete() {
    log "Starting complete Portainer uninstallation..."
    
    # Stop and remove Portainer container
    if docker ps -a --format 'table {{.Names}}' | grep -q '^portainer$'; then
        log "Stopping and removing Portainer container..."
        docker stop portainer 2>/dev/null || warn "Failed to stop Portainer container"
        docker rm portainer 2>/dev/null || warn "Failed to remove Portainer container"
    else
        log "Portainer container not found (may already be removed)"
    fi
    
    # Remove Portainer data volume
    if docker volume ls | grep -q portainer_data; then
        log "Removing Portainer data volume..."
        echo "WARNING: This will permanently delete all Portainer data including:"
        echo "  • User accounts and settings"
        echo "  • Stack configurations"
        echo "  • Template customizations"
        echo "  • All Portainer application data"
        echo
        read -p "Are you sure you want to delete the Portainer data volume? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            docker volume rm portainer_data 2>/dev/null || warn "Failed to remove Portainer data volume"
            log "Portainer data volume removed"
        else
            log "Keeping Portainer data volume (can be reused on reinstall)"
        fi
    else
        log "Portainer data volume not found"
    fi
    
    # Remove any Portainer images
    log "Removing Portainer Docker images..."
    docker images --format "table {{.Repository}}:{{.Tag}}" | grep "portainer/portainer" | while read -r image; do
        if [[ -n "$image" && "$image" != "REPOSITORY:TAG" ]]; then
            docker rmi "$image" 2>/dev/null || warn "Failed to remove image: $image"
        fi
    done
    
    # Remove firewall rules for Portainer
    log "Cleaning up firewall rules..."
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw delete allow 9443/tcp 2>/dev/null || true
        ufw delete allow 9000/tcp 2>/dev/null || true  # Legacy port
        log "Removed Portainer UFW firewall rules"
    fi
    
    # Remove any backup files (with confirmation)
    if [[ -d /backup/portainer ]] && [[ -n "$(ls -A /backup/portainer 2>/dev/null)" ]]; then
        echo
        echo "Found Portainer backup files in /backup/portainer"
        read -p "Do you want to remove backup files as well? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf /backup/portainer 2>/dev/null || warn "Failed to remove backup directory"
            log "Portainer backup files removed"
        else
            log "Keeping Portainer backup files"
        fi
    fi
    
    # Remove Portainer state from our tracking
    if [[ -f /var/lib/jterrazz-infra/state ]]; then
        sed -i '/portainer_/d' /var/lib/jterrazz-infra/state 2>/dev/null || true
    fi
    
    # Clean up Docker system
    log "Cleaning up Docker system..."
    docker system prune -f &>/dev/null || true
    
    log "✅ Portainer completely uninstalled"
    log "All Portainer containers, configurations, and firewall rules have been removed"
    log "You can reinstall with: infra portainer --deploy"
    
    return 0
}

# Main command function
cmd_portainer() {
    local action="status"
    local backup_path="/backup/portainer"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --deploy|-d)
                action="deploy"
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
            --backup|-b)
                action="backup"
                if [[ -n "$2" && "$2" != --* ]]; then
                    backup_path="$2"
                    shift
                fi
                shift
                ;;
            --restore)
                action="restore"
                backup_path="$2"
                if [[ -z "$backup_path" ]]; then
                    error "Backup file path required for restore"
                    show_portainer_help
                    exit 1
                fi
                shift 2
                ;;
            --status|-s)
                action="status"
                shift
                ;;
            --help|-h)
                show_portainer_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_portainer_help
                exit 1
                ;;
        esac
    done
    
    # Execute action based on parsed arguments
    case "$action" in
        deploy)
            print_header "Portainer Deployment"
            
            # Check prerequisites
            if ! command -v docker &> /dev/null; then
                error "Docker is not installed. Run: infra install"
                exit 1
            fi
            
            # Deploy Portainer
            run_step "portainer_volume" "create_portainer_volume" || exit 1
            run_step "portainer_deployment" "deploy_portainer_container" || exit 1
            
            print_section "Deployment Summary"
            log "Portainer deployed successfully"
            echo
            show_portainer_access_info
            ;;
        update)
            print_header "Portainer Update"
            update_portainer || exit 1
            ;;
        uninstall)
            print_header "Portainer Complete Uninstallation"
            echo
            echo "This will completely remove Portainer and optionally its data:"
            echo "  • Stop and remove Portainer container"
            echo "  • Optionally remove data volume (with confirmation)"
            echo "  • Remove Docker images"
            echo "  • Remove firewall rules"
            echo "  • Optionally remove backup files"
            echo
            read -p "Are you sure you want to uninstall Portainer? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                uninstall_portainer_complete || exit 1
            else
                log "Uninstallation cancelled"
            fi
            ;;
        backup)
            print_header "Portainer Backup"
            backup_portainer "$backup_path" || exit 1
            ;;
        restore)
            print_header "Portainer Restore"
            restore_portainer "$backup_path" || exit 1
            ;;
        status)
            show_portainer_status
            ;;
    esac
}

# Show Portainer access information
show_portainer_access_info() {
    echo "🎉 Portainer deployed successfully!"
    echo
    echo -e "${BLUE}🌐 Access Information:${NC}"
    
    if is_tailscale_connected; then
        local ts_ip
        ts_ip=$(get_tailscale_ip)
        if [[ -n "$ts_ip" ]]; then
            echo "  • Private access: https://$DOMAIN_NAME:9443 (via Tailscale)"
            echo "  • Direct IP access: https://$ts_ip:9443"
        else
            echo "  • Local access: https://127.0.0.1:9443"
        fi
    else
        echo "  • Local access: https://127.0.0.1:9443"
        echo "  • For remote access: Configure Tailscale with 'infra tailscale --connect'"
    fi
    
    echo
    echo -e "${YELLOW}⚠️  Important Notes:${NC}"
    echo "  • Initial setup timeout: 5 minutes"
    echo "  • Management tool - private access only"
    echo "  • Create admin user on first visit"
    
    if is_tailscale_connected; then
        echo "  • Access via Tailscale network for security"
    else
        echo "  • Connect Tailscale for remote private access"
    fi
}
