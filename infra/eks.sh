#!/bin/bash
# infra/eks.sh — Creates the EKS cluster for nitro-kyc-demo
#
# Provisions:
#   - 2 general-purpose nodes (m5.large)  — Spark driver, control workloads
#   - 1 Nitro Enclave-enabled node (m5.2xlarge) — enclave DaemonSet + Spark executors
#
# The Nitro node is configured via a launch template that sets EnclaveOptions.Enabled=true.
# The AWS Nitro Enclaves device plugin is installed automatically; it labels the Nitro node
# with aws-nitro-enclaves-k8s-dp=enabled and advertises the aws.ec2.nitro/nitro_enclaves
# resource so the DaemonSet scheduler can target it.
#
# Usage:
#   bash infra/eks.sh
#
# Optional env overrides:
#   CLUSTER_NAME          (default: eks-emr-ne)
#   AWS_REGION            (default: us-west-2)
#   K8S_VERSION           (default: 1.35)
#   GENERAL_INSTANCE_TYPE (default: m5.large)
#   NITRO_INSTANCE_TYPE   (default: m5.2xlarge)
#
# Idempotent: each step checks whether the resource already exists and skips
# creation if so. Safe to re-run after a partial failure.

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-eks-emr-ne}"
AWS_REGION="${AWS_REGION:-us-west-2}"
K8S_VERSION="${K8S_VERSION:-1.35}"
GENERAL_INSTANCE_TYPE="${GENERAL_INSTANCE_TYPE:-m5.large}"
NITRO_INSTANCE_TYPE="${NITRO_INSTANCE_TYPE:-m5.2xlarge}"
GENERAL_NODE_COUNT=2
NITRO_NODE_COUNT=1
LT_NAME="${CLUSTER_NAME}-nitro-enclaves"

# ─── Prerequisites ────────────────────────────────────────────────────────────
for cmd in aws eksctl kubectl; do
  command -v "$cmd" &>/dev/null || {
    echo "ERROR: '$cmd' not found. Please install it before running this script."
    exit 1
  }
done

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account        : $ACCOUNT_ID"
echo "Region         : $AWS_REGION"
echo "Cluster        : $CLUSTER_NAME"
echo "K8s version    : $K8S_VERSION"
echo "General nodes  : ${GENERAL_NODE_COUNT} x $GENERAL_INSTANCE_TYPE"
echo "Nitro node     : ${NITRO_NODE_COUNT} x $NITRO_INSTANCE_TYPE"
echo ""

# ─── 1. Create cluster + general nodegroup ────────────────────────────────────
CLUSTER_STATUS=$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'cluster.status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$CLUSTER_STATUS" = "ACTIVE" ]; then
  echo "==> Cluster '${CLUSTER_NAME}' already exists — skipping creation."
  aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"
else
  echo "==> Creating EKS cluster and general nodegroup (this takes ~15 min)..."

  cat > /tmp/eks-cluster-config.yaml <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "${K8S_VERSION}"

iam:
  withOIDC: true   # Required for IRSA (pod IAM roles)

managedNodeGroups:
  - name: general-nodes
    instanceType: ${GENERAL_INSTANCE_TYPE}
    desiredCapacity: ${GENERAL_NODE_COUNT}
    minSize: 1
    maxSize: 4
    labels:
      role: general
    iam:
      withAddonPolicies:
        cloudWatch: true
EOF

  eksctl create cluster -f /tmp/eks-cluster-config.yaml
  echo "    Cluster and general nodegroup created."
fi

# ─── 2. Create EC2 launch template with EnclaveOptions + InstanceType ─────────
# When a launch template is supplied to an eksctl managed nodegroup, eksctl
# does NOT allow instanceType to also be set in the nodegroup config — it must
# come from the launch template itself. So we include both InstanceType and
# EnclaveOptions in the launch template data.
echo ""
echo "==> Creating EC2 launch template with EnclaveOptions.Enabled=true..."

EXISTING_LT=$(aws ec2 describe-launch-templates \
  --filters "Name=launch-template-name,Values=${LT_NAME}" \
  --region "${AWS_REGION}" \
  --query 'LaunchTemplates[0].LaunchTemplateId' \
  --output text 2>/dev/null || echo "None")

if [ "$EXISTING_LT" != "None" ] && [ -n "$EXISTING_LT" ]; then
  echo "    Launch template $EXISTING_LT already exists — reusing."
  LT_ID="$EXISTING_LT"
else
  LT_ID=$(aws ec2 create-launch-template \
    --launch-template-name "${LT_NAME}" \
    --version-description "Nitro Enclaves enabled" \
    --launch-template-data "{\"InstanceType\": \"${NITRO_INSTANCE_TYPE}\", \"EnclaveOptions\": {\"Enabled\": true}}" \
    --region "${AWS_REGION}" \
    --query 'LaunchTemplate.LaunchTemplateId' \
    --output text)
  echo "    Created launch template: $LT_ID"
fi

echo "    Launch template: $LT_ID ($LT_NAME, instance type: $NITRO_INSTANCE_TYPE)"

# ─── 3. Add Nitro Enclave nodegroup ───────────────────────────────────────────
echo ""

NG_STATUS=$(aws eks describe-nodegroup \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name "nitro-nodes" \
  --region "${AWS_REGION}" \
  --query 'nodegroup.status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$NG_STATUS" = "ACTIVE" ]; then
  echo "==> Nodegroup 'nitro-nodes' already exists — skipping creation."
else
  echo "==> Adding Nitro Enclave nodegroup..."

  cat > /tmp/eks-nitro-nodegroup-config.yaml <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}

managedNodeGroups:
  - name: nitro-nodes
    # instanceType must NOT be set here when a launchTemplate is supplied —
    # it is specified in the launch template instead.
    desiredCapacity: ${NITRO_NODE_COUNT}
    minSize: 1
    maxSize: 2
    labels:
      role: nitro
    # Launch template provides InstanceType + EnclaveOptions.
    launchTemplate:
      id: ${LT_ID}
      version: "1"
    iam:
      withAddonPolicies:
        cloudWatch: true
EOF

  eksctl create nodegroup -f /tmp/eks-nitro-nodegroup-config.yaml
  echo "    Nitro nodegroup created."
fi

# ─── 4. Label Nitro nodes + install device plugin ─────────────────────────────
# The device plugin DaemonSet uses nodeSelector: aws-nitro-enclaves-k8s-dp=enabled
# so the label must be applied BEFORE the DaemonSet is deployed, otherwise the
# plugin pod will never be scheduled and the node will never advertise the
# aws.ec2.nitro/nitro_enclaves resource.
#
# kubectl apply is idempotent — safe to run on every invocation.
echo ""
echo "==> Labelling Nitro nodes and installing AWS Nitro Enclaves device plugin..."

# Wait for the Nitro node to appear with role=nitro before labelling.
# eksctl sets the label but it can take a few seconds after the node joins.
echo "    Waiting for Nitro node to appear with role=nitro..."
kubectl wait node -l role=nitro --for=condition=Ready --timeout=120s

# Label all nodes in the nitro-nodes nodegroup
kubectl label nodes -l role=nitro aws-nitro-enclaves-k8s-dp=enabled --overwrite
echo "    Nitro nodes labelled: aws-nitro-enclaves-k8s-dp=enabled"

# Deploy device plugin — repo: aws/aws-nitro-enclaves-k8s-device-plugin
kubectl apply -f https://raw.githubusercontent.com/aws/aws-nitro-enclaves-k8s-device-plugin/main/aws-nitro-enclaves-k8s-ds.yaml
kubectl -n kube-system rollout status daemonset/aws-nitro-enclaves-k8s-daemonset --timeout=120s
echo "    Device plugin installed."

# ─── 5. Install hugepage allocator ────────────────────────────────────────────
# Nitro Enclaves require 1 GiB hugepages pre-allocated on the host.
# The allocator DaemonSet installs nitro-enclaves-allocator.service on the host
# and starts it. On AL2023 / newer kernels the allocator always uses 1 GB
# hugepages (not 2 MB), so the pod spec must declare hugepages-1Gi.
#
# IMPORTANT: after the allocator runs, the kubelet must be restarted on the
# Nitro node so it re-reads /sys/kernel/mm/hugepages and advertises
# hugepages-1Gi capacity to the scheduler. Without this restart the enclave
# DaemonSet pod stays Pending because the node shows hugepages-1Gi: 0.
# We restart kubelet via SSM (no SSH required).
echo ""
echo "==> Installing Nitro Enclaves hugepage allocator..."
kubectl apply -f ../k8s/kyc-allocator-setup.yaml

# rollout status waits for the DaemonSet pod to be scheduled, initContainer
# to complete, and the pause container to become Ready — all in one command.
# Unlike "kubectl wait pod", it handles the case where the pod doesn't exist yet.
echo "    Waiting for allocator to complete (~60-90s)..."
kubectl -n kube-system rollout status daemonset/kyc-nitro-enclaves-allocator --timeout=180s
echo "    Hugepage allocator installed."

# ─── 6. Restart kubelet on Nitro nodes via SSM ────────────────────────────────
# The kubelet reads hugepage capacity at startup. After the allocator reserves
# 1 GB hugepages, kubelet must restart to discover and advertise hugepages-1Gi.
# We use SSM SendCommand so no SSH key or bastion is needed.
echo ""
echo "==> Restarting kubelet on Nitro nodes via SSM to pick up hugepage capacity..."

NITRO_INSTANCE_IDS=$(aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --filters \
    "Name=tag:eks:nodegroup-name,Values=nitro-nodes" \
    "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text | tr '\t' ' ')

if [ -z "$NITRO_INSTANCE_IDS" ]; then
  echo "    WARNING: No running Nitro node instances found."
  echo "    Restart kubelet manually on each Nitro node:"
  echo "      sudo systemctl restart kubelet"
else
  echo "    Nitro node instance(s): $NITRO_INSTANCE_IDS"

  SSM_COMMAND_ID=$(aws ssm send-command \
    --region "${AWS_REGION}" \
    --instance-ids $NITRO_INSTANCE_IDS \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["systemctl restart kubelet"]' \
    --comment "Restart kubelet to advertise hugepages-1Gi after Nitro allocator" \
    --query 'Command.CommandId' \
    --output text)

  echo "    SSM command sent: $SSM_COMMAND_ID"

  # Poll until every instance's SSM command reaches a terminal state.
  # A fixed sleep risks checking before kubelet has restarted.
  for INSTANCE_ID in $NITRO_INSTANCE_IDS; do
    echo "    Waiting for kubelet restart on $INSTANCE_ID..."
    while true; do
      STATUS=$(aws ssm get-command-invocation \
        --region "${AWS_REGION}" \
        --command-id "${SSM_COMMAND_ID}" \
        --instance-id "${INSTANCE_ID}" \
        --query 'Status' \
        --output text 2>/dev/null || echo "InProgress")
      case "$STATUS" in
        Success|Failed|Cancelled|TimedOut) break ;;
      esac
      sleep 5
    done
    echo "    Instance $INSTANCE_ID — kubelet restart: $STATUS"
  done

  # Brief pause to let the node go NotReady before we wait for Ready.
  # Without this, kubectl wait can return immediately on a still-Ready node.
  sleep 10

  echo "    Waiting for Nitro node to return to Ready state..."
  kubectl wait node \
    -l role=nitro \
    --for=condition=Ready \
    --timeout=120s

  # Verify hugepages-1Gi was picked up by the restarted kubelet.
  HUGEPAGES=$(kubectl get node -l role=nitro \
    -o jsonpath='{.items[0].status.allocatable.hugepages-1Gi}' 2>/dev/null || echo "0")
  if [ -z "$HUGEPAGES" ] || [ "$HUGEPAGES" = "0" ]; then
    echo "    WARNING: hugepages-1Gi not advertised after kubelet restart."
    echo "    Run manually: sudo systemctl restart kubelet on the Nitro node."
  else
    echo "    hugepages-1Gi: $HUGEPAGES — kubelet restart confirmed."
  fi
fi

# ─── 7. Update kubeconfig ─────────────────────────────────────────────────────
echo ""
echo "==> Updating kubeconfig..."
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}"

# ─── 8. Summary ───────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo " EKS CLUSTER READY"
echo "════════════════════════════════════════════════════════"
kubectl get nodes -L role,aws-nitro-enclaves-k8s-dp
echo ""
echo " Hugepage capacity on Nitro node:"
kubectl get node -l role=nitro \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.capacity.hugepages-1Gi}{"\n"}{end}'
echo ""
echo " NEXT STEP: Create AWS resources"
echo "   cd nitro-kyc-demo/infra && bash setup.sh"
echo "════════════════════════════════════════════════════════"
