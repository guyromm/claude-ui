"""Minimal PostgreSQL access for the relay -- claude-ui's own, so it never imports the host project.
DSN: CLAUDE_UI_PG, else DBURI (libpq strings/URIs)."""
import os
import sys
import psycopg
from psycopg.rows import dict_row

DSN = os.environ.get("CLAUDE_UI_PG") or os.environ.get("DBURI") or ""   # "" = libpq defaults (PG* env)
# claude_* tables live in the host's data schema; queries are unqualified and resolve through search_path
_S = os.environ.get("CLAUDE_UI_SCHEMA") or "public"
SEARCH_PATH = f"{_S},public"
_APP = os.path.basename(sys.argv[0] or "python")
_OPTS = f"-c search_path={SEARCH_PATH} -c application_name={_APP}"


def connect(autocommit=False):
    return psycopg.connect(DSN, autocommit=autocommit, options=_OPTS)


def q(sql, params=None):
    with psycopg.connect(DSN, row_factory=dict_row, options=_OPTS) as c:
        return c.execute(sql, params or ()).fetchall()


def q1(sql, params=None):
    rows = q(sql, params)
    return rows[0] if rows else None
