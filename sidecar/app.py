"""
sidecar/app.py — DaemonSet sidecar for the KYC Nitro Enclave service

Responsibilities:
  1. Start vsock-proxy (forwards KMS HTTPS traffic from enclave to real KMS)
  2. Launch the Nitro Enclave from the baked-in EIF with a fixed CID (16)
  3. Monitor enclave health every 30s — restart if it has exited
  4. On SIGTERM: terminate enclave, stop vsock-proxy, exit cleanly

The enclave (CID=16, port 5000) is accessible to any pod on the same node.
Spark executor pods connect to VSOCK CID=16:5000 directly — no coordination
with this sidecar is needed once the enclave is running.

Environment variables (set in enclave-daemonset.yaml):
  AWS_REGION        — AWS region (default: us-west-2)
  EIF_PATH          — Path to the EIF file (default: /app/enclave.eif)
  ENCLAVE_CPU_COUNT — vCPUs for the enclave (default: 2)
  ENCLAVE_MEMORY_MB — Memory in MiB for the enclave (default: 2048)
  ENCLAVE_DEBUG     — "true" enables --debug-mode (PCR0 = all-zeros)
"""

import json
import logging
import os
import signal
import subprocess
import sys
import threading
import time

AWS_REGION        = os.environ.get("AWS_REGION", "us-west-2")
EIF_PATH          = os.environ.get("EIF_PATH", "/app/enclave.eif")
ENCLAVE_CPU_COUNT = int(os.environ.get("ENCLAVE_CPU_COUNT", "2"))
ENCLAVE_MEMORY_MB = int(os.environ.get("ENCLAVE_MEMORY_MB", "2048"))
ENCLAVE_DEBUG     = os.environ.get("ENCLAVE_DEBUG", "").lower() == "true"
ENCLAVE_CID       = 16          # Fixed CID — Spark executors hardcode this
KMS_ENDPOINT      = f"kms.{AWS_REGION}.amazonaws.com"
VSOCK_PROXY_PORT  = 8000
HEALTH_CHECK_INTERVAL = 30      # seconds between enclave health checks

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [SIDECAR] %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)

# Global handles for cleanup
_vsock_proxy_proc = None
_enclave_id       = None
_shutting_down    = False


# ─── vsock-proxy ──────────────────────────────────────────────────────────────

def start_vsock_proxy() -> subprocess.Popen:
    """
    Start vsock-proxy to forward KMS HTTPS traffic from the enclave.
    vsock-proxy listens on VSOCK CID=3 (sidecar) port 8000 and forwards
    all traffic to kms.<region>.amazonaws.com:443.
    kmstool_enclave_cli inside the enclave connects directly to VSOCK CID=3:8000.
    """
    log.info("Starting vsock-proxy: VSOCK port %d → %s:443",
             VSOCK_PROXY_PORT, KMS_ENDPOINT)
    proc = subprocess.Popen(
        ["vsock-proxy", str(VSOCK_PROXY_PORT), KMS_ENDPOINT, "443"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    time.sleep(2)
    if proc.poll() is not None:
        _, stderr = proc.communicate()
        raise RuntimeError(f"vsock-proxy failed to start: {stderr.decode()}")
    log.info("vsock-proxy started (pid=%d)", proc.pid)
    return proc


# ─── Enclave lifecycle ────────────────────────────────────────────────────────

def _stream_enclave_console(enclave_id: str):
    """Stream enclave console output to sidecar logs (debug mode only)."""
    try:
        proc = subprocess.Popen(
            ["nitro-cli", "console", "--enclave-id", enclave_id],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        for line in proc.stdout:
            log.info("[ENCLAVE] %s", line.rstrip())
    except Exception as e:
        log.warning("Enclave console capture stopped: %s", e)


def launch_enclave() -> str:
    """
    Launch the Nitro Enclave from the EIF.
    Returns the enclave_id string.
    Uses fixed CID=16 so Spark executors can always connect to the same address.
    """
    log.info("Launching enclave: eif=%s cpu=%d memory=%dMiB cid=%d debug=%s",
             EIF_PATH, ENCLAVE_CPU_COUNT, ENCLAVE_MEMORY_MB, ENCLAVE_CID, ENCLAVE_DEBUG)

    cmd = [
        "nitro-cli", "run-enclave",
        "--eif-path",   EIF_PATH,
        "--cpu-count",  str(ENCLAVE_CPU_COUNT),
        "--memory",     str(ENCLAVE_MEMORY_MB),
        "--enclave-cid", str(ENCLAVE_CID),
    ]
    if ENCLAVE_DEBUG:
        cmd.append("--debug-mode")

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        log.error("nitro-cli run-enclave failed (exit=%d)", e.returncode)
        log.error("stdout: %s", e.stdout.strip())
        log.error("stderr: %s", e.stderr.strip())
        raise

    output     = json.loads(result.stdout)
    enclave_id = output["EnclaveID"]
    log.info("Enclave launched: id=%s CID=%s", enclave_id, output["EnclaveCID"])

    if ENCLAVE_DEBUG:
        t = threading.Thread(target=_stream_enclave_console,
                             args=(enclave_id,), daemon=True)
        t.start()

    return enclave_id


def terminate_enclave(enclave_id: str):
    """Terminate the enclave gracefully."""
    try:
        subprocess.run(
            ["nitro-cli", "terminate-enclave", "--enclave-id", enclave_id],
            capture_output=True, check=True,
        )
        log.info("Enclave %s terminated", enclave_id)
    except subprocess.CalledProcessError as e:
        log.warning("Failed to terminate enclave %s: %s", enclave_id, e)


def enclave_is_running(enclave_id: str) -> bool:
    """Return True if the enclave is still in RUNNING state."""
    try:
        result = subprocess.run(
            ["nitro-cli", "describe-enclaves"],
            capture_output=True, text=True, check=True,
        )
        enclaves = json.loads(result.stdout)
        for enc in enclaves:
            if enc.get("EnclaveID") == enclave_id and enc.get("State") == "RUNNING":
                return True
        return False
    except Exception as e:
        log.warning("describe-enclaves error: %s", e)
        return False


# ─── Signal handling ──────────────────────────────────────────────────────────

def _shutdown(signum, frame):
    global _shutting_down
    log.info("Received signal %d — shutting down", signum)
    _shutting_down = True
    if _enclave_id:
        terminate_enclave(_enclave_id)
    if _vsock_proxy_proc and _vsock_proxy_proc.poll() is None:
        _vsock_proxy_proc.terminate()
        log.info("vsock-proxy terminated")
    sys.exit(0)


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    global _vsock_proxy_proc, _enclave_id

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT,  _shutdown)

    log.info("KYC Enclave sidecar starting (region=%s)", AWS_REGION)

    # Start vsock-proxy
    _vsock_proxy_proc = start_vsock_proxy()

    # Launch enclave
    _enclave_id = launch_enclave()

    log.info("Enclave is running. Spark executors can connect to VSOCK CID=%d port 5000.",
             ENCLAVE_CID)

    # Monitor loop — restart enclave if it crashes
    while not _shutting_down:
        time.sleep(HEALTH_CHECK_INTERVAL)

        if not enclave_is_running(_enclave_id):
            log.warning("Enclave %s is no longer running — restarting...", _enclave_id)
            try:
                terminate_enclave(_enclave_id)  # clean up stale entry if any
            except Exception:
                pass
            try:
                _enclave_id = launch_enclave()
                log.info("Enclave restarted: id=%s", _enclave_id)
            except Exception as e:
                log.error("Failed to restart enclave: %s — will retry in %ds",
                          e, HEALTH_CHECK_INTERVAL)
        else:
            log.debug("Enclave health check OK")


if __name__ == "__main__":
    main()
