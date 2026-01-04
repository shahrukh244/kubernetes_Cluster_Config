#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys

# ----------------------------
# Run shell command helper
# ----------------------------
def run(cmd, check=True):
    print(f"[+] Running: {cmd}")
    result = subprocess.run(cmd, shell=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        print(f"[-] Command failed: {cmd}")
        print(result.stderr)
        sys.exit(1)
    return result

# ----------------------------
# Ensure root
# ----------------------------
if os.geteuid() != 0:
    print("❌ Run this script as root!")
    sys.exit(1)

print("=== Ansible Installer & Configurator (ROOT USER-LEVEL) ===")

# ----------------------------
# 1. Update & Install Ansible
# ----------------------------
print("[*] Updating package list...")
run("apt update")

print("[*] Installing Ansible...")
run("apt install -y ansible")

# ----------------------------
# 2. Setup /root/.ansible
# ----------------------------
ansible_dir = "/root/.ansible"
os.makedirs(ansible_dir, exist_ok=True)

ansible_cfg_path = os.path.join(ansible_dir, "ansible.cfg")
hosts_path = os.path.join(ansible_dir, "hosts")

# ansible.cfg content
ansible_cfg = f"""[defaults]
inventory = {hosts_path}
host_key_checking = False
interpreter_python = auto_silent
collections_path = /root/.ansible/collections:/usr/share/ansible/collections
deprecation_warnings = False

[privilege_escalation]
become = True
become_method = sudo
become_user = root
"""

print(f"[+] Writing ansible.cfg → {ansible_cfg_path}")
with open(ansible_cfg_path, "w") as f:
    f.write(ansible_cfg)

# copy hosts from current directory (your repo)
local_hosts = os.path.join(os.getcwd(), "hosts")
if os.path.exists(local_hosts):
    shutil.copy(local_hosts, hosts_path)
    print(f"[+] Hosts copied → {hosts_path}")
else:
    print("[*] No hosts file found, creating default localhost inventory")
    with open(hosts_path, "w") as f:
        f.write("[all]\nlocalhost ansible_connection=local\n")

# ----------------------------
# 3. Verify Ansible (localhost only)
# ----------------------------
print("\n[*] Verifying Ansible installation (localhost only)...")
result = run("ansible localhost -m ping", check=False)
if result.returncode == 0 and '"pong"' in result.stdout:
    print("[+] ✅ Ansible is fully operational for root user (localhost only).")
else:
    print("[-] ❌ Ping test failed!")
    print(result.stderr)
    sys.exit(1)

print("\n🎉 Ansible is READY! User-level config: /root/.ansible")
