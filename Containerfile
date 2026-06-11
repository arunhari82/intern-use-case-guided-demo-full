# ─────────────────────────────────────────────────────────────────────────────
# Containerfile — Thoughts Dashboard
# Image: quay.io/redhat_na_ssa/thoughts-dashboard-guided
#
# Base image: Red Hat UBI 9 Python 3.11 (enterprise-approved, non-root UID 1001)
# Spec: specs/deployment/dockerfile.spec
# ─────────────────────────────────────────────────────────────────────────────

# ── Stage 1: Builder ─────────────────────────────────────────────────────────
FROM registry.access.redhat.com/ubi9/python-311:latest AS builder

# Install build-time dependencies (not carried into runtime image)
USER root
RUN dnf install -y \
        gcc \
        postgresql-devel \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Create isolated virtual environment
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install Python dependencies — requirements first for layer cache efficiency
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir \
        Flask==3.0.3 \
        psycopg2-binary==2.9.9 \
        gunicorn==22.0.0

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM registry.access.redhat.com/ubi9/python-311:latest

LABEL name="thoughts-dashboard" \
      version="1.0.0" \
      maintainer="redhat_na_ssa" \
      description="Thoughts Dashboard — read-only reporting UI" \
      org.opencontainers.image.source="quay.io/redhat_na_ssa/thoughts-dashboard-guided"

# Install runtime-only native libraries
USER root
RUN dnf install -y \
        postgresql \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Copy virtual environment from builder (no build tools included)
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Copy application source — owned by UID 1001 (UBI non-root default)
COPY --chown=1001:0 src/ /app/src/

# Red Hat UBI images already run as UID 1001 — enforce explicitly
USER 1001

EXPOSE 8000

# Liveness/readiness probe target
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

# Production WSGI server — never use `flask run` in containers
CMD ["gunicorn", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "2", \
     "--timeout", "60", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "src.app:app"]
