#!/bin/bash
# env.sh — Central environment configuration for nitro-kyc-demo
#
# Source this file from any script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../env.sh"    # from infra/ or build/
#   source "${SCRIPT_DIR}/env.sh"       # from project root
#
# Variables can be overridden by exporting them before running any script:
#   export S3_BUCKET=my-other-bucket
#   bash infra/setup.sh

# ─── AWS ──────────────────────────────────────────────────────────────────────
export AWS_REGION="${AWS_REGION:-us-west-2}"

# ─── EKS Cluster ──────────────────────────────────────────────────────────────
export CLUSTER_NAME="${CLUSTER_NAME:-eks-emr-ne}"
export K8S_VERSION="${K8S_VERSION:-1.35}"
export K8S_NAMESPACE="${K8S_NAMESPACE:-default}"
export K8S_SERVICE_ACCOUNT="${K8S_SERVICE_ACCOUNT:-nitro-kyc-sa}"

# ─── EKS Nodegroups ───────────────────────────────────────────────────────────
export GENERAL_INSTANCE_TYPE="${GENERAL_INSTANCE_TYPE:-m5.large}"
export NITRO_INSTANCE_TYPE="${NITRO_INSTANCE_TYPE:-m5.2xlarge}"
export GENERAL_NODE_COUNT="${GENERAL_NODE_COUNT:-2}"
export NITRO_NODE_COUNT="${NITRO_NODE_COUNT:-1}"

# ─── S3 ───────────────────────────────────────────────────────────────────────
export S3_BUCKET="${S3_BUCKET:-eks-ne-testing-abhi}"
export S3_EIF_BUCKET="${S3_EIF_BUCKET:-${S3_BUCKET}}"
export S3_EIF_KEY="${S3_EIF_KEY:-eif/enclave.eif}"

# ─── KMS ──────────────────────────────────────────────────────────────────────
export KMS_KEY_ALIAS="${KMS_KEY_ALIAS:-alias/nitro-kyc-demo}"
# KMS_KEY_ID (the real UUID) is resolved at runtime by setup.sh and update_kms_policy.sh
# via aws kms describe-key, and passed explicitly to data-gen/generate_data.py.
# It is NOT set here — pass it as: KMS_KEY_ID=<uuid-from-setup.sh> python3 data-gen/generate_data.py

# ─── IAM ──────────────────────────────────────────────────────────────────────
export IAM_ROLE_NAME="${IAM_ROLE_NAME:-nitro-kyc-pod-role}"
export IAM_POLICY_NAME="${IAM_POLICY_NAME:-nitro-kyc-pod-policy}"

# ─── ECR / Docker ─────────────────────────────────────────────────────────────
export ECR_REPO_NAME="${ECR_REPO_NAME:-nitro-kyc-sidecar}"
export DOCKER_IMAGE_NAME="${DOCKER_IMAGE_NAME:-nitro-kyc-enclave}"
export IMAGE_TAG="${IMAGE_TAG:-latest}"
