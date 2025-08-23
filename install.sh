#!/bin/bash

# JTerrazz Infrastructure CLI - Installation Script
# This script installs the infra command and makes it globally available

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Configuration
readonly CLI_NAME="infra"
readonly INSTALL_DIR="/usr/local/bin"
readonly CLI_HOME="/opt/jterrazz-infra"

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

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This installation script must be run as root"
        echo "Please run: sudo $0"
        exit 1
    fi
}

# Detect current directory (where install.sh is located)
get_source_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
}

# Install the CLI
install_cli() {
    local source_dir="$1"
    
    log "Installing JTerrazz Infrastructure CLI..."
    
    # Create CLI home directory
    log "Creating CLI home directory: $CLI_HOME"
    rm -rf "$CLI_HOME"
    mkdir -p "$CLI_HOME"
    
    # Copy all files to CLI home
    log "Copying CLI files..."
    cp -r "$source_dir"/* "$CLI_HOME/"
    
    # Make main CLI executable
    chmod +x "$CLI_HOME/$CLI_NAME"
    
    # Make all command scripts executable
    find "$CLI_HOME/commands" -name "*.sh" -exec chmod +x {} \;
    
    # Make library files executable
    find "$CLI_HOME/lib" -name "*.sh" -exec chmod +x {} \;
    
    # Create symlink in PATH
    log "Creating global command symlink..."
    ln -sf "$CLI_HOME/$CLI_NAME" "$INSTALL_DIR/$CLI_NAME"
    
    # Verify installation
    if command -v "$CLI_NAME" &> /dev/null; then
        log "Installation completed successfully!"
    else
        error "Installation failed - command not found in PATH"
        return 1
    fi
    
    return 0
}

# Uninstall the CLI
uninstall_cli() {
    log "Uninstalling JTerrazz Infrastructure CLI..."
    
    # Remove symlink
    if [[ -L "$INSTALL_DIR/$CLI_NAME" ]]; then
        rm "$INSTALL_DIR/$CLI_NAME"
        log "Removed command symlink"
    fi
    
    # Remove CLI home directory
    if [[ -d "$CLI_HOME" ]]; then
        rm -rf "$CLI_HOME"
        log "Removed CLI files"
    fi
    
    log "Uninstallation completed"
    return 0
}



# Show installation status with nice formatting
show_status() {
    # Header
    echo
    echo -e "${BLUE}═══ JTerrazz Infrastructure CLI - Installation Status ═══${NC}"
    echo
    
    # Command Installation Status
    echo -e "${BLUE}▸ Command Installation${NC}"
    if [[ -L "$INSTALL_DIR/$CLI_NAME" ]]; then
        echo "  ✅ Global command symlink"
        echo "     Location: $INSTALL_DIR/$CLI_NAME"
        
        local target
        target=$(readlink "$INSTALL_DIR/$CLI_NAME")
        if [[ -f "$target" ]]; then
            echo "     Target: $target ✅"
        else
            echo "     Target: $target ❌ (missing)"
        fi
    else
        echo "  ❌ Global command symlink not found"
        echo "     Expected: $INSTALL_DIR/$CLI_NAME"
    fi
    
    # CLI Home Directory Status  
    echo
    echo -e "${BLUE}▸ CLI Home Directory${NC}"
    if [[ -d "$CLI_HOME" ]]; then
        echo "  ✅ CLI home directory exists"
        echo "     Location: $CLI_HOME"
        
        local file_count dir_count
        file_count=$(find "$CLI_HOME" -type f 2>/dev/null | wc -l)
        dir_count=$(find "$CLI_HOME" -type d 2>/dev/null | wc -l)
        
        echo "     Contents: $file_count files, $((dir_count - 1)) directories"
        
        # Check key directories
        if [[ -d "$CLI_HOME/commands" ]]; then
            local cmd_count
            cmd_count=$(ls -1 "$CLI_HOME/commands"/*.sh 2>/dev/null | wc -l)
            echo "     Commands: $cmd_count available"
        fi
        
        if [[ -d "$CLI_HOME/lib" ]]; then
            echo "     Libraries: ✅ Available"
        fi
    else
        echo "  ❌ CLI home directory not found"
        echo "     Expected: $CLI_HOME"
    fi
    
    # Command Availability
    echo
    echo -e "${BLUE}▸ Command Availability${NC}"
    if command -v "$CLI_NAME" &> /dev/null; then
        echo "  ✅ Command available in PATH"
        
        # Get version info
        local version_info
        if version_info=$("$CLI_NAME" --version 2>/dev/null); then
            echo "     Version: $version_info"
        else
            echo "     Version: Unable to determine"
        fi
        
        # Test basic functionality
        if "$CLI_NAME" --help &>/dev/null; then
            echo "     Status: ✅ Fully functional"
        else
            echo "     Status: ⚠️  May have issues"
        fi
    else
        echo "  ❌ Command not found in PATH"
        echo "     Run: hash -r  # Refresh shell command cache"
    fi
    
    # System Integration  
    echo
    echo -e "${BLUE}▸ System Integration${NC}"
    
    # Check shell integration
    local shell_name
    shell_name=$(basename "$SHELL" 2>/dev/null || echo "unknown")
    echo "  Shell: $shell_name"
    
    # Check if running as expected user
    if [[ $EUID -eq 0 ]]; then
        echo "  User: root (installation mode)"
    else
        echo "  User: $(whoami) (normal operation)"
    fi
    
    # Check permissions
    if [[ -x "$INSTALL_DIR/$CLI_NAME" ]]; then
        echo "  Permissions: ✅ Executable"
    else
        echo "  Permissions: ❌ Not executable"
    fi
    
    # Summary
    echo
    echo -e "${BLUE}▸ Summary${NC}"
    
    local issues=0
    local status_icon="✅"
    local status_msg="Installation is healthy"
    
    # Check for issues
    if [[ ! -L "$INSTALL_DIR/$CLI_NAME" ]]; then
        ((issues++))
    fi
    
    if [[ ! -d "$CLI_HOME" ]]; then
        ((issues++))
    fi
    
    if ! command -v "$CLI_NAME" &> /dev/null; then
        ((issues++))
    fi
    
    if [[ $issues -gt 0 ]]; then
        status_icon="⚠️"
        status_msg="Found $issues issue(s) - run 'sudo $0 install' to fix"
    fi
    
    echo "  $status_icon $status_msg"
    
    if [[ $issues -eq 0 ]]; then
        echo
        echo -e "${GREEN}🎉 Installation is working perfectly!${NC}"
        echo
        echo "Available commands:"
        echo "  infra --help           # Show help"
        echo "  infra status           # Show system status"  
        echo "  infra install          # Install dependencies"
        echo "  infra tailscale        # Manage VPN"
        echo "  infra portainer        # Manage containers"
        echo "  infra nginx            # Configure reverse proxy"
    fi
    
    echo
}

# Show help
show_help() {
    echo "JTerrazz Infrastructure CLI Installation Script"
    echo
    echo "Usage: $0 [action]"
    echo
    echo "Actions:"
    echo "  install   Install the CLI (default)"
    echo "  uninstall Remove the CLI"

    echo "  status    Show installation status"
    echo "  help      Show this help message"
    echo
    echo "Examples:"
    echo "  sudo $0           # Install CLI"
    echo "  sudo $0 install   # Install CLI"

    echo "  sudo $0 status    # Check installation"
    echo "  sudo $0 uninstall # Remove CLI"
}

# Validate source directory
validate_source() {
    local source_dir="$1"
    
    # Check required files exist
    local required_files=("$CLI_NAME" "lib/common.sh" "commands")
    
    for file in "${required_files[@]}"; do
        if [[ ! -e "$source_dir/$file" ]]; then
            error "Required file/directory not found: $file"
            error "Make sure you're running this script from the project root directory"
            return 1
        fi
    done
    
    return 0
}

# Main function
main() {
    local action="${1:-install}"
    
    case "$action" in
        install)
            check_root
            local source_dir
            source_dir=$(get_source_dir)
            validate_source "$source_dir" || exit 1
            install_cli "$source_dir" || exit 1
            echo
            info "🎉 Installation successful!"
            echo
            echo "You can now use the 'infra' command:"
            echo "  infra --help        # Show help"
            echo "  infra status        # Show system status"
            echo "  infra upgrade       # Update system"
            echo "  infra install       # Install dependencies"
            echo "  infra portainer     # Setup Portainer"
            echo "  infra nginx         # Configure reverse proxy"
            ;;

        uninstall)
            check_root
            uninstall_cli || exit 1
            ;;
        status)
            show_status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown action: $action"
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
