"""
spark/kyc_screening.py — PySpark KYC screening job for EMR on EKS

Reads encrypted customer applications from S3, sends each partition to the
local Nitro Enclave via VSOCK for KYC eligibility screening, and writes the
decisions (APPROVE/REJECT + reason) back to S3.

The enclave (CID=16, port 5000) runs on every Nitro-capable node as a
DaemonSet. Executors connect to it via AF_VSOCK — no network, no IAM
credential exposure on the wire.

PII (name, DOB, country) is decrypted only inside the enclave.
This job only ever handles: app_id, name_enc, dob_enc, country_enc, decisions.

Usage (submit via EMR on EKS):
  spark-submit kyc_screening.py
  or via: aws emr-containers start-job-run (see README)

Required environment variables (set in EMR job config or pod template):
  S3_BUCKET      — bucket containing kyc/ prefix
  S3_INPUT_KEY   — parquet key (default: kyc/customers.parquet)
  S3_DEK_KEY     — encrypted DEK key (default: kyc/dek.enc)
  S3_OUTPUT_KEY  — results prefix (default: kyc/results)
  AWS_REGION     — AWS region (default: us-west-2)
"""

import base64
import json
import os
import socket
import struct
import sys
import time

import boto3
from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql.types import ArrayType, StringType, StructField, StructType

# ─── Configuration ────────────────────────────────────────────────────────────
AWS_REGION    = os.environ.get("AWS_REGION", "us-west-2")
S3_BUCKET     = os.environ["S3_BUCKET"]
S3_INPUT_KEY  = os.environ.get("S3_INPUT_KEY",  "kyc/customers.parquet")
S3_DEK_KEY    = os.environ.get("S3_DEK_KEY",    "kyc/dek.enc")
S3_OUTPUT_KEY = os.environ.get("S3_OUTPUT_KEY", "kyc/results")

ENCLAVE_CID   = 16      # Fixed CID — matches sidecar/app.py ENCLAVE_CID
VSOCK_PORT    = 5000    # Enclave listen port — matches enclave/app.py VSOCK_PORT
BATCH_SIZE    = 50      # Records per VSOCK call


# ─── VSOCK helpers ────────────────────────────────────────────────────────────

def _recvall(sock, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("VSOCK socket closed unexpectedly")
        buf += chunk
    return buf


def _send_message(sock, data: bytes):
    sock.sendall(struct.pack(">I", len(data)) + data)


def _recv_message(sock) -> bytes:
    raw_len = _recvall(sock, 4)
    msg_len = struct.unpack(">I", raw_len)[0]
    return _recvall(sock, msg_len)


# ─── Enclave call ─────────────────────────────────────────────────────────────

def call_enclave(records: list, dek_ciphertext: str, creds: dict) -> list:
    """
    Send a batch of encrypted records to the local Nitro Enclave via VSOCK.
    Returns a list of {app_id, decision, reason} dicts.

    Retries up to 5 times if the enclave is not yet ready (e.g. just restarted).
    """
    payload = json.dumps({
        "dek_ciphertext": dek_ciphertext,
        "credentials":    creds,
        "records":        records,
    }).encode("utf-8")

    last_err = None
    for attempt in range(1, 6):
        try:
            sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            sock.settimeout(30)
            sock.connect((ENCLAVE_CID, VSOCK_PORT))
            _send_message(sock, payload)
            raw_resp = _recv_message(sock)
            sock.close()
            resp = json.loads(raw_resp.decode("utf-8"))
            if "error" in resp:
                raise RuntimeError(f"Enclave returned error: {resp['error']}")
            return resp["decisions"]
        except (ConnectionRefusedError, OSError) as e:
            last_err = e
            time.sleep(3 * attempt)
        except Exception as e:
            raise

    raise RuntimeError(
        f"Could not connect to enclave at CID={ENCLAVE_CID}:{VSOCK_PORT} "
        f"after 5 attempts: {last_err}"
    )


# ─── Partition processor ──────────────────────────────────────────────────────

def screen_partition(rows, dek_ciphertext_bc, region_bc):
    """
    mapPartitions function. Receives an iterator of Row objects,
    calls the enclave in batches, yields result rows.
    """
    dek_ciphertext = dek_ciphertext_bc.value
    region         = region_bc.value

    # Get IRSA credentials from the executor's IAM role
    session = boto3.Session()
    frozen  = session.get_credentials().get_frozen_credentials()
    creds   = {
        "aws_access_key_id":     frozen.access_key,
        "aws_secret_access_key": frozen.secret_key,
        "aws_session_token":     frozen.token or "",
        "region":                region,
    }

    batch = []
    for row in rows:
        batch.append({
            "app_id":      row["app_id"],
            "name_enc":    row["name_enc"],
            "dob_enc":     row["dob_enc"],
            "country_enc": row["country_enc"],
        })

        if len(batch) >= BATCH_SIZE:
            decisions = call_enclave(batch, dek_ciphertext, creds)
            yield from decisions
            batch = []

    if batch:
        decisions = call_enclave(batch, dek_ciphertext, creds)
        yield from decisions


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    spark = SparkSession.builder \
        .appName("nitro-kyc-screening") \
        .getOrCreate()

    spark.sparkContext.setLogLevel("WARN")
    log = spark._jvm.org.apache.log4j.LogManager.getLogger("nitro-kyc-screening")
    log.info(f"KYC screening job starting | bucket={S3_BUCKET} | input={S3_INPUT_KEY}")

    s3 = boto3.client("s3", region_name=AWS_REGION)

    # ── Read DEK ciphertext from S3 and broadcast to all executors ────────────
    log.info("Reading DEK ciphertext from S3...")
    resp = s3.get_object(Bucket=S3_BUCKET, Key=S3_DEK_KEY)
    dek_ciphertext = resp["Body"].read().decode("utf-8").strip()
    dek_bc  = spark.sparkContext.broadcast(dek_ciphertext)
    region_bc = spark.sparkContext.broadcast(AWS_REGION)
    log.info("DEK ciphertext broadcast to executors")

    # ── Read encrypted customer records ───────────────────────────────────────
    input_path = f"s3://{S3_BUCKET}/{S3_INPUT_KEY}"
    log.info(f"Reading encrypted records from {input_path}")
    df = spark.read.parquet(input_path)
    total_records = df.count()
    log.info(f"Loaded {total_records} records")

    # ── Screen partitions via enclave ─────────────────────────────────────────
    result_schema = StructType([
        StructField("app_id",   StringType(), False),
        StructField("decision", StringType(), False),
        StructField("reason",   StringType(), True),
    ])

    results_rdd = df.rdd.mapPartitions(
        lambda rows: screen_partition(rows, dek_bc, region_bc)
    )
    results_df = spark.createDataFrame(results_rdd, schema=result_schema)

    # ── Write results to S3 ───────────────────────────────────────────────────
    output_path = f"s3://{S3_BUCKET}/{S3_OUTPUT_KEY}"
    log.info(f"Writing results to {output_path}")
    results_df.write.mode("overwrite").parquet(output_path)

    # ── Print summary ─────────────────────────────────────────────────────────
    summary = results_df.groupBy("decision", "reason").count().orderBy("decision", "reason")
    print("\n" + "=" * 60)
    print("KYC SCREENING COMPLETE")
    print("=" * 60)
    summary.show(truncate=False)

    approve_count = results_df.filter(F.col("decision") == "APPROVE").count()
    reject_count  = results_df.filter(F.col("decision") == "REJECT").count()
    print(f"Total   : {total_records}")
    print(f"APPROVE : {approve_count} ({approve_count/total_records*100:.1f}%)")
    print(f"REJECT  : {reject_count}  ({reject_count/total_records*100:.1f}%)")
    print(f"Results : {output_path}")
    print("=" * 60 + "\n")

    spark.stop()


if __name__ == "__main__":
    main()
