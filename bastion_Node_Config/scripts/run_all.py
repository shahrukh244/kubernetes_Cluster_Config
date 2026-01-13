#!/usr/bin/env python3

import subprocess
import sys
import time
from pathlib import Path

# Directory where scripts are located (updated)
BASE_DIR = Path.home() / "kubernetes_Cluster_Config/bastion_Node_Config/scripts/"

# Ordered list of scripts to execute (updated names)
SCRIPTS = [
    "01 - InstallAnsible.py",
    "02 - hostnameSet.yaml",
    "03 - rootLoginEnable.yaml",
    "04 - rootPasswdChange.yaml",
    "05 - sshKeyGen.yaml",
    "06 - disableSwap.yaml",
    "07 - disableUFW.yaml",
    "08 - enable_ip_forwarding.yaml",
    "09 - configure_chrony.yaml",
    "10 - install_oc_cli.yaml",
    "11 - install_kubectl.yaml",
    "12 - all_Node_Passwd-Less.yaml",
    "13 - fetch_kubeconfig.yaml",
]

def run_script(script_name):
    script_path = BASE_DIR / script_name

    if not script_path.exists():
        print(f"❌ Script not found: {script_name}")
        sys.exit(1)

    print("\n" + "=" * 70)
    print(f"▶ Running: {script_name}")
    print("=" * 70)

    if script_name.endswith(".py"):
        cmd = ["python3", str(script_path)]
    elif script_name.endswith((".yaml", ".yml")):
        cmd = ["ansible-playbook", str(script_path)]
    else:
        print(f"⚠ Unsupported file type: {script_name}")
        return

    result = subprocess.run(cmd)

    if result.returncode != 0:
        print(f"\n❌ FAILED: {script_name}")
        sys.exit(result.returncode)

    print(f"✅ Completed: {script_name}")
    print("⏳ Sleeping for 5 seconds before next script...\n")
    time.sleep(5)

def main():
    for script in SCRIPTS:
        run_script(script)

    print("\n🎉 ALL SCRIPTS EXECUTED SUCCESSFULLY")

if __name__ == "__main__":
    main()
