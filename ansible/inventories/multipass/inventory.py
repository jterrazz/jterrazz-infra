#!/usr/bin/env python3
"""
Dynamic Ansible inventory for Multipass VMs
Automatically discovers VM IP addresses from multipass
"""

import json
import subprocess
import sys
import os
import argparse

def get_multipass_vm_info():
    """Get VM information from multipass"""
    try:
        result = subprocess.run(['multipass', 'list', '--format', 'json'], 
                              capture_output=True, text=True, check=True)
        return json.loads(result.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError, FileNotFoundError):
        return {"list": []}

def get_project_root():
    """Get the project root directory"""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # Go up from ansible/inventories/multipass to project root
    return os.path.dirname(os.path.dirname(os.path.dirname(script_dir)))

def get_inventory():
    """Get the complete inventory structure"""
    project_root = get_project_root()
    ssh_key_path = os.path.join(project_root, "local-data/ssh/id_rsa")
    
    # Get multipass VM info
    multipass_data = get_multipass_vm_info()
    
    # Find jterrazz-infra VM
    target_vm = None
    for vm in multipass_data.get("list", []):
        if vm.get("name") == "jterrazz-infra":
            target_vm = vm
            break
    
    # Base inventory structure
    inventory = {
        "all": {
            "children": ["development"]
        },
        "development": {
            "hosts": []
        },
        "_meta": {
            "hostvars": {}
        }
    }
    
    # If VM is found and running, add it to inventory
    if target_vm and target_vm.get("state") == "Running":
        vm_ip = None
        for ip in target_vm.get("ipv4", []):
            # Skip localhost and docker IPs, prefer 192.168.x.x
            if not ip.startswith(("127.", "172.", "10.42.")):
                vm_ip = ip
                break
        
        if vm_ip:
            # Add host to group
            inventory["development"]["hosts"] = ["jterrazz-infra"]
            
            # Add host variables - CONNECTION INFO ONLY
            inventory["_meta"]["hostvars"]["jterrazz-infra"] = {
                "ansible_host": vm_ip,
                "ansible_user": "ubuntu", 
                "ansible_ssh_private_key_file": ssh_key_path,
                "ansible_ssh_common_args": "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
            }
    
    return inventory

def main():
    parser = argparse.ArgumentParser(description='Dynamic inventory for Multipass VMs')
    parser.add_argument('--list', action='store_true', help='List all hosts')
    parser.add_argument('--host', help='Get variables for a specific host')
    
    args = parser.parse_args()
    
    inventory = get_inventory()
    
    if args.list:
        print(json.dumps(inventory, indent=2))
    elif args.host:
        # Return host variables
        hostvars = inventory.get("_meta", {}).get("hostvars", {}).get(args.host, {})
        print(json.dumps(hostvars, indent=2))
    else:
        # Default to --list if no arguments
        print(json.dumps(inventory, indent=2))

if __name__ == "__main__":
    main()