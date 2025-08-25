#!/bin/bash
# Status checking utilities

# Check if we're in local development environment
is_local_dev() {
    command -v multipass &> /dev/null || [[ -f "local-kubeconfig.yaml" ]]
}

# Show access information
show_access_info() {
    section "🎉 Application Access"
    
    if is_local_dev; then
        # Local environment with mDNS - automatic .local domain resolution
        subsection "🌐 Your Applications"
        echo "  • Landing Page:      https://app.local/"
        echo "  • ArgoCD:           https://argocd.local/"
        echo "  • Portainer:        https://portainer.local/"
    else
        # Production environment
        subsection "🌐 Configure DNS and Access"
        echo "  • Landing Page:      https://yourdomain.com"
        echo "  • ArgoCD:           https://argocd.yourdomain.com"
        echo "  • Portainer:        https://portainer.yourdomain.com"
    fi
}



# Show VM exposed ports table
show_vm_ports_table() {
    local vm_ip="$1"
    
    subsection "🌐 VM Network & Exposed Ports"
    
    # Display VM network info cleanly
    local vm_state=$(multipass info "$VM_NAME" 2>/dev/null | grep "State:" | awk '{print $2}')
    local vm_ip=$(get_vm_ip)
    
    printf "  %-12s %s\n" "State:" "$vm_state"
    printf "  %-12s %s\n" "IPv4:" "$vm_ip"
    echo ""
    
    # Port security analysis
    info "Port Security Analysis"
    printf "  %-8s %-12s %-20s %s\n" "PORT" "ACCESS" "SERVICE" "DETAILS"
    printf "  %-8s %-12s %-20s %s\n" "----" "------" "-------" "-------"
    
    # Function to check UFW rules for a port
    check_port_access() {
        local port="$1"
        local service_name="$2"
        local description="$3"
        
        # Check if service is running first
        local service_running=false
        case "$port" in
            "22")
                ssh_vm "true" &>/dev/null && service_running=true
                ;;
            "80"|"443")
                ssh_vm "sudo k3s kubectl get svc traefik -n kube-system -o jsonpath='{.spec.ports[?(@.port==$port)].port}' 2>/dev/null" | grep -q "$port" &>/dev/null && service_running=true
                ;;
            "6443")
                ssh_vm "sudo k3s kubectl cluster-info 2>/dev/null" | grep -q "Kubernetes" &>/dev/null && service_running=true
                ;;
        esac
        
        if [ "$service_running" = false ]; then
            printf "  %-8s %-12s %-20s %s\n" "$port" "CLOSED" "$service_name" "$description (not running)"
            return
        fi
        
        # Check UFW rules for this port (UFW is always active now)
        local ufw_rules=$(ssh_vm "sudo ufw status verbose 2>/dev/null | grep -E '${port}/(tcp|udp)'" 2>/dev/null || echo "")
        
        if [[ -z "$ufw_rules" ]]; then
            # No UFW rules found = blocked by firewall
            printf "  %-8s %-12s %-20s %s\n" "$port" "BLOCKED" "$service_name" "$description (no firewall rule)"
        else
            # Analyze UFW rules to determine access level
            if echo "$ufw_rules" | grep -q "ALLOW IN.*Anywhere"; then
                printf "  %-8s %-12s %-20s %s\n" "$port" "OPEN" "$service_name" "$description (public access)"
            elif echo "$ufw_rules" | grep -qE "(192\.168\.|10\.|172\.|100\.64\.)"; then
                printf "  %-8s %-12s %-20s %s\n" "$port" "PRIVATE" "$service_name" "$description (private networks only)"
            elif echo "$ufw_rules" | grep -q "ALLOW IN"; then
                printf "  %-8s %-12s %-20s %s\n" "$port" "RESTRICTED" "$service_name" "$description (specific IPs only)"
            else
                printf "  %-8s %-12s %-20s %s\n" "$port" "UNKNOWN" "$service_name" "$description (complex rules)"
            fi
        fi
    }
    
    # Check each port
    check_port_access "22" "SSH" "VM remote access"
    check_port_access "80" "HTTP (Traefik)" "Web traffic → HTTPS redirect"  
    check_port_access "443" "HTTPS (Traefik)" "Secure web applications"
    check_port_access "6443" "Kubernetes API" "Cluster management"
    
    echo ""
    echo "  Access levels: OPEN=public, PRIVATE=internal only, RESTRICTED=specific IPs, CLOSED=not running, BLOCKED=no rule"
}

# Show comprehensive Kubernetes services table
show_kubernetes_services_table() {
    local vm_ip="$1"
    
    subsection "🚀 Kubernetes Services & Pods"
    
    # Get all services
    local services_raw=$(ssh_vm "sudo k3s kubectl get svc --all-namespaces -o wide --no-headers 2>/dev/null" || echo "")
    
    if [[ -n "$services_raw" ]]; then
        info "Services Overview"
        printf "  %-15s %-20s %-12s %-15s %-20s %s\n" "NAMESPACE" "NAME" "TYPE" "CLUSTER-IP" "EXTERNAL-IP" "PORTS"
        printf "  %-15s %-20s %-12s %-15s %-20s %s\n" "---------" "----" "----" "----------" "-----------" "-----"
        
        echo "$services_raw" | while IFS= read -r line; do
            local namespace=$(echo "$line" | awk '{print $1}')
            local name=$(echo "$line" | awk '{print $2}')
            local type=$(echo "$line" | awk '{print $3}')
            local cluster_ip=$(echo "$line" | awk '{print $4}')
            local external_ip=$(echo "$line" | awk '{print $5}')
            local ports=$(echo "$line" | awk '{print $6}')
            
            # Truncate long values for table formatting
            [[ ${#name} -gt 19 ]] && name="${name:0:16}..."
            [[ ${#external_ip} -gt 19 ]] && external_ip="${external_ip:0:16}..."
            [[ ${#ports} -gt 19 ]] && ports="${ports:0:16}..."
            
            printf "  %-15s %-20s %-12s %-15s %-20s %s\n" "$namespace" "$name" "$type" "$cluster_ip" "$external_ip" "$ports"
        done
        echo ""
    fi
    
    # Get pod status for key namespaces
    info "Key Application Pods"
    printf "  %-15s %-30s %-12s %-8s %s\n" "NAMESPACE" "NAME" "STATUS" "RESTARTS" "AGE"
    printf "  %-15s %-30s %-12s %-8s %s\n" "---------" "----" "------" "--------" "---"
    
    local pod_info=$(ssh_vm "sudo k3s kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -E '(argocd|portainer|kube-system)'" || echo "")
    
    if [[ -n "$pod_info" ]]; then
        echo "$pod_info" | while IFS= read -r line; do
            local namespace=$(echo "$line" | awk '{print $1}')
            local name=$(echo "$line" | awk '{print $2}')
            local ready=$(echo "$line" | awk '{print $3}')
            local status=$(echo "$line" | awk '{print $4}')
            local restarts=$(echo "$line" | awk '{print $5}')
            local age=$(echo "$line" | awk '{print $6}')
            
            # Truncate long pod names
            [[ ${#name} -gt 29 ]] && name="${name:0:26}..."
            
            printf "  %-15s %-30s %-12s %-8s %s\n" "$namespace" "$name" "$status" "$restarts" "$age"
        done
    else
        echo "  No pods found in key namespaces"
    fi
}

# Check ArgoCD applications specifically
show_argocd_applications() {
    local vm_ip="$1"
    
    subsection "🎯 ArgoCD Applications"
    
    local apps=$(ssh_vm "sudo k3s kubectl get applications -n argocd --no-headers 2>/dev/null" || echo "")
    if [[ -n "$apps" ]]; then
        printf "  %-20s %-12s %-12s %-15s %s\n" "APPLICATION" "SYNC STATUS" "HEALTH" "SERVER" "PATH"
        printf "  %-20s %-12s %-12s %-15s %s\n" "-----------" "-----------" "------" "------" "----"
        
        echo "$apps" | while IFS= read -r line; do
            local name=$(echo "$line" | awk '{print $1}')
            local project=$(echo "$line" | awk '{print $2}')
            local sync=$(echo "$line" | awk '{print $3}')
            local health=$(echo "$line" | awk '{print $4}')
            local server=$(echo "$line" | awk '{print $5}')
            local path=$(echo "$line" | awk '{print $6}' || echo "N/A")
            
            # Truncate for formatting
            [[ ${#name} -gt 19 ]] && name="${name:0:16}..."
            [[ ${#server} -gt 14 ]] && server="${server:0:11}..."
            [[ ${#path} -gt 19 ]] && path="${path:0:16}..."
            
            printf "  %-20s %-12s %-12s %-15s %s\n" "$name" "$sync" "$health" "$server" "$path"
        done
    else
        echo "  No ArgoCD applications deployed yet"
        echo "  Use ArgoCD to deploy your apps from separate git repositories"
    fi
}

# User-friendly VM status display
show_vm_status() {
    section "🖥️ Infrastructure Overview"
    
    if ! vm_exists; then
        error "VM '$VM_NAME' not found"
        echo "    • Run 'make start' to create VM"
        return 1
    fi
    
    local vm_ip=$(get_vm_ip)
    if [[ -z "$vm_ip" ]]; then
        error "Cannot determine VM IP"
        return 1
    fi
    
    # VM basic info
    subsection "📋 VM Details"
    local vm_state=$(multipass info "$VM_NAME" | grep "State:" | awk '{print $2}')
    local vm_cpu=$(multipass info "$VM_NAME" | grep "CPU(s):" | awk '{print $2}')
    local vm_mem=$(multipass info "$VM_NAME" | grep "Memory usage:" | awk '{print $3, $4, $5, $6, $7}')
    local vm_disk=$(multipass info "$VM_NAME" | grep "Disk usage:" | awk '{print $3, $4, $5, $6, $7}')
    
    printf "  %-12s %-15s %-25s %s\n" "PROPERTY" "VALUE" "USAGE" "STATUS"
    printf "  %-12s %-15s %-25s %s\n" "--------" "-----" "-----" "------"
    printf "  %-12s %-15s %-25s %s\n" "State" "$vm_state" "-" "$([ "$vm_state" = "Running" ] && echo "✅ OK" || echo "❌ ISSUE")"
    printf "  %-12s %-15s %-25s %s\n" "CPU" "${vm_cpu} cores" "-" "✅ OK"
    printf "  %-12s %-15s %-25s %s\n" "Memory" "-" "$vm_mem" "✅ OK"
    printf "  %-12s %-15s %-25s %s\n" "Disk" "-" "$vm_disk" "✅ OK"
    
    # VM network & ports
    show_vm_ports_table "$vm_ip"
    
    # System health check
    echo ""
    section "🔍 System Health"
    if ssh_vm "true" &>/dev/null; then
        echo "  ✅ SSH connectivity working"
    else
        echo "  ❌ SSH connectivity failed"
        return 1
    fi
    
    if ssh_vm "sudo k3s kubectl get nodes --no-headers 2>/dev/null" | grep -q "Ready"; then
        echo "  ✅ Kubernetes cluster healthy"
        local node_info=$(ssh_vm "sudo k3s kubectl get nodes --no-headers 2>/dev/null | head -1")
        echo "     Node: $(echo "$node_info" | awk '{print $1" ("$2", "$3")"}')"
    else
        echo "  ❌ Kubernetes cluster not responding"
        return 1
    fi
    
    # Enhanced security overview
    section "🛡️ Security Overview"
    
    subsection "🔐 Security Services"
    printf "  %-20s %-12s %s\n" "SERVICE" "STATUS" "DETAILS"
    printf "  %-20s %-12s %s\n" "-------" "------" "-------"
    
    # fail2ban with jail info
    if ssh_vm "sudo systemctl is-active fail2ban 2>/dev/null" | grep -q "active"; then
        local jail_count=$(ssh_vm "sudo fail2ban-client status 2>/dev/null | grep -c 'Jail list:' || echo '0'" 2>/dev/null)
        local banned_count=$(ssh_vm "sudo fail2ban-client status 2>/dev/null | grep -o 'Currently banned:[[:space:]]*[0-9]*' | grep -o '[0-9]*' || echo '0'" 2>/dev/null)
        printf "  %-20s %-12s %s\n" "fail2ban" "✅ Active" "Jails: ${jail_count:-0}, Banned IPs: ${banned_count:-0}"
    else
        printf "  %-20s %-12s %s\n" "fail2ban" "⚠️  Inactive" "Intrusion prevention disabled"
    fi
    
    # UFW with rules count and security context
    if ssh_vm "sudo systemctl is-active ufw 2>/dev/null" | grep -q "active"; then
        local ufw_status=$(ssh_vm "sudo ufw status 2>/dev/null | head -1 | awk '{print \$2}'" 2>/dev/null || echo "unknown")
        local rules_count=$(ssh_vm "sudo ufw status numbered 2>/dev/null | grep -c '^\\[' || echo '0'" 2>/dev/null)
        if [[ "$ufw_status" == "active" ]]; then
            printf "  %-20s %-12s %s\n" "ufw" "✅ Active" "Firewall: ${ufw_status}, Rules: ${rules_count:-0}"
        else
            printf "  %-20s %-12s %s\n" "ufw" "⚠️  Service Running" "Firewall: ${ufw_status}, Rules: ${rules_count:-0}"
        fi
    else
        if is_local_dev; then
            printf "  %-20s %-12s %s\n" "ufw" "🔧 Local Mode" "Configured for local environment"
        else
            printf "  %-20s %-12s %s\n" "ufw" "❌ Critical" "Production firewall disabled!"
        fi
    fi
    
    # auditd
    if ssh_vm "sudo systemctl is-active auditd 2>/dev/null" | grep -q "active"; then
        printf "  %-20s %-12s %s\n" "auditd" "✅ Active" "System call auditing enabled"
    else
        printf "  %-20s %-12s %s\n" "auditd" "⚠️  Inactive" "System auditing disabled"
    fi
    
    # unattended-upgrades
    if ssh_vm "sudo systemctl is-active unattended-upgrades 2>/dev/null" | grep -q "active"; then
        printf "  %-20s %-12s %s\n" "auto-updates" "✅ Active" "Automatic security updates enabled"
    else
        printf "  %-20s %-12s %s\n" "auto-updates" "⚠️  Inactive" "Manual updates required"
    fi
    
    
    subsection "🔒 SSH Security"
    printf "  %-25s %s\n" "SETTING" "STATUS"
    printf "  %-25s %s\n" "-------" "------"
    
    # SSH root login
    local root_login=$(ssh_vm "sudo grep '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | awk '{print \$2}' || echo 'unknown'" 2>/dev/null)
    if [[ "$root_login" == "no" ]]; then
        printf "  %-25s %s\n" "Root login" "✅ Disabled"
    else
        printf "  %-25s %s\n" "Root login" "⚠️  Enabled or unknown"
    fi
    
    # SSH password authentication
    local pwd_auth=$(ssh_vm "sudo grep '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print \$2}' || echo 'unknown'" 2>/dev/null)
    if [[ "$pwd_auth" == "no" ]]; then
        printf "  %-25s %s\n" "Password authentication" "✅ Disabled (key-only)"
    else
        printf "  %-25s %s\n" "Password authentication" "⚠️  Enabled"
    fi
    
    # SSH port
    local ssh_port=$(ssh_vm "sudo grep '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print \$2}' || echo '22'" 2>/dev/null)
    printf "  %-25s %s\n" "SSH Port" "Port ${ssh_port:-22}"
    
    
    subsection "📊 System Security Stats"
    printf "  %-25s %s\n" "METRIC" "VALUE"
    printf "  %-25s %s\n" "------" "-----"
    
    # System uptime
    local uptime_info=$(ssh_vm "uptime -p 2>/dev/null || uptime" 2>/dev/null)
    printf "  %-25s %s\n" "System uptime" "${uptime_info:-unknown}"
    
    # Load average
    local load_avg=$(ssh_vm "uptime 2>/dev/null | awk -F'load average:' '{print \$2}' | sed 's/^[[:space:]]*//' || echo 'unknown'" 2>/dev/null)
    printf "  %-25s %s\n" "Load average" "${load_avg:-unknown}"
    
    # Failed login attempts (last 24h)
    local failed_logins=$(ssh_vm "sudo grep 'Failed password' /var/log/auth.log 2>/dev/null | grep \"\$(date +'%b %d')\" | wc -l || echo '0'" 2>/dev/null)
    if [[ "${failed_logins:-0}" -gt 0 ]]; then
        printf "  %-25s %s\n" "Failed logins (today)" "⚠️  ${failed_logins} attempts"
    else
        printf "  %-25s %s\n" "Failed logins (today)" "✅ 0 attempts"
    fi
    
    # Available updates
    local updates=$(ssh_vm "sudo apt list --upgradable 2>/dev/null | wc -l || echo '1'" 2>/dev/null)
    local update_count=$((${updates:-1} - 1))  # Subtract header line
    if [[ "$update_count" -gt 0 ]]; then
        printf "  %-25s %s\n" "Available updates" "⚠️  ${update_count} packages"
    else
        printf "  %-25s %s\n" "Available updates" "✅ System up to date"
    fi
    
    # Kubernetes services and pods
    echo ""
    show_kubernetes_services_table "$vm_ip"
    
    # ArgoCD applications
    echo ""
    show_argocd_applications "$vm_ip"
    
    # Access information
    echo ""
    show_access_info
    
    return 0
}
