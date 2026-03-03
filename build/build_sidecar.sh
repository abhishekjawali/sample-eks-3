#!/bin/bash
# build_sidecar.sh — Builds the sidecar container image and pushes to ECR.
#
# Run this AFTER build_eif.sh has completed and the EIF is in S3.
# The EIF is downloaded from S3 and baked into the sidecar image.
#
# Usage:
#   ECR_URI=123456789.dkr.ecr.us-west-2.amazonaws.com/nitro-kyc-sidecar \
#   S3_EIF_BUCKET=my-bucket \
#   bash build_sidecar.sh

set -euo pipefail

ECR_URI="${ECR_URI:-}"
S3_EIF_BUCKET="${S3_EIF_BUCKET:-}"
S3_EIF_KEY="${S3_EIF_KEY:-eif/enclave.eif}"
AWS_REGION="${AWS_REGION:-us-west-2}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
EIF_LOCAL_PATH="enclave.eif"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIDECAR_DIR="${SCRIPT_DIR}/../sidecar"

if [ -z "$ECR_URI" ] || [ -z "$S3_EIF_BUCKET" ]; then
  echo "ERROR: ECR_URI and S3_EIF_BUCKET are required."
  echo "Usage: ECR_URI=<uri> S3_EIF_BUCKET=<bucket> bash build_sidecar.sh"
  exit 1
fi

# ─── 1. Download EIF from S3 ──────────────────────────────────────────────────
echo "==> Downloading EIF from s3://${S3_EIF_BUCKET}/${S3_EIF_KEY}..."
aws s3 cp "s3://${S3_EIF_BUCKET}/${S3_EIF_KEY}" "${SIDECAR_DIR}/${EIF_LOCAL_PATH}" \
  --region "$AWS_REGION"
echo "    EIF downloaded to ${SIDECAR_DIR}/${EIF_LOCAL_PATH}"

# ─── 2. ECR Login ─────────────────────────────────────────────────────────────
echo "==> Logging into ECR..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# ─── 3. Build sidecar Docker image ────────────────────────────────────────────
FULL_IMAGE="${ECR_URI}:${IMAGE_TAG}"
echo "==> Building sidecar Docker image: ${FULL_IMAGE}..."
docker build \
  --platform linux/amd64 \
  -t "$FULL_IMAGE" \
  "$SIDECAR_DIR"

# ─── 4. Push to ECR ───────────────────────────────────────────────────────────
echo "==> Pushing image to ECR..."
docker push "$FULL_IMAGE"
echo "    Image pushed: $FULL_IMAGE"

# ─── 5. Clean up EIF from local sidecar dir ───────────────────────────────────
rm -f "${SIDECAR_DIR}/${EIF_LOCAL_PATH}"
echo "    Cleaned up local EIF copy."

echo ""
echo "════════════════════════════════════════════════════════"
echo " Sidecar image built and pushed:"
echo "   $FULL_IMAGE"
echo ""
echo " NEXT STEPS: Deploy to EKS:"
echo "   # 1. Apply hugepage allocator (run once per cluster):"
echo "   kubectl apply -f ../nitro-kms-demo/k8s/nitro-allocator-setup.yaml"
echo "   kubectl -n kube-system rollout status daemonset/nitro-enclaves-allocator-setup"
echo ""
echo "   # 2. Update k8s/enclave-daemonset.yaml with the image URI above, then:"
echo "   kubectl apply -f k8s/serviceaccount.yaml"
echo "   kubectl apply -f k8s/enclave-daemonset.yaml"
echo "   kubectl get pods -l app=nitro-kyc-enclave"
echo "════════════════════════════════════════════════════════"
