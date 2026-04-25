#!/bin/bash
# Create RAID0 across 8 × 3.5 TB NVMe ephemeral disks on p5en, mount at /mnt/nvme.
set -eux

if mountpoint -q /mnt/nvme; then
  echo "/mnt/nvme already mounted"; df -h /mnt/nvme; exit 0
fi

# Teardown any stale md0 first so disks become selectable again
if [ -e /dev/md0 ]; then
  umount /mnt/nvme 2>/dev/null || true
  mdadm --stop /dev/md0 || true
fi
# Zero superblock on any disk that has one
for d in /dev/nvme*n1; do
  mdadm --zero-superblock "$d" 2>/dev/null || true
done

# Find 3.5 TB disks by size only (no FSTYPE filter; we already zeroed)
mapfile -t DISKS < <(lsblk -b -d -n -o NAME,SIZE,TYPE | awk '$2 > 3e12 && $3=="disk" {print "/dev/"$1}')
echo "found ${#DISKS[@]} NVMe ephemeral disks:"
printf '  %s\n' "${DISKS[@]}"
if [ "${#DISKS[@]}" -ne 8 ]; then
  echo "ERROR: expected 8, got ${#DISKS[@]}"; exit 1
fi

if ! command -v mdadm >/dev/null; then dnf install -y mdadm; fi

yes | mdadm --create --verbose /dev/md0 --level=0 --raid-devices=8 --chunk=512 "${DISKS[@]}"
sleep 2
cat /proc/mdstat

# Plain ext4 with journal (avoid incompatible options)
mkfs.ext4 -F -E nodiscard,lazy_itable_init=1,lazy_journal_init=1 -m 0 /dev/md0
mkdir -p /mnt/nvme
mount -o noatime,nodiratime /dev/md0 /mnt/nvme
chmod 1777 /mnt/nvme
df -h /mnt/nvme
echo "RAID0 setup done"
