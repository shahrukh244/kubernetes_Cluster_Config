

NFS-Server Should Already Configured And Running Only Then Run This...

showmount -e  10.0.0.1

_________________________________________________________________________________________

 
# Ensure repo is up-to-date
helm repo update



# Verify version 
helm search repo csi-driver-nfs



# Install latest version (4.12.1 as of now)
helm install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
  --namespace kube-system \
  --version 4.12.1 \
  --set node.selector="kubernetes.io/os=linux" \
  --create-namespace



# Verify Installation
kubectl get pods -n kube-system -l app.kubernetes.io/name=csi-driver-nfs
kubectl get csidrivers nfs.csi.k8s.io
helm list -n kube-system | grep csi-driver-nfs


____________________________________________________________________________


# To Install Storage_Class Delete
helm install nfs-delete ./nfs-storageclass_Delete


# To Uninstall Storage_Class Delete
helm uninstall nfs-delete


___________________________________________________________________________


# To Install Storage_Class Retain
helm install nfs-retain ./nfs-storageclass_Retain


# To Uninstall Storage_Class Retain
helm uninstall nfs-retain


_____________________________________________________________________________