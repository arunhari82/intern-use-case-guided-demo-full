#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# run.sh  –  Setup and launch the Thoughts Dashboard locally
#
# Usage:
#   ./run.sh                  # uses defaults below
#   DB_PASSWORD=xxx ./run.sh  # override any variable
# ─────────────────────────────────────────────────────────────
set -euo pipefail

VENV_DIR="$(dirname "$0")/.venv"
REQUIREMENTS="$(dirname "$0")/requirements.txt"

# ── Database config (override via env vars) ──────────────────
export DB_HOST="${DB_HOST:-postgresql.thoughts-app.svc.cluster.local}"
export DB_NAME="${DB_NAME:-thoughts}"
export DB_USER="${DB_USER:-thoughts}"

# DB_PASSWORD must be set in the environment — never hardcoded
if [ -z "${DB_PASSWORD:-}" ]; then
  echo ""
  echo "ERROR: DB_PASSWORD environment variable is not set."
  echo "       Export it before running this script:"
  echo ""
  echo "         export DB_PASSWORD=<your-password>"
  echo "         ./run.sh"
  echo ""
  exit 1
fi

# ── Create venv if missing ───────────────────────────────────
if [ ! -d "$VENV_DIR" ]; then
  echo "→ Creating virtual environment..."
  python3 -m venv "$VENV_DIR"
fi

# ── Install / sync dependencies ──────────────────────────────
echo "→ Installing dependencies..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet \
  Flask==3.0.3 \
  psycopg2-binary==2.9.9 \
  gunicorn==22.0.0

echo ""
echo "✔  Virtual env ready: $VENV_DIR"
echo "✔  Connecting to:     $DB_HOST / $DB_NAME as $DB_USER"
echo ""
echo "→ Starting dashboard on http://localhost:8000 ..."
echo "   Press Ctrl+C to stop."
echo ""

# ── Launch Flask dev server ──────────────────────────────────
FLASK_APP=src/app.py \
  "$VENV_DIR/bin/python" -m flask run --host=0.0.0.0 --port=8000
