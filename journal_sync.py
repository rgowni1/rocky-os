#!/usr/bin/env python3
"""Notion Logging Journal → Supabase public.journal_entries.

Runs at the end of each week. Replaces the half of kanban's
sync_journal_to_supabase.py that filled journal_entries; the meal / food-log
half did not come across.

Sleep columns are deliberately NOT written here. oura.py owns slp_hrs,
slp_score, slp_hrv, rhr, avg_sleep_time and avg_wake_time, sourcing them from
oura_weekly (the Supabase source of truth) and pushing them *out* to Notion.
Reading them back off the Notion page would close a Notion → Supabase → Notion
loop and let a rounded, one-run-stale copy overwrite the real values.

Usage:
    python journal_sync.py                 # last 4 weeks (catches late edits)
    python journal_sync.py --weeks 12
    python journal_sync.py --all           # every week in the database
    python journal_sync.py --dry-run       # fetch and map, write nothing
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import date, datetime, timedelta, timezone
from urllib import error as urlerror
from urllib import parse as urlparse
from urllib import request as urlrequest

from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

NOTION_VERSION = "2022-06-28"
DEFAULT_LOOKBACK_WEEKS = 4

# A week whose food log was abandoned after a meal or two reports a real-looking
# but tiny daily average that wrecks every nutrition trend. Treat anything below
# a subsistence floor as unlogged. Carried over from the original sync.
MIN_PLAUSIBLE_DAILY_CALS = 900

# Notion properties already mapped to their own column, so the `unstructured`
# catch-all does not duplicate them.
MAPPED_TEXT_PROPS = {
    "High", "Low", "High Of the Week", "Stressors", "Bud",
    "Avg Sleep Time", "Avg Wake Time",
}

# Empty journal templates come back with these instead of nothing.
PLACEHOLDERS = {"", "no content", "n/a", "-"}


# ── env / http ───────────────────────────────────────────────────────────────

def require_env(*keys):
    missing = [k for k in keys if not os.getenv(k)]
    if missing:
        raise SystemExit(f"Missing required environment variables: {', '.join(missing)}")


def http(url, *, method="GET", headers=None, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urlrequest.Request(url, data=data, method=method)
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    try:
        with urlrequest.urlopen(req, timeout=timeout) as response:
            return response.status, json.loads(response.read() or b"null")
    except urlerror.HTTPError as exc:
        try:
            payload = json.loads(exc.read() or b"{}")
        except Exception:
            payload = {"error": str(exc)}
        return exc.code, payload


# ── Notion → row ─────────────────────────────────────────────────────────────

def page_to_row(page, user_id, synced_at):
    props = page.get("properties", {})

    def number(name):
        return (props.get(name) or {}).get("number")

    def formula_number(name):
        formula = (props.get(name) or {}).get("formula") or {}
        if formula.get("type") == "number":
            return formula.get("number")
        if formula.get("type") == "string":
            match = re.search(r"-?[\d,]+(?:\.\d+)?", formula.get("string") or "")
            return float(match.group(0).replace(",", "")) if match else None
        return None

    def positive_formula_number(name):
        value = formula_number(name)
        return value if value is not None and value > 0 else None

    def rollup_number(name):
        rollup = (props.get(name) or {}).get("rollup") or {}
        return rollup.get("number") if rollup.get("type") == "number" else None

    def date_value(name):
        return ((props.get(name) or {}).get("date") or {}).get("start")

    def rich_text(name):
        parts = (props.get(name) or {}).get("rich_text", [])
        text = "".join(part.get("plain_text", "") for part in parts).strip()
        return None if text.lower() in PLACEHOLDERS else text

    def title(name):
        parts = (props.get(name) or {}).get("title", [])
        text = "".join(part.get("plain_text", "") for part in parts).strip()
        return text or None

    def people(name):
        entries = (props.get(name) or {}).get("people", [])
        names = [p.get("name") for p in entries if p.get("name")]
        return names or None

    # Any other text property, so a new Notion field is captured without a
    # migration. Promote a key to a real column once something queries it.
    unstructured = {}
    for prop_name, prop in props.items():
        if prop.get("type") != "rich_text" or prop_name in MAPPED_TEXT_PROPS:
            continue
        value = rich_text(prop_name)
        if value:
            unstructured[prop_name] = value

    row = {
        "user_id": user_id,
        "week": date_value("Week of Journal"),
        "notion_page_id": page.get("id"),
        "source_updated_at": page.get("last_edited_time"),
        "synced_at": synced_at,
        # Narrative / unstructured
        "journal_title": title("Name"),
        "journal_high": rich_text("High"),
        "journal_low": rich_text("Low"),
        "journal_high_of_week": rich_text("High Of the Week"),
        "journal_stressors": rich_text("Stressors"),
        "journal_bud": rich_text("Bud"),
        "people_met": people("People Met"),
        "people_tagged": people("Person"),
        "unstructured": unstructured or None,
        # Numeric (sleep columns omitted on purpose — see module docstring)
        "run_miles": number("Run Miles"),
        "bike_miles": number("Bike Miles"),
        "swim_yards": number("Swim Yards"),
        "strength_mins": number("Strength Minutes"),
        "intensity_mins": number("Intensity Minutes"),
        "step_count": number("Step Count"),
        "body_fat": number("Body Fat %"),
        "weekly_weight": number("Weekly Weight"),
        "stress": number("Stress Level"),
        "meditation": number("Meditation Sessions"),
        "articles": number("Articles"),
        "podcasts": number("Podcasts & Videos"),
        "phone_pickups": number("Total Ph Pick Ups"),
        "avg_daily_pickups": formula_number("Avg Daily Pick Ups"),
        "training_hrs": number("Logged Training Hrs"),
        "consumed_cals": positive_formula_number("Consumed Cals"),
        "avg_protein": positive_formula_number("Avg Protein"),
        "calorie_deficit": formula_number("Calorie Deficit"),
        "garmin_tdee": number("Garmin TDEE"),
        "non_profile_meals": rollup_number("FL Non Profile"),
        "dcp_meals": rollup_number("FL DCP"),
        "drinks": rollup_number("FL Drinks"),
    }

    # Nutrition is derived from intake, so drop the triple together.
    if row["consumed_cals"] is not None and row["consumed_cals"] < MIN_PLAUSIBLE_DAILY_CALS:
        row["consumed_cals"] = None
        row["avg_protein"] = None
        row["calorie_deficit"] = None

    # "FL Non Profile" is a sum rollup: an empty food log reports 0, which is
    # indistinguishable from a week of perfect adherence once it is drawn.
    if row["consumed_cals"] is None:
        row["non_profile_meals"] = None
        row["dcp_meals"] = None
        row["drinks"] = None

    return row


def fetch_notion_rows(token, database_id, user_id, since: date | None):
    headers = {
        "Authorization": f"Bearer {token}",
        "Notion-Version": NOTION_VERSION,
        "Content-Type": "application/json",
    }
    synced_at = datetime.now(timezone.utc).isoformat()
    rows = []
    cursor = None
    while True:
        body = {
            "page_size": 100,
            "sorts": [{"property": "Week of Journal", "direction": "ascending"}],
        }
        if since:
            body["filter"] = {
                "property": "Week of Journal",
                "date": {"on_or_after": since.isoformat()},
            }
        if cursor:
            body["start_cursor"] = cursor

        status, payload = http(
            f"https://api.notion.com/v1/databases/{database_id}/query",
            method="POST", headers=headers, body=body,
        )
        if status >= 400:
            raise SystemExit(f"Notion query error {status}: {payload}")

        for page in payload.get("results") or []:
            row = page_to_row(page, user_id, synced_at)
            # A page with no "Week of Journal" has no key to upsert on.
            if not row["week"]:
                continue
            rows.append(row)

        if not payload.get("has_more"):
            break
        cursor = payload.get("next_cursor")

    return dedupe_by_week(rows)


NARRATIVE_KEYS = (
    "journal_high", "journal_low", "journal_high_of_week",
    "journal_stressors", "journal_bud",
)


def _content_rank(row):
    """Rank candidates for the same week: most narrative first, then freshest.

    Deliberately NOT based on the page title. 31 weeks are titled "Weekly
    Template" yet hold genuine journal text (a contiguous run from 2025-07-28 to
    2026-01-12 among them), so filtering on the title silently drops real weeks.
    The 21 unfilled duplicates that forced this all sit on 2023-01-12 and lose
    on content length instead. Page id breaks ties so runs are reproducible.
    """
    text_len = sum(len(row.get(k) or "") for k in NARRATIVE_KEYS)
    return (text_len, row["source_updated_at"] or "", row["notion_page_id"] or "")


def dedupe_by_week(rows):
    """One row per week — the upsert targets (user_id, week).

    Postgres rejects an ON CONFLICT batch that touches the same key twice, so a
    duplicate week fails the whole request rather than just itself.
    """
    best = {}
    for row in rows:
        current = best.get(row["week"])
        if current is None or _content_rank(row) > _content_rank(current):
            best[row["week"]] = row

    dropped = len(rows) - len(best)
    if dropped:
        print(f"  Collapsed {dropped} duplicate-week page(s), keeping the fullest each")
    return [best[week] for week in sorted(best)]


# ── Supabase ─────────────────────────────────────────────────────────────────

def upsert_journal_entries(supabase_url, secret_key, rows) -> int:
    if not rows:
        return 0
    headers = {
        "apikey": secret_key,
        "Authorization": f"Bearer {secret_key}",
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates,return=minimal",
    }
    endpoint = (
        f"{supabase_url}/rest/v1/journal_entries?"
        + urlparse.urlencode({"on_conflict": "user_id,week"})
    )
    synced = 0
    for i in range(0, len(rows), 100):
        chunk = rows[i:i + 100]
        status, body = http(endpoint, method="POST", headers=headers, body=chunk)
        if status >= 400:
            raise SystemExit(f"Supabase journal_entries upsert error {status}: {body}")
        synced += len(chunk)
    return synced


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Notion Logging Journal → Supabase")
    parser.add_argument(
        "--weeks", type=int, default=DEFAULT_LOOKBACK_WEEKS,
        help=f"How many recent weeks to re-sync (default {DEFAULT_LOOKBACK_WEEKS})",
    )
    parser.add_argument("--all", action="store_true", help="Sync every week in the database")
    parser.add_argument("--dry-run", action="store_true", help="Fetch and map, write nothing")
    args = parser.parse_args()

    require_env("NOTION_TOKEN", "SUPABASE_URL", "SUPABASE_SECRET_KEY", "KANBAN_USER_ID")
    token = os.environ["NOTION_TOKEN"]
    supabase_url = os.environ["SUPABASE_URL"].rstrip("/")
    secret_key = os.environ["SUPABASE_SECRET_KEY"]
    user_id = os.environ["KANBAN_USER_ID"]

    database_id = os.getenv("NOTION_DATABASE_ID") or os.getenv("NOTION_JOURNAL_DB_ID")
    if not database_id:
        raise SystemExit("Missing NOTION_DATABASE_ID (or NOTION_JOURNAL_DB_ID)")

    since = None
    if not args.all:
        today = datetime.now(timezone.utc).date()
        monday = today - timedelta(days=today.weekday())
        since = monday - timedelta(weeks=args.weeks - 1)

    scope = "all weeks" if args.all else f"weeks since {since}"
    print(f"\n=== Notion → Supabase journal_entries: {scope} ===")

    rows = fetch_notion_rows(token, database_id, user_id, since)
    print(f"Fetched {len(rows)} journal pages")
    if not rows:
        print("Nothing to sync.")
        return

    narrative = sum(
        1 for r in rows
        if any(r[k] for k in ("journal_high", "journal_low", "journal_high_of_week",
                              "journal_stressors", "journal_bud", "unstructured"))
    )
    print(f"  {narrative} of them carry narrative text")

    if args.dry_run:
        print("\n--dry-run, writing nothing. Sample:")
        for row in rows[-3:]:
            preview = {
                k: v for k, v in row.items()
                if k in ("week", "journal_title", "journal_high", "journal_low",
                         "journal_high_of_week", "journal_stressors", "people_met",
                         "unstructured") and v
            }
            print(f"  {json.dumps(preview, default=str)[:300]}")
        return

    synced = upsert_journal_entries(supabase_url, secret_key, rows)
    print(f"Upserted {synced} journal_entries rows")

    for row in rows[-3:]:
        bits = [f"{k}={'yes' if row[k] else '—'}" for k in
                ("journal_high", "journal_low", "journal_high_of_week", "journal_stressors")]
        print(f"  {row['week']}: " + " ".join(bits))

    print("\n✓ Complete")


if __name__ == "__main__":
    main()
