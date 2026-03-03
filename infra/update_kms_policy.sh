#!/bin/bash
# update_kms_policy.sh — Restricts the KMS key policy to only allow decryption
# from a Nitro Enclave whose PCR0 matches the built EIF.
#
# Run this AFTER building the EIF and noting the PCR0 value.
# Usage: bash update_kms_policy.sh <PCR0_VALUE>

set -euo pipefail

PCR0="${1:-}"
if [ -z "$PCR0" ]; then
  echo "ERROR: PCR0 value required."
  echo "Usage: bash update_kms_policy.sh <PCR0_VALUE>"
  echo ""
  echo "Get PCR0 from the build_eif.sh output or:"
  echo "  nitro-cli describe-eif --eif-path enclave.eif | jq -r '.Measurements.PCR0'"
  exit 1
fi

AWS_REGION="us-west-2"
KMS_KEY_ALIAS="alias/nitro-kyc-demo"
IAM_ROLE_NAME="nitro-kyc-pod-role"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
KMS_KEY_ID=$(aws kms describe-key \
  --key-id "$KMS_KEY_ALIAS" \
  --region "$AWS_REGION" \
  --query 'KeyMetadata.KeyId' \
  --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

echo "==> Updating KMS key policy with PCR0 attestation condition..."
echo "    KMS Key ID : $KMS_KEY_ID"
echo "    PCR0       : $PCR0"
echo "    Role ARN   : $ROLE_ARN"

RESTRICTED_POLICY_JSON=$(cat <<EOF
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
    },
    {
      "Sid": "AllowNitroEnclaveDecryptOnly",
      "Effect": "Allow",
      "Principal": {
        "AWS": "${ROLE_ARN}"
      },
      "Action": "kms:Decrypt",
      "Resource": "*",
      "Condition": {
        "StringEqualsIgnoreCase": {
          "kms:RecipientAttestation:ImageSha384": "${PCR0}",
          "kms:RecipientAttestation:PCR0": "${PCR0}"
        }
      }
    }
  ]
}
EOF
)

aws kms put-key-policy \
  --key-id "$KMS_KEY_ID" \
  --policy-name default \
  --policy "$RESTRICTED_POLICY_JSON" \
  --region "$AWS_REGION"

echo ""
echo "KMS key policy updated."
echo "Only the Nitro Enclave with PCR0=$PCR0 can now decrypt."
echo ""
echo "NEXT STEP: Build the sidecar image:"
echo "  ECR_URI=<ECR_URI> S3_EIF_BUCKET=<BUCKET> bash build/build_sidecar.sh"
