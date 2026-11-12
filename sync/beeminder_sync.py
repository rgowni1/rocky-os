"""
Beeminder Sync — Push Notion weekly tracking data to Beeminder goals.

Reads the specified week's data from the Notion "Log" database and posts
datapoints to the corresponding Beeminder goals. Uses requestid-based
deduplication so re-runs safely update rather than duplicate.

Week is parameterized: "this" (week ending this Sunday) or "previous"
(week ending last Sunday). The Beeminder daystamp is always the Sunday
(end of week) for that period.
"""

import argparse
import os
from datetime import date, timedelta
from typing import Optional

import requests

try:
    from dotenv import load_dotenv
    load_dotenv(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env"))
except ImportError:
    pass  # dotenv not needed in CI where env vars are set directly

# Configuration
NOTION_TOKEN = os.getenv("NOTION_TOKEN")
NOTION_DATABASE_ID = os.getenv("NOTION_DATABASE_ID")
BEEMINDER_USERNAME = os.getenv("BEEMINDER_USERNAME")
BEEMINDER_AUTH_TOKEN = os.getenv("BEEMINDER_AUTH_TOKEN")

# Map of Notion column -> Beeminder goal slug
SYNC_GOALS = {
    "Strength Minutes": "strengthmins",
}


def get_sunday_for_week(week: str, reference: Optional[date] = None) -> date:
    """
    Return the Sunday (end of week) for 'this' or 'previous' week.
    reference: date to use as "today" (default: today).
    """
    ref = reference or date.today()
    # This week's Sunday: the upcoming or current Sunday (weekday() Mon=0, Sun=6)
    days_until_sunday = (6 - ref.weekday()) % 7
    this_sunday = ref + timedelta(days=days_until_sunday)
    if week == "this":
        return this_sunday
    if week == "previous":
        return this_sunday - timedelta(days=7)
    raise ValueError(f"week must be 'this' or 'previous', got {week!r}")


def get_notion_entry_for_week(sunday: date):
    """
    Query the Notion Log database for the entry whose "Week of Journal"
    falls in the week ending on the given Sunday.
    Returns a dict with the page's name, tracked values, and the Sunday
    (used as Beeminder daystamp). Raises if no matching record.
    """
    monday = sunday - timedelta(days=6)
    monday_str = monday.isoformat()
    sunday_str = sunday.isoformat()

    url = f"https://api.notion.com/v1/databases/{NOTION_DATABASE_ID}/query"
    headers = {
        "Authorization": f"Bearer {NOTION_TOKEN}",
        "Notion-Version": "2022-06-28",
        "Content-Type": "application/json",
    }
    payload = {
        "filter": {
            "and": [
                {"property": "Week of Journal", "date": {"on_or_after": monday_str}},
                {"property": "Week of Journal", "date": {"on_or_before": sunday_str}},
            ]
        },
        "sorts": [{"timestamp": "created_time", "direction": "descending"}],
        "page_size": 1,
    }

    resp = requests.post(url, headers=headers, json=payload)
    resp.raise_for_status()
    data = resp.json()
    results = data.get("results", [])

    if not results:
        raise SystemExit(
            f"No Notion record found for week ending {sunday_str} "
            f"(Week of Journal between {monday_str} and {sunday_str})."
        )

    page = results[0]
    props = page["properties"]

    values = {}
    for notion_col in SYNC_GOALS:
        num_prop = props.get(notion_col, {})
        if num_prop.get("number") is not None:
            values[notion_col] = num_prop["number"]
        else:
            values[notion_col] = None

    page_name = ""
    title_prop = props.get("Name", {})
    if title_prop.get("title"):
        page_name = title_prop["title"][0]["plain_text"]

    return {
        "daystamp": sunday_str,
        "name": page_name,
        "values": values,
    }


def post_to_beeminder(goal_slug, value, daystamp, comment=""):
    """
    Create or update a Beeminder datapoint.
    Uses the create_all endpoint with requestid for idempotent upserts —
    if the requestid already exists with a different value, it updates it.
    If the value is identical, it's silently ignored (no error).
    """
    url = f"https://www.beeminder.com/api/v1/users/{BEEMINDER_USERNAME}/goals/{goal_slug}/datapoints/create_all.json"
    request_id = f"notion-{goal_slug}-{daystamp}"

    payload = {
        "auth_token": BEEMINDER_AUTH_TOKEN,
        "datapoints": [
            {
                "value": value,
                "daystamp": daystamp.replace("-", ""),  # YYYYMMDD format
                "comment": comment,
                "requestid": request_id,
            }
        ],
    }

    resp = requests.post(url, json=payload)
    resp.raise_for_status()
    result = resp.json()
    # create_all returns a list of datapoints
    return result[0] if isinstance(result, list) and result else result


def main():
    parser = argparse.ArgumentParser(
        description="Sync Notion Log weekly data to Beeminder. Week is the one ending on Sunday."
    )
    parser.add_argument(
        "week",
        nargs="?",
        default="this",
        choices=("this", "previous"),
        help="'this' = week ending this Sunday (default), 'previous' = week ending last Sunday",
    )
    args = parser.parse_args()

    sunday = get_sunday_for_week(args.week)
    daystamp_str = sunday.isoformat()

    print("🔄 Beeminder Sync — Notion → Beeminder")
    print("=" * 45)
    print(f"\n📅 Week: {args.week!r} → Sunday {daystamp_str}")

    entry = get_notion_entry_for_week(sunday)
    print(f"   Notion entry: {entry['name']}")

    for notion_col, goal_slug in SYNC_GOALS.items():
        value = entry["values"].get(notion_col)
        if value is None:
            print(f"  ⏭  {notion_col}: no value, skipping")
            continue

        print(f"\n  📊 {notion_col}: {value}")
        print(f"     → Beeminder goal: {goal_slug} (daystamp: {daystamp_str})")

        result = post_to_beeminder(
            goal_slug=goal_slug,
            value=value,
            daystamp=daystamp_str,
            comment=f"Auto-synced from Notion ({entry['name']})",
        )
        dp_id = result.get("id") if isinstance(result, dict) else None
        if dp_id:
            print(f"     ✅ Created/updated! Datapoint ID: {dp_id}")
        else:
            print(f"     ✅ Already up to date (no change needed)")

    print("\n🎉 Sync complete!")


if __name__ == "__main__":
    main()
