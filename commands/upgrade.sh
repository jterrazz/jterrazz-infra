#!/bin/bash

# JTerrazz Infrastructure - System Upgrade Command
# Updates system packages and security patches

# Source required libraries (paths set by main infra script)
# If running standalone, set up paths
if [[ -z "${LIB_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
    source "$LIB_DIR/common.sh"
fi

# Update system packages
update_system_packages() {
    log "Updating package lists..."
    if ! apt update; then
        error "Failed to update package lists"
        return 1
    fi
    
    # Check how many packages can be upgraded
    local upgradable_count
    upgradable_count=$(apt list --upgradable 2>/dev/null | wc -l)
    upgradable_count=$((upgradable_count - 1)) # Remove header line
    
    if [[ $upgradable_count -eq 0 ]]; then
        log "All packages are already up to date"
        return 0
    fi
    
    log "Upgrading $upgradable_count package(s)..."
    if ! apt upgrade -y; then
        error "Failed to upgrade packages"
        return 1
    fi
    
    log "System packages updated successfully"
    return 0
}

# Update security patches only
update_security_patches() {
    log "Checking for security updates..."
    
    # Check for security-related packages that can be upgraded
    local security_packages
    security_packages=$(apt list --upgradable 2>/dev/null | grep -i security | wc -l)
    
    if [[ $security_packages -eq 0 ]]; then
        log "No security updates available"
        return 0
    fi
    
    log "Found $security_packages security update(s), installing..."
    if ! unattended-upgrade -v; then
        # Fallback to manual security updates if unattended-upgrades not available
        if ! apt list --upgradable | grep -i security | cut -d'/' -f1 | xargs apt install -y; then
            warn "Could not install security updates automatically"
        fi
    fi
    
    log "Security updates completed"
    return 0
}

# Clean up package cache and orphaned packages
cleanup_system() {
    log "Cleaning up package cache..."
    apt autoremove -y
    apt autoclean
    
    log "System cleanup completed"
    return 0
}

# Check for pending reboots
check_reboot_required() {
    if [[ -f /var/run/reboot-required ]]; then
        warn "System reboot is required for some updates to take effect"
        if [[ -f /var/run/reboot-required.pkgs ]]; then
            warn "Packages requiring reboot:"
            cat /var/run/reboot-required.pkgs | sed 's/^/  - /'
        fi
        echo
        echo "Run 'sudo reboot' when convenient to complete the update process."
    else
        log "No reboot required"
    fi
}

# Perform system package upgrade
perform_system_upgrade() {
    local security_only="$1"
    
    print_header "System Upgrade"
    
    # Validate system
    check_root || exit 1
    check_os || exit 1
    
    # Show current system info
    info "Current system: $(lsb_release -d | cut -f2)"
    info "Kernel: $(uname -r)"
    echo
    
    # Perform upgrade (always check for updates)
    if [[ "$security_only" == "true" ]]; then
        update_security_patches || exit 1
    else
        update_system_packages || exit 1
    fi
    
    # Cleanup system
    cleanup_system || exit 1
    
    # Check for reboot requirement
    check_reboot_required
    
    print_section "Upgrade Summary"
    log "✅ System upgrade completed successfully!"
    
    if [[ "$security_only" != "true" ]]; then
        info "System packages checked and updated as needed"
    else
        info "Security updates checked and applied as needed"
    fi
}

# Perform self-update of the CLI
perform_self_update() {
    print_header "CLI Self-Update"
    
    # Validate system
    check_root || exit 1
    
    # Check prerequisites
    if ! command -v git &> /dev/null; then
        error "Git is required for self-update but not installed"
        error "Install git with: apt install git"
        return 1
    fi
    
    # Configuration
    local repo_url="https://github.com/jterrazz/jterrazz-infra.git"
    local temp_dir="/tmp/jterrazz-infra-update-$$"
    local current_version=""
    local new_version=""
    
    # Get current version
    if current_version=$(infra --version 2>/dev/null); then
        info "Current version: $current_version"
    else
        current_version="Unknown"
        warn "Could not determine current version"
    fi
    
    log "🔄 Fetching latest version from GitHub..."
    
    # Clean up any existing temp directory
    [[ -d "$temp_dir" ]] && rm -rf "$temp_dir"
    
    # Clone the repository
    if ! git clone --depth 1 "$repo_url" "$temp_dir" 2>/dev/null; then
        error "Failed to clone repository from $repo_url"
        error "Please check your internet connection and try again"
        return 1
    fi
    
    log "✅ Repository cloned successfully"
    
    # Check if there are actual changes
    if [[ -f "$temp_dir/infra" ]]; then
        # Simple version check (could be enhanced)
        if [[ -f /opt/jterrazz-infra/infra ]] && cmp -s "$temp_dir/infra" "/opt/jterrazz-infra/infra"; then
            info "You already have the latest version!"
            rm -rf "$temp_dir"
            return 0
        fi
    fi
    
    log "🚀 Installing updates..."
    
    # Change to temp directory and run install
    if ! (cd "$temp_dir" && ./install.sh); then
        error "Failed to install updates"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Get new version
    if new_version=$(infra --version 2>/dev/null); then
        info "Updated to: $new_version"
    else
        new_version="Updated"
    fi
    
    # Clean up
    rm -rf "$temp_dir"
    
    print_section "Self-Update Summary"
    log "✅ CLI updated successfully!"
    echo
    echo -e "${BLUE}📋 Version Information:${NC}"
    echo "  Previous: $current_version"
    echo "  Current:  $new_version"
    echo
    echo -e "${BLUE}🎉 Update completed!${NC}"
    echo "All CLI commands are now using the latest version."
    echo
    info "You can now use all the latest features and improvements!"
}

# Main upgrade command
cmd_upgrade() {
    local security_only=false
    local self_update=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --security-only)
                security_only=true
                shift
                ;;
            --self)
                self_update=true
                shift
                ;;
            --help|-h)
                show_upgrade_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_upgrade_help
                exit 1
                ;;
        esac
    done
    
    # Handle self-update or system upgrade
    if [[ "$self_update" == "true" ]]; then
        perform_self_update
    else
        perform_system_upgrade "$security_only"
    fi
}

# Show upgrade command help
show_upgrade_help() {
    echo "Usage: infra upgrade [options]"
    echo
    echo "Update system packages, security patches, or the CLI itself"
    echo
    echo "Options:"
    echo "  --security-only   Install security updates only"
    echo "  --self            Update the CLI itself from GitHub"
    echo "  --help, -h        Show this help message"
    echo
    echo "Examples:"
    echo "  infra upgrade                # Full system upgrade"
    echo "  infra upgrade --security-only  # Security patches only"
    echo "  infra upgrade --self         # Update CLI to latest version"
}
