import subprocess
import sys
import time
from pathlib import Path

# Logging setup
LOG_FILE = Path.home() / "svc-2_setup.log"

BASE_DIR = Path.home() / "kubernetes_Cluster_Config/service_Node_Config/service_Node-02/scripts/"

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
    "15 - reboot.yaml",
]

def log_message(msg):
    """Print to console and append to log file"""
    print(msg)
    with open(LOG_FILE, "a") as f:
        f.write(msg + "\n")

def run_script(script_name):
    script_path = BASE_DIR / script_name

    if not script_path.exists():
        log_message(f"❌ Script not found: {script_name}")
        sys.exit(1)

    log_message("\n" + "=" * 70)
    log_message(f"▶ Running: {script_name}")
    log_message("=" * 70)

    if script_name.endswith(".py"):
        cmd = ["python3", str(script_path)]
    elif script_name.endswith((".yaml", ".yml")):
        cmd = ["ansible-playbook", str(script_path)]
    else:
        log_message(f"⚠ Unsupported file type: {script_name}")
        return

    # Capture output and errors
    try:
        result = subprocess.run(cmd, capture_output=True, text=True)
        output = result.stdout
        error = result.stderr

        if output:
            log_message(output)
        if error:
            log_message(error)

        if result.returncode != 0:
            log_message(f"\n❌ FAILED: {script_name}")
            sys.exit(result.returncode)

        log_message(f"✅ Completed: {script_name}")
        log_message("⏳ Sleeping for 5 seconds before next script...\n")
        time.sleep(5)

    except Exception as e:
        log_message(f"💥 Unexpected error running {script_name}: {e}")
        sys.exit(1)

def main():
    # Clear or initialize log
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(LOG_FILE, "w") as f:
        f.write("=== Bastion Node Setup Log ===\n")

    for script in SCRIPTS:
        run_script(script)

    log_message("\n🎉 ALL SCRIPTS EXECUTED SUCCESSFULLY")

if __name__ == "__main__":
    main()
