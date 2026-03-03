#!/bin/bash
# build_eif.sh — Run this on a Nitro-capable EC2 instance.
#
# What it does:
#   1. Installs missing dependencies (docker, git, aws-cli, python3)
#   2. Installs aws-nitro-enclaves-cli (if not present)
#   3. Builds the AWS Nitro Enclaves SDK C image (provides kmstool_enclave_cli)
#   4. Builds the enclave Docker image (FROM aws-nitro-enclaves-sdk-c)
#   5. Converts to EIF with nitro-cli build-enclave
#   6. Prints PCR0, PCR1, PCR2 values  ← copy PCR0 for KMS key policy
#   7. Uploads EIF and PCR values to S3
#
# Prerequisites on the EC2 instance:
#   - Amazon Linux 2023 (recommended)
#   - IAM role with: s3:PutObject on EIF bucket
#
# Usage:
#   S3_EIF_BUCKET=my-bucket bash build_eif.sh

set -euo pipefail

S3_EIF_BUCKET="${S3_EIF_BUCKET:-}"
S3_EIF_KEY="${S3_EIF_KEY:-eif/enclave.eif}"
AWS_REGION="${AWS_REGION:-us-west-2}"
DOCKER_IMAGE_NAME="nitro-kyc-enclave"
DOCKER_IMAGE_TAG="latest"
EIF_OUTPUT="enclave.eif"

if [ -z "$S3_EIF_BUCKET" ]; then
  echo "ERROR: S3_EIF_BUCKET environment variable is required."
  echo "Usage: S3_EIF_BUCKET=my-bucket bash build_eif.sh"
  exit 1
fi

# ─── 1. Install system dependencies ──────────────────────────────────────────
PKGS_TO_INSTALL=()

if ! command -v docker &>/dev/null; then
  PKGS_TO_INSTALL+=(docker)
fi

if ! command -v git &>/dev/null; then
  PKGS_TO_INSTALL+=(git)
fi

if ! command -v aws &>/dev/null; then
  PKGS_TO_INSTALL+=(awscli2)
fi

if ! command -v python3 &>/dev/null; then
  PKGS_TO_INSTALL+=(python3)
fi

if [ ${#PKGS_TO_INSTALL[@]} -gt 0 ]; then
  echo "==> Installing missing packages: ${PKGS_TO_INSTALL[*]}"
  dnf install -y "${PKGS_TO_INSTALL[@]}"
fi

if ! systemctl is-active --quiet docker; then
  systemctl enable --now docker
  usermod -aG docker ec2-user
  echo "    Docker started."
fi

# ─── 2. Install aws-nitro-enclaves-cli ───────────────────────────────────────
if ! command -v nitro-cli &>/dev/null; then
  echo "==> Installing aws-nitro-enclaves-cli..."
  dnf install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel
  usermod -aG ne ec2-user
  systemctl enable --now nitro-enclaves-allocator.service
  echo "    nitro-cli installed."
fi

# ─── 3. Check allocator config ───────────────────────────────────────────────
ALLOCATOR_CFG="/etc/nitro_enclaves/allocator.yaml"
if [ -f "$ALLOCATOR_CFG" ]; then
  echo "==> Nitro Enclaves allocator config:"
  grep -E "memory_mib|cpu_count" "$ALLOCATOR_CFG" || true
fi

# ─── 4. Build the AWS Nitro Enclaves SDK C image ─────────────────────────────
# The enclave Dockerfile uses FROM aws-nitro-enclaves-sdk-c to copy kmstool.
# Official build: docker build -f containers/Dockerfile.al2 --target builder
# Reference: https://github.com/aws/aws-nitro-enclaves-sdk-c
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENCLAVE_DIR="${SCRIPT_DIR}/../enclave"
SDK_IMAGE="aws-nitro-enclaves-sdk-c"

if docker image inspect "${SDK_IMAGE}:latest" &>/dev/null; then
  echo "==> SDK image '${SDK_IMAGE}' already exists, skipping SDK build."
  echo "    To force a rebuild: docker rmi ${SDK_IMAGE}"
else
  echo "==> Cloning AWS Nitro Enclaves SDK C (first run takes ~15-20 min)..."
  SDK_TMP=$(mktemp -d)
  git clone --depth 1 https://github.com/aws/aws-nitro-enclaves-sdk-c "$SDK_TMP"

  echo "==> Building SDK image (--target builder)..."
  docker build \
    -f "${SDK_TMP}/containers/Dockerfile.al2" \
    --target builder \
    -t "${SDK_IMAGE}" \
    "$SDK_TMP"

  rm -rf "$SDK_TMP"
  echo "==> SDK image built: ${SDK_IMAGE}"
fi

# ─── 5. Build the enclave Docker image ───────────────────────────────────────
echo "==> Building enclave Docker image: ${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}"
docker build \
  -t "${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}" \
  "$ENCLAVE_DIR"

# ─── 6. Build EIF ────────────────────────────────────────────────────────────
echo "==> Building EIF from Docker image..."
nitro-cli build-enclave \
  --docker-uri "${DOCKER_IMAGE_NAME}:${DOCKER_IMAGE_TAG}" \
  --output-file "$EIF_OUTPUT" \
  2>&1 | tee /tmp/eif_build_output.txt

# ─── 7. Extract and display PCR values ───────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo " EIF BUILD COMPLETE — PCR VALUES"
echo "════════════════════════════════════════════════════════"
PCR0=$(nitro-cli describe-eif --eif-path "$EIF_OUTPUT" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(d['Measurements']['PCR0'])")
PCR1=$(nitro-cli describe-eif --eif-path "$EIF_OUTPUT" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(d['Measurements']['PCR1'])")
PCR2=$(nitro-cli describe-eif --eif-path "$EIF_OUTPUT" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(d['Measurements']['PCR2'])")

echo " PCR0 (image) : $PCR0"
echo " PCR1 (kernel): $PCR1"
echo " PCR2 (app)   : $PCR2"
echo ""
echo " Use PCR0 to update the KMS key policy:"
echo "   bash infra/update_kms_policy.sh $PCR0"
echo "════════════════════════════════════════════════════════"
echo ""

# Save PCR values to a file for reference
cat > pcr_values.json <<EOF
{
  "PCR0": "$PCR0",
  "PCR1": "$PCR1",
  "PCR2": "$PCR2",
  "eif_file": "$EIF_OUTPUT",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
echo "PCR values saved to pcr_values.json"

# ─── 8. Upload to S3 ─────────────────────────────────────────────────────────
echo "==> Uploading EIF to s3://${S3_EIF_BUCKET}/${S3_EIF_KEY}..."
aws s3 cp "$EIF_OUTPUT" "s3://${S3_EIF_BUCKET}/${S3_EIF_KEY}" --region "$AWS_REGION"
echo "    EIF uploaded."

aws s3 cp pcr_values.json "s3://${S3_EIF_BUCKET}/eif/pcr_values.json" --region "$AWS_REGION"
echo "    PCR values uploaded to s3://${S3_EIF_BUCKET}/eif/pcr_values.json"

echo ""
echo "NEXT STEP: Update the KMS key policy with the PCR0 value above:"
echo "  bash infra/update_kms_policy.sh $PCR0"
echo ""
echo "Then build the sidecar image:"
echo "  ECR_URI=<ECR_URI> S3_EIF_BUCKET=$S3_EIF_BUCKET bash build/build_sidecar.sh"
