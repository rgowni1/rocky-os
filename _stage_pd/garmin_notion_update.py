#!/usr/bin/env python3
"""Push one week's garmin_weekly rollup from Supabase into the Notion Log page.

Usage:
    python3 notion_week_update.py 2026-10-19          # that week
    python3 notion_week_update.py 2026-10-19 --dry-run

Works headlessly: uses the Notion REST API with NOTION_TOKEN (not the Notion MCP
server, which is only available inside an interactive claude.ai session).

Exit codes: 0 ok, 1 error, 2 no matching Notion page.
"""
import json
import os
import sys
import urllib.error
import urllib.request

ENV_PATH = os.environ.get("GARMIN_ENV_FILE", os.path.expanduser("~/workspace/kanban/.env"))
LOG_DB_ENV = "NOTION_JOURNAL_DB_ID"
DATE_PROP = "Week of Journal"

# garmin_weekly column -> Notion property. Wellness metrics are skipped when null
# (never write 0 for a metric that simply has no data); activity-derived zeros are real.
WELLNESS = {
    "garmin_tdee": "Garmin TDEE",
    "adjusted_tdee": "Adjusted TDEE",
    "step_count": "Step Count",
    "intensity_minutes": "Intensity Minutes",
    "stress_level": "Stress Level",
    "weekly_weight": "Weekly Weight",
    "body_fat_pct": "Body Fat %",
}
ACTIVITY = {
    "training_hours": "Logged Training Hrs",
    "strength_minutes": "Strength Minutes",
    "swim_yards": "Swim Yards",
    "run_miles": "Run Miles",
    "bike_miles": "Bike Miles",
    "meditation_sessions": "Meditation Sessions",
}


def load_env():
    """Local .env if present; in CI the values are already exported."""
    if not os.path.exists(ENV_PATH):
        need = ("SUPABASE_URL", "SUPABASE_SECRET_KEY", "NOTION_TOKEN", LOG_DB_ENV)
        missing = [k for k in need if not os.environ.get(k)]
        if missing:
            sys.exit(f"no env file at {ENV_PATH} and unset: {', '.join(missing)}")
        return
    for line in open(ENV_PATH):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())


def req(url, token, method="GET", body=None, extra=None):
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    if extra:
        headers.update(extra)
    r = urllib.request.Request(
        url, method=method, data=json.dumps(body).encode() if body is not None else None, headers=headers
    )
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {url} -> HTTP {e.code}: {e.read().decode()[:400]}")


def supabase_week(week_start):
    url = os.environ["SUPABASE_URL"].rstrip("/")
    key = os.environ["SUPABASE_SECRET_KEY"]
    rows = req(
        f"{url}/rest/v1/garmin_weekly?select=*&week_start=eq.{week_start}",
        key,
        extra={"apikey": key},
    )
    if not rows:
        sys.exit(f"no garmin_weekly row for week_start={week_start}")
    return rows[0]


def notion_page(week_start, token, db):
    res = req(
        f"https://api.notion.com/v1/databases/{db}/query",
        token,
        "POST",
        {"filter": {"property": DATE_PROP, "date": {"equals": week_start}}, "page_size": 5},
        extra={"Notion-Version": "2022-06-28"},
    )
    results = res.get("results", [])
    if not results:
        print(f"no Notion page with {DATE_PROP} = {week_start} (NEVER create one)", file=sys.stderr)
        sys.exit(2)
    page = results[0]
    title = ""
    for v in page["properties"].values():
        if v["type"] == "title":
            title = "".join(x.get("plain_text", "") for x in v["title"])
    return page["id"], title


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    if len(args) != 1:
        sys.exit(__doc__)
    week_start = args[0]

    load_env()
    token, db = os.environ["NOTION_TOKEN"], os.environ[LOG_DB_ENV]

    row = supabase_week(week_start)
    page_id, title = notion_page(week_start, token, db)

    props, skipped = {}, []
    for col, prop in WELLNESS.items():
        val = row.get(col)
        if val is None:
            skipped.append(prop)
        else:
            props[prop] = {"number": float(val)}
    for col, prop in ACTIVITY.items():
        val = row.get(col)
        props[prop] = {"number": float(val) if val is not None else 0}

    print(f"week {week_start} -> \"{title}\" ({page_id})")
    print(f"  full_days={row.get('full_days')} partial_days={row.get('partial_days')}")
    for p, v in sorted(props.items()):
        print(f"  {p:22} = {v['number']}")
    if skipped:
        print(f"  skipped (null, not written as 0): {', '.join(skipped)}")

    if dry:
        print("  [dry-run] nothing written")
        return

    req(
        f"https://api.notion.com/v1/pages/{page_id}",
        token,
        "PATCH",
        {"properties": props},
        extra={"Notion-Version": "2022-06-28"},
    )
    print(f"  ✅ wrote {len(props)} properties")


if __name__ == "__main__":
    main()
