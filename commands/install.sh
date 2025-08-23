#!/bin/bash

# JTerrazz Infrastructure - Install Command
# Installs dependencies, Docker, and core utilities

# Source required libraries (paths set by main infra script)
# If running standalone, set up paths
if [[ -z "${LIB_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
    source "$LIB_DIR/common.sh"
fi

# Install required system packages
install_system_dependencies() {
    log "Installing required system packages..."
    
    local packages=(
        curl
        wget
        gnupg
        lsb-release
        ca-certificates
        apt-transport-https
        software-properties-common
        nginx
        ssl-cert
        unattended-upgrades
        logrotate
        rsyslog
        htop
        vim
        git
        ufw
        fail2ban
    )
    
    if ! apt install -y "${packages[@]}"; then
        error "Failed to install required packages"
        return 1
    fi
    
    log "System dependencies installed successfully"
    return 0
}

# Install Docker CE
install_docker() {
    log "Installing Docker CE..."
    
    # Check if Docker is already installed
    if is_docker_installed; then
        warn "Docker is already installed, skipping installation"
        docker --version
        return 0
    fi
    
    # Add Docker's official GPG key
    if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; then
        error "Failed to add Docker GPG key"
        return 1
    fi
    
    # Add Docker repository
    local arch
    arch=$(dpkg --print-architecture)
    local codename
    codename=$(lsb_release -cs)
    
    echo "deb [arch=$arch signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $codename stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    if [[ $? -ne 0 ]]; then
        error "Failed to add Docker repository"
        return 1
    fi
    
    # Update package index
    if ! apt update; then
        error "Failed to update package index for Docker"
        return 1
    fi
    
    # Install Docker packages
    if ! apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        error "Failed to install Docker packages"
        return 1
    fi
    
    # Enable and start Docker service
    if ! systemctl enable docker; then
        error "Failed to enable Docker service"
        return 1
    fi
    
    if ! systemctl start docker; then
        error "Failed to start Docker service"
        return 1
    fi
    
    # Verify Docker installation
    if ! docker run --rm hello-world &>/dev/null; then
        warn "Docker installation verification failed, but service is running"
    fi
    
    log "Docker installed and configured successfully"
    docker --version
    return 0
}

# Configure basic firewall
configure_firewall() {
    log "Configuring basic firewall rules..."
    
    # Reset UFW to defaults
    ufw --force reset
    
    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH
    ufw allow ssh
    
    # Allow HTTPS only (no HTTP)
    ufw allow 443/tcp
    
    # Enable UFW
    ufw --force enable
    
    log "Firewall configured (SSH and HTTPS allowed)"
    return 0
}

# Configure fail2ban for basic security
configure_fail2ban() {
    log "Configuring fail2ban for SSH protection..."
    
    # Create local jail configuration
    cat > /etc/fail2ban/jail.local << 'FAIL2BAN_EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
FAIL2BAN_EOF
    
    # Enable and start fail2ban
    systemctl enable fail2ban
    systemctl restart fail2ban
    
    log "Fail2ban configured for SSH protection"
    return 0
}

# Configure automatic security updates
configure_auto_updates() {
    log "Configuring automatic security updates..."
    
    # Configure unattended-upgrades
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UNATTENDED_EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
    // Add packages to blacklist here if needed
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::SyslogEnable "true";
UNATTENDED_EOF
    
    # Enable automatic updates
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUTO_UPDATES_EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
AUTO_UPDATES_EOF
    
    log "Automatic security updates configured"
    return 0
}

# Optimize system settings
optimize_system() {
    log "Applying system optimizations..."
    
    # Configure systemd journal limits
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-limits.conf << 'JOURNAL_EOF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=1month
JOURNAL_EOF
    
    # Configure logrotate for docker logs
    cat > /etc/logrotate.d/docker-container << 'LOGROTATE_EOF'
/var/lib/docker/containers/*/*.log {
    rotate 5
    daily
    compress
    size=10M
    missingok
    delaycompress
    copytruncate
}
LOGROTATE_EOF
    
    # Apply journal configuration
    systemctl restart systemd-journald
    
    log "System optimizations applied"
    return 0
}

# Main install command
cmd_install() {
    local skip_docker=false
    local skip_firewall=false
    local skip_security=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-docker)
                skip_docker=true
                shift
                ;;
            --skip-firewall)
                skip_firewall=true
                shift
                ;;
            --skip-security)
                skip_security=true
                shift
                ;;
            --help|-h)
                show_install_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_install_help
                exit 1
                ;;
        esac
    done
    
    print_header "System Installation"
    
    # Validate system
    check_root || exit 1
    check_os || exit 1
    
    # Show system information
    info "Installing on: $(lsb_release -d | cut -f2)"
    info "Architecture: $(dpkg --print-architecture)"
    echo
    
    # Install components
    run_step "system_dependencies" "install_system_dependencies" || exit 1
    
    if [[ "$skip_docker" != "true" ]]; then
        run_step "docker_installation" "install_docker" || exit 1
    fi
    
    if [[ "$skip_firewall" != "true" ]]; then
        run_step "firewall_configuration" "configure_firewall" || exit 1
    fi
    
    if [[ "$skip_security" != "true" ]]; then
        run_step "fail2ban_configuration" "configure_fail2ban" || exit 1
        run_step "auto_updates_configuration" "configure_auto_updates" || exit 1
    fi
    
    run_step "system_optimization" "optimize_system" || exit 1
    
    # Summary
    print_section "Installation Summary"
    log "System installation completed successfully"
    
    echo
    echo "✅ Installed Components:"
    echo "  • System dependencies and utilities"
    [[ "$skip_docker" != "true" ]] && echo "  • Docker CE with compose plugin"
    echo "  • Nginx web server"
    [[ "$skip_firewall" != "true" ]] && echo "  • UFW firewall (HTTPS and SSH allowed)"
    [[ "$skip_security" != "true" ]] && echo "  • Fail2ban SSH protection"
    [[ "$skip_security" != "true" ]] && echo "  • Automatic security updates"
    echo "  • System optimizations and log management"
    
    echo
    info "You can now proceed with:"
    info "  infra portainer  # Setup Portainer container manager"
    info "  infra nginx      # Configure Nginx reverse proxy"
}

# Show install command help
show_install_help() {
    echo "Usage: infra install [options]"
    echo
    echo "Install system dependencies, Docker, and security configurations"
    echo
    echo "Options:"
    echo "  --skip-docker     Skip Docker installation"
    echo "  --skip-firewall   Skip firewall configuration"
    echo "  --skip-security   Skip security hardening (fail2ban, auto-updates)"
    echo "  --help, -h        Show this help message"
    echo
    echo "Examples:"
    echo "  infra install                    # Full installation"
    echo "  infra install --skip-docker     # Install without Docker"
}
