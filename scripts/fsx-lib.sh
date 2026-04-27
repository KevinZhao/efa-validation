#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# FSx for Lustre region profiles for yanxi-validation.
# Sourced by fsx-create.sh / fsx-status.sh / fsx-destroy.sh / fsx-sg-setup.sh.
#
# Design:
#   - Deployment: SCRATCH_2 (cheapest; 200 MB/s/TiB baseline, burst 1.3 GB/s/TiB).
#   - Capacity:   2400 GiB per region (Kimi K2 959 GB + other models + headroom).
#   - Placement: same AZ/subnet as the active GPU node group in each region, so
#                GPU pods mount across ENA without cross-AZ hops.
#   - SG:        dedicated SG per region, inbound Lustre ports from GPU node SG.
# -----------------------------------------------------------------------------
set -euo pipefail

# Common tags for everything we create.
export FSX_TAG_PROJECT="yanxi-validation"
export FSX_TAG_STACK="fsx-lustre"
export FSX_NAME="yanxi-model-cache"
export FSX_SG_NAME="yanxi-fsx-lustre-sg"

# SCRATCH_2 knobs.
export FSX_DEPLOYMENT_TYPE="SCRATCH_2"
export FSX_STORAGE_CAPACITY="${FSX_STORAGE_CAPACITY:-2400}"
# Lustre server version; 2.10 is legacy and incompatible with AL2023's
# bundled 2.15 client (rejected as "Client must be recompiled"). Use 2.15
# so AL2023 / EL9 out-of-the-box Lustre clients can mount.
export FSX_LUSTRE_VERSION="${FSX_LUSTRE_VERSION:-2.15}"

# ----- region profiles -----
# Each profile sets: FSX_VPC, FSX_SUBNET, FSX_GPU_NODE_SG
#
# Keys:
#   us-east-2: Ohio — p5.48xlarge Spot runs in subnet-0c86f1c69e4067890 (us-east-2b)
#   us-west-2: Oregon — p6-b300.48xlarge Spot runs in subnet-0343696171ce4cdc9 (us-west-2b)

fsx_load_region() {
  local region="$1"
  case "$region" in
    us-east-2)
      export FSX_VPC="vpc-0bcb622cffd226d26"
      export FSX_SUBNET="subnet-0c86f1c69e4067890"
      export FSX_AZ="us-east-2b"
      export FSX_GPU_NODE_SG="sg-067fb33ae2c309f5f"  # gpu-cluster-ohio-gpu-node-sg
      ;;
    us-west-2)
      export FSX_VPC="vpc-081ea929da61b21d7"
      export FSX_SUBNET="subnet-0343696171ce4cdc9"
      export FSX_AZ="us-west-2b"
      export FSX_GPU_NODE_SG="sg-0b5a28e11052ef250"  # gpu-cluster-oregon-gpu-node-sg
      ;;
    *)
      echo "unknown region: $region" >&2
      return 1
      ;;
  esac
  export FSX_REGION="$region"
}

# fsx_sg_id REGION — prints existing FSx SG id, empty if absent.
fsx_sg_id() {
  local region="$1"
  aws ec2 describe-security-groups --region "$region" \
    --filters "Name=group-name,Values=${FSX_SG_NAME}" "Name=vpc-id,Values=${FSX_VPC}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | sed 's/^None$//'
}

# fsx_fs_id REGION — prints existing FSx file system id tagged with our
# project name that is NOT already being deleted. Empty if absent.
fsx_fs_id() {
  local region="$1"
  aws fsx describe-file-systems --region "$region" \
    --query "FileSystems[?Tags[?Key=='Name' && Value=='${FSX_NAME}'] && Lifecycle!='DELETING' && Lifecycle!='DELETED' && Lifecycle!='FAILED'].FileSystemId | [0]" \
    --output text 2>/dev/null | sed 's/^None$//'
}

# fsx_fs_details REGION FS_ID — prints a JSON object with key fields.
fsx_fs_details() {
  local region="$1" fsid="$2"
  aws fsx describe-file-systems --region "$region" --file-system-ids "$fsid" \
    --query 'FileSystems[0].{
      id: FileSystemId,
      lifecycle: Lifecycle,
      type: FileSystemType,
      subType: LustreConfiguration.DeploymentType,
      storage: StorageCapacity,
      throughput: LustreConfiguration.PerUnitStorageThroughput,
      dns: DNSName,
      mount: LustreConfiguration.MountName,
      vpc: VpcId,
      subnet: SubnetIds[0]
    }' --output json
}
