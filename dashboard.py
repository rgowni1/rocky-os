#!/usr/bin/env python3
"""
Personal Dashboard — Monthly view with quarterly journal word clouds.
Fetches from Notion Log database, generates a self-contained HTML file.

Usage:
    python dashboard.py [--year 2026] [--output dashboard.html]
"""

import argparse
import base64
import io
import os
from collections import defaultdict
from datetime import date
from html import escape

import requests

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

try:
    from wordcloud import WordCloud, STOPWORDS
    import matplotlib
    matplotlib.use("Agg")
    HAS_WORDCLOUD = True
except ImportError:
    HAS_WORDCLOUD = False

NOTION_TOKEN = os.getenv("NOTION_TOKEN")
NOTION_DATABASE_ID = os.getenv("NOTION_DATABASE_ID")

MONTH_NAMES = [
    "", "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
]

# Extra stopwords for journal text
JOURNAL_STOPWORDS = {
    "week", "weekly", "also", "the", "and", "was", "were", "with", "this",
    "that", "there", "their", "they", "have", "has", "had", "for", "from",
    "been", "but", "not", "are", "will", "would", "could", "should", "one",
    "including", "while", "during", "both", "it", "its", "as", "led", "due",
    "felt", "feeling", "although", "despite", "however", "towards", "upon",
    "particularly", "specifically", "overall", "throughout", "significant",
    "highlighted", "highlighting", "contributing", "contributed", "noted",
    "week's", "positive", "negative", "included", "including", "remains",
    "which", "when", "where", "who", "what", "how", "she", "he", "we",
    "them", "those", "these", "such", "more", "some", "any", "all", "been",
    "into", "out", "over", "under", "again", "further", "then", "once",
    "here", "just", "too", "very", "still", "first", "last", "new", "old",
    "whether", "within", "without", "time", "times", "day", "days",
    "good", "great", "well", "little", "much", "many", "like",
}


# ---------------------------------------------------------------------------
# Notion data fetching
# ---------------------------------------------------------------------------

def fetch_all_log_entries():
    """Fetch all pages from the Notion Log database (paginated)."""
    url = f"https://api.notion.com/v1/databases/{NOTION_DATABASE_ID}/query"
    headers = {
        "Authorization": f"Bearer {NOTION_TOKEN}",
        "Notion-Version": "2022-06-28",
        "Content-Type": "application/json",
    }
    entries, cursor = [], None
    while True:
        payload = {
            "sorts": [{"property": "Week of Journal", "direction": "descending"}],
            "page_size": 100,
        }
        if cursor:
            payload["start_cursor"] = cursor
        resp = requests.post(url, headers=headers, json=payload)
        resp.raise_for_status()
        data = resp.json()
        entries.extend(data["results"])
        if not data.get("has_more"):
            break
        cursor = data["next_cursor"]
    return entries


def _prop(page, name):
    """Extract a property value from a Notion page dict."""
    p = page.get("properties", {}).get(name, {})
    t = p.get("type")
    if t == "number":
        return p.get("number")
    if t == "date":
        return (p.get("date") or {}).get("start")
    if t == "rich_text":
        rt = p.get("rich_text", [])
        return rt[0]["plain_text"] if rt else None
    if t == "title":
        rt = p.get("title", [])
        return rt[0]["plain_text"] if rt else None
    if t == "formula":
        f = p.get("formula", {})
        ft = f.get("type")
        return f.get("number") if ft == "number" else f.get("string")
    return None


def parse_entries(raw):
    """Convert raw Notion pages to clean dicts with typed fields."""
    parsed = []
    for page in raw:
        week_start_str = _prop(page, "Week of Journal")
        if not week_start_str:
            continue
        try:
            week_start = date.fromisoformat(week_start_str[:10])
        except ValueError:
            continue

        phone_daily = _prop(page, "Phone Pick Ups")
        phone_total = _prop(page, "Total Ph Pick Ups")

        # Daily avg: prefer Phone Pick Ups (already per-day), else derive from total
        if phone_daily is not None:
            daily_avg = phone_daily
        elif phone_total is not None:
            daily_avg = phone_total / 7
        else:
            daily_avg = None

        parsed.append({
            "week_start": week_start,
            "name": _prop(page, "Name"),
            # Sleep
            "slp_hrs": _prop(page, "Slp Hrs"),
            "slp_score": _prop(page, "Slp Score"),
            "slp_hrv": _prop(page, "Slp HRV"),
            "rhr": _prop(page, "RHR"),
            "slp_latency": _prop(page, "Slp Latency"),
            "avg_sleep_time": _prop(page, "Avg Sleep Time"),
            "avg_wake_time": _prop(page, "Avg Wake Time"),
            "breath_rate": _prop(page, "Breath Rate"),
            # Phone
            "phone_daily_avg": daily_avg,
            # Fitness
            "step_count": _prop(page, "Step Count"),
            "strength_mins": _prop(page, "Strength Minutes"),
            "run_miles": _prop(page, "Run Miles"),
            "bike_miles": _prop(page, "Bike Miles"),
            "swim_yards": _prop(page, "Swim Yards"),
            "meditation": _prop(page, "Meditation Sessions"),
            "deep_work": _prop(page, "Deep Work Check"),
            # Body
            "weight": _prop(page, "Weekly Weight"),
            "body_fat": _prop(page, "Body Fat %"),
            # Reading
            "highlights": _prop(page, "Highlights"),
            "articles": _prop(page, "Articles"),
            "podcasts_videos": _prop(page, "Podcasts & Videos"),
            # Journal
            "high": _prop(page, "High"),
            "low": _prop(page, "Low"),
        })
    return parsed


# ---------------------------------------------------------------------------
# Aggregation helpers
# ---------------------------------------------------------------------------

def _avg(vals):
    vs = [v for v in vals if v is not None]
    return round(sum(vs) / len(vs), 1) if vs else None


def _total(vals):
    vs = [v for v in vals if v is not None]
    return int(sum(vs)) if vs else None


def group_by_month(entries):
    buckets = defaultdict(list)
    for e in entries:
        key = (e["week_start"].year, e["week_start"].month)
        buckets[key].append(e)
    return dict(sorted(buckets.items(), reverse=True))


def group_by_quarter(entries):
    buckets = defaultdict(lambda: {"highs": [], "lows": []})
    for e in entries:
        y = e["week_start"].year
        q = (e["week_start"].month - 1) // 3 + 1
        key = (y, q)
        if e.get("high"):
            buckets[key]["highs"].append(e["high"])
        if e.get("low"):
            buckets[key]["lows"].append(e["low"])
    return {k: buckets[k] for k in sorted(buckets.keys(), reverse=True)}


def monthly_stats(entries):
    return {
        "slp_hrs": _avg([e["slp_hrs"] for e in entries]),
        "slp_score": _avg([e["slp_score"] for e in entries]),
        "slp_hrv": _avg([e["slp_hrv"] for e in entries]),
        "rhr": _avg([e["rhr"] for e in entries]),
        "phone_daily": _avg([e["phone_daily_avg"] for e in entries]),
        "steps": _avg([e["step_count"] for e in entries]),
        "strength_mins": _total([e["strength_mins"] for e in entries]),
        "run_miles": _avg([e["run_miles"] for e in entries]),
        "bike_miles": _avg([e["bike_miles"] for e in entries]),
        "meditation": _avg([e["meditation"] for e in entries]),
        "deep_work": _avg([e["deep_work"] for e in entries]),
        "weight": _avg([e["weight"] for e in entries]),
        "body_fat": _avg([e["body_fat"] for e in entries]),
        "highlights": _total([e["highlights"] for e in entries]),
        "articles": _total([e["articles"] for e in entries]),
        "podcasts_videos": _total([e["podcasts_videos"] for e in entries]),
        "num_weeks": len(entries),
    }


# ---------------------------------------------------------------------------
# Word cloud generation
# ---------------------------------------------------------------------------

def make_wordcloud_b64(texts, colormap, bg="#111827"):
    if not HAS_WORDCLOUD or not texts:
        return None
    combined = " ".join(t for t in texts if t)
    if len(combined.split()) < 5:
        return None
    sw = STOPWORDS | JOURNAL_STOPWORDS
    wc = WordCloud(
        width=640, height=300,
        background_color=bg,
        colormap=colormap,
        stopwords=sw,
        max_words=80,
        prefer_horizontal=0.85,
        min_font_size=10,
        max_font_size=72,
    ).generate(combined)
    buf = io.BytesIO()
    wc.to_image().save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


# ---------------------------------------------------------------------------
# HTML generation
# ---------------------------------------------------------------------------

def _metric(label, value, unit="", color="#64b5f6"):
    if value is None:
        disp = "—"
    elif isinstance(value, float) and value == int(value):
        disp = str(int(value))
    else:
        disp = str(value)
    return (
        f'<div class="mc">'
        f'<div class="ml">{escape(label)}</div>'
        f'<div class="mv" style="color:{color}">{disp}'
        f'<span class="mu">{escape(unit)}</span></div>'
        f'</div>'
    )


CSS = """
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
  padding:28px;max-width:1080px;margin:0 auto}
h1{font-size:1.8rem;font-weight:700;color:#e6edf3;margin-bottom:8px}
.subtitle{color:#6e7681;font-size:.9rem;margin-bottom:36px}
.section-title{font-size:.7rem;text-transform:uppercase;letter-spacing:2px;color:#444d56;
  margin:28px 0 8px;padding-left:4px}
.month-block{background:#161b22;border:1px solid #21262d;border-radius:12px;
  padding:24px;margin-bottom:28px}
.month-name{font-size:1.3rem;font-weight:700;color:#e6edf3;margin-bottom:4px}
.week-tag{font-size:.78rem;color:#6e7681;font-weight:400;margin-left:8px}
.row{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:4px}
.mc{background:#0d1117;border:1px solid #21262d;border-radius:8px;
  padding:14px 18px;min-width:120px}
.ml{font-size:.68rem;text-transform:uppercase;letter-spacing:.5px;color:#6e7681;margin-bottom:5px}
.mv{font-size:1.5rem;font-weight:700;line-height:1}
.mu{font-size:.72rem;font-weight:400;color:#6e7681;margin-left:2px}
.journal-wrap{margin-top:48px}
.q-block{background:#161b22;border:1px solid #21262d;border-radius:12px;
  padding:24px;margin-bottom:24px}
.q-title{font-size:1.1rem;font-weight:700;color:#e6edf3;margin-bottom:16px}
.wc-pair{display:flex;gap:20px;flex-wrap:wrap}
.wc-col{flex:1;min-width:260px}
.wc-label{font-size:.72rem;text-transform:uppercase;letter-spacing:1px;margin-bottom:8px;font-weight:600}
.wc-pos{color:#56d364}
.wc-neg{color:#f85149}
.wc-img{width:100%;border-radius:8px;display:block}
.no-data{color:#444d56;font-size:.85rem;padding:12px 0}
hr.divider{border:none;border-top:1px solid #21262d;margin:36px 0}
"""


def build_html(year, months_data, quarters_data):
    all_years = sorted({y for y, _ in months_data.keys()}, reverse=True)
    generated = date.today().isoformat()

    # Monthly sections
    month_blocks = []
    for (y, m), entries in months_data.items():
        if y != year:
            continue
        s = monthly_stats(entries)
        block = f"""
<div class="month-block">
  <div class="month-name">{MONTH_NAMES[m]}<span class="week-tag">{s['num_weeks']} weeks</span></div>

  <div class="section-title">Sleep</div>
  <div class="row">
    {_metric("Sleep Hrs", s['slp_hrs'], "hrs", "#8b949e")}
    {_metric("Sleep Score", s['slp_score'], "", "#8b949e")}
    {_metric("HRV", s['slp_hrv'], "", "#58a6ff")}
    {_metric("RHR", s['rhr'], "bpm", "#58a6ff")}
  </div>

  <div class="section-title">Phone</div>
  <div class="row">
    {_metric("Avg Daily Pickups", round(s['phone_daily']) if s['phone_daily'] else None, "/day", "#f85149")}
  </div>

  <div class="section-title">Fitness</div>
  <div class="row">
    {_metric("Avg Steps", int(s['steps']) if s['steps'] else None, "/day", "#56d364")}
    {_metric("Strength", s['strength_mins'], "mins", "#56d364")}
    {_metric("Run Miles", s['run_miles'], "mi/wk", "#56d364") if s['run_miles'] else ""}
    {_metric("Bike Miles", s['bike_miles'], "mi/wk", "#56d364") if s['bike_miles'] else ""}
    {_metric("Deep Work", s['deep_work'], "days/wk", "#56d364")}
    {_metric("Meditation", s['meditation'], "sess/wk", "#56d364")}
  </div>

  <div class="section-title">Body</div>
  <div class="row">
    {_metric("Weight", s['weight'], "lbs", "#d2a679")}
    {_metric("Body Fat", s['body_fat'], "%", "#d2a679") if s['body_fat'] else ""}
  </div>

  <div class="section-title">Reading</div>
  <div class="row">
    {_metric("Highlights", s['highlights'], "", "#79c0ff")}
    {_metric("Articles", s['articles'], "", "#79c0ff")}
    {_metric("Pods & Videos", s['podcasts_videos'], "", "#79c0ff")}
  </div>
</div>"""
        month_blocks.append(block)

    if not month_blocks:
        month_blocks = ['<p style="color:#444d56;padding:20px 0">No data for this year.</p>']

    # Quarterly journal word clouds
    quarter_blocks = []
    for (y, q), data in quarters_data.items():
        pos_b64 = make_wordcloud_b64(data["highs"], "YlGn")
        neg_b64 = make_wordcloud_b64(data["lows"], "OrRd")

        pos_html = (f'<img src="data:image/png;base64,{pos_b64}" class="wc-img" alt="Highs">'
                    if pos_b64 else '<div class="no-data">Not enough data yet</div>')
        neg_html = (f'<img src="data:image/png;base64,{neg_b64}" class="wc-img" alt="Lows">'
                    if neg_b64 else '<div class="no-data">Not enough data yet</div>')

        n_weeks = len(data["highs"])
        quarter_blocks.append(f"""
<div class="q-block">
  <div class="q-title">{y} &nbsp;Q{q} <span class="week-tag">{n_weeks} weeks</span></div>
  <div class="wc-pair">
    <div class="wc-col">
      <div class="wc-label wc-pos">Highs</div>
      {pos_html}
    </div>
    <div class="wc-col">
      <div class="wc-label wc-neg">Lows</div>
      {neg_html}
    </div>
  </div>
</div>""")

    if not quarter_blocks:
        quarter_blocks = ['<p style="color:#444d56;padding:20px 0">No journal data available.</p>']

    year_links = " ".join(
        f'<a href="dashboard_{y}.html" {"class=active" if y == year else ""}>{y}</a>'
        for y in all_years
    )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Personal Dashboard {year}</title>
<style>{CSS}</style>
</head>
<body>
<h1>Personal Dashboard</h1>
<div class="subtitle">Generated {generated} &nbsp;·&nbsp; {year_links}</div>

<div style="font-size:.75rem;color:#6e7681;margin-bottom:20px">
  Monthly averages from Oura + Notion weekly logs.
  Phone pickups = avg daily pickups across the month's weeks.
</div>

{''.join(month_blocks)}

<hr class="divider">

<div class="journal-wrap">
  <h2 style="font-size:1.1rem;color:#8b949e;text-transform:uppercase;letter-spacing:2px;margin-bottom:20px">
    Journal · Quarterly Word Clouds
  </h2>
  {''.join(quarter_blocks)}
</div>

</body>
</html>"""


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Generate personal dashboard HTML")
    parser.add_argument("--year", type=int, default=date.today().year)
    parser.add_argument("--output", default=None, help="Output file (default: dashboard_<year>.html)")
    args = parser.parse_args()

    if not NOTION_TOKEN or not NOTION_DATABASE_ID:
        raise SystemExit("Missing NOTION_TOKEN or NOTION_DATABASE_ID env vars")

    if not HAS_WORDCLOUD:
        print("Warning: wordcloud/matplotlib not installed — word clouds will be skipped.")
        print("  Run: pip install wordcloud matplotlib")

    output = args.output or f"dashboard_{args.year}.html"

    print("Fetching Notion log entries…")
    raw = fetch_all_log_entries()
    print(f"  {len(raw)} entries fetched")

    entries = parse_entries(raw)
    print(f"  {len(entries)} entries with valid dates")

    months_data = group_by_month(entries)
    quarters_data = group_by_quarter(entries)

    html = build_html(args.year, months_data, quarters_data)
    with open(output, "w") as f:
        f.write(html)
    print(f"Dashboard written → {output}")


if __name__ == "__main__":
    main()
