#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

exec >> /var/log/ha-storage.log 2>&1
echo "===== MASTER $(date) ====="

drbdadm primary --force kube
udevadm settle

mountpoint -q /share/kube || mount /dev/drbd0 /share/kube

/usr/sbin/exportfs -rav
systemctl start rpcbind
systemctl start nfs-server
