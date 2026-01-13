#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys

def run(cmd, check=True):
    print(f"[+] Running: {cmd}")
    result = subprocess.run(
        cmd, shell=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
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
# 2. Prepare directories
# ----------------------------
ansible_dir = "/root/.ansible"
os.makedirs(ansible_dir, exist_ok=True)

# ----------------------------
# 3. Copy ansible.cfg (STATIC FILE)
# ----------------------------
repo_cfg = "/root/kubernetes_Cluster_Config/service_Node_Config/service_Node-01/config_Files/ansible/ansible.cfg"
dest_cfg = "/root/.ansible.cfg"

if not os.path.exists(repo_cfg):
    print(f"❌ ansible.cfg not found in repo: {repo_cfg}")
    sys.exit(1)

shutil.copy(repo_cfg, dest_cfg)
print(f"[+] ansible.cfg copied → {dest_cfg}")

# ----------------------------
# 4. Copy inventory
# ----------------------------
repo_hosts = "/root/kubernetes_Cluster_Config/service_Node_Config/service_Node-01/config_Files/ansible/hosts"
dest_hosts = os.path.join(ansible_dir, "hosts")

if os.path.exists(repo_hosts):
    shutil.copy(repo_hosts, dest_hosts)
    print(f"[+] Hosts copied → {dest_hosts}")
else:
    print("[*] No hosts file found, creating localhost inventory")
    with open(dest_hosts, "w") as f:
        f.write("[all]\nlocalhost ansible_connection=local\n")

# ----------------------------
# 5. Verify Ansible
# ----------------------------
print("\n[*] Verifying Ansible installation (localhost only)...")
result = run("ansible localhost -m ping", check=False)

if result.returncode == 0 and '"pong"' in result.stdout:
    print("[+] ✅ Ansible is fully operational for root user.")
else:
    print("[-] ❌ Ping test failed!")
    print(result.stderr)
    sys.exit(1)

print("\n🎉 Ansible is READY!")
print("📄 Config   : /root/.ansible.cfg")
print("📦 Inventory: /root/.ansible/hosts")



