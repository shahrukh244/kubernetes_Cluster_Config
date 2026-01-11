#!/bin/bash
# Check if kube DRBD is Primary
drbdadm role kube | grep -q Primary
