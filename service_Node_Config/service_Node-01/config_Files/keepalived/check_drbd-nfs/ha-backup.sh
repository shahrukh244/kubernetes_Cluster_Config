#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

exec >> /var/log/ha-storage.log 2>&1
echo "===== BACKUP $(date) ====="

systemctl stop nfs-server
/usr/sbin/exportfs -au

mountpoint -q /share/kube && umount /share/kube

drbdadm secondary kube
