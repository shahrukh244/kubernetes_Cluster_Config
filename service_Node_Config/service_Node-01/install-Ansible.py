#!/usr/bin/env python3

import os
import subprocess
import sys

def run_cmd(cmd, check=True):
    print(f"[+] Running: {' '.join(cmd)}")
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )
    if check and result.returncode != 0:
        print(f"[-] Command failed: {' '.join(cmd)}", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
    return result

def install_ansible():
    print("[*] Updating package list...")
    run_cmd(["sudo", "apt", "update"])

    print("[*] Installing Ansible from Ubuntu repository...")
    run_cmd(["sudo", "apt", "install", "-y", "ansible"])

def configure_ansible():
    config_dir = "/etc/ansible"
    config_file = os.path.join(config_dir, "ansible.cfg")
    hosts_file = os.path.join(config_dir, "hosts")

    # Create config directory
    os.makedirs(config_dir, exist_ok=True)

    # Write clean ansible.cfg (fixes deprecation warning)
    config_content = """[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
interpreter_python = auto_silent
collections_path = /root/.ansible/collections:/usr/share/ansible/collections
deprecation_warnings = False

[privilege_escalation]
become = True
become_method = sudo
become_user = root
"""

    print(f"[+] Writing Ansible config to {config_file}")
    with open(config_file, "w") as f:
        f.write(config_content)

    # Write inventory with localhost
    if not os.path.exists(hosts_file):
        print(f"[+] Creating inventory file at {hosts_file}")
        with open(hosts_file, "w") as f:
            f.write("localhost ansible_connection=local\n")

def verify_install():
    print("\n[*] Verifying Ansible installation and config...")
    result = run_cmd(["ansible", "--version"], check=False)
    if result.returncode != 0:
        print("[-] ❌ Ansible not found!", file=sys.stderr)
        sys.exit(1)

    # Check if config file is loaded
    output = result.stdout
    for line in output.splitlines():
        if line.startswith("  config file = /etc/ansible/ansible.cfg"):
            print("[+] ✅ Ansible config is active.")
            break
    else:
        print("[-] ⚠️ Config file not detected in output.")

    # Final ping test
    print("[*] Running local ping test...")
    ping_result = run_cmd([
        "ansible", "localhost", "-m", "ping"
    ], check=False)

    if ping_result.returncode == 0 and '"ping": "pong"' in ping_result.stdout:
        print("[+] ✅ Ansible is fully operational!")
    else:
        print("[-] ❌ Ping test failed.", file=sys.stderr)
        print(ping_result.stderr, file=sys.stderr)
        sys.exit(1)

def main():
    print("=== Ansible Installer & Configurator for Ubuntu 24.04 ===")
    install_ansible()
    configure_ansible()
    verify_install()
    print("\n🎉 Ansible is ready for automation!")

if __name__ == "__main__":
    # Ensure running as root (required for apt and /etc writes)
    if os.geteuid() != 0:
        print("[-] This script must be run as root (use sudo).")
        sys.exit(1)
    main()