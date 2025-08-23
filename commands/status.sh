#!/bin/bash

# JTerrazz Infrastructure - Status Command
# Show comprehensive system and service status

# Get script directory and source libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

# Source required libraries
source "$LIB_DIR/common.sh"
source "$LIB_DIR/ssl.sh"

# Show system information
show_system_info() {
    print_section "System Information"
    
    echo "OS: $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown')"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo "Hostname: $(hostname)"
    echo "Uptime: $(uptime -p 2>/dev/null || uptime | cut -d',' -f1 | sed 's/.*up //')"
    
    # Memory info
    if command -v free &> /dev/null; then
        echo "Memory: $(free -h | awk 'NR==2{printf "%.1fG/%.1fG (%.0f%%)", $3/1024/1024, $2/1024/1024, $3*100/$2}')"
    fi
    
    # Disk space
    echo "Disk Usage: $(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
    
    # Load average
    echo "Load Average: $(uptime | awk -F'load average:' '{print $2}')"
}

# Show Docker status
show_docker_status() {
    print_section "Docker Status"
    
    if ! is_docker_installed; then
        echo "❌ Docker is not installed"
        echo "   Run: infra install"
        return 1
    fi
    
    if is_service_running docker; then
        echo "✅ Docker service is running"
        docker --version
        
        # Show container status
        echo
        echo "Container Status:"
        local containers
        containers=$(docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}")
        if [[ -n "$containers" && "$containers" != "NAMES	STATUS	PORTS" ]]; then
            echo "$containers" | tail -n +2 | sed 's/^/  /'
        else
            echo "  No running containers"
        fi
        
        # Show volumes
        echo
        echo "Volumes:"
        local volumes
        volumes=$(docker volume ls --format "table {{.Name}}\t{{.Driver}}")
        if [[ -n "$volumes" && "$volumes" != "NAME	DRIVER" ]]; then
            echo "$volumes" | tail -n +2 | sed 's/^/  /'
        else
            echo "  No volumes"
        fi
        
        # Docker system info
        echo
        echo "System Usage:"
        docker system df 2>/dev/null | tail -n +2 | sed 's/^/  /' || echo "  Unable to get system usage"
        
    else
        echo "❌ Docker service is not running"
        if is_service_enabled docker; then
            echo "   Status: Enabled but stopped"
        else
            echo "   Status: Not enabled"
        fi
    fi
}

# Show network status
show_network_status() {
    print_section "Network Status"
    
    # Show listening ports
    echo "Listening Ports:"
    
    # Check key ports
    local ports=("22:SSH" "80:HTTP" "443:HTTPS" "9443:Portainer")
    for port_info in "${ports[@]}"; do
        local port="${port_info%%:*}"
        local service="${port_info##*:}"
        
        if is_port_open "$port"; then
            echo "  ✅ Port $port ($service) - Listening"
        else
            echo "  ❌ Port $port ($service) - Not listening"
        fi
    done
    
    # Show all listening ports
    echo
    echo "All Listening Ports:"
    if command -v ss &> /dev/null; then
        ss -tuln | grep LISTEN | awk '{print $5}' | sort -u | sed 's/^/  /' || echo "  Unable to list ports"
    elif command -v netstat &> /dev/null; then
        netstat -tuln | grep LISTEN | awk '{print $4}' | sort -u | sed 's/^/  /' || echo "  Unable to list ports"
    else
        echo "  ss or netstat not available"
    fi
    
    # Test external connectivity
    echo
    echo "External Connectivity:"
    if curl -s --connect-timeout 5 ifconfig.me &>/dev/null; then
        local external_ip
        external_ip=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null)
        echo "  ✅ Internet access available"
        echo "  🌐 Public IP: ${external_ip:-Unknown}"
    else
        echo "  ❌ No internet access or timeout"
    fi
}

# Show security status
show_security_status() {
    print_section "Security Status"
    
    # UFW status
    if command -v ufw &> /dev/null; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1)
        if [[ "$ufw_status" == *"active"* ]]; then
            echo "✅ UFW firewall is active"
            
            # Show rules summary
            local rules_count
            rules_count=$(ufw status numbered 2>/dev/null | grep -c "^\[")
            echo "   Rules: $rules_count configured"
        else
            echo "❌ UFW firewall is inactive"
        fi
    else
        echo "❌ UFW firewall not installed"
    fi
    
    # Fail2ban status
    if command -v fail2ban-client &> /dev/null; then
        if is_service_running fail2ban; then
            echo "✅ Fail2ban is running"
            
            # Show jail status
            local jails
            jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | cut -d: -f2 | tr -d ' \t')
            if [[ -n "$jails" ]]; then
                echo "   Active jails: $jails"
                
                # Show ban counts
                for jail in ${jails//,/ }; do
                    local banned
                    banned=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned:" | awk '{print $3}')
                    echo "   $jail: ${banned:-0} banned IPs"
                done
            fi
        else
            echo "❌ Fail2ban is not running"
        fi
    else
        echo "❌ Fail2ban not installed"
    fi
    
    # Automatic updates status
    if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
        echo "✅ Automatic security updates configured"
    else
        echo "❌ Automatic security updates not configured"
    fi
    
    # Check for pending updates
    local updates_available
    if apt list --upgradable 2>/dev/null | grep -c upgradable > /dev/null; then
        updates_available=$(apt list --upgradable 2>/dev/null | grep -c upgradable)
        if [[ "$updates_available" -gt 0 ]]; then
            echo "⚠️  $updates_available package updates available"
        else
            echo "✅ System is up to date"
        fi
    fi
    
    # Check for reboot requirement
    if [[ -f /var/run/reboot-required ]]; then
        echo "⚠️  System reboot required"
        if [[ -f /var/run/reboot-required.pkgs ]]; then
            local pkg_count
            pkg_count=$(wc -l < /var/run/reboot-required.pkgs)
            echo "   $pkg_count packages require reboot"
        fi
    else
        echo "✅ No reboot required"
    fi
}

# Show service-specific status
show_service_status() {
    print_section "Infrastructure Services"
    
    # Portainer status
    echo "Portainer:"
    if is_container_running portainer; then
        echo "  ✅ Container running"
        
        # Check accessibility
        if curl -k -s --connect-timeout 3 https://127.0.0.1:9443 &>/dev/null; then
            echo "  ✅ Service responding on https://127.0.0.1:9443"
        else
            echo "  ❌ Service not responding"
        fi
    else
        echo "  ❌ Container not running"
    fi
    
    # Nginx status
    echo
    echo "Nginx:"
    if is_service_running nginx; then
        echo "  ✅ Service running"
        
        # Check configuration
        if nginx -t &>/dev/null; then
            echo "  ✅ Configuration valid"
        else
            echo "  ❌ Configuration has errors"
        fi
        
        # Check SSL certificates
        if has_certificates "$DOMAIN_NAME"; then
            local days_remaining
            days_remaining=$(get_cert_expiry_days "$DOMAIN_NAME")
            echo "  ✅ SSL certificate valid (expires in $days_remaining days)"
            
            if [[ "$days_remaining" -lt 30 ]]; then
                echo "  ⚠️  Certificate expires soon!"
            fi
        else
            echo "  ⚠️  Using self-signed certificates"
        fi
        
        # Test domain access
        if test_domain_resolution "$DOMAIN_NAME"; then
            echo "  ✅ Domain $DOMAIN_NAME resolves"
            
            if curl -k -s --connect-timeout 5 "https://$DOMAIN_NAME" &>/dev/null; then
                echo "  ✅ HTTPS access working"
            else
                echo "  ❌ HTTPS access failed"
            fi
        else
            echo "  ❌ Domain $DOMAIN_NAME does not resolve"
        fi
    else
        echo "  ❌ Service not running"
    fi
    
    # Tailscale status
    echo
    echo "Tailscale VPN:"
    if is_tailscale_installed; then
        echo "  ✅ Tailscale installed"
        
        if is_service_running tailscaled; then
            echo "  ✅ Daemon running"
            
            if is_tailscale_connected; then
                echo "  ✅ Connected to network"
                
                # Show Tailscale IP
                local ts_ip
                ts_ip=$(get_tailscale_ip)
                if [[ -n "$ts_ip" ]]; then
                    echo "  🔗 Tailscale IP: $ts_ip"
                fi
                
                # Check if this enables private access to domain
                if [[ -n "$ts_ip" ]]; then
                    echo "  🏠 Private access: https://$DOMAIN_NAME (via Tailscale)"
                fi
            else
                echo "  ❌ Not connected to network"
            fi
        else
            echo "  ❌ Daemon not running"
        fi
    else
        echo "  ❌ Not installed"
        echo "     Run: infra tailscale --install"
    fi
}

# Show detailed Tailscale status
show_tailscale_status() {
    print_section "Tailscale VPN Status"
    
    # Check if installed
    if ! is_tailscale_installed; then
        echo "❌ Tailscale is not installed"
        echo "   Run: infra tailscale --install"
        return 1
    fi
    
    # Show version
    echo "Version: $(tailscale version 2>/dev/null | head -1 || echo 'Unknown')"
    
    # Check daemon status
    if is_service_running tailscaled; then
        echo "✅ Tailscale daemon is running"
        if is_service_enabled tailscaled; then
            echo "✅ Service is enabled (auto-start)"
        else
            echo "⚠️  Service is not enabled"
        fi
    else
        echo "❌ Tailscale daemon is not running"
        if is_service_enabled tailscaled; then
            echo "⚠️  Service is enabled but not running"
        else
            echo "❌ Service is not enabled"
        fi
        return 1
    fi
    
    # Check connection status
    if is_tailscale_connected; then
        echo "✅ Connected to Tailscale network"
        
        # Show connection details
        echo
        echo "Connection Information:"
        
        # Get Tailscale IP
        local ts_ip
        ts_ip=$(get_tailscale_ip)
        if [[ -n "$ts_ip" ]]; then
            echo "  🔗 Tailscale IP: $ts_ip"
        fi
        
        # Show hostname if available
        if command -v jq &> /dev/null; then
            local status_json hostname machine_name
            status_json=$(tailscale status --json 2>/dev/null)
            
            if [[ -n "$status_json" ]]; then
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
        
        # Show private access information
        echo
        echo "Private Network Access:"
        echo "  🏠 Domain access: https://$DOMAIN_NAME"
        echo "  🔒 Private access from any Tailscale device"
        echo "  🌐 No public DNS/firewall configuration needed"
        
        # Show peer count
        local peer_count
        peer_count=$(tailscale status --peers=false 2>/dev/null | tail -n +2 | wc -l || echo "0")
        echo "  👥 Network peers visible: $peer_count"
        
    else
        echo "❌ Not connected to Tailscale network"
        echo "   Run: infra tailscale --connect"
    fi
}

# Show completed setup steps
show_setup_progress() {
    print_section "Setup Progress"
    
    init_state
    
    if [[ -s "$STATE_FILE" ]]; then
        echo "Completed steps:"
        while IFS= read -r step; do
            echo "  ✅ $step"
        done < "$STATE_FILE"
        
        # Suggest next steps
        echo
        echo "Suggested next steps:"
        
        if ! is_step_completed "system_upgrade"; then
            echo "  • infra upgrade - Update system packages"
        fi
        
        if ! is_step_completed "system_dependencies"; then
            echo "  • infra install - Install dependencies and Docker"
        fi
        
        if ! is_tailscale_installed && is_step_completed "system_dependencies"; then
            echo "  • infra tailscale --install - Setup VPN for private access"
        fi
        
        if is_tailscale_installed && ! is_tailscale_connected && is_step_completed "system_dependencies"; then
            echo "  • infra tailscale --connect - Connect to Tailscale network"
        fi
        
        if is_tailscale_connected && ! is_step_completed "portainer_container"; then
            echo "  • Configure DNS: Point $DOMAIN_NAME to $(get_tailscale_ip 2>/dev/null || echo 'your Tailscale IP')"
            echo "  • infra portainer --deploy - Deploy Portainer"
        fi
        
        if ! is_step_completed "nginx_configuration" && is_step_completed "portainer_container"; then
            echo "  • infra nginx --configure - Setup reverse proxy"
        fi
        
    else
        echo "No setup steps completed yet"
        echo
        echo "Getting started:"
        echo "  1. infra upgrade    - Update system"
        echo "  2. infra install    - Install dependencies"
        echo "  3. infra tailscale  - Setup VPN network"
        echo "  4. Configure DNS: Point domain to Tailscale IP"
        echo "  5. infra portainer  - Deploy Portainer"
        echo "  6. infra nginx      - Setup reverse proxy"
    fi
}

# Show resource usage
show_resource_usage() {
    print_section "Resource Usage"
    
    # CPU usage
    if command -v top &> /dev/null; then
        echo "CPU Usage:"
        # Get 1-second CPU snapshot
        local cpu_usage
        cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
        echo "  Current: ${cpu_usage:-Unknown}%"
    fi
    
    # Memory usage details
    if command -v free &> /dev/null; then
        echo
        echo "Memory Usage:"
        free -h | grep -E "(Mem|Swap)" | sed 's/^/  /'
    fi
    
    # Disk usage details
    echo
    echo "Disk Usage:"
    df -h | grep -v tmpfs | tail -n +2 | sed 's/^/  /'
    
    # Docker resource usage
    if is_docker_installed && is_service_running docker; then
        echo
        echo "Docker Resource Usage:"
        docker system df 2>/dev/null | sed 's/^/  /' || echo "  Unable to get Docker usage"
    fi
}

# Main status command
cmd_status() {
    local show_all=true
    local show_system=false
    local show_docker=false
    local show_network=false
    local show_security=false
    local show_services=false
    local show_progress=false
    local show_resources=false
    local show_tailscale=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --system)
                show_all=false
                show_system=true
                shift
                ;;
            --docker)
                show_all=false
                show_docker=true
                shift
                ;;
            --network)
                show_all=false
                show_network=true
                shift
                ;;
            --security)
                show_all=false
                show_security=true
                shift
                ;;
            --services)
                show_all=false
                show_services=true
                shift
                ;;
            --progress)
                show_all=false
                show_progress=true
                shift
                ;;
            --resources)
                show_all=false
                show_resources=true
                shift
                ;;
            --tailscale)
                show_all=false
                show_tailscale=true
                shift
                ;;
            --all|-a)
                show_all=true
                shift
                ;;
            --help|-h)
                show_status_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_status_help
                exit 1
                ;;
        esac
    done
    
    print_header "Infrastructure Status Report"
    
    # Show sections based on options
    if [[ "$show_all" == "true" ]]; then
        show_system_info
        show_docker_status
        show_service_status
        show_network_status
        show_security_status
        show_setup_progress
    else
        [[ "$show_system" == "true" ]] && show_system_info
        [[ "$show_docker" == "true" ]] && show_docker_status
        [[ "$show_network" == "true" ]] && show_network_status
        [[ "$show_security" == "true" ]] && show_security_status
        [[ "$show_services" == "true" ]] && show_service_status
        [[ "$show_progress" == "true" ]] && show_setup_progress
        [[ "$show_resources" == "true" ]] && show_resource_usage
        [[ "$show_tailscale" == "true" ]] && show_tailscale_status
    fi
    
    echo
    log "Status report completed"
}

# Show status command help
show_status_help() {
    echo "Usage: infra status [section] [options]"
    echo
    echo "Show comprehensive infrastructure status report"
    echo
    echo "Sections:"
    echo "  --system      System information and resources"
    echo "  --docker      Docker service and container status"
    echo "  --network     Network connectivity and ports"
    echo "  --security    Security services and updates"
    echo "  --services    Infrastructure service status"
    echo "  --tailscale   Tailscale VPN network status"
    echo "  --progress    Setup progress and next steps"
    echo "  --resources   Detailed resource usage"
    echo "  --all, -a     Show all sections (default)"
    echo "  --help, -h    Show this help message"
    echo
    echo "Examples:"
    echo "  infra status              # Show all status information"
    echo "  infra status --services   # Show only service status"
    echo "  infra status --tailscale  # Show only Tailscale status"
    echo "  infra status --security   # Show only security status"
}
