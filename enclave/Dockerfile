# enclave/Dockerfile
# This image is NOT run directly. It is converted to an EIF via:
#   nitro-cli build-enclave --docker-uri nitro-kyc-enclave:latest --output-file enclave.eif
#
# The EIF runs inside the Nitro Enclave — it has NO network, NO persistent storage.
# Communication with the sidecar/Spark executors happens exclusively via VSOCK.
#
# Prerequisites: build_eif.sh builds the AWS Nitro Enclaves SDK C image first:
#   docker build -f containers/Dockerfile.al2 --target builder \
#                -t aws-nitro-enclaves-sdk-c <sdk-repo-dir>
# That image provides kmstool_enclave_cli and libnsm.so used below.

# ── Stage 1: SDK builder (pre-built by build_eif.sh) ─────────────────────────
FROM aws-nitro-enclaves-sdk-c AS sdk-builder

# ── Stage 2: Final enclave image ─────────────────────────────────────────────
FROM amazonlinux:2023

# Python for the VSOCK service; pip for cryptography package
RUN dnf install -y python3 python3-pip iproute && dnf clean all

# cryptography — AES-GCM decryption of PII fields
WORKDIR /app
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

# kmstool_enclave_cli — handles NSM attestation, VSOCK→KMS, DEK decryption
COPY --from=sdk-builder /usr/bin/kmstool_enclave_cli /usr/local/bin/kmstool_enclave_cli

# NSM shared library required by kmstool at runtime
COPY --from=sdk-builder /usr/lib64/libnsm.so /usr/lib64/libnsm.so

# CA certificates for TLS verification when kmstool calls KMS
COPY --from=sdk-builder /etc/pki/tls/certs/ca-bundle.crt /etc/pki/tls/certs/ca-bundle.crt

# Enclave application
COPY app.py .

ENV AWS_REGION=us-west-2
ENV LD_LIBRARY_PATH=/usr/lib64

CMD ["python3", "/app/app.py"]
