#!/bin/bash
# Status checking utilities

# Check SSH connectivity
check_ssh_connectivity() {
    local vm_ip="$1"
    
    if ssh_vm "true"; then
        success "SSH connection established"
        return 0
    else
        error "SSH connection failed"
        return 1
    fi
}

# Check Kubernetes cluster health
check_kubernetes_health() {
    local vm_ip="$1"
    
    if ssh_vm "sudo k3s kubectl get nodes --no-headers 2>/dev/null" | grep -q "Ready"; then
        success "Kubernetes cluster is healthy"
        
        # Show node info
        local node_info=$(ssh_vm "sudo k3s kubectl get nodes -o wide --no-headers 2>/dev/null" | head -1)
        if [[ -n "$node_info" ]]; then
            subsection "📋 Cluster details:"
            echo "    • Node: $node_info"
        fi
        return 0
    else
        error "Kubernetes cluster not responding"
        return 1
    fi
}

# Check security services
check_security_services() {
    local vm_ip="$1"
    local services=("fail2ban" "ufw" "auditd" "unattended-upgrades")
    local all_good=true
    
    for service in "${services[@]}"; do
        if ssh_vm "sudo systemctl is-active $service 2>/dev/null" | grep -q "active"; then
            success "$service is active"
        else
            warn "$service is not active"
            all_good=false
        fi
    done
    
    return $([ "$all_good" = true ] && echo 0 || echo 1)
}

# Check Kubernetes services
check_kubernetes_services() {
    local vm_ip="$1"
    
    # Get LoadBalancer services
    local lb_services=$(ssh_vm "sudo k3s kubectl get svc --all-namespaces -o wide 2>/dev/null" | grep LoadBalancer || echo "")
    
    if [[ -n "$lb_services" ]]; then
        success "Kubernetes services running"
        subsection "🌐 LoadBalancer services:"
        
        echo "$lb_services" | while read -r line; do
            local namespace=$(echo "$line" | awk '{print $1}')
            local name=$(echo "$line" | awk '{print $2}')
            local external_ip=$(echo "$line" | awk '{print $5}')
            local ports=$(echo "$line" | awk '{print $6}')
            echo "    • $namespace/$name - $external_ip:$ports"
        done
    else
        info "No LoadBalancer services found"
    fi
}

# Check ArgoCD status
check_argocd_status() {
    local vm_ip="$1"
    
    if ssh_vm "sudo k3s kubectl get pods -n argocd 2>/dev/null | grep -q 'argocd-server.*Running'"; then
        success "ArgoCD is running"
        
        # Check applications
        local apps=$(ssh_vm "sudo k3s kubectl get applications -n argocd --no-headers 2>/dev/null" || echo "")
        if [[ -n "$apps" ]]; then
            subsection "🚀 ArgoCD applications:"
            echo "$apps" | while read -r line; do
                local name=$(echo "$line" | awk '{print $1}')
                local sync=$(echo "$line" | awk '{print $2}')
                local health=$(echo "$line" | awk '{print $3}')
                echo "    • $name: $sync/$health"
            done
        fi
    else
        warn "ArgoCD is not running"
    fi
}

# Simple VM status display
show_vm_status() {
    section "🖥️ VM Status"
    
    if ! vm_exists; then
        error "VM '$VM_NAME' not found"
        echo "    • Run 'make start' to create VM"
        return 1
    fi
    
    multipass info "$VM_NAME"
    
    local vm_ip=$(get_vm_ip)
    if [[ -z "$vm_ip" ]]; then
        error "Cannot determine VM IP"
        return 1
    fi
    
    # Basic checks
    section "🔍 Health Checks"
    check_ssh_connectivity "$vm_ip"
    check_kubernetes_health "$vm_ip"
    
    # Security
    section "🛡️ Security"
    check_security_services "$vm_ip"
    
    # Services
    section "🌐 Services"
    check_kubernetes_services "$vm_ip"
    check_argocd_status "$vm_ip"
    
    return 0
}
