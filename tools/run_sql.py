#!/usr/bin/env python3
"""Run arbitrary SQL against the Supabase Postgres database.

Usage:
    python3 run_sql.py "ALTER TABLE tasks ADD COLUMN foo TEXT;"
    python3 run_sql.py < supabase/migrations/some_migration.sql

Connects straight to Postgres with SUPABASE_DB_URL rather than going through
the Management API. That API needs a Personal Access Token, and the PAT
expired three times -- twice inside eight days -- each time silently breaking
whatever was mid-flight. A database password does not expire.

Use the **Session pooler** URI from Dashboard > Project Settings > Database >
Connection string. The direct host (db.<ref>.supabase.co) publishes only an
AAAA record since Supabase deprecated IPv4, and this machine has no global
IPv6 address, so the direct URI cannot connect at all. The pooler has IPv4.

Multiple statements in one call are supported -- psycopg2 sends a parameterless
execute() over the simple query protocol -- so whole migration files pipe in
unchanged. Everything runs in one transaction and rolls back as a unit.
"""
import json
import os
import sys
from datetime import date, datetime
from decimal import Decimal


def load_env(path):
    if not os.path.exists(path):
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())


def jsonable(v):
    if isinstance(v, (datetime, date)):
        return v.isoformat(sep=" ")
    if isinstance(v, Decimal):
        # Mirrors the Management API, which returned numerics as strings.
        return str(v)
    if isinstance(v, memoryview):
        return v.hex()
    return v


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    load_env(os.path.join(root, ".env"))

    db_url = os.environ.get("SUPABASE_DB_URL")
    if not db_url:
        sys.exit(
            "Missing SUPABASE_DB_URL in .env.\n"
            "  Dashboard > Project Settings > Database > Connection string >\n"
            "  Session pooler, then add it as:\n"
            "    SUPABASE_DB_URL=postgresql://postgres.<ref>:<password>"
            "@aws-N-<region>.pooler.supabase.com:5432/postgres"
        )

    try:
        import psycopg2
    except ImportError:
        sys.exit("psycopg2 is not installed. Run: python3 -m pip install psycopg2-binary")

    sql = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else sys.stdin.read()
    if not sql.strip():
        sys.exit("No SQL provided")

    ref = os.environ.get("SUPABASE_URL", "").replace("https://", "").split(".", 1)[0]
    print(f"Project {ref}:\n  {sql.strip()}\n")

    # sslmode=require: the pooler accepts plaintext, and a database password
    # should never cross the wire in the clear.
    if "sslmode=" not in db_url:
        db_url += ("&" if "?" in db_url else "?") + "sslmode=require"

    try:
        conn = psycopg2.connect(db_url, connect_timeout=15)
    except Exception as e:
        sys.exit(f"Connection failed: {type(e).__name__}: {e}")

    try:
        with conn, conn.cursor() as cur:
            cur.execute(sql)
            print("OK")
            # Only the final statement's result set is retrievable, which is
            # what the Management API returned too. Output stays a JSON array
            # so existing callers that parse this can keep doing so.
            if cur.description:
                cols = [d[0] for d in cur.description]
                rows = [{c: jsonable(v) for c, v in zip(cols, r)} for r in cur.fetchall()]
                print(json.dumps(rows, indent=2))
    except Exception as e:
        # `with conn` already rolled back; say so rather than leaving the
        # caller to wonder whether half a migration landed.
        sys.exit(f"Error ({type(e).__name__}), transaction rolled back: {e}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
