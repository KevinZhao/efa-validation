#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Launch a one-shot m6in.32xlarge Spot instance in the FSx AZ that mounts the
# shared FSx Lustre filesystem and downloads the Stage-5 model catalog from
# Hugging Face. The instance self-terminates when done (UserData runs
# `shutdown -h +1` after a success report, and InstanceInitiatedShutdownBehavior
# is set to "terminate").
#
#   Usage:
#     ./prefetch-models-launch.sh us-east-2
#     ./prefetch-models-launch.sh us-west-2
#
# Prereqs:
#   - FSx AVAILABLE (see scripts/fsx-create.sh)
#   - aws-fsx-csi-driver deployed in the target cluster (only needed when we
#     later consume from Kubernetes; the prefetcher itself just mounts FSx
#     directly from the EC2 instance)
# -----------------------------------------------------------------------------
set -euo pipefail

REGION="${1:-}"
if [ -z "$REGION" ]; then
  echo "usage: $0 <us-east-2|us-west-2>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=fsx-lib.sh
source "${SCRIPT_DIR}/fsx-lib.sh"
fsx_load_region "$REGION"

log() { printf '[%s] [%s] %s\n' "$(date -u +%H:%M:%S)" "$REGION" "$*" >&2; }

# --- 1. discover FSx details ------------------------------------------------
fs_id=$(fsx_fs_id "$REGION")
if [ -z "$fs_id" ]; then
  echo "no FSx with Name=${FSX_NAME} in ${REGION}; run fsx-create.sh first" >&2
  exit 1
fi
details=$(fsx_fs_details "$REGION" "$fs_id")
life=$(echo "$details" | jq -r '.lifecycle')
if [ "$life" != "AVAILABLE" ]; then
  echo "FSx ${fs_id} not AVAILABLE (state=${life})" >&2
  exit 1
fi
dns=$(echo "$details"      | jq -r '.dns')
mount=$(echo "$details"    | jq -r '.mount')
log "FSx ${fs_id} dns=${dns} mount=${mount}"

# --- 2. FSx SG (so the prefetcher's ENI can hit Lustre) ---------------------
fsx_sg=$(fsx_sg_id "$REGION")
if [ -z "$fsx_sg" ]; then
  echo "FSx SG missing in ${REGION}; run scripts/fsx-sg-setup.sh first" >&2
  exit 1
fi
log "FSx SG: ${fsx_sg}"

# --- 3. resolve AL2023 AMI --------------------------------------------------
ami=$(aws ssm get-parameter --region "$REGION" \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)
log "AMI: ${ami}"

# --- 4. pick instance type --------------------------------------------------
# Prefer high-ENA n-series to saturate FSx burst (~3 GB/s) and HF egress.
# us-east-2b (FSx AZ) only offers c6in/m6in from the n-family.
# us-west-2b additionally offers c8in/m7in (8th/7th gen) — prefer newest.
INSTANCE_TYPES=(
  "c8in.32xlarge"   # 200 Gbps (usw2 only)
  "c8in.24xlarge"   # 150 Gbps (usw2 only)
  "m7in.32xlarge"   # 200 Gbps (usw2 only, if available)
  "m7in.16xlarge"   # 100 Gbps
  "m6in.32xlarge"   # 200 Gbps
  "m6in.24xlarge"   # 150 Gbps
  "m6in.16xlarge"   # 100 Gbps
  "c6in.32xlarge"   # 200 Gbps
  "c6in.24xlarge"   # 150 Gbps
  "c6in.16xlarge"   # 100 Gbps
)

# --- 5. ensure we have an SG that can mount the FSx -------------------------
# The prefetcher needs to be in a SG that is an *authorized source* on the FSx
# SG. The simplest thing is to use the FSx SG itself for both sides (membership
# match counts as authorization when the source is "this SG"). Add an explicit
# self-ingress entry if not already present.
if ! aws ec2 describe-security-groups --region "$REGION" --group-ids "$fsx_sg" \
      --query 'SecurityGroups[0].IpPermissions[?UserIdGroupPairs[?GroupId==`'"${fsx_sg}"'`]]' \
      --output text | grep -q .; then
  log "adding self-ingress on FSx SG (Lustre ports 988, 1018-1023)"
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$fsx_sg" \
    --ip-permissions \
      "IpProtocol=tcp,FromPort=988,ToPort=988,UserIdGroupPairs=[{GroupId=${fsx_sg}}]" \
      "IpProtocol=tcp,FromPort=1018,ToPort=1023,UserIdGroupPairs=[{GroupId=${fsx_sg}}]" \
    >/dev/null 2>&1 || log "self-ingress already present"
fi

# Also allow outbound HTTPS 443 (HF) and NTP — default egress on fresh SGs is
# all-allow, so nothing to do here.

# --- 6. render UserData -----------------------------------------------------
tmpl="${SCRIPT_DIR}/prefetch-models-userdata.sh.tpl"
rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT
sed \
  -e "s|__FSX_DNS__|${dns}|g" \
  -e "s|__FSX_MOUNT__|${mount}|g" \
  -e "s|__REGION__|${REGION}|g" \
  -e "s|__LOG_BUCKET__|${LOG_BUCKET:-}|g" \
  "$tmpl" > "$rendered"
ud_b64=$(base64 -w0 "$rendered")

# --- 7. IAM profile ---------------------------------------------------------
INSTANCE_PROFILE="${PREFETCH_INSTANCE_PROFILE:-JD-SSM-Profile}"
log "Instance profile: ${INSTANCE_PROFILE}"

# --- 8. launch template + EC2 Fleet with capacity-optimized fallback -------
# run-instances only accepts one type; when that type is out of capacity in
# the FSx AZ, the whole launch fails (we hit this with m6in.32xlarge in
# us-east-2b). EC2 Fleet uses a Launch Template + override list so AWS picks
# whichever type currently has capacity in the required AZ.
NAME="yanxi-prefetch-${REGION}-$(date -u +%Y%m%dT%H%M%SZ)"
log "creating launch template + EC2 Fleet across ${#INSTANCE_TYPES[@]} candidate types in ${FSX_SUBNET}"

lt_data=$(jq -n \
  --arg ami "$ami" \
  --arg sg "$fsx_sg" \
  --arg profile "$INSTANCE_PROFILE" \
  --arg ud "$ud_b64" \
  --arg name "$NAME" \
  '{
    ImageId: $ami,
    IamInstanceProfile: { Name: $profile },
    UserData: $ud,
    InstanceInitiatedShutdownBehavior: "terminate",
    NetworkInterfaces: [{
      DeviceIndex: 0,
      AssociatePublicIpAddress: true,
      Groups: [ $sg ]
    }],
    BlockDeviceMappings: [{
      DeviceName: "/dev/xvda",
      Ebs: { VolumeSize: 200, VolumeType: "gp3", DeleteOnTermination: true }
    }],
    TagSpecifications: [
      { ResourceType: "instance", Tags: [
          { Key: "Name",           Value: $name },
          { Key: "Project",        Value: "yanxi-validation" },
          { Key: "Stack",          Value: "model-prefetch" },
          { Key: "auto-terminate", Value: "true" }
      ]}
    ]
  }')

lt_id=$(aws ec2 create-launch-template --region "$REGION" \
  --launch-template-name "${NAME}-lt" \
  --launch-template-data "$lt_data" \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)
log "launch template: ${lt_id}"

overrides='[]'
for it in "${INSTANCE_TYPES[@]}"; do
  overrides=$(jq --arg it "$it" --arg subnet "$FSX_SUBNET" \
    '. + [{ InstanceType: $it, SubnetId: $subnet }]' <<< "$overrides")
done

fleet_cfg=$(mktemp)
config_file="$fleet_cfg"
trap 'rm -f "$rendered" "$fleet_cfg"' EXIT
# PREFETCH_MARKET: "spot" (default) or "on-demand".
PREFETCH_MARKET="${PREFETCH_MARKET:-spot}"
if [ "$PREFETCH_MARKET" = "on-demand" ]; then
  jq -n --argjson overrides "$overrides" --arg lt "$lt_id" \
    '{
      LaunchTemplateConfigs: [{
        LaunchTemplateSpecification: { LaunchTemplateId: $lt, Version: "$Latest" },
        Overrides: $overrides
      }],
      TargetCapacitySpecification: {
        TotalTargetCapacity: 1,
        OnDemandTargetCapacity: 1,
        SpotTargetCapacity: 0,
        DefaultTargetCapacityType: "on-demand"
      },
      OnDemandOptions: {
        AllocationStrategy: "lowest-price"
      },
      Type: "instant"
    }' > "$fleet_cfg"
else
  jq -n --argjson overrides "$overrides" --arg lt "$lt_id" \
    '{
      LaunchTemplateConfigs: [{
        LaunchTemplateSpecification: { LaunchTemplateId: $lt, Version: "$Latest" },
        Overrides: $overrides
      }],
      TargetCapacitySpecification: {
        TotalTargetCapacity: 1,
        OnDemandTargetCapacity: 0,
        SpotTargetCapacity: 1,
        DefaultTargetCapacityType: "spot"
      },
      SpotOptions: {
        AllocationStrategy: "capacityOptimized",
        InstanceInterruptionBehavior: "terminate"
      },
      Type: "instant"
    }' > "$fleet_cfg"
fi

fleet_json=$(aws ec2 create-fleet --region "$REGION" --cli-input-json "file://$fleet_cfg" --output json)
fleet_id=$(echo "$fleet_json" | jq -r '.FleetId')
iid=$(echo "$fleet_json" | jq -r '.Instances[0].InstanceIds[0] // empty')

if [ -z "$iid" ] || [ "$iid" = "None" ]; then
  log "EC2 Fleet rejected all candidates:"
  echo "$fleet_json" | jq '.Errors'
  exit 1
fi
log "fleet ${fleet_id} produced instance ${iid}"
log "launched ${iid}; watch with:"
log "  aws ec2 describe-instances --region ${REGION} --instance-ids ${iid} --query 'Reservations[0].Instances[0].State.Name' --output text"
log "  aws ssm start-session --region ${REGION} --target ${iid}"
log "  (inside the box) tail -F /var/log/yanxi-prefetch.log"

# Persist a small record of what we launched so operator can re-run or monitor.
records="${REPO_ROOT}/logs/prefetch-launches.ndjson"
mkdir -p "$(dirname "$records")"
actual_type=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$iid" \
  --query 'Reservations[0].Instances[0].InstanceType' --output text 2>/dev/null || echo unknown)
jq -c -n \
  --arg region "$REGION" \
  --arg iid "$iid" \
  --arg fleet_id "$fleet_id" \
  --arg name "$NAME" \
  --arg type "$actual_type" \
  --arg fs_id "$fs_id" \
  --arg dns "$dns" \
  --arg mount "$mount" \
  --arg subnet "$FSX_SUBNET" \
  --arg sg "$fsx_sg" \
  --arg ami "$ami" \
  --arg launched_at "$(date -u -Is)" \
  '{region:$region, instance_id:$iid, fleet_id:$fleet_id, name:$name, type:$type, fs_id:$fs_id, fsx_dns:$dns, fsx_mount:$mount, subnet:$subnet, sg:$sg, ami:$ami, launched_at:$launched_at}' \
  >> "$records"

echo "$iid"
