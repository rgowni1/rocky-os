#!/usr/bin/env python3
"""Oura → Supabase (source of truth), then Notion / consumers from Supabase.

Daily sleep rows land in public.oura_daily. Weekly averages live in the
oura_weekly view. weekly_master joins that view for readers; Notion Logging
Journal sleep fields are pushed from it. Nothing is copied into weekly_metrics.

Usage:
    python oura.py                          # last 14 days, then Notion for those weeks
    python oura.py --backfill 2026-01-01    # through today
    python oura.py --backfill 2026-01-01 2026-10-05
    python oura.py --skip-notion            # Supabase only
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date, datetime, timedelta
from urllib import error as urlerror
from urllib import parse as urlparse
from urllib import request as urlrequest

import pandas as pd
import pytz
import requests
from dotenv import load_dotenv

load_dotenv()

PACIFIC = pytz.timezone("America/Los_Angeles")
NOTION_VERSION = "2022-06-28"
DEFAULT_LOOKBACK_DAYS = 14
CHUNK_DAYS = 30
MIN_SLEEP_HOURS = 3


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
            payload = response.read()
            return response.status, json.loads(payload or b"null")
    except urlerror.HTTPError as exc:
        try:
            payload = json.loads(exc.read() or b"{}")
        except Exception:
            payload = {"error": str(exc)}
        return exc.code, payload


def parse_ymd(value: str) -> date:
    return datetime.strptime(value, "%Y-%m-%d").date()


# ── Oura ─────────────────────────────────────────────────────────────────────

class OuraClient:
    def __init__(self, access_token):
        self.base_url = "https://api.ouraring.com/v2"
        self.headers = {"Authorization": f"Bearer {access_token}"}

    def _paged(self, path, start_date, end_date):
        url = f"{self.base_url}{path}"
        params = {"start_date": start_date, "end_date": end_date}
        rows = []
        while True:
            response = requests.get(url, headers=self.headers, params=params, timeout=60)
            response.raise_for_status()
            payload = response.json()
            rows.extend(payload.get("data") or [])
            next_token = payload.get("next_token")
            if not next_token:
                break
            params = {"next_token": next_token}
        return rows

    def get_sleep_data(self, start_date, end_date):
        return self._paged("/usercollection/daily_sleep", start_date, end_date)

    def get_sleep_detail_data(self, start_date, end_date):
        return self._paged("/usercollection/sleep", start_date, end_date)


def _mins_after_midnight(dt: datetime, *, sleep_wrap: bool) -> int:
    mins = dt.hour * 60 + dt.minute
    if sleep_wrap and dt.hour < 6:
        mins += 1440
    return mins


def _fmt_hhmm(dt: datetime) -> str:
    return f"{dt.hour:02d}:{dt.minute:02d}"


def collect_oura_sleep_rows(access_token, start_date: str, end_date: str) -> list[dict]:
    """Fetch Oura sleep for [start_date, end_date] and return one row per day."""
    client = OuraClient(access_token)
    # Detail endpoint is exclusive of wake-ups after midnight on end_date.
    end_plus = (parse_ymd(end_date) + timedelta(days=1)).strftime("%Y-%m-%d")

    detail = pd.DataFrame(client.get_sleep_detail_data(start_date, end_plus))
    daily = pd.DataFrame(client.get_sleep_data(start_date, end_date))
    if detail.empty:
        return []

    detail_fields = [
        "id", "day", "latency", "average_hrv", "total_sleep_duration",
        "lowest_heart_rate", "average_breath", "bedtime_start", "bedtime_end",
    ]
    available = [f for f in detail_fields if f in detail.columns]
    detail = detail[available].copy()

    if not daily.empty and "score" in daily.columns:
        scores = daily[["day", "score"]].rename(columns={"score": "sleep_score"})
        merged = detail.merge(scores, on="day", how="outer")
    else:
        merged = detail
        merged["sleep_score"] = None

    if "total_sleep_duration" in merged.columns:
        merged["total_sleep_hours"] = (merged["total_sleep_duration"] / 3600).round(2)
    else:
        merged["total_sleep_hours"] = None

    if "latency" in merged.columns:
        merged["latency_minutes"] = (merged["latency"] / 60).round(2)
    else:
        merged["latency_minutes"] = None

    # Prefer the longest session when a day has multiple sleeps.
    merged = merged.sort_values(
        by=["day", "total_sleep_hours"],
        ascending=[True, False],
        na_position="last",
    )
    filtered = merged[merged["total_sleep_hours"].fillna(0) >= MIN_SLEEP_HOURS]
    if filtered.empty:
        return []

    rows = []
    for day, group in filtered.groupby("day", sort=True):
        primary = group.iloc[0]
        sleep_time = wake_time = None
        sleep_mins = wake_mins = None
        bedtime_start = bedtime_end = None

        if pd.notna(primary.get("bedtime_start")) and pd.notna(primary.get("bedtime_end")):
            start_dt = pd.to_datetime(primary["bedtime_start"], utc=True).tz_convert(PACIFIC)
            end_dt = pd.to_datetime(primary["bedtime_end"], utc=True).tz_convert(PACIFIC)
            bedtime_start = start_dt.isoformat()
            bedtime_end = end_dt.isoformat()

            onset = start_dt
            if pd.notna(primary.get("latency_minutes")):
                onset = start_dt + timedelta(minutes=float(primary["latency_minutes"]))

            sleep_time = _fmt_hhmm(onset.to_pydatetime())
            wake_time = _fmt_hhmm(end_dt.to_pydatetime())
            sleep_mins = _mins_after_midnight(onset.to_pydatetime(), sleep_wrap=True)
            wake_mins = _mins_after_midnight(end_dt.to_pydatetime(), sleep_wrap=False)

        def num(key):
            val = primary.get(key)
            if val is None or (isinstance(val, float) and pd.isna(val)):
                return None
            return float(val)

        row = {
            "calendar_date": str(day),
            "sleep_score": num("sleep_score"),
            "total_sleep_hours": num("total_sleep_hours"),
            "average_hrv": num("average_hrv"),
            "lowest_heart_rate": num("lowest_heart_rate"),
            "average_breath": num("average_breath"),
            "latency_minutes": num("latency_minutes"),
            "sleep_time": sleep_time,
            "wake_time": wake_time,
            "sleep_time_mins": sleep_mins,
            "wake_time_mins": wake_mins,
            "bedtime_start": bedtime_start,
            "bedtime_end": bedtime_end,
            "oura_sleep_id": primary.get("id") if pd.notna(primary.get("id")) else None,
            "raw": {
                "day": str(day),
                "sleep_score": num("sleep_score"),
                "total_sleep_hours": num("total_sleep_hours"),
                "average_hrv": num("average_hrv"),
                "lowest_heart_rate": num("lowest_heart_rate"),
                "average_breath": num("average_breath"),
                "latency_minutes": num("latency_minutes"),
                "bedtime_start": bedtime_start,
                "bedtime_end": bedtime_end,
                "session_count": int(len(group)),
            },
        }
        rows.append(row)
    return rows


def collect_oura_range(access_token, start: date, end: date) -> list[dict]:
    """Pull Oura in CHUNK_DAYS windows to stay under API limits."""
    all_rows = []
    cursor = start
    while cursor <= end:
        chunk_end = min(cursor + timedelta(days=CHUNK_DAYS - 1), end)
        print(f"  Oura fetch {cursor} → {chunk_end}")
        all_rows.extend(
            collect_oura_sleep_rows(
                access_token,
                cursor.strftime("%Y-%m-%d"),
                chunk_end.strftime("%Y-%m-%d"),
            )
        )
        cursor = chunk_end + timedelta(days=1)
    # De-dupe by calendar_date (later chunk wins)
    by_day = {r["calendar_date"]: r for r in all_rows}
    return [by_day[k] for k in sorted(by_day)]


# ── Supabase ─────────────────────────────────────────────────────────────────

def upsert_oura_daily(supabase_url, secret_key, user_id, rows: list[dict]) -> int:
    if not rows:
        return 0
    synced_at = datetime.now(pytz.UTC).isoformat()
    payload = []
    for row in rows:
        payload.append({
            "user_id": user_id,
            "synced_at": synced_at,
            **row,
        })

    headers = {
        "apikey": secret_key,
        "Authorization": f"Bearer {secret_key}",
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates,return=minimal",
    }
    endpoint = (
        f"{supabase_url}/rest/v1/oura_daily?"
        + urlparse.urlencode({"on_conflict": "user_id,calendar_date"})
    )
    synced = 0
    for i in range(0, len(payload), 250):
        chunk = payload[i:i + 250]
        status, body = http(endpoint, method="POST", headers=headers, body=chunk)
        if status >= 400:
            raise SystemExit(f"Supabase oura_daily upsert error {status}: {body}")
        synced += len(chunk)
    return synced


def fetch_oura_weekly(supabase_url, secret_key, user_id, week_start: date, week_end: date) -> list[dict]:
    headers = {
        "apikey": secret_key,
        "Authorization": f"Bearer {secret_key}",
    }
    # Both gte and lte on week_start — build query string manually.
    qs = (
        f"user_id=eq.{user_id}"
        f"&week_start=gte.{week_start.isoformat()}"
        f"&week_start=lte.{week_end.isoformat()}"
        f"&order=week_start.asc"
        f"&select=*"
    )
    status, body = http(f"{supabase_url}/rest/v1/oura_weekly?{qs}", headers=headers)
    if status >= 400:
        raise SystemExit(f"Supabase oura_weekly read error {status}: {body}")
    return body or []


# ── Notion (consumer of Supabase) ────────────────────────────────────────────

def notion_headers(token):
    return {
        "Authorization": f"Bearer {token}",
        "Notion-Version": NOTION_VERSION,
        "Content-Type": "application/json",
    }


def find_notion_page_for_week(database_id, token, week_start: date):
    """Find Logging Journal page whose Week of Journal == week_start (Monday)."""
    url = f"https://api.notion.com/v1/databases/{database_id}/query"
    body = {
        "filter": {
            "property": "Week of Journal",
            "date": {"equals": week_start.isoformat()},
        },
        "page_size": 1,
    }
    response = requests.post(url, headers=notion_headers(token), json=body, timeout=60)
    response.raise_for_status()
    results = response.json().get("results") or []
    return results[0]["id"] if results else None


def update_notion_page(page_id, notion_token, properties):
    url = f"https://api.notion.com/v1/pages/{page_id}"
    response = requests.patch(
        url, headers=notion_headers(notion_token), json={"properties": properties}, timeout=60
    )
    if response.status_code != 200:
        print(f"  ✗ Notion API error {response.status_code}: {response.text[:500]}")
    response.raise_for_status()
    return response.json()


def sync_notion_sleep_from_weekly(weeks: list[dict], database_id, token) -> int:
    updated = 0
    for week in weeks:
        week_start = week["week_start"]
        if isinstance(week_start, str):
            week_date = parse_ymd(week_start[:10])
        else:
            week_date = week_start

        page_id = find_notion_page_for_week(database_id, token, week_date)
        if not page_id:
            print(f"  ⚠ No Notion page for week {week_date}")
            continue

        properties = {}
        mapping = {
            "slp_hrs": ("Slp Hrs", "number"),
            "slp_score": ("Slp Score", "number"),
            "slp_hrv": ("Slp HRV", "number"),
            "rhr": ("RHR", "number"),
            "breath_rate": ("Breath Rate", "number"),
            "slp_latency": ("Slp Latency", "number"),
            "avg_sleep_time": ("Avg Sleep Time", "text"),
            "avg_wake_time": ("Avg Wake Time", "text"),
        }
        for key, (notion_name, kind) in mapping.items():
            val = week.get(key)
            if val is None:
                continue
            if kind == "number":
                properties[notion_name] = {"number": float(val)}
            else:
                properties[notion_name] = {"rich_text": [{"text": {"content": str(val)}}]}

        if not properties:
            continue
        print(f"  Notion week {week_date}: {list(properties.keys())}")
        update_notion_page(page_id, token, properties)
        updated += 1
    return updated


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Oura → Supabase → Notion")
    parser.add_argument(
        "--backfill",
        nargs="+",
        metavar="DATE",
        help="Backfill start [end]. End defaults to today (Pacific).",
    )
    parser.add_argument("--skip-notion", action="store_true", help="Skip Notion consumer sync")
    parser.add_argument(
        "--lookback-days",
        type=int,
        default=DEFAULT_LOOKBACK_DAYS,
        help=f"Days to re-sync when not backfilling (default {DEFAULT_LOOKBACK_DAYS})",
    )
    args = parser.parse_args()

    require_env("OURA_ACCESS_TOKEN", "SUPABASE_URL", "SUPABASE_SECRET_KEY", "KANBAN_USER_ID")
    oura_token = os.environ["OURA_ACCESS_TOKEN"]
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

    print(f"\n=== Oura → Supabase: {start} to {end} ===")
    daily_rows = collect_oura_range(oura_token, start, end)
    upserted = upsert_oura_daily(supabase_url, secret_key, user_id, daily_rows)
    print(f"Upserted {upserted} oura_daily rows ({len(daily_rows)} distinct days)")

    # Align weekly window to Mondays covering the daily range.
    week_start = start - timedelta(days=start.weekday())
    week_end = end - timedelta(days=end.weekday())
    weeks = fetch_oura_weekly(supabase_url, secret_key, user_id, week_start, week_end)
    print(f"oura_weekly weeks in range: {len(weeks)}")

    if not args.skip_notion:
        if not notion_database_id or not notion_token:
            print("⚠ NOTION_DATABASE_ID/TOKEN missing — skipping Notion sync")
        else:
            print("Syncing Notion sleep fields from oura_weekly…")
            n = sync_notion_sleep_from_weekly(weeks, notion_database_id, notion_token)
            print(f"Updated {n} Notion week pages")

    print("\nSample weeks:")
    for week in weeks[-4:]:
        print(
            f"  {week.get('week_start')}: "
            f"score={week.get('slp_score')} hrs={week.get('slp_hrs')} "
            f"hrv={week.get('slp_hrv')} rhr={week.get('rhr')} "
            f"sleep={week.get('avg_sleep_time')} wake={week.get('avg_wake_time')} "
            f"nights={week.get('nights')}"
        )
    print("\n✓ Complete")


if __name__ == "__main__":
    main()
