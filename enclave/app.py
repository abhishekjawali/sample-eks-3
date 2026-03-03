"""
enclave/app.py — Nitro Enclave KYC screening service

Long-running VSOCK server. Accepts batch requests from Spark executor pods,
decrypts PII fields using a KMS-protected DEK, applies KYC eligibility rules,
and returns only the decision — never the plaintext PII.

Flow per connection:
  1. Accept VSOCK connection on port 5000
  2. Receive JSON: { dek_ciphertext, credentials, records: [{app_id, name_enc, dob_enc, country_enc}] }
  3. Call kmstool_enclave_cli to decrypt the DEK (PCR-enforced KMS call)
  4. AES-GCM decrypt each PII field using the DEK
  5. Apply KYC rules: age check, country sanctions, name blocklist
  6. Send JSON response: { decisions: [{app_id, decision, reason}] }
  7. Close connection, loop back to step 1

VSOCK ports:
  5000 — enclave listens; Spark executors connect, send batch, receive decisions
  8000 — kmstool connects to vsock-proxy (CID=3) for KMS HTTPS forwarding
"""

import base64
import datetime
import json
import logging
import os
import socket
import struct
import subprocess
import unicodedata

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

VSOCK_PORT     = 5000
KMS_PROXY_PORT = 8000
PARENT_CID     = 3
KMSTOOL_PATH   = "/usr/local/bin/kmstool_enclave_cli"
KMS_REGION     = os.environ.get("AWS_REGION", "us-west-2")

# ─── KYC rule configuration ───────────────────────────────────────────────────

MINIMUM_AGE = 18

# OFAC/US Treasury sanctioned countries (ISO-3166-1 alpha-2)
SANCTIONED_COUNTRIES = {"IR", "KP", "SY", "CU", "SD", "MM"}

# Simple exact-match blocklist (normalised to uppercase, spaces stripped)
NAME_BLOCKLIST = {
    "JOHN DOE",
    "JANE DOE",
}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [ENCLAVE] %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)


# ─── VSOCK helpers ────────────────────────────────────────────────────────────

def _recvall(sock, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("Socket closed unexpectedly")
        buf += chunk
    return buf


def recv_message(sock) -> bytes:
    raw_len = _recvall(sock, 4)
    msg_len = struct.unpack(">I", raw_len)[0]
    return _recvall(sock, msg_len)


def send_message(sock, data: bytes):
    sock.sendall(struct.pack(">I", len(data)) + data)


# ─── DEK decryption via kmstool ───────────────────────────────────────────────

def decrypt_dek(dek_ciphertext_b64: str, creds: dict, region: str) -> bytes:
    """
    Decrypt the AES-256 DEK using kmstool_enclave_cli.
    The tool acquires the NSM attestation document (PCR values) and calls KMS
    Decrypt with the Recipient parameter — KMS validates PCR0 against the key
    policy before returning the plaintext DEK.
    Returns raw 32-byte DEK.
    """
    cmd = [
        KMSTOOL_PATH,
        "decrypt",
        "--region",                region,
        "--proxy-port",            str(KMS_PROXY_PORT),
        "--aws-access-key-id",     creds["aws_access_key_id"],
        "--aws-secret-access-key", creds["aws_secret_access_key"],
        "--aws-session-token",     creds.get("aws_session_token", ""),
        "--ciphertext",            dek_ciphertext_b64,
    ]

    result = subprocess.run(cmd, capture_output=True)

    stderr_text = result.stderr.decode("utf-8", errors="replace").strip()
    stdout_text = result.stdout.decode("utf-8", errors="replace").strip()

    if stderr_text:
        log.info("kmstool stderr: %s", stderr_text[:300])

    if result.returncode != 0:
        raise RuntimeError(
            f"kmstool_enclave_cli decrypt failed (exit={result.returncode}): {stderr_text}"
        )

    if not stdout_text.startswith("PLAINTEXT:"):
        raise ValueError(f"Unexpected kmstool output: {stdout_text!r}")

    dek_b64 = stdout_text.split(":", 1)[1].strip()
    return base64.b64decode(dek_b64)


# ─── Field decryption ─────────────────────────────────────────────────────────

def decrypt_field(dek: bytes, ciphertext_b64: str) -> str:
    """
    AES-256-GCM decrypt a single PII field.
    Ciphertext format (base64-encoded): nonce (12 bytes) || ciphertext+tag
    Returns the plaintext string (UTF-8).
    """
    raw = base64.b64decode(ciphertext_b64)
    nonce      = raw[:12]
    ciphertext = raw[12:]
    aesgcm = AESGCM(dek)
    plaintext = aesgcm.decrypt(nonce, ciphertext, None)
    return plaintext.decode("utf-8")


# ─── KYC rules ────────────────────────────────────────────────────────────────

def _normalise_name(name: str) -> str:
    """Uppercase, strip accents, collapse whitespace."""
    nfkd = unicodedata.normalize("NFKD", name)
    ascii_name = nfkd.encode("ascii", "ignore").decode("ascii")
    return " ".join(ascii_name.upper().split())


def apply_kyc_rules(name: str, dob_str: str, country: str):
    """
    Apply eligibility rules. Returns (decision, reason).
    decision: "APPROVE" | "REJECT"
    reason:   None | "UNDERAGE" | "SANCTIONED_COUNTRY" | "BLOCKLIST"

    Rules checked in priority order — first failure wins.
    """
    # Rule 1 — Age check
    try:
        dob = datetime.date.fromisoformat(dob_str)          # expects YYYY-MM-DD
        today = datetime.date.today()
        age = today.year - dob.year - ((today.month, today.day) < (dob.month, dob.day))
    except ValueError:
        return "REJECT", "INVALID_DOB"

    if age < MINIMUM_AGE:
        return "REJECT", "UNDERAGE"

    # Rule 2 — Sanctioned country
    if country.strip().upper() in SANCTIONED_COUNTRIES:
        return "REJECT", "SANCTIONED_COUNTRY"

    # Rule 3 — Name blocklist
    if _normalise_name(name) in NAME_BLOCKLIST:
        return "REJECT", "BLOCKLIST"

    return "APPROVE", None


# ─── Request handler ──────────────────────────────────────────────────────────

def handle_request(conn):
    """Process one batch request on an open VSOCK connection."""
    try:
        raw = recv_message(conn)
        payload = json.loads(raw.decode("utf-8"))

        dek_ciphertext = payload["dek_ciphertext"]
        creds          = payload["credentials"]
        records        = payload["records"]
        region         = creds.get("region", KMS_REGION)

        log.info("Batch received: %d records", len(records))

        # Decrypt DEK via KMS (PCR-enforced)
        dek = decrypt_dek(dek_ciphertext, creds, region)
        log.info("DEK decrypted successfully")

        decisions = []
        for rec in records:
            app_id = rec["app_id"]
            try:
                name    = decrypt_field(dek, rec["name_enc"])
                dob_str = decrypt_field(dek, rec["dob_enc"])
                country = decrypt_field(dek, rec["country_enc"])

                # Apply rules — name/dob/country never logged or returned
                decision, reason = apply_kyc_rules(name, dob_str, country)
            except Exception as e:
                log.warning("Record %s processing error: %s", app_id, e)
                decision, reason = "REJECT", "PROCESSING_ERROR"

            decisions.append({
                "app_id":   app_id,
                "decision": decision,
                "reason":   reason,
            })

        approve_count = sum(1 for d in decisions if d["decision"] == "APPROVE")
        reject_count  = len(decisions) - approve_count
        log.info("Batch complete: %d APPROVE, %d REJECT", approve_count, reject_count)

        response = json.dumps({"decisions": decisions}).encode("utf-8")
        send_message(conn, response)

    except Exception as e:
        log.error("handle_request error: %s", e, exc_info=True)
        error_resp = json.dumps({"error": str(e)}).encode("utf-8")
        try:
            send_message(conn, error_resp)
        except Exception:
            pass


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    log.info("KYC Enclave service starting (region=%s)", KMS_REGION)

    server_sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    server_sock.bind((socket.VMADDR_CID_ANY, VSOCK_PORT))
    server_sock.listen(5)
    log.info("Listening on VSOCK port %d", VSOCK_PORT)

    while True:
        conn, addr = server_sock.accept()
        log.info("Connection accepted from CID=%s", addr)
        with conn:
            handle_request(conn)


if __name__ == "__main__":
    main()
