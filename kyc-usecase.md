# KYC Screening Use Case

## Problem Statement

Financial institutions are required by law to verify the identity and eligibility of every customer before onboarding them. This process — Know Your Customer (KYC) — involves checking sensitive personal information (PII) such as full name, date of birth, and country of residence against regulatory rules:

- **Age requirements** — applicants must be at least 18 years old
- **Sanctions screening** — applicants from OFAC-sanctioned countries (Iran, North Korea, Syria, Cuba, Sudan, Myanmar) must be rejected
- **Watchlist screening** — applicants whose names appear on internal or regulatory blocklists must be flagged

The challenge is that this screening must be performed at scale — often across millions of customer records — while meeting strict data privacy and regulatory requirements. The tension is acute:

> **You need to process plaintext PII to screen it, but regulations and security policy require that plaintext PII never be exposed to the processing infrastructure.**

Existing approaches force an uncomfortable tradeoff:

| Approach | Problem |
|---|---|
| Process PII in plain Spark executors | PII visible to cluster operators, logs, memory dumps |
| Encrypt everything and never decrypt | Cannot apply rules — encrypted data is opaque |
| Decrypt in a trusted application server | Server becomes a high-value attack target; operator access is a risk |
| Tokenise PII before processing | Tokenisation service itself must see the plaintext |

In each case, plaintext PII is either exposed to the processing environment or the screening cannot be performed.

---

## What This Application Solves

This demo shows how to perform KYC screening at Spark scale **without ever exposing plaintext PII to the processing cluster**.

The key insight is to push the decryption and rule evaluation into an **AWS Nitro Enclave** — a hardware-isolated execution environment that is cryptographically sealed from the rest of the system, including the host operating system, cluster operators, and AWS itself.

### How It Works

Customer PII (name, date of birth, country) is encrypted field-by-field with AES-256-GCM before it is ever stored. The encryption key (DEK) is itself encrypted by AWS KMS and stored alongside the data. No plaintext PII ever reaches S3 or the Spark cluster.

When the EMR on EKS Spark job runs:

1. Executors read the **encrypted** records from S3 — they see only ciphertext.
2. Each executor sends a batch of encrypted records to the **Nitro Enclave** running on the same node via a VSOCK socket (host-local, no network).
3. Inside the enclave, the DEK is decrypted via KMS. KMS will only release the DEK if the enclave's **PCR0 measurement** matches the value locked into the KMS key policy — meaning KMS cryptographically verifies it is talking to the exact enclave image that was approved. No other code, person, or process can obtain the DEK.
4. The enclave decrypts each PII field, applies the KYC rules, then **discards the plaintext immediately**. Only the decision — `APPROVE` or `REJECT` with a reason code — leaves the enclave.
5. The Spark executor writes the decision records back to S3. At no point does the executor, driver, or any other cluster component see the plaintext name, date of birth, or country.

### Security Properties

| Property | How It Is Achieved |
|---|---|
| Plaintext PII never leaves the enclave | Enclave returns decisions only; PII is discarded in-memory |
| KMS key cannot be used outside the enclave | KMS key policy requires PCR0 attestation match |
| Operators cannot access PII | Nitro Enclave has no SSH, no shell, no external network |
| AWS itself cannot access PII | Nitro Enclaves are isolated from the hypervisor and AWS operators |
| Tampered enclave image cannot decrypt | PCR0 changes if any byte of the enclave image changes |
| No IAM path bypasses attestation | `kms:Decrypt` is excluded from the admin IAM statement entirely |

### Business Value

- **Regulatory compliance** — PII is processed but never exposed; satisfies GDPR, CCPA, and financial data handling requirements
- **Operational security** — Cluster operators, DevOps engineers, and data engineers cannot access customer PII even with full AWS console access
- **Auditability** — The enclave image is reproducible and its PCR0 measurement is a verifiable commitment to exactly what code runs
- **Scale** — Standard EMR on EKS infrastructure; the enclave adds no bottleneck for batch workloads
- **Separation of duties** — The team that writes KYC rules (baked into the EIF) is separated from the team that operates the Spark cluster and accesses S3

### Example Output

After processing 1,000 customer records, the Spark job produces a decision dataset with no PII:

```
+--------+------------------+-----+
|decision|reason            |count|
+--------+------------------+-----+
|APPROVE |null              |850  |
|REJECT  |BLOCKLIST         |20   |
|REJECT  |SANCTIONED_COUNTRY|50   |
|REJECT  |UNDERAGE          |80   |
+--------+------------------+-----+
```

The downstream system receives eligibility decisions. It never receives — and cannot reconstruct — the name, date of birth, or country of any applicant.
