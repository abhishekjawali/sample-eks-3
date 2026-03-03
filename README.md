# nitro-kyc-demo

KYC customer onboarding eligibility screening on EMR on EKS, with PII decryption and KYC rule evaluation inside a Nitro Enclave. Plaintext PII (name, DOB, country) never leaves the enclave — only the screening decision (APPROVE/REJECT + reason) is returned to the Spark executor.

---

## How It Works

```
S3 (encrypted customer applications)
  customers.parquet: { app_id, name_enc, dob_enc, country_enc }
  dek.enc:          KMS-encrypted AES-256 DEK
         │
         │ 1. Spark reads encrypted partition
         ▼
┌────────────────────────────────────────────────┐
│  EMR on EKS — Spark Executor Pod               │
│                                                │
│  spark/kyc_screening.py                        │
│    • Reads customers.parquet from S3           │
│    • Reads dek.enc from S3 (broadcast)         │
│    • Gets IRSA credentials (boto3)             │
│    • Sends batches (50 records) via VSOCK      │
│      to local enclave CID=16:5000              │
│    • Receives { app_id, decision, reason }     │
│    • Writes results parquet to S3              │
│                                                │
│  ← executor never sees plaintext PII →         │
└────────────────────┬───────────────────────────┘
                     │ VSOCK CID=16:5000 (host-local)
                     ▼
┌────────────────────────────────────────────────┐
│  Nitro Enclave (DaemonSet on same node)        │
│                                                │
│  enclave/app.py (long-running loop service)    │
│    Per batch:                                  │
│    • KMS Decrypt DEK via kmstool (PCR-gated)   │
│    • AES-GCM decrypt name, dob, country        │
│    • Apply KYC rules:                          │
│        age < 18         → REJECT UNDERAGE      │
│        country in OFAC  → REJECT SANCTIONED    │
│        name in blocklist→ REJECT BLOCKLIST     │
│        else             → APPROVE              │
│    • Discard PII, return decisions only        │
└────────────────────────────────────────────────┘
         │ VSOCK CID=3:8000
         ▼
┌─────────────────────────────┐
│  vsock-proxy (in sidecar)   │
│  VSOCK:8000 → KMS:443       │
└─────────────────────────────┘
```

**Key security property:** The KMS key policy requires `kms:RecipientAttestation:PCR0` matching the built enclave image. The `KeyAdminAccess` statement intentionally excludes `kms:Decrypt` — there is no IAM path that bypasses the attestation requirement. Plaintext PII exists only inside the enclave, only in memory, only during processing.

---

## Project Structure

```
nitro-kyc-demo/
├── data-gen/
│   ├── generate_data.py       # Generates 1000 synthetic encrypted customer records
│   └── requirements.txt
├── enclave/
│   ├── app.py                 # Long-running VSOCK batch service: decrypt PII, apply rules, return decisions
│   ├── Dockerfile             # Multi-stage: kmstool from SDK image + cryptography package
│   └── requirements.txt       # cryptography (AES-GCM)
├── sidecar/
│   ├── app.py                 # DaemonSet manager: vsock-proxy + enclave lifecycle + health monitoring
│   ├── Dockerfile             # nitro-cli + vsock-proxy + EIF baked in
│   └── requirements.txt       # boto3
├── spark/
│   └── kyc_screening.py       # PySpark job: mapPartitions → VSOCK enclave calls → S3 results
├── build/
│   ├── build_eif.sh           # Run on Nitro EC2: builds EIF, prints PCR values, uploads to S3
│   └── build_sidecar.sh       # Builds sidecar Docker image, pushes to ECR
├── infra/
│   ├── setup.sh               # Creates AWS resources (run once)
│   └── update_kms_policy.sh   # Locks KMS key to enclave PCR0 (run after EIF build)
└── k8s/
    ├── enclave-daemonset.yaml  # Long-running enclave service on every Nitro node
    ├── serviceaccount.yaml     # IRSA service account
    └── executor-pod-template.yaml # EMR executor pod template: nodeSelector + IRSA SA
```

---

## AWS Resources

| Resource | Name | Purpose |
|---|---|---|
| KMS Key | `alias/nitro-kyc-demo` | Encrypts the DEK used to encrypt customer PII |
| ECR Repository | `nitro-kyc-sidecar` | Stores the sidecar container image |
| IAM Policy | `nitro-kyc-pod-policy` | S3 read/write + KMS decrypt + GenerateDataKey |
| IAM Role | `nitro-kyc-pod-role` | Assumed by DaemonSet pods and Spark executors via IRSA |
| S3 prefix | `<bucket>/kyc/` | Input parquet, DEK ciphertext, output results |

---

## Prerequisites

### EKS Cluster
- Same as nitro-kms-demo: `eksworkshop-eksctl`, `us-west-2`
- Nitro-capable node group (`m5.xlarge` or larger)
- AWS Nitro Enclaves device plugin installed
- Nodes labelled `aws-nitro-enclaves-k8s-dp=enabled`

### EMR on EKS
- EMR virtual cluster linked to the EKS cluster
- EMR execution role with `s3:GetObject`, `s3:PutObject`, `kms:Decrypt`

### Local Tools

| Tool | Install |
|---|---|
| AWS CLI v2 | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| eksctl | https://eksctl.io/installation/ |
| kubectl | https://kubernetes.io/docs/tasks/tools/ |
| Python 3.9+ | For running data-gen locally |

---

## Execution Steps

> Steps must run in order — each step depends on the previous one.

---

### Step 1 — Create AWS Resources

```bash
cd nitro-kyc-demo/infra
bash setup.sh
```

Creates the KMS key (+ alias), ECR repository, IAM role/policy, and IRSA binding. If the KMS alias already exists, the existing key is reused.

Save the output:
```
KMS_KEY_ID = <key-id>
ECR_URI    = <account>.dkr.ecr.us-west-2.amazonaws.com/nitro-kyc-sidecar
ROLE_ARN   = arn:aws:iam::<account>:role/nitro-kyc-pod-role
```

---

### Step 2 — Generate Encrypted Customer Data

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r data-gen/requirements.txt

KMS_KEY_ID=<KMS_KEY_ID> \
S3_BUCKET=eks-ne-testing-abhi \
python3 data-gen/generate_data.py

deactivate
```

Generates 1000 synthetic records with a realistic distribution of outcomes, encrypts each PII field with AES-GCM, uploads `kyc/customers.parquet` and `kyc/dek.enc` to S3.

---

### Step 3 — Build the EIF on a Nitro EC2

```bash
# Copy project files to Nitro EC2
scp -i <PATH_TO_KEY.pem> -r nitro-kyc-demo ec2-user@<NITRO_EC2_IP>:~/

# SSH in and build
ssh -i <PATH_TO_KEY.pem> ec2-user@<NITRO_EC2_IP>
cd nitro-kyc-demo
S3_EIF_BUCKET=eks-ne-testing-abhi bash build/build_eif.sh
```

`build_eif.sh` will:
1. Install missing dependencies automatically
2. Build the AWS Nitro Enclaves SDK C image — **first run ~15-20 min**; subsequent runs use cache
3. Build the enclave Docker image
4. Convert to EIF and print PCR0, PCR1, PCR2
5. Upload `enclave.eif` and `pcr_values.json` to S3

**Copy the PCR0 value** — needed for Step 4.

> **Note:** PCR0 changes every time the EIF is rebuilt. Always run Step 4 after a rebuild.

---

### Step 4 — Lock the KMS Key to the Enclave

```bash
cd nitro-kyc-demo/infra
bash update_kms_policy.sh <PCR0_VALUE>
```

Updates the KMS key policy so `kms:Decrypt` is only allowed from a Nitro Enclave with the matching PCR0. The `KeyAdminAccess` statement does **not** include `kms:Decrypt` — there is no IAM bypass.

---

### Step 5 — Build the Sidecar Image

```bash
cd nitro-kyc-demo/build

ECR_URI=<ECR_URI from Step 1> \
S3_EIF_BUCKET=eks-ne-testing-abhi \
bash build_sidecar.sh
```

Downloads the EIF from S3, bakes it into the sidecar image alongside `nitro-cli` and `vsock-proxy`, pushes to ECR.

---

### Step 6 — Configure Manifests

Edit [k8s/enclave-daemonset.yaml](k8s/enclave-daemonset.yaml) and replace `<ACCOUNT_ID>` with your AWS account ID.

Edit [k8s/serviceaccount.yaml](k8s/serviceaccount.yaml) and replace `<ACCOUNT_ID>`.

Edit [k8s/executor-pod-template.yaml](k8s/executor-pod-template.yaml) and replace the S3 bucket if different.

---

### Step 7 — Deploy the Enclave DaemonSet

```bash
# 1. Hugepage allocator (reuse from nitro-kms-demo — run once per cluster)
kubectl apply -f ../nitro-kms-demo/k8s/nitro-allocator-setup.yaml
kubectl -n kube-system rollout status daemonset/nitro-enclaves-allocator-setup

# 2. Service account (IRSA)
kubectl apply -f k8s/serviceaccount.yaml

# 3. Deploy enclave DaemonSet
kubectl apply -f k8s/enclave-daemonset.yaml
kubectl get pods -l app=nitro-kyc-enclave -w
```

Wait until DaemonSet pods are Running. Check logs to confirm the enclave started:
```bash
kubectl logs -l app=nitro-kyc-enclave
# Expected: "Enclave is running. Spark executors can connect to VSOCK CID=16 port 5000."
```

---

### Step 8 — Create EMR on EKS Virtual Cluster

#### 8a — Grant EMR access to the EKS namespace

```bash
eksctl create iamidentitymapping \
  --cluster eksworkshop-eksctl \
  --region us-west-2 \
  --namespace default \
  --service-name "emr-containers"
```

This creates the Kubernetes RBAC roles (`emr-containers-role`, `emr-containers-role-binding`) in the `default` namespace so EMR can launch and manage driver and executor pods.

#### 8b — Update IAM role trust policy

The `nitro-kyc-pod-role` is used as the EMR job execution role. Add `emr-containers.amazonaws.com` as a trusted principal so EMR can assume it when starting the job:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ISSUER=$(aws eks describe-cluster \
  --name eksworkshop-eksctl \
  --region us-west-2 \
  --query 'cluster.identity.oidc.issuer' \
  --output text | sed 's|https://||')

aws iam update-assume-role-policy \
  --role-name nitro-kyc-pod-role \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Principal\": {
          \"Federated\": \"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER}\"
        },
        \"Action\": \"sts:AssumeRoleWithWebIdentity\",
        \"Condition\": {
          \"StringLike\": {
            \"${OIDC_ISSUER}:sub\": \"system:serviceaccount:default:*\",
            \"${OIDC_ISSUER}:aud\": \"sts.amazonaws.com\"
          }
        }
      },
      {
        \"Effect\": \"Allow\",
        \"Principal\": {
          \"Service\": \"emr-containers.amazonaws.com\"
        },
        \"Action\": [\"sts:AssumeRole\", \"sts:TagSession\"]
      }
    ]
  }"
```

#### 8c — Create the virtual cluster

```bash
VIRTUAL_CLUSTER_ID=$(aws emr-containers create-virtual-cluster \
  --name nitro-kyc-emr \
  --container-provider '{
    "id": "eksworkshop-eksctl",
    "type": "EKS",
    "info": {
      "eksInfo": {
        "namespace": "default"
      }
    }
  }' \
  --region us-west-2 \
  --query 'id' \
  --output text)

echo "VIRTUAL_CLUSTER_ID = $VIRTUAL_CLUSTER_ID"
```

Save the `VIRTUAL_CLUSTER_ID` — needed for Step 9.

---

### Step 9 — Upload Spark Script and Submit EMR Job

```bash
# Upload Spark job and executor template to S3
aws s3 cp spark/kyc_screening.py s3://eks-ne-testing-abhi/scripts/kyc_screening.py
aws s3 cp k8s/executor-pod-template.yaml s3://eks-ne-testing-abhi/templates/executor-pod-template.yaml

# Submit EMR on EKS job
aws emr-containers start-job-run \
  --virtual-cluster-id <VIRTUAL_CLUSTER_ID> \
  --name kyc-screening \
  --execution-role-arn arn:aws:iam::<ACCOUNT_ID>:role/nitro-kyc-pod-role \
  --release-label emr-6.10.0-latest \
  --job-driver '{
    "sparkSubmitJobDriver": {
      "entryPoint": "s3://eks-ne-testing-abhi/scripts/kyc_screening.py",
      "sparkSubmitParameters": "--conf spark.executor.instances=2 --conf spark.executor.cores=2 --conf spark.kubernetes.executor.podTemplateFile=s3://eks-ne-testing-abhi/templates/executor-pod-template.yaml --conf spark.kubernetes.driverEnv.S3_BUCKET=eks-ne-testing-abhi --conf spark.kubernetes.driverEnv.S3_INPUT_KEY=kyc/customers.parquet --conf spark.kubernetes.driverEnv.S3_DEK_KEY=kyc/dek.enc --conf spark.kubernetes.driverEnv.S3_OUTPUT_KEY=kyc/results --conf spark.kubernetes.driverEnv.AWS_REGION=us-west-2"
    }
  }' \
  --configuration-overrides '{
    "monitoringConfiguration": {
      "cloudWatchMonitoringConfiguration": {
        "logGroupName": "/emr-on-eks/nitro-kyc-demo",
        "logStreamNamePrefix": "kyc-screening"
      }
    }
  }' \
  --region us-west-2
```

---

## Verifying the Output

```bash
# EMR job status
aws emr-containers describe-job-run \
  --virtual-cluster-id <VIRTUAL_CLUSTER_ID> \
  --id <JOB_RUN_ID> \
  --region us-west-2 \
  --query 'jobRun.state'

# Results in S3
aws s3 ls s3://eks-ne-testing-abhi/kyc/results/

# DaemonSet pod logs — shows batch processing, no PII
kubectl logs -l app=nitro-kyc-enclave --tail=50
```

Expected Spark driver output:
```
============================================================
KYC SCREENING COMPLETE
============================================================
+--------+-----------------+-----+
|decision|reason           |count|
+--------+-----------------+-----+
|APPROVE |null             |  850|
|REJECT  |BLOCKLIST        |   20|
|REJECT  |SANCTIONED_COUNTRY|  50|
|REJECT  |UNDERAGE         |   80|
+--------+-----------------+-----+

Total   : 1000
APPROVE : 850  (85.0%)
REJECT  : 150  (15.0%)
============================================================
```

---

## Debug Mode vs Production

| | Debug (`ENCLAVE_DEBUG: "true"`) | Production (`ENCLAVE_DEBUG: "false"`) |
|---|---|---|
| PCR0 | All-zeros (`000...000`) | Real image hash |
| KMS policy | Set PCR0 to all-zeros | Set PCR0 to value from `build_eif.sh` |
| Use for | Initial testing | Real deployments |

---

## How the Enclave Decrypts

1. Receives batch JSON via VSOCK (port 5000) from Spark executor
2. Calls `kmstool_enclave_cli decrypt` with the KMS-encrypted DEK:
   - Gets NSM attestation document (PCR0 of the running enclave image)
   - Connects to vsock-proxy (CID=3:8000) → KMS:443
   - KMS validates PCR0 against key policy → returns plaintext DEK
3. AES-GCM decrypts each PII field using the plaintext DEK (`cryptography` library)
4. Applies KYC rules on plaintext PII — PII is discarded immediately after
5. Returns `{ decisions: [{app_id, decision, reason}] }` — no PII

---

## Cleanup

```bash
# EMR virtual cluster
aws emr-containers delete-virtual-cluster \
  --id <VIRTUAL_CLUSTER_ID> \
  --region us-west-2

kubectl delete daemonset nitro-kyc-enclave
kubectl delete serviceaccount nitro-kyc-sa

aws ecr delete-repository --repository-name nitro-kyc-sidecar --force --region us-west-2

aws iam detach-role-policy \
  --role-name nitro-kyc-pod-role \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/nitro-kyc-pod-policy

aws iam delete-role --role-name nitro-kyc-pod-role
aws iam delete-policy --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/nitro-kyc-pod-policy

aws s3 rm s3://eks-ne-testing-abhi/kyc/ --recursive
aws s3 rm s3://eks-ne-testing-abhi/eif/ --recursive
aws s3 rm s3://eks-ne-testing-abhi/scripts/kyc_screening.py
aws s3 rm s3://eks-ne-testing-abhi/templates/executor-pod-template.yaml

aws kms schedule-key-deletion \
  --key-id alias/nitro-kyc-demo \
  --pending-window-in-days 7 \
  --region us-west-2
```
