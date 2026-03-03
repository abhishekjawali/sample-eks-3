# sidecar/Dockerfile
# Sidecar container image for the Nitro KYC DaemonSet.
#
# Contains:
#   - nitro-cli       : to launch/terminate/monitor the enclave
#   - vsock-proxy     : to forward KMS HTTPS traffic from the enclave
#   - enclave.eif     : the Nitro Enclave image (baked in by build_sidecar.sh)
#   - app.py          : long-running sidecar that manages enclave lifecycle
#
# The EIF file must be present in this directory before building.
# build_sidecar.sh downloads it from S3 automatically.

FROM amazonlinux:2023

# ─── System packages ──────────────────────────────────────────────────────────
RUN dnf install -y \
      python3 \
      python3-pip \
      aws-nitro-enclaves-cli \
      aws-nitro-enclaves-cli-devel \
    && dnf clean all

# vsock-proxy is shipped with aws-nitro-enclaves-cli
RUN which vsock-proxy && vsock-proxy --version || true

# ─── Python dependencies ──────────────────────────────────────────────────────
WORKDIR /app
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

# ─── Application ──────────────────────────────────────────────────────────────
COPY app.py .

# ─── EIF (baked in by build_sidecar.sh) ──────────────────────────────────────
# build_sidecar.sh downloads enclave.eif from S3 before building this image.
COPY enclave.eif /app/enclave.eif

ENV AWS_REGION=us-west-2
ENV EIF_PATH=/app/enclave.eif
ENV ENCLAVE_CPU_COUNT=2
ENV ENCLAVE_MEMORY_MB=2048
ENV ENCLAVE_DEBUG=false

CMD ["python3", "app.py"]
