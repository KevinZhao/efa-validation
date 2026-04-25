#!/bin/bash
set -eux
if mountpoint -q /mnt/nvme; then
  echo "/mnt/nvme already mounted"; df -h /mnt/nvme; exit 0
fi
if [ -e /dev/md0 ]; then
  umount /mnt/nvme 2>/dev/null || true
  mdadm --stop /dev/md0 || true
fi

# Disks owned by any LVM (containerd sits on vg_data → one NVMe)
LVM_DEVS=$(pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
echo "LVM_DEVS=[${LVM_DEVS}]"

# Find all 3.5TB disks, then filter out LVM-owned
ALL_BIG=$(lsblk -b -d -n -o NAME,SIZE,TYPE | awk '$2 > 3e12 && $3=="disk" {print "/dev/"$1}' | sort)
echo "ALL_BIG:"; echo "$ALL_BIG"

DISKS=()
for d in $ALL_BIG; do
  skip=0
  for lvm_d in $LVM_DEVS; do
    if [ "$d" = "$lvm_d" ]; then skip=1; break; fi
  done
  if [ $skip -eq 1 ]; then
    echo "  skip (LVM): $d"
  else
    mdadm --zero-superblock "$d" 2>/dev/null || true
    DISKS+=("$d")
  fi
done

echo "selected ${#DISKS[@]} free disks: ${DISKS[*]}"
if [ "${#DISKS[@]}" -lt 6 ]; then
  echo "ERROR: need >=6 free disks, got ${#DISKS[@]}"; exit 1
fi

if ! command -v mdadm >/dev/null; then dnf install -y mdadm; fi
yes | mdadm --create --verbose /dev/md0 --level=0 --raid-devices=${#DISKS[@]} --chunk=512 "${DISKS[@]}"
sleep 2
cat /proc/mdstat
mkfs.ext4 -F -E nodiscard,lazy_itable_init=1,lazy_journal_init=1 -m 0 /dev/md0
mkdir -p /mnt/nvme
mount -o noatime,nodiratime /dev/md0 /mnt/nvme
chmod 1777 /mnt/nvme
df -h /mnt/nvme
echo "RAID0 setup done with ${#DISKS[@]} disks"
