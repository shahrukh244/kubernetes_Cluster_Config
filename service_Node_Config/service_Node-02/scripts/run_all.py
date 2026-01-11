#!/usr/bin/env python3

import subprocess
import sys
import time
from pathlib import Path

# Get the current script's directory
CURRENT_DIR = Path(__file__).resolve().parent

# Define the two different paths relative to the current script
# Current script is in: service_Node-02/scripts/
# So to get to service_Node-01/scripts/: go up one level, then to service_Node-01/scripts
BASE_DIR_01 = CURRENT_DIR.parent.parent / "service_Node-01" / "scripts"
BASE_DIR_02 = CURRENT_DIR  # Scripts for node 02 are in the same directory as this script

# Ordered list of scripts to execute
SCRIPTS = [
    "01 - InstallAnsible.py",
    "02 - hostnameSet.yaml",
    "03 - setIP.yaml",
    "04 - NAT.yaml",
    "05 - rootLoginEnable.yaml",
    "06 - rootPasswdChange.yaml",
    "07 - sshKeyGen.yaml",
    "08 - disableSwap.yaml",
    "09 - disableUFW.yaml",
    "10 - keepalived.yaml",
    "11 - dhcp.yaml",
    "12 - bind9.yaml",
    "13 - ntp.yaml",
    "14 - haproxy.yaml",
    "15 - drbd_nfs.yaml",
    "16 - reboot.yaml",
]

def run_script(script_name):
    # Determine which base directory to use based on the script
    if script_name == "01 - InstallAnsible.py":
        script_path = BASE_DIR_01 / script_name
    else:
        script_path = BASE_DIR_02 / script_name

    if not script_path.exists():
        print(f"❌ Script not found: {script_name}")
        print(f"   Looked for: {script_path}")
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
