# Static PV + PVC for the yanxi FSx model cache.
# Placeholders (replaced by scripts/fsx-apply-pvpvc.sh):
#   __FS_ID__     e.g. fs-0abc...
#   __DNS__       e.g. fs-0abc....fsx.us-east-2.amazonaws.com
#   __MOUNT__     Lustre MountName, e.g. "abcdef" (NOT the DNS)
#   __CAPACITY__  storage capacity GiB (typically 2400)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: yanxi-model-cache-pv
  labels:
    app.kubernetes.io/part-of: yanxi-validation
    storage: fsx-lustre
spec:
  capacity:
    storage: __CAPACITY__Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: fsx-lustre-static
  mountOptions:
    - flock
  csi:
    driver: fsx.csi.aws.com
    volumeHandle: __FS_ID__
    volumeAttributes:
      dnsname: __DNS__
      mountname: __MOUNT__
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: yanxi-model-cache
  namespace: yanxi-validation
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: fsx-lustre-static
  resources:
    requests:
      storage: __CAPACITY__Gi
  volumeName: yanxi-model-cache-pv
