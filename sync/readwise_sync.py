#!/usr/bin/env python3
"""Readwise → Supabase (source of truth), then weekly_master / Notion.

Mirrors oura.py: highlights land in public.readwise_daily at
(calendar_date, book_id) grain, readwise_weekly rolls them up, weekly_master
joins it for readers, and the Notion Logging Journal is pushed from it.

Split out of oura.py, where Readwise weekly counts were computed in memory and
written only to Notion — journal_sync.py then read them back into
weekly_metrics, so a number left Supabase's control and re-entered it.

Usage:
    python readwise_sync.py                      # last 14 days
    python readwise_sync.py --backfill 2026-01-01
    python readwise_sync.py --backfill 2026-01-01 2026-10-05
    python readwise_sync.py --skip-notion
"""
from __future__ import annotations

import argparse
import json
import os
from collections import defaultdict
from datetime import date, datetime, timedelta
from urllib import error as urlerror
from urllib import parse as urlparse
from urllib import request as urlrequest

import pytz
import requests
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env"))

PACIFIC = pytz.timezone("America/Los_Angeles")
NOTION_VERSION = "2022-06-28"
DEFAULT_LOOKBACK_DAYS = 14


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


def parse_ymd(value: str) -> date:
    return datetime.strptime(value, "%Y-%m-%d").date()


# ── Readwise ─────────────────────────────────────────────────────────────────

def fetch_highlights(token, start: date, end: date) -> list[dict]:
    headers = {"Authorization": f"Token {token}"}
    params = {
        "page_size": 1000,
        "highlighted_at__gt": f"{start.isoformat()}T00:00:00Z",
        "highlighted_at__lt": f"{(end + timedelta(days=1)).isoformat()}T00:00:00Z",
    }
    out, next_page = [], "https://readwise.io/api/v2/highlights/"
    while next_page:
        response = requests.get(next_page, headers=headers, params=params, timeout=60)
        response.raise_for_status()
        payload = response.json()
        out.extend(payload.get("results") or [])
        next_page = payload.get("next")
        params = {}
    return out


def fetch_books(token, book_ids) -> dict:
    """Book metadata keyed by id.

    Pages the list endpoint rather than fetching each book individually. The
    account has ~3.6k sources, so per-book lookups would mean thousands of
    requests on a backfill; this is a handful.
    """
    headers = {"Authorization": f"Token {token}"}
    wanted = set(book_ids)
    books = {}
    next_page = "https://readwise.io/api/v2/books/"
    params = {"page_size": 1000}
    while next_page and len(books) < len(wanted):
        response = requests.get(next_page, headers=headers, params=params, timeout=60)
        response.raise_for_status()
        payload = response.json()
        for book in payload.get("results") or []:
            if book.get("id") in wanted:
                books[book["id"]] = book
        next_page = payload.get("next")
        params = {}

    missing = wanted - set(books)
    if missing:
        print(f"  ⚠ {len(missing)} source(s) had no metadata; recorded uncategorised")
        for book_id in missing:
            books[book_id] = {}
    return books


def build_rows(highlights, books, user_id) -> list[dict]:
    """Collapse highlights to one row per (local day, book)."""
    synced_at = datetime.now(pytz.UTC).isoformat()
    counts = defaultdict(int)
    for highlight in highlights:
        stamp = highlight.get("highlighted_at")
        book_id = highlight.get("book_id")
        if not stamp or not book_id:
            continue
        # Readwise timestamps are UTC; oura_daily is keyed on Pacific calendar
        # dates, so convert to keep the two tables joinable by date.
        local = datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone(PACIFIC)
        counts[(local.date(), book_id)] += 1

    rows = []
    for (day, book_id), count in sorted(counts.items()):
        book = books.get(book_id) or {}
        source_url = book.get("source_url") or book.get("url") or ""
        is_youtube = bool(source_url) and (
            "youtube.com" in source_url.lower() or "youtu.be" in source_url.lower()
        )
        rows.append({
            "user_id": user_id,
            "calendar_date": day.isoformat(),
            "book_id": book_id,
            "book_title": book.get("title"),
            "author": book.get("author"),
            "category": book.get("category"),
            "source": book.get("source"),
            "source_url": source_url or None,
            "is_youtube": is_youtube,
            "highlight_count": count,
            "synced_at": synced_at,
        })
    return rows


# ── Supabase ─────────────────────────────────────────────────────────────────

def upsert_readwise_daily(supabase_url, secret_key, rows) -> int:
    if not rows:
        return 0
    headers = {
        "apikey": secret_key,
        "Authorization": f"Bearer {secret_key}",
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates,return=minimal",
    }
    endpoint = (
        f"{supabase_url}/rest/v1/readwise_daily?"
        + urlparse.urlencode({"on_conflict": "user_id,calendar_date,book_id"})
    )
    synced = 0
    for i in range(0, len(rows), 250):
        chunk = rows[i:i + 250]
        status, body = http(endpoint, method="POST", headers=headers, body=chunk)
        if status >= 400:
            raise SystemExit(f"Supabase readwise_daily upsert error {status}: {body}")
        synced += len(chunk)
    return synced


def fetch_readwise_weekly(supabase_url, secret_key, user_id, week_start: date, week_end: date):
    headers = {"apikey": secret_key, "Authorization": f"Bearer {secret_key}"}
    qs = (
        f"user_id=eq.{user_id}"
        f"&week_start=gte.{week_start.isoformat()}"
        f"&week_start=lte.{week_end.isoformat()}"
        f"&order=week_start.asc&select=*"
    )
    status, body = http(f"{supabase_url}/rest/v1/readwise_weekly?{qs}", headers=headers)
    if status >= 400:
        raise SystemExit(f"Supabase readwise_weekly read error {status}: {body}")
    return body or []


# ── Notion ───────────────────────────────────────────────────────────────────

def notion_headers(token):
    return {
        "Authorization": f"Bearer {token}",
        "Notion-Version": NOTION_VERSION,
        "Content-Type": "application/json",
    }


def find_notion_page_for_week(database_id, token, week_start: date):
    response = requests.post(
        f"https://api.notion.com/v1/databases/{database_id}/query",
        headers=notion_headers(token),
        json={
            "filter": {"property": "Week of Journal", "date": {"equals": week_start.isoformat()}},
            "page_size": 1,
        },
        timeout=60,
    )
    response.raise_for_status()
    results = response.json().get("results") or []
    return results[0]["id"] if results else None


def sync_notion_from_weekly(weeks, database_id, token) -> int:
    """Notion is a waypoint here, not a source — these values come from Supabase."""
    updated = 0
    for week in weeks:
        week_start = week["week_start"]
        week_date = parse_ymd(week_start[:10]) if isinstance(week_start, str) else week_start

        page_id = find_notion_page_for_week(database_id, token, week_date)
        if not page_id:
            print(f"  ⚠ No Notion page for week {week_date}")
            continue

        properties = {
            "Highlights": {"number": int(week.get("highlights") or 0)},
            "Articles": {"number": int(week.get("distinct_articles") or 0)},
            "Podcasts & Videos": {"number": int(week.get("distinct_podcasts_videos") or 0)},
        }
        print(f"  Notion week {week_date}: {list(properties.keys())}")
        response = requests.patch(
            f"https://api.notion.com/v1/pages/{page_id}",
            headers=notion_headers(token), json={"properties": properties}, timeout=60,
        )
        if response.status_code != 200:
            print(f"  ✗ Notion API error {response.status_code}: {response.text[:300]}")
            continue
        updated += 1
    return updated


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Readwise → Supabase → Notion")
    parser.add_argument("--backfill", nargs="+", metavar="DATE",
                        help="Backfill start [end]. End defaults to today (Pacific).")
    parser.add_argument("--skip-notion", action="store_true")
    parser.add_argument("--lookback-days", type=int, default=DEFAULT_LOOKBACK_DAYS)
    args = parser.parse_args()

    require_env("READWISE_API_TOKEN", "SUPABASE_URL", "SUPABASE_SECRET_KEY", "KANBAN_USER_ID")
    token = os.environ["READWISE_API_TOKEN"]
    supabase_url = os.environ["SUPABASE_URL"].rstrip("/")
    secret_key = os.environ["SUPABASE_SECRET_KEY"]
    user_id = os.environ["KANBAN_USER_ID"]

    notion_database_id = os.getenv("NOTION_DATABASE_ID") or os.getenv("NOTION_JOURNAL_DB_ID")
    notion_token = os.getenv("NOTION_TOKEN")

    today = datetime.now(pytz.UTC).astimezone(PACIFIC).date()
    if args.backfill:
        start = parse_ymd(args.backfill[0])
        end = parse_ymd(args.backfill[1]) if len(args.backfill) > 1 else today
    else:
        end = today
        start = today - timedelta(days=args.lookback_days - 1)
    if start > end:
        raise SystemExit("start date must be <= end date")

    print(f"\n=== Readwise → Supabase: {start} to {end} ===")
    highlights = fetch_highlights(token, start, end)
    print(f"  {len(highlights)} highlights")

    book_ids = {h["book_id"] for h in highlights if h.get("book_id")}
    print(f"  {len(book_ids)} distinct sources — fetching metadata")
    books = fetch_books(token, book_ids)

    rows = build_rows(highlights, books, user_id)
    print(f"Upserted {upsert_readwise_daily(supabase_url, secret_key, rows)} readwise_daily rows")

    week_start = start - timedelta(days=start.weekday())
    week_end = end - timedelta(days=end.weekday())
    weeks = fetch_readwise_weekly(supabase_url, secret_key, user_id, week_start, week_end)
    print(f"readwise_weekly weeks in range: {len(weeks)}")

    if not args.skip_notion:
        if not notion_database_id or not notion_token:
            print("⚠ NOTION_DATABASE_ID/TOKEN missing — skipping Notion sync")
        else:
            print("Syncing Notion from readwise_weekly…")
            print(f"Updated {sync_notion_from_weekly(weeks, notion_database_id, notion_token)} Notion week pages")

    print("\nSample weeks:")
    for week in weeks[-4:]:
        print(f"  {week.get('week_start')}: highlights={week.get('highlights')} "
              f"articles={week.get('distinct_articles')} "
              f"pods+vids={week.get('distinct_podcasts_videos')} "
              f"books={week.get('distinct_books')}")
    print("\n✓ Complete")


if __name__ == "__main__":
    main()
