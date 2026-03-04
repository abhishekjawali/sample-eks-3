#!/bin/bash
# setup.sh — Creates all AWS resources needed for nitro-kyc-demo
# Run this ONCE before generating data or building images.
# Prerequisites: AWS CLI configured, kubectl configured for eksworkshop-eksctl

set -euo pipefail

# ─── Prerequisites ────────────────────────────────────────────────────────────
for cmd in aws eksctl; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: '$cmd' not found. Please install it before running this script."; exit 1; }
done

# ─── Configuration ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../env.sh"

# ─── Helpers ──────────────────────────────────────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID : $ACCOUNT_ID"
echo "Region     : $AWS_REGION"
echo "Cluster    : $CLUSTER_NAME"
echo ""

# ─── Rollback on failure ──────────────────────────────────────────────────────
KMS_KEY_CREATED=""
ECR_CREATED=""

cleanup() {
  local exit_code=$?
  if [ $exit_code -eq 0 ]; then return; fi
  echo ""
  echo "==> ERROR detected — rolling back partially created resources..."
  if [ -n "$ECR_CREATED" ]; then
    echo "    Deleting ECR repository: $ECR_REPO_NAME"
    aws ecr delete-repository --repository-name "$ECR_REPO_NAME" --force \
      --region "$AWS_REGION" 2>/dev/null || true
  fi
  aws iam detach-role-policy --role-name "$IAM_ROLE_NAME" \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_POLICY_NAME}" 2>/dev/null || true
  aws iam delete-role --role-name "$IAM_ROLE_NAME" 2>/dev/null || true
  aws iam delete-policy \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_POLICY_NAME}" 2>/dev/null || true
  if [ -n "$KMS_KEY_CREATED" ]; then
    echo "    Scheduling KMS key deletion (7-day pending window): $KMS_KEY_CREATED"
    aws kms schedule-key-deletion --key-id "$KMS_KEY_CREATED" \
      --pending-window-in-days 7 --region "$AWS_REGION" 2>/dev/null || true
  fi
  echo "    Rollback complete. Fix the error above and re-run setup.sh."
}
trap cleanup EXIT

# ─── 1. KMS Key ───────────────────────────────────────────────────────────────
# Create a new symmetric KMS key and attach the alias.
# If the alias already exists, look up the existing key instead.
echo "==> Creating KMS key ($KMS_KEY_ALIAS)..."
if aws kms describe-key --key-id "$KMS_KEY_ALIAS" \
    --region "$AWS_REGION" &>/dev/null; then
  echo "    Alias already exists — looking up existing key..."
  KMS_KEY_ID=$(aws kms describe-key \
    --key-id "$KMS_KEY_ALIAS" \
    --region "$AWS_REGION" \
    --query 'KeyMetadata.KeyId' \
    --output text)
  echo "    (existing) KMS Key ID : $KMS_KEY_ID"
else
  KMS_KEY_ID=$(aws kms create-key \
    --description "nitro-kyc-demo: DEK encryption key for KYC customer PII" \
    --key-usage ENCRYPT_DECRYPT \
    --key-spec SYMMETRIC_DEFAULT \
    --region "$AWS_REGION" \
    --query 'KeyMetadata.KeyId' \
    --output text)
  KMS_KEY_CREATED="$KMS_KEY_ID"   # Track for rollback

  aws kms create-alias \
    --alias-name "$KMS_KEY_ALIAS" \
    --target-key-id "$KMS_KEY_ID" \
    --region "$AWS_REGION"

  echo "    KMS Key ID : $KMS_KEY_ID"
fi

# ─── 2. ECR Repository ────────────────────────────────────────────────────────
echo "==> Creating ECR repository..."
ECR_URI=$(aws ecr create-repository \
  --repository-name "$ECR_REPO_NAME" \
  --region "$AWS_REGION" \
  --query 'repository.repositoryUri' \
  --output text)
ECR_CREATED="yes"
echo "    ECR URI : $ECR_URI"

# ─── 3. EKS OIDC Provider ────────────────────────────────────────────────────
echo "==> Associating OIDC provider with EKS cluster..."
eksctl utils associate-iam-oidc-provider \
  --region "$AWS_REGION" \
  --cluster "$CLUSTER_NAME" \
  --approve
OIDC_ISSUER=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.identity.oidc.issuer' \
  --output text | sed 's|https://||')
echo "    OIDC Issuer : $OIDC_ISSUER"

# ─── 4. IAM Policy ───────────────────────────────────────────────────────────
echo "==> Creating IAM policy..."

POLICY_JSON=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ListBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::${S3_BUCKET}"
    },
    {
      "Sid": "S3ReadInputData",
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET}/kyc/*",
        "arn:aws:s3:::${S3_BUCKET}/scripts/*",
        "arn:aws:s3:::${S3_BUCKET}/templates/*"
      ]
    },
    {
      "Sid": "S3WriteResults",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET}/kyc/*",
        "arn:aws:s3:::${S3_BUCKET}/kyc_*"
      ]
    },
    {
      "Sid": "KMSDecrypt",
      "Effect": "Allow",
      "Action": ["kms:Decrypt"],
      "Resource": "arn:aws:kms:${AWS_REGION}:${ACCOUNT_ID}:key/${KMS_KEY_ID}"
    },
    {
      "Sid": "KMSGenerateDataKey",
      "Effect": "Allow",
      "Action": ["kms:GenerateDataKey"],
      "Resource": "arn:aws:kms:${AWS_REGION}:${ACCOUNT_ID}:key/${KMS_KEY_ID}"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"
if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
  echo "    Policy already exists — updating to latest version..."
  aws iam create-policy-version \
    --policy-arn "$POLICY_ARN" \
    --policy-document "$POLICY_JSON" \
    --set-as-default
else
  aws iam create-policy \
    --policy-name "$IAM_POLICY_NAME" \
    --policy-document "$POLICY_JSON" \
    --query 'Policy.Arn' \
    --output text
fi
echo "    Policy ARN : $POLICY_ARN"

# ─── 5. IAM Role (IRSA) ──────────────────────────────────────────────────────
echo "==> Creating IAM role for IRSA..."

TRUST_JSON=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_ISSUER}:sub": "system:serviceaccount:${K8S_NAMESPACE}:${K8S_SERVICE_ACCOUNT}",
          "${OIDC_ISSUER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF
)

ROLE_ARN=$(aws iam create-role \
  --role-name "$IAM_ROLE_NAME" \
  --assume-role-policy-document "$TRUST_JSON" \
  --query 'Role.Arn' \
  --output text)

aws iam attach-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-arn "$POLICY_ARN"

echo "    Role ARN : $ROLE_ARN"

# ─── 6. KMS key policy — admin only ──────────────────────────────────────────
# Pod decrypt access is added AFTER the EIF is built and PCR0 is known.
# kms:Decrypt is intentionally excluded from KeyAdminAccess — PCR enforcement
# cannot be bypassed via IAM when Decrypt is absent from the admin statement.
# Note: GenerateDataKey (used by data-gen script) is kept in admin policy so
# the data generation script can generate a DEK without needing the PCR condition.
echo "==> Applying KMS key policy (admin access only — pod decrypt access added after EIF build)..."
KMS_POLICY_JSON=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "KeyAdminAccess",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:root"
      },
      "Action": [
        "kms:Create*",
        "kms:Describe*",
        "kms:Enable*",
        "kms:List*",
        "kms:Put*",
        "kms:Update*",
        "kms:Revoke*",
        "kms:Disable*",
        "kms:Get*",
        "kms:Delete*",
        "kms:TagResource",
        "kms:UntagResource",
        "kms:ScheduleKeyDeletion",
        "kms:CancelKeyDeletion",
        "kms:Encrypt",
        "kms:GenerateDataKey*",
        "kms:ReEncrypt*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)

aws kms put-key-policy \
  --key-id "$KMS_KEY_ID" \
  --policy-name default \
  --policy "$KMS_POLICY_JSON" \
  --region "$AWS_REGION"

# ─── 7. Print Summary ────────────────────────────────────────────────────────
trap - EXIT
echo ""
echo "════════════════════════════════════════════════════════"
echo " SETUP COMPLETE — save these values"
echo "════════════════════════════════════════════════════════"
echo " KMS_KEY_ID   = $KMS_KEY_ID"
echo " KMS_KEY_ARN  = arn:aws:kms:${AWS_REGION}:${ACCOUNT_ID}:key/${KMS_KEY_ID}"
echo " ECR_URI      = $ECR_URI"
echo " ROLE_ARN     = $ROLE_ARN"
echo " OIDC_ISSUER  = $OIDC_ISSUER"
echo ""
echo " NEXT STEPS:"
echo "  1. Generate encrypted customer data:"
echo "     python3 -m venv .venv && source .venv/bin/activate"
echo "     pip install -r data-gen/requirements.txt"
echo "     KMS_KEY_ID=$KMS_KEY_ID S3_BUCKET=$S3_BUCKET python3 data-gen/generate_data.py"
echo "     deactivate"
echo ""
echo "  2. Build the EIF on a Nitro EC2:"
echo "     S3_EIF_BUCKET=$S3_BUCKET bash build/build_eif.sh"
echo ""
echo "  3. After EIF build — update KMS policy with PCR0:"
echo "     bash infra/update_kms_policy.sh <PCR0_VALUE>"
echo "════════════════════════════════════════════════════════"
