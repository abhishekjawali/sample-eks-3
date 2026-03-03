#!/usr/bin/env python3
"""
data-gen/generate_data.py — Generate synthetic encrypted customer applications

Creates 1000 realistic customer records with a mix of:
  - Adults (age 18-80)         → should APPROVE (unless sanctioned/blocklisted)
  - Minors (age 14-17)         → should REJECT with UNDERAGE
  - Sanctioned country residents → should REJECT with SANCTIONED_COUNTRY
  - Blocklisted names           → should REJECT with BLOCKLIST

Each PII field (name, dob, country) is AES-256-GCM encrypted with a single DEK.
The DEK is encrypted with KMS (GenerateDataKey) and stored alongside the data.

Output to S3:
  s3://<S3_BUCKET>/kyc/customers.parquet  — encrypted customer records
  s3://<S3_BUCKET>/kyc/dek.enc            — base64-encoded KMS-encrypted DEK

Usage:
  KMS_KEY_ID=alias/nitro-kyc-demo S3_BUCKET=my-bucket python3 generate_data.py
"""

import base64
import io
import os
import random
import secrets
import sys
from datetime import date, timedelta

import boto3
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# ─── Configuration ────────────────────────────────────────────────────────────
AWS_REGION  = os.environ.get("AWS_REGION", "us-west-2")
KMS_KEY_ID  = os.environ.get("KMS_KEY_ID", "alias/nitro-kyc-demo")
S3_BUCKET   = os.environ.get("S3_BUCKET", "eks-ne-testing-abhi")
NUM_RECORDS = int(os.environ.get("NUM_RECORDS", "1000"))

# Distribution of record types
PCT_UNDERAGE           = 0.08   # 8%  — UNDERAGE
PCT_SANCTIONED_COUNTRY = 0.05   # 5%  — SANCTIONED_COUNTRY
PCT_BLOCKLIST          = 0.02   # 2%  — BLOCKLIST
# Remaining 85% → APPROVE

SANCTIONED_COUNTRIES = ["IR", "KP", "SY", "CU", "SD", "MM"]
ALLOWED_COUNTRIES    = ["US", "GB", "CA", "AU", "DE", "FR", "IN", "SG", "JP", "BR",
                         "NL", "SE", "NO", "CH", "NZ", "ZA", "MX", "IT", "ES", "PL"]

FIRST_NAMES = ["Alice", "Bob", "Carlos", "Diana", "Ethan", "Fatima", "George",
               "Hannah", "Ivan", "Julia", "Kevin", "Layla", "Mohamed", "Nina",
               "Oscar", "Priya", "Quinn", "Rachel", "Samuel", "Tara", "Uma",
               "Victor", "Wendy", "Xiao", "Yusuf", "Zara"]

LAST_NAMES  = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller",
               "Davis", "Martinez", "Wilson", "Anderson", "Taylor", "Thomas", "Lee",
               "Harris", "Jackson", "White", "Robinson", "Lewis", "Walker", "Hall",
               "Young", "Allen", "King", "Wright", "Scott", "Green", "Baker"]

# Blocklisted names (must match enclave/app.py NAME_BLOCKLIST)
BLOCKLIST_NAMES = [("John", "Doe"), ("Jane", "Doe")]


# ─── Encryption helpers ───────────────────────────────────────────────────────

def encrypt_field(dek: bytes, plaintext: str) -> str:
    """AES-256-GCM encrypt a field. Returns base64(nonce || ciphertext+tag)."""
    nonce  = secrets.token_bytes(12)
    aesgcm = AESGCM(dek)
    ct     = aesgcm.encrypt(nonce, plaintext.encode("utf-8"), None)
    return base64.b64encode(nonce + ct).decode("utf-8")


# ─── Record generators ────────────────────────────────────────────────────────

def random_dob_adult() -> date:
    """Random DOB for someone aged 18–80."""
    today = date.today()
    age_days = random.randint(18 * 365, 80 * 365)
    return today - timedelta(days=age_days)


def random_dob_minor() -> date:
    """Random DOB for someone aged 14–17."""
    today = date.today()
    age_days = random.randint(14 * 365, 17 * 365 + 364)
    return today - timedelta(days=age_days)


def random_name() -> tuple:
    return random.choice(FIRST_NAMES), random.choice(LAST_NAMES)


def generate_records() -> list:
    records = []
    n_underage    = int(NUM_RECORDS * PCT_UNDERAGE)
    n_sanctioned  = int(NUM_RECORDS * PCT_SANCTIONED_COUNTRY)
    n_blocklisted = int(NUM_RECORDS * PCT_BLOCKLIST)
    n_approve     = NUM_RECORDS - n_underage - n_sanctioned - n_blocklisted

    # APPROVE cases
    for _ in range(n_approve):
        first, last = random_name()
        records.append({
            "first_name": first,
            "last_name":  last,
            "dob":        random_dob_adult().isoformat(),
            "country":    random.choice(ALLOWED_COUNTRIES),
            "_expected":  "APPROVE",
        })

    # UNDERAGE cases
    for _ in range(n_underage):
        first, last = random_name()
        records.append({
            "first_name": first,
            "last_name":  last,
            "dob":        random_dob_minor().isoformat(),
            "country":    random.choice(ALLOWED_COUNTRIES),
            "_expected":  "REJECT:UNDERAGE",
        })

    # SANCTIONED_COUNTRY cases
    for _ in range(n_sanctioned):
        first, last = random_name()
        records.append({
            "first_name": first,
            "last_name":  last,
            "dob":        random_dob_adult().isoformat(),
            "country":    random.choice(SANCTIONED_COUNTRIES),
            "_expected":  "REJECT:SANCTIONED_COUNTRY",
        })

    # BLOCKLIST cases
    for i in range(n_blocklisted):
        first, last = BLOCKLIST_NAMES[i % len(BLOCKLIST_NAMES)]
        records.append({
            "first_name": first,
            "last_name":  last,
            "dob":        random_dob_adult().isoformat(),
            "country":    random.choice(ALLOWED_COUNTRIES),
            "_expected":  "REJECT:BLOCKLIST",
        })

    random.shuffle(records)
    return records


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    print(f"Generating {NUM_RECORDS} synthetic customer records...")
    print(f"  KMS key  : {KMS_KEY_ID}")
    print(f"  S3 bucket: {S3_BUCKET}")
    print(f"  Region   : {AWS_REGION}")
    print()

    kms = boto3.client("kms", region_name=AWS_REGION)
    s3  = boto3.client("s3",  region_name=AWS_REGION)

    # ── Generate DEK ──────────────────────────────────────────────────────────
    print("==> Generating AES-256 DEK via KMS GenerateDataKey...")
    resp = kms.generate_data_key(KeyId=KMS_KEY_ID, KeySpec="AES_256")
    dek_plaintext  = resp["Plaintext"]       # raw 32 bytes — used locally then discarded
    dek_ciphertext = resp["CiphertextBlob"]  # KMS-encrypted — stored in S3
    dek_ciphertext_b64 = base64.b64encode(dek_ciphertext).decode("utf-8")
    print(f"    DEK generated (ciphertext length: {len(dek_ciphertext)} bytes)")

    # ── Generate and encrypt records ──────────────────────────────────────────
    print("==> Generating and encrypting customer records...")
    records = generate_records()

    rows = []
    for i, rec in enumerate(records):
        app_id      = f"APP{i+1:06d}"
        full_name   = f"{rec['first_name']} {rec['last_name']}"
        name_enc    = encrypt_field(dek_plaintext, full_name)
        dob_enc     = encrypt_field(dek_plaintext, rec["dob"])
        country_enc = encrypt_field(dek_plaintext, rec["country"])
        rows.append({
            "app_id":      app_id,
            "name_enc":    name_enc,
            "dob_enc":     dob_enc,
            "country_enc": country_enc,
        })

    # Discard DEK plaintext from memory
    del dek_plaintext

    df = pd.DataFrame(rows)

    # ── Print expected distribution ───────────────────────────────────────────
    from collections import Counter
    dist = Counter(r["_expected"] for r in records)
    print(f"    Expected distribution:")
    for outcome, count in sorted(dist.items()):
        print(f"      {outcome:35s}: {count:4d} ({count/NUM_RECORDS*100:.1f}%)")

    # ── Upload to S3 ──────────────────────────────────────────────────────────
    print("==> Uploading to S3...")

    # customers.parquet
    table  = pa.Table.from_pandas(df)
    buf    = io.BytesIO()
    pq.write_table(table, buf)
    buf.seek(0)
    s3.put_object(
        Bucket=S3_BUCKET,
        Key="kyc/customers.parquet",
        Body=buf.getvalue(),
        ContentType="application/octet-stream",
    )
    print(f"    s3://{S3_BUCKET}/kyc/customers.parquet ({len(df)} records)")

    # dek.enc — base64-encoded KMS-encrypted DEK
    s3.put_object(
        Bucket=S3_BUCKET,
        Key="kyc/dek.enc",
        Body=dek_ciphertext_b64.encode("utf-8"),
        ContentType="text/plain",
    )
    print(f"    s3://{S3_BUCKET}/kyc/dek.enc")

    print()
    print("════════════════════════════════════════════════════════")
    print(" DATA GENERATION COMPLETE")
    print("════════════════════════════════════════════════════════")
    print(f" Input parquet : s3://{S3_BUCKET}/kyc/customers.parquet")
    print(f" DEK ciphertext: s3://{S3_BUCKET}/kyc/dek.enc")
    print()
    print(" NEXT STEP: Build the EIF on a Nitro EC2:")
    print(f"   S3_EIF_BUCKET={S3_BUCKET} bash build/build_eif.sh")
    print("════════════════════════════════════════════════════════")


if __name__ == "__main__":
    main()
