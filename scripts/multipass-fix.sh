#!/bin/bash
# Quick multipass troubleshooting script

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }

echo -e "${GREEN}🔧 Multipass Troubleshooting Tool${NC}"
echo

case "${1:-help}" in
    restart)
        info "Restarting multipass daemon..."
        sudo launchctl stop com.canonical.multipassd 2>/dev/null || true
        sleep 3
        sudo launchctl start com.canonical.multipassd 2>/dev/null || true
        sleep 2
        success "Multipass daemon restarted"
        ;;
    
    kill)
        info "Force killing all multipass processes..."
        sudo pkill -f multipass 2>/dev/null || true
        sleep 2
        success "Multipass processes killed"
        ;;
    
    nuclear)
        info "Nuclear option: killing processes and restarting daemon..."
        sudo pkill -f multipass 2>/dev/null || true
        sleep 2
        sudo launchctl stop com.canonical.multipassd 2>/dev/null || true
        sleep 3
        sudo launchctl start com.canonical.multipassd 2>/dev/null || true
        sleep 3
        multipass delete --all --purge 2>/dev/null || true
        success "Nuclear restart complete"
        ;;
    
    status)
        info "Checking multipass status..."
        echo "Multipass version:"
        multipass version 2>/dev/null || error "Multipass not responding"
        echo
        echo "Running VMs:"
        multipass list 2>/dev/null || error "Cannot list VMs"
        ;;
    
    help|*)
        echo "Usage: $0 {restart|kill|nuclear|status}"
        echo
        echo "Commands:"
        echo "  restart  - Restart multipass daemon"
        echo "  kill     - Force kill multipass processes"
        echo "  nuclear  - Kill processes, restart daemon, delete all VMs"
        echo "  status   - Check multipass status"
        echo "  help     - Show this help"
        ;;
esac
