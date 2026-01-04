#!/usr/bin/env python3
import os
import shutil
import stat
import sys
import subprocess

# Ensure script is run as root
if os.geteuid() != 0:
    print("❌ This script must be run as root!")
    sys.exit(1)

print("=== Netplan Config Installer ===")

# Paths
repo_dir = "/root/kubernetes_Cluster_Config/service_Node_Config/service_Node-01/network-ip"
netplan_dir = "/etc/netplan"
old_file = os.path.join(netplan_dir, "50-cloud-init.yaml")

# 1️⃣ Remove existing 50-cloud-init.yaml if it exists
if os.path.exists(old_file):
    os.remove(old_file)
    print(f"[+] Removed old netplan file: {old_file}")
else:
    print("[*] No old netplan file found, skipping removal")

# 2️⃣ Copy ens32.yaml and ens33.yaml to /etc/netplan/
for fname in ["ens32.yaml", "ens33.yaml"]:
    src = os.path.join(repo_dir, fname)
    dst = os.path.join(netplan_dir, fname)
    if os.path.exists(src):
        shutil.copy(src, dst)
        print(f"[+] Copied {fname} → {netplan_dir}")
    else:
        print(f"[-] Source file not found: {src}")
        continue

    # 3️⃣ Set file permissions to -rw------- (600) and owner root:root
    os.chmod(dst, stat.S_IRUSR | stat.S_IWUSR)  # 0o600
    os.chown(dst, 0, 0)  # root:root
    print(f"[+] Set permissions 600 and owner root:root for {dst}")

# 4️⃣ Optional: Apply netplan now (so config is active without waiting for reboot)
# subprocess.run(["netplan", "apply"], check=False)
# print("[*] Netplan applied successfully")

# 5️⃣ Reboot system
print("\n[*] Rebooting system in 15 seconds to apply new network config...")
subprocess.run("sleep 15 && reboot", shell=True)
