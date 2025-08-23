#!/bin/bash

# JTerrazz Infrastructure - System Upgrade Command
# Updates system packages and security patches

# Update system packages
update_system_packages() {
    log "Updating package lists..."
    if ! apt update; then
        error "Failed to update package lists"
        return 1
    fi
    
    log "Upgrading installed packages..."
    if ! apt upgrade -y; then
        error "Failed to upgrade packages"
        return 1
    fi
    
    log "System packages updated successfully"
    return 0
}

# Update security patches only
update_security_patches() {
    log "Installing security updates only..."
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

# Main upgrade command
cmd_upgrade() {
    local security_only=false
    local skip_cleanup=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --security-only)
                security_only=true
                shift
                ;;
            --skip-cleanup)
                skip_cleanup=true
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
    
    print_header "System Upgrade"
    
    # Validate system
    check_root || exit 1
    check_os || exit 1
    
    # Show current system info
    info "Current system: $(lsb_release -d | cut -f2)"
    info "Kernel: $(uname -r)"
    echo
    
    # Perform upgrade
    if [[ "$security_only" == "true" ]]; then
        run_step "security_updates" "update_security_patches" || exit 1
    else
        run_step "system_upgrade" "update_system_packages" || exit 1
    fi
    
    # Cleanup unless skipped
    if [[ "$skip_cleanup" != "true" ]]; then
        run_step "system_cleanup" "cleanup_system" || exit 1
    fi
    
    # Check for reboot requirement
    check_reboot_required
    
    print_section "Upgrade Summary"
    log "System upgrade completed successfully"
    
    if [[ "$security_only" != "true" ]]; then
        info "All packages have been updated to the latest versions"
    else
        info "Security patches have been applied"
    fi
}

# Show upgrade command help
show_upgrade_help() {
    echo "Usage: infra upgrade [options]"
    echo
    echo "Update system packages and security patches"
    echo
    echo "Options:"
    echo "  --security-only   Install security updates only"
    echo "  --skip-cleanup    Skip package cleanup (autoremove/autoclean)"
    echo "  --help, -h        Show this help message"
    echo
    echo "Examples:"
    echo "  infra upgrade                # Full system upgrade"
    echo "  infra upgrade --security-only  # Security patches only"
}
