#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

exec >> /var/log/ha-storage.log 2>&1
echo "===== MASTER $(date) ====="

drbdadm primary --force kube
udevadm settle

mountpoint -q /share/drbd_nfs || mount /dev/drbd0 /share/drbd_nfs

/usr/sbin/exportfs -rav
systemctl start rpcbind
systemctl start nfs-server
