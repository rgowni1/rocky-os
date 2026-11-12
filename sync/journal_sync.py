#!/usr/bin/env python3
"""Notion Logging Journal → Supabase public.journal_entries.

This is the reflections sync. For each weekly journal page it stores:

    journal_raw_text   the page body as indented plain text — the day-by-day
                       bullets and the end-of-week Claude notes
    journal_high / journal_low / journal_bud
                       generated from that text with Claude

Nothing numeric is read here. Every weekly number on the Notion page has its
own source — sleep (oura_daily), reading (readwise_daily), training/body/stress
(garmin_daily), food (food_log_entries), phone pickups (screentime_weekly) —
that rolls up into weekly_master and is pushed *out* to Notion. Reading them
back off the page would close a Supabase → Notion → Supabase loop.

A week is only re-summarised when its raw text changes (journal_summary_of
holds the md5 of the text the summaries came from), so re-runs are cheap and
history is not rewritten. Weeks summarised before this existed carry the
Notion High / Low properties and are adopted as-is until they are edited.

Without ANTHROPIC_API_KEY the raw text still syncs; summaries wait for a run
that has the key.

Usage:
    python journal_sync.py                 # last 4 weeks (catches late edits)
    python journal_sync.py --weeks 12
    python journal_sync.py --all           # every week in the database
    python journal_sync.py --regenerate    # re-summarise even unchanged weeks
    python journal_sync.py --dry-run       # fetch and map, write nothing
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from datetime import date, datetime, timedelta, timezone
from urllib import error as urlerror
from urllib import parse as urlparse
from urllib import request as urlrequest

from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env"))

NOTION_VERSION = "2022-06-28"
DEFAULT_LOOKBACK_WEEKS = 4
# Notion allows ~3 requests/second; a page body is one request per nested block.
NOTION_REQUEST_GAP_S = 0.34

MODEL = "claude-opus-5-5"

# Block types whose text is not the journal: the synced quarterly-goals block
# is identical on every page, and the rest carry no prose.
SKIPPED_BLOCK_TYPES = {
    "synced_block", "child_page", "child_database", "link_to_page",
    "divider", "table_of_contents", "breadcrumb", "column_list",
    "image", "video", "file", "pdf", "embed", "bookmark", "equation",
}

# Template scaffolding. A block whose whole text is one of these is dropped
# unless something was written beneath it, so an untouched "Wed" disappears
# while "Tue" with a bullet under it stays as context.
TEMPLATE_LABELS = {
    "journalling", "journaling", "reflect - high, low and goals",
    "highs/energizers", "lows/stressors", "bud", "food journal",
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
    "-", "",
}


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
    except (urlerror.URLError, TimeoutError, OSError) as exc:
        # Status 0 = never got a response (timeout, reset); callers may retry.
        return 0, {"error": str(exc)}


def notion_headers(token):
    return {
        "Authorization": f"Bearer {token}",
        "Notion-Version": NOTION_VERSION,
        "Content-Type": "application/json",
    }


# ── Notion pages ─────────────────────────────────────────────────────────────

def fetch_pages(token, database_id, since: date | None):
    """Journal pages with a Week of Journal date, oldest first."""
    pages = []
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
            method="POST", headers=notion_headers(token), body=body,
        )
        if status >= 400:
            raise SystemExit(f"Notion query error {status}: {payload}")

        for page in payload.get("results") or []:
            week = (((page.get("properties") or {}).get("Week of Journal") or {}).get("date") or {}).get("start")
            # A page with no "Week of Journal" has no key to upsert on.
            if week:
                pages.append({
                    "id": page["id"],
                    "week": week,
                    "last_edited_time": page.get("last_edited_time"),
                })

        if not payload.get("has_more"):
            return pages
        cursor = payload.get("next_cursor")


def fetch_children(token, block_id):
    blocks = []
    cursor = None
    failures = 0
    while True:
        query = {"page_size": 100}
        if cursor:
            query["start_cursor"] = cursor
        time.sleep(NOTION_REQUEST_GAP_S)
        status, payload = http(
            f"https://api.notion.com/v1/blocks/{block_id}/children?{urlparse.urlencode(query)}",
            headers=notion_headers(token),
        )
        if status == 429:
            time.sleep(float((payload or {}).get("retry_after") or 2))
            continue
        # A full --all backfill is a few thousand requests; one dropped
        # connection should not throw the whole run away.
        if (status == 0 or status >= 500) and failures < 4:
            failures += 1
            time.sleep(2 ** failures)
            continue
        if status == 0 or status >= 400:
            raise SystemExit(f"Notion blocks error {status} on {block_id}: {payload}")
        blocks.extend(payload.get("results") or [])
        if not payload.get("has_more"):
            return blocks
        cursor = payload.get("next_cursor")


def block_lines(token, blocks, depth=0):
    """Render blocks as indented text, pruning untouched template labels."""
    lines = []
    for block in blocks:
        kind = block.get("type")
        if kind in SKIPPED_BLOCK_TYPES:
            continue
        content = block.get(kind) or {}
        text = "".join(part.get("plain_text", "") for part in content.get("rich_text") or []).strip()
        if kind == "to_do" and text:
            text = f"[{'x' if content.get('checked') else ' '}] {text}"

        children = block_lines(token, fetch_children(token, block["id"]), depth + 1) if block.get("has_children") else []
        if text.lower() in TEMPLATE_LABELS and not children:
            continue

        indent = "  " * depth
        if kind.startswith("heading_"):
            lines.append(f"{indent}{'#' * int(kind[-1])} {text}")
        elif kind in ("bulleted_list_item", "numbered_list_item", "to_do", "toggle"):
            lines.append(f"{indent}- {text}")
        elif text:
            lines.append(f"{indent}{text}")
        lines.extend(children)
    return lines


def page_raw_text(token, page_id):
    text = "\n".join(block_lines(token, fetch_children(token, page_id))).strip()
    return text or None


def dedupe_by_week(rows):
    """One row per week — the upsert targets (user_id, week).

    Keeps the page with the most raw text, then the freshest edit, then the
    page id so runs are reproducible. Deliberately not by title: dozens of
    real weeks are still titled "Weekly Template".
    """
    def rank(row):
        return (len(row["journal_raw_text"] or ""), row["source_updated_at"] or "", row["notion_page_id"])

    best = {}
    for row in rows:
        current = best.get(row["week"])
        if current is None or rank(row) > rank(current):
            best[row["week"]] = row
    dropped = len(rows) - len(best)
    if dropped:
        print(f"  Collapsed {dropped} duplicate-week page(s), keeping the fullest each")
    return [best[week] for week in sorted(best)]


# ── Summaries ────────────────────────────────────────────────────────────────

SUMMARY_SYSTEM = """You turn one week of someone's personal journal into three short fields for their weekly log.

- high: the week's energizers — the moments, wins or people that gave energy.
- low: the week's stressors — what drained, went wrong or caused friction.
- bud: something emerging that is worth building on — a new idea, habit, \
insight or relationship that is starting to grow.

Style: one sentence each, at most ~40 words, concrete and specific (name the \
day, person or activity when the notes do). Write in a clipped past-tense \
log voice without "I" or "the author", like:
  high: "Good session Thursday with strong reps, motivating conversations Friday fueling product drive."
  low: "Very bad idea to go to San Jose without a car, wasting three hours on Tuesday trying to get back."

Use only what the notes say. If the notes give nothing for a field, return an \
empty string for it rather than inventing one."""

SUMMARY_SCHEMA = {
    "type": "object",
    "properties": {
        "high": {"type": "string"},
        "low": {"type": "string"},
        "bud": {"type": "string"},
    },
    "required": ["high", "low", "bud"],
    "additionalProperties": False,
}


def make_client():
    if not os.getenv("ANTHROPIC_API_KEY"):
        print("  ANTHROPIC_API_KEY not set — syncing raw text only; summaries wait for a keyed run")
        return None
    try:
        import anthropic
    except ImportError:
        print("  anthropic>=1.0 not installed (needs Python 3.10+) — syncing raw text only")
        return None
    return anthropic.Anthropic()


def summarize(client, week, raw_text):
    """{journal_high, journal_low, journal_bud}, or None if Claude declined."""
    response = client.beta.messages.create(
        model=MODEL,
        max_tokens=16000,
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",
        output_config={
            "effort": "low",
            "format": {"type": "json_schema", "schema": SUMMARY_SCHEMA},
        },
        system=SUMMARY_SYSTEM,
        messages=[{
            "role": "user",
            "content": f"Journal for the week of {week}:\n\n<journal>\n{raw_text}\n</journal>",
        }],
    )
    if response.stop_reason in ("refusal", "max_tokens"):
        print(f"  ⚠ {week}: summary stopped ({response.stop_reason}); keeping previous values")
        return None
    text = next((b.text for b in response.content if b.type == "text"), "")
    fields = json.loads(text)
    return {f"journal_{k}": (fields.get(k) or "").strip() or None for k in ("high", "low", "bud")}


def text_hash(text):
    return hashlib.md5(text.encode()).hexdigest()


# ── Supabase ─────────────────────────────────────────────────────────────────

def supabase_headers(secret_key):
    return {"apikey": secret_key, "Authorization": f"Bearer {secret_key}"}


def fetch_existing(supabase_url, secret_key, user_id, weeks):
    """Current summaries per week, so unchanged weeks are not re-summarised."""
    if not weeks:
        return {}
    qs = urlparse.urlencode({
        "select": "week,journal_raw_text,journal_high,journal_low,journal_bud,journal_summary_of",
        "user_id": f"eq.{user_id}",
        "week": f"in.({','.join(weeks)})",
    })
    status, body = http(f"{supabase_url}/rest/v1/journal_entries?{qs}", headers=supabase_headers(secret_key))
    if status >= 400:
        raise SystemExit(f"Supabase journal_entries read error {status}: {body}")
    return {row["week"]: row for row in body}


def upsert(supabase_url, secret_key, rows) -> int:
    if not rows:
        return 0
    headers = {
        **supabase_headers(secret_key),
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
    parser.add_argument("--regenerate", action="store_true", help="Re-summarise even unchanged weeks")
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

    pages = fetch_pages(token, database_id, since)
    print(f"Fetched {len(pages)} journal pages; reading page bodies…")
    synced_at = datetime.now(timezone.utc).isoformat()
    rows = dedupe_by_week([
        {
            "user_id": user_id,
            "week": page["week"],
            "notion_page_id": page["id"],
            "source_updated_at": page["last_edited_time"],
            "synced_at": synced_at,
            "journal_raw_text": page_raw_text(token, page["id"]),
        }
        for page in pages
    ])
    print(f"  {sum(1 for r in rows if r['journal_raw_text'])} of {len(rows)} weeks have journal text")

    existing = fetch_existing(supabase_url, secret_key, user_id, [r["week"] for r in rows])
    client = make_client()

    generated = adopted = pending = 0
    for row in rows:
        prev = existing.get(row["week"]) or {}
        row["journal_high"] = prev.get("journal_high")
        row["journal_low"] = prev.get("journal_low")
        row["journal_bud"] = prev.get("journal_bud")
        row["journal_summary_of"] = prev.get("journal_summary_of")

        raw = row["journal_raw_text"]
        if not raw:
            continue
        target = text_hash(raw)

        # Summaries that predate this sync (the Notion High / Low properties)
        # are taken as describing the text as it stands now.
        if row["journal_summary_of"] is None and (row["journal_high"] or row["journal_low"]) and not args.regenerate:
            row["journal_summary_of"] = target
            adopted += 1
            continue

        if row["journal_summary_of"] == target and not args.regenerate:
            continue
        if client is None or args.dry_run:
            pending += 1
            continue

        summary = summarize(client, row["week"], raw)
        if summary:
            row.update(summary)
            row["journal_summary_of"] = target
            generated += 1

    print(f"  Summaries: {generated} generated, {adopted} adopted from Notion, {pending} pending")

    if args.dry_run:
        print("\n--dry-run, writing nothing. Latest week's raw text:")
        latest = next((r for r in reversed(rows) if r["journal_raw_text"]), None)
        print(latest["journal_raw_text"][:1200] if latest else "  (none)")
        return

    print(f"Upserted {upsert(supabase_url, secret_key, rows)} journal_entries rows")
    for row in rows[-3:]:
        print(f"  {row['week']}: high={'yes' if row['journal_high'] else '—'} "
              f"low={'yes' if row['journal_low'] else '—'} bud={'yes' if row['journal_bud'] else '—'} "
              f"raw={len(row['journal_raw_text'] or '')} chars")

    print("\n✓ Complete")


if __name__ == "__main__":
    main()
