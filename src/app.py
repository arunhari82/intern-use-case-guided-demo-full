"""
Thoughts Dashboard - Flask application for reporting thoughts and ratings.

Credentials are loaded exclusively from environment variables.
Required env vars: DB_HOST, DB_NAME, DB_USER, DB_PASSWORD
"""

import os
import logging
from typing import Any, Optional

import psycopg2
import psycopg2.extras
from flask import Flask, render_template, abort, request

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# App factory
# ---------------------------------------------------------------------------
app = Flask(__name__)

# Security headers applied to every response
@app.after_request
def set_security_headers(response):
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-XSS-Protection"] = "1; mode=block"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; "
        "style-src 'self' 'unsafe-inline'; "
        "script-src 'self' 'unsafe-inline';"
    )
    return response


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Whitelist of valid status values — user input is validated against this set
# before being used in any query. The mapping accepts the friendly CLI/URL
# names the CTO uses ("pending") as well as the raw DB enum values.
VALID_STATUSES: dict[str, str] = {
    "approved": "APPROVED",
    "rejected": "REJECTED",
    "pending":  "IN_REVIEW",
    "in_review": "IN_REVIEW",
    "removed":  "REMOVED",
}

# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def _get_db_config() -> dict[str, str]:
    """Load database configuration from environment variables only."""
    required = {
        "host": "DB_HOST",
        "dbname": "DB_NAME",
        "user": "DB_USER",
        "password": "DB_PASSWORD",
    }
    config: dict[str, str] = {}
    missing = []
    for key, env_var in required.items():
        value = os.environ.get(env_var)
        if not value:
            missing.append(env_var)
        else:
            config[key] = value

    if missing:
        raise ValueError(f"Required environment variable(s) not set: {', '.join(missing)}")

    config["connect_timeout"] = "5"
    return config


def _get_connection():
    """Open a new database connection using env-var credentials."""
    return psycopg2.connect(**_get_db_config())


def fetch_summary() -> dict[str, Any]:
    """Return status counts and aggregate rating metrics."""
    with _get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT
                    COUNT(*)                                                        AS total,
                    COUNT(*) FILTER (WHERE status = 'APPROVED')                    AS approved,
                    COUNT(*) FILTER (WHERE status = 'REJECTED')                    AS rejected,
                    COUNT(*) FILTER (WHERE status = 'IN_REVIEW')                   AS in_review,
                    COUNT(*) FILTER (WHERE status = 'REMOVED')                     AS removed,
                    ROUND(
                        COUNT(*) FILTER (WHERE status = 'APPROVED')::numeric
                        / NULLIF(COUNT(*), 0) * 100, 1
                    )                                                               AS approval_rate,
                    COALESCE(SUM(thumbs_up), 0)                                    AS total_thumbs_up,
                    COALESCE(SUM(thumbs_down), 0)                                  AS total_thumbs_down,
                    COALESCE(ROUND(AVG(thumbs_up - thumbs_down)::numeric, 1), 0)   AS avg_net_rating
                FROM thoughts
                """
            )
            return dict(cur.fetchone())


def fetch_top_thoughts(limit: int = 10) -> list[dict[str, Any]]:
    """Return top-rated approved thoughts ordered by net rating."""
    with _get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT
                    id,
                    content,
                    author,
                    author_bio,
                    status,
                    thumbs_up,
                    thumbs_down,
                    (thumbs_up - thumbs_down) AS net_rating,
                    created_at
                FROM thoughts
                WHERE status = 'APPROVED'
                ORDER BY net_rating DESC
                LIMIT %s
                """,
                (limit,),
            )
            return [dict(row) for row in cur.fetchall()]


def fetch_all_thoughts(status_filter: Optional[str] = None) -> list[dict[str, Any]]:
    """Return thoughts joined with their latest evaluation.

    Args:
        status_filter: A DB enum value (e.g. 'APPROVED') to filter by, or
                       None to return all thoughts. Value MUST already be
                       validated against VALID_STATUSES before calling.
    """
    with _get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            # WHERE clause is added only when a filter is requested.
            # The value is passed as a parameter — never interpolated —
            # to prevent SQL injection regardless of input.
            where_clause = "WHERE t.status = %s" if status_filter else ""
            params = (status_filter,) if status_filter else ()

            cur.execute(
                f"""
                SELECT
                    t.id,
                    t.content,
                    t.author,
                    t.status,
                    t.thumbs_up,
                    t.thumbs_down,
                    (t.thumbs_up - t.thumbs_down)   AS net_rating,
                    t.created_at,
                    te.similarity_score,
                    te.evaluated_at
                FROM thoughts t
                LEFT JOIN LATERAL (
                    SELECT similarity_score, evaluated_at
                    FROM thought_evaluations
                    WHERE thought_id = t.id
                    ORDER BY evaluated_at DESC
                    LIMIT 1
                ) te ON true
                {where_clause}
                ORDER BY t.created_at DESC
                """,
                params,
            )
            return [dict(row) for row in cur.fetchall()]


def fetch_evaluation_stats() -> list[dict[str, Any]]:
    """Return average / min / max similarity score grouped by evaluation status."""
    with _get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT
                    status,
                    COUNT(*)                                    AS count,
                    ROUND(AVG(similarity_score)::numeric, 4)    AS avg_score,
                    ROUND(MIN(similarity_score)::numeric, 4)    AS min_score,
                    ROUND(MAX(similarity_score)::numeric, 4)    AS max_score
                FROM thought_evaluations
                GROUP BY status
                ORDER BY status
                """
            )
            return [dict(row) for row in cur.fetchall()]


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/health")
def health():
    return {"status": "ok"}, 200


@app.route("/")
def dashboard():
    # ── Status filter ────────────────────────────────────────────────────
    # Accept ?status=approved|pending|rejected|in_review|removed|all
    # Input is validated strictly against a whitelist — any unrecognised
    # value is rejected with 400 rather than passed to the database.
    raw_status = request.args.get("status", "").strip().lower()

    if raw_status in ("", "all"):
        status_filter = None          # no WHERE clause → all thoughts
        active_filter = "all"
    elif raw_status in VALID_STATUSES:
        status_filter = VALID_STATUSES[raw_status]   # e.g. "APPROVED"
        active_filter = raw_status
    else:
        logger.warning("Invalid status filter requested: %r", raw_status)
        abort(400)

    try:
        summary = fetch_summary()
        top_thoughts = fetch_top_thoughts(10)
        all_thoughts = fetch_all_thoughts(status_filter)
        eval_stats = fetch_evaluation_stats()
    except ValueError as exc:
        logger.error("Configuration error: %s", exc)
        abort(500)
    except psycopg2.OperationalError:
        logger.exception("Database connection failed")
        abort(503)
    except Exception:
        logger.exception("Unexpected error fetching dashboard data")
        abort(500)

    return render_template(
        "dashboard.html",
        summary=summary,
        top_thoughts=top_thoughts,
        all_thoughts=all_thoughts,
        eval_stats=eval_stats,
        active_filter=active_filter,
    )


# ---------------------------------------------------------------------------
# Entry point (dev only — use gunicorn in production)
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000, debug=False)
