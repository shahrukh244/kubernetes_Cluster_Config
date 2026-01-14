#!/usr/bin/env python3

import subprocess
import sys
import os
import glob
import time
import socket

# ---------- AUTO-INSTALL PARAMIKO ----------
def ensure_paramiko():
    try:
        import paramiko
        return paramiko
    except ImportError:
        print("[+] Paramiko not found, installing automatically...")
        subprocess.run(["apt", "update"], check=True)
        subprocess.run(["apt", "install", "-y", "python3-paramiko"], check=True)
        import paramiko
        return paramiko

paramiko = ensure_paramiko()

# ---------- CONFIG ----------
REMOTE_HOST = "10.0.0.113"
REMOTE_USER = "ubuntu"
REMOTE_PASS = "123"

LOCAL_PUBKEY_DIR = "/root/.ssh"
KNOWN_HOSTS = "/root/.ssh/known_hosts"
REMOTE_AUTH_KEYS = "/root/.ssh/authorized_keys"

# ---------- FUNCTIONS ----------
def read_local_pubkeys():
    keys = []
    for pub in glob.glob(os.path.join(LOCAL_PUBKEY_DIR, "*.pub")):
        with open(pub, "r") as f:
            keys.append(f.read().strip())
    if not keys:
        print("[-] No public keys found in /root/.ssh/")
        sys.exit(1)
    return keys


def add_host_to_known_hosts():
    print("[+] Fetching SSH host key and adding to known_hosts")
    os.makedirs(os.path.dirname(KNOWN_HOSTS), exist_ok=True)
    os.chmod(os.path.dirname(KNOWN_HOSTS), 0o700)

    sock = socket.socket()
    sock.connect((REMOTE_HOST, 22))

    transport = paramiko.Transport(sock)
    transport.start_client(timeout=5)

    key = transport.get_remote_server_key()
    transport.close()
    sock.close()

    entry = f"{REMOTE_HOST} {key.get_name()} {key.get_base64()}\n"

    # Avoid duplicate entries
    if os.path.exists(KNOWN_HOSTS):
        with open(KNOWN_HOSTS, "r") as f:
            if entry in f.read():
                print("[+] Host already present in known_hosts")
                return

    with open(KNOWN_HOSTS, "a") as f:
        f.write(entry)

    os.chmod(KNOWN_HOSTS, 0o600)
    print("[✓] Host key added to known_hosts")


def ssh_connect():
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(
        REMOTE_HOST,
        username=REMOTE_USER,
        password=REMOTE_PASS,
        look_for_keys=False,
        allow_agent=False
    )
    return ssh


def sudo_root_shell(ssh):
    chan = ssh.invoke_shell()
    time.sleep(1)

    chan.send("sudo su -\n")
    time.sleep(1)
    chan.send(REMOTE_PASS + "\n")
    time.sleep(1)

    return chan


def push_keys(chan, keys):
    chan.send("mkdir -p /root/.ssh\n")
    time.sleep(0.5)

    for key in keys:
        chan.send(f'echo "{key}" >> {REMOTE_AUTH_KEYS}\n')
        time.sleep(0.2)

    chan.send("chmod 700 /root/.ssh\n")
    chan.send("chmod 600 /root/.ssh/authorized_keys\n")
    time.sleep(1)


def enable_root_key_ssh(chan):
    chan.send("sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config\n")
    chan.send("sed -i 's/^#\\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config\n")
    chan.send("systemctl restart ssh\n")
    time.sleep(1)

# ---------- MAIN ----------
def main():
    if os.geteuid() != 0:
        print("[-] Run this script as root")
        sys.exit(1)

    print("[+] Reading local public SSH keys")
    keys = read_local_pubkeys()

    add_host_to_known_hosts()

    print("[+] Connecting to remote host")
    ssh = ssh_connect()

    print("[+] Switching to root on remote host")
    chan = sudo_root_shell(ssh)

    print("[+] Copying keys to remote root authorized_keys")
    push_keys(chan, keys)

    print("[+] Enabling root SSH login via key")
    enable_root_key_ssh(chan)

    ssh.close()
    print("[✓] DONE: You can now SSH as root without prompt → ssh root@10.0.0.112")


if __name__ == "__main__":
    main()
