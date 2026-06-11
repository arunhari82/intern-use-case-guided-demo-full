#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# build.sh — Build, tag, and push the Thoughts Dashboard container image
#
# Usage:
#   ./build.sh                   # build + tag + push (latest + git SHA)
#   ./build.sh --build-only      # build and tag only, skip push
#   ./build.sh --no-cache        # force full rebuild (no layer cache)
#
# Prerequisites:
#   - podman OR docker installed and in PATH
#   - Logged in to quay.io:  podman login quay.io
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
REGISTRY="quay.io"
IMAGE_NAME="redhat_na_ssa/thoughts-dashboard-guided"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}"
CONTAINERFILE="Containerfile"
BUILD_ONLY=false
NO_CACHE=""

# ── Argument parsing ──────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --build-only) BUILD_ONLY=true ;;
    --no-cache)   NO_CACHE="--no-cache" ;;
    *)
      echo "Unknown argument: $arg"
      echo "Usage: $0 [--build-only] [--no-cache]"
      exit 1
      ;;
  esac
done

# ── Detect container engine (prefer podman, fall back to docker) ──────────────
if command -v podman &>/dev/null; then
  ENGINE="podman"
elif command -v docker &>/dev/null; then
  ENGINE="docker"
else
  echo "ERROR: Neither podman nor docker found in PATH."
  exit 1
fi
echo "→ Container engine: ${ENGINE}"

# ── Derive image tags ─────────────────────────────────────────────────────────
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")
DATE_TAG=$(date -u +%Y%m%d)
VERSION_TAG="${DATE_TAG}-${GIT_SHA}"

echo "→ Image:   ${FULL_IMAGE}"
echo "→ Tags:    latest  |  ${VERSION_TAG}"
echo ""

# ── Build ─────────────────────────────────────────────────────────────────────
echo "▶  Building image..."
"$ENGINE" build \
  ${NO_CACHE} \
  --file "${CONTAINERFILE}" \
  --tag "${FULL_IMAGE}:latest" \
  --tag "${FULL_IMAGE}:${VERSION_TAG}" \
  .

echo ""
echo "✔  Build complete."
echo ""

# ── Verify non-root user ──────────────────────────────────────────────────────
echo "▶  Verifying container runs as non-root..."
RUNNING_UID=$("$ENGINE" run --rm --entrypoint '' "${FULL_IMAGE}:latest" id -u)
if [ "$RUNNING_UID" -eq 0 ]; then
  echo "ERROR: Container is running as root (UID 0). Aborting."
  exit 1
fi
echo "✔  Running as UID ${RUNNING_UID} (non-root confirmed)."
echo ""

# ── Push ─────────────────────────────────────────────────────────────────────
if [ "$BUILD_ONLY" = true ]; then
  echo "ℹ  --build-only set. Skipping push."
  echo ""
  echo "To push manually:"
  echo "  ${ENGINE} push ${FULL_IMAGE}:latest"
  echo "  ${ENGINE} push ${FULL_IMAGE}:${VERSION_TAG}"
  exit 0
fi

echo "▶  Pushing image to ${REGISTRY}..."
"$ENGINE" push "${FULL_IMAGE}:latest"
"$ENGINE" push "${FULL_IMAGE}:${VERSION_TAG}"

echo ""
echo "✔  Push complete."
echo ""
echo "  Image:   ${FULL_IMAGE}:latest"
echo "  Tagged:  ${FULL_IMAGE}:${VERSION_TAG}"
echo ""
echo "To run locally:"
echo "  ${ENGINE} run --rm -p 8000:8000 \\"
echo "    -e DB_HOST=<host> \\"
echo "    -e DB_NAME=thoughts \\"
echo "    -e DB_USER=thoughts \\"
echo "    -e DB_PASSWORD=<password> \\"
echo "    ${FULL_IMAGE}:latest"
