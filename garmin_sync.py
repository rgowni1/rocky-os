#!/usr/bin/env python3
"""garmin-sync — Garmin Connect -> Supabase -> Notion -> iMessage, deterministically.

This replaces the agentic (`claude -p`) version of steps 1-4 and 6. It drives the
same `garmin` MCP server over stdio, using the same OAuth tokens in ~/.garmin-mcp/,
and writes the same SQL. No model in the loop, no Anthropic API dependency.

    python3 sync.py                 # full run
    python3 sync.py --dry-run       # fetch + report, write nothing, send nothing
    python3 sync.py --no-notify     # run normally but skip the iMessage
    python3 sync.py --days 30       # widen the backfill window (default 14)
    python3 sync.py --no-samples    # skip per-second session samples

Field mappings were verified against live data on 2026-10-27: 11/11 days and 13/13
activities matched the previous browser-based pipeline on every column.

Exit codes: 0 ok, 1 failure (details on stderr and in the log), 2 no network.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import select
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
# Local-Mac defaults, all overridable so the same file runs unchanged in CI.
ENV_PATH = os.environ.get("GARMIN_ENV_FILE", os.path.expanduser("~/workspace/kanban/.env"))
MCP_SERVER = os.environ.get(
    "GARMIN_MCP_SERVER",
    os.path.join(HERE, "vendor", "garmin-mcp", "index.js")
    if os.path.exists(os.path.join(HERE, "vendor", "garmin-mcp", "index.js"))
    else os.path.expanduser("~/garmin-connect-mcp/dist/index.js"))
TOKEN_DIR = os.environ.get("GARMIN_MCP_TOKEN_DIR", os.path.expanduser("~/.garmin-mcp"))
IMESSAGE_TO = os.environ.get("GARMIN_IMESSAGE_TO", "+16465057208")
# Per-MCP-call ceiling. A Garmin call hung ~30min on 2026-11-01 right after
# a maintenance wake; the whole run should take ~12s.
RPC_TIMEOUT_S = 45.0
# A same-day wellness reading before this clock time means the watch stopped
# syncing mid-day; at or after it the day is treated as finished. Tied to the
# 22:30 nightly run — raise both together if the schedule moves earlier.
PARTIAL_CUTOFF = "22:00:00.0"

# Wellness columns: never write 0 when the source is null (the watch may simply
# not have synced). Activity-derived zeros are legitimate.
WELLNESS_COLS = [
    "total_kilocalories", "total_steps", "moderate_intensity_minutes",
    "vigorous_intensity_minutes", "avg_stress_level", "weight_lbs", "body_fat_pct",
]

DAILY_COLS = [
    "calendar_date", "total_kilocalories", "total_steps",
    "moderate_intensity_minutes", "vigorous_intensity_minutes",
    "avg_stress_level", "high_stress_seconds", "medium_stress_seconds",
    "low_stress_seconds", "weight_lbs", "body_fat_pct",
    "includes_wellness_data", "wellness_end_time_local", "is_partial",
    # Overnight HRV. Garmin computes no per-activity HRV — get_activity_details
    # exposes no hrv/rmssd/rrInterval channel — so the sleep-window figure is
    # the only HRV that exists.
    "hrv_last_night_avg", "hrv_last_night_5min_high", "hrv_weekly_avg",
    "hrv_status", "hrv_baseline_low_upper", "hrv_baseline_balanced_low",
    "hrv_baseline_balanced_upper",
]

SAMPLE_COLS = [
    "activity_id", "offset_seconds", "timestamp_gmt", "heart_rate",
    "respiration_rate", "stress", "body_battery",
]
# Which detail channels we keep, by descriptor KEY. The numeric metricsIndex is
# NOT stable across activities (directHeartRate was index 2 on one session and
# would be elsewhere on another), so always resolve by key.
SAMPLE_CHANNELS = {
    "sumDuration": "offset_seconds",
    "directTimestamp": "timestamp_gmt",
    "directHeartRate": "heart_rate",
    "directRespirationRate": "respiration_rate",
    "directCurrentStress": "stress",
    "directBodyBattery": "body_battery",
}
# intensity_minutes and adjusted_kilocalories are GENERATED — never insert them.

ACTIVITY_COLS = [
    "activity_id", "activity_name", "activity_type", "start_time_local",
    "duration_seconds", "distance_meters", "calories", "avg_hr", "max_hr",
    "avg_respiration_rate", "min_respiration_rate", "max_respiration_rate",
    "start_stress", "end_stress", "avg_stress", "max_stress", "stress_change",
]

MEDITATION_TYPES = {"meditation", "mindfulness", "breathwork"}


def log(msg: str) -> None:
    print(f"[{dt.datetime.now():%H:%M:%S}] {msg}", flush=True)


# --------------------------------------------------------------------------- env


REQUIRED_ENV = ("SUPABASE_URL", "SUPABASE_SECRET_KEY", "SUPABASE_ACCESS_TOKEN",
                "NOTION_TOKEN", "NOTION_JOURNAL_DB_ID")


def load_env() -> None:
    """Read the local .env if present; in CI the values are already exported."""
    if not os.path.exists(ENV_PATH):
        missing = [k for k in REQUIRED_ENV if not os.environ.get(k)]
        if missing:
            die(f"no env file at {ENV_PATH} and these are unset: {', '.join(missing)}")
        return
    for line in open(ENV_PATH):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())


def die(msg: str) -> "NoReturn":  # type: ignore[valid-type]
    print(f"FATAL: {msg}", file=sys.stderr, flush=True)
    raise SystemExit(1)


# ----------------------------------------------------------------------- network


def wait_for_network(timeout_s: int = 900) -> bool:
    """launchd fires this job on maintenance wakes when the network may not be up
    yet. On 2026-10-28 and -29 that killed both runs. Wait rather than fail."""
    deadline = time.time() + timeout_s
    attempt = 0
    while time.time() < deadline:
        attempt += 1
        try:
            socket.create_connection(("connectapi.garmin.com", 443), timeout=10).close()
            socket.create_connection(("api.supabase.com", 443), timeout=10).close()
            # A TCP handshake is not enough: on 2026-11-01 connect() succeeded while
            # real requests still hung. Require an actual HTTPS round-trip.
            urllib.request.urlopen("https://connectapi.garmin.com/", timeout=15).close()
            if attempt > 1:
                log(f"network up after {attempt} attempts")
            return True
        except urllib.error.HTTPError:
            # Any HTTP status means the path is live; 404/401 from / is expected.
            if attempt > 1:
                log(f"network up after {attempt} attempts")
            return True
        except (OSError, urllib.error.URLError):
            log(f"network not ready (attempt {attempt}), retrying in 30s")
            time.sleep(30)
    return False


# --------------------------------------------------------------------------- MCP


class MCPClient:
    """Minimal stdio JSON-RPC client. An agent is one kind of MCP client; so is this."""

    def __init__(self, server_js: str):
        env = dict(os.environ, GARMIN_MCP_TOKEN_DIR=TOKEN_DIR)
        self.proc = subprocess.Popen(
            ["node", server_js], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, env=env, text=True, bufsize=1,
        )
        self._id = 0
        self._rpc("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "garmin-sync", "version": "1.0"},
        })
        self._notify("notifications/initialized")

    def _send(self, payload: dict) -> None:
        assert self.proc.stdin
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()

    def _notify(self, method: str) -> None:
        self._send({"jsonrpc": "2.0", "method": method})

    def _rpc(self, method: str, params: dict, timeout: float = RPC_TIMEOUT_S) -> dict:
        self._id += 1
        self._send({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params})
        assert self.proc.stdout
        # A bare readline() blocks forever. On 2026-11-01 a single Garmin call
        # hung right after a maintenance wake and the whole run took 30 minutes
        # instead of 12 seconds. Bound every call.
        deadline = time.time() + timeout
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError(f"{method} timed out after {timeout:.0f}s")
            ready, _, _ = select.select([self.proc.stdout], [], [], min(remaining, 5.0))
            if not ready:
                continue
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("garmin MCP server closed unexpectedly")
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == self._id:
                return msg

    def call(self, tool: str, args: dict, retries: int = 1):
        """Returns None on timeout/transport failure so one bad day doesn't kill
        the run — callers already treat None as 'skip and continue'."""
        for attempt in range(retries + 1):
            try:
                msg = self._rpc("tools/call", {"name": tool, "arguments": args})
                break
            except (TimeoutError, RuntimeError) as e:
                if attempt >= retries:
                    log(f"  ! {tool}({args}) failed: {type(e).__name__}: {e}")
                    return None
                log(f"  ~ {tool} {type(e).__name__}, retrying ({attempt + 1}/{retries})")
        if "error" in msg:
            raise RuntimeError(f"{tool}: {msg['error']}")
        content = msg.get("result", {}).get("content", [])
        if not content:
            return None
        try:
            return json.loads(content[0]["text"])
        except (json.JSONDecodeError, KeyError):
            return None

    def close(self) -> None:
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


# ---------------------------------------------------------------------- Supabase


def run_sql(sql: str) -> list:
    pat = os.environ.get("SUPABASE_ACCESS_TOKEN")
    url = os.environ.get("SUPABASE_URL", "")
    ref = url.replace("https://", "").split(".", 1)[0]
    if not pat or not ref:
        die("SUPABASE_ACCESS_TOKEN / SUPABASE_URL missing from .env")
    req = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{ref}/database/query",
        data=json.dumps({"query": sql}).encode(), method="POST",
        headers={"Authorization": f"Bearer {pat}", "Content-Type": "application/json",
                 "User-Agent": "garmin-sync/1.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"null") or []
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Supabase SQL {e.code}: {e.read().decode('utf-8','replace')[:400]}")


def q(v) -> str:
    """SQL literal. None -> NULL, strings single-quote-escaped."""
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    return "'" + str(v).replace("'", "''") + "'"


# ------------------------------------------------------------------------ fetch


def fetch(mcp: MCPClient, days: list[str]) -> tuple[list[dict], list[dict]]:
    start, end = days[0], days[-1]

    # Weight: dailyWeightSummaries[], NOT the old dateWeightList[].
    weigh = mcp.call("get_weigh_ins", {"startDate": start, "endDate": end}) or {}
    by_date: dict[str, dict] = {}
    for s in weigh.get("dailyWeightSummaries", []):
        lw = s.get("latestWeight") or {}
        grams = lw.get("weight")
        by_date[s.get("summaryDate")] = {
            "weight_lbs": round(grams / 1000 * 2.20462, 2) if grams is not None else None,
            "body_fat_pct": lw.get("bodyFat"),
        }

    daily = []
    for date in days:
        o = mcp.call("get_daily_summary", {"date": date})
        if not o:
            log(f"  ! daily summary failed for {date} (continuing)")
            continue
        wet = o.get("wellnessEndTimeLocal")
        w = by_date.get(date, {})
        row = {
            "calendar_date": date,
            "total_kilocalories": o.get("totalKilocalories"),
            "total_steps": o.get("totalSteps"),
            "moderate_intensity_minutes": o.get("moderateIntensityMinutes"),
            "vigorous_intensity_minutes": o.get("vigorousIntensityMinutes"),
            # These four used to need a separate stats/stress/daily range call that
            # 400'd past ~28 days. get_daily_summary carries them; verified identical.
            "avg_stress_level": o.get("averageStressLevel"),
            "high_stress_seconds": o.get("highStressDuration"),
            "medium_stress_seconds": o.get("mediumStressDuration"),
            "low_stress_seconds": o.get("lowStressDuration"),
            "weight_lbs": w.get("weight_lbs"),
            "body_fat_pct": w.get("body_fat_pct"),
            "includes_wellness_data": o.get("includesWellnessData"),
            "wellness_end_time_local": wet,
            # Partial = watch synced only part of the day. A full day reports
            # T00:00:00.0 of the NEXT date; a partial reports a real clock time.
            # This is the only thing that catches a plausible-looking undercount
            # sitting above the 1500-cal outage floor.
            #
            # Cutoff is 22:00, not 23:00: the nightly run is at 22:30 and the
            # watch is normally off by then, so a same-day reading around 22:0x
            # is a finished day rather than a sync failure. Completed days are
            # unaffected either way — they report next-day midnight, which beats
            # any same-day cutoff. Tomorrow's run backfills the true total for
            # any BMR Garmin adds after the watch came off.
            "is_partial": bool(o.get("includesWellnessData")) and wet is not None
                          and wet < f"{date}T{PARTIAL_CUTOFF}",
        }

        # Overnight HRV. Separate endpoint — the daily summary doesn't carry it.
        hrv = mcp.call("get_hrv", {"date": date}) or {}
        hs = hrv.get("hrvSummary") or {}
        base = hs.get("baseline") or {}
        row.update({
            "hrv_last_night_avg": hs.get("lastNightAvg"),
            "hrv_last_night_5min_high": hs.get("lastNight5MinHigh"),
            "hrv_weekly_avg": hs.get("weeklyAvg"),
            "hrv_status": hs.get("status"),
            "hrv_baseline_low_upper": base.get("lowUpper"),
            "hrv_baseline_balanced_low": base.get("balancedLow"),
            "hrv_baseline_balanced_upper": base.get("balancedUpper"),
        })

        if all(row[c] is None for c in WELLNESS_COLS):
            log(f"  - {date}: no data yet (watch not synced), skipping")
            continue
        daily.append(row)

    acts_raw = mcp.call("get_activities_by_date", {"startDate": start, "endDate": end}) or []
    acts = []
    for a in acts_raw:
        def rz(key):  # a respiration value of 0 means "not measured"
            v = a.get(key)
            return None if not v else v
        acts.append({
            "activity_id": a.get("activityId"),
            "activity_name": a.get("activityName"),
            "activity_type": (a.get("activityType") or {}).get("typeKey"),
            "start_time_local": a.get("startTimeLocal"),
            "duration_seconds": round(a["duration"], 2) if a.get("duration") is not None else None,
            # distance/calories are ABSENT keys (not null) on meditation/breathwork.
            "distance_meters": round(a["distance"], 2) if a.get("distance") is not None else None,
            "calories": round(a["calories"], 2) if a.get("calories") is not None else None,
            "avg_hr": a.get("averageHR"),
            "max_hr": a.get("maxHR"),
            "avg_respiration_rate": rz("avgRespirationRate"),
            "min_respiration_rate": rz("minRespirationRate"),
            "max_respiration_rate": rz("maxRespirationRate"),
            "start_stress": a.get("startStress"),
            "end_stress": a.get("endStress"),
            "avg_stress": a.get("avgStress"),
            "max_stress": a.get("maxStress"),
            "stress_change": a.get("differenceStress"),
        })
    return daily, acts



def fetch_samples(mcp: MCPClient, acts: list[dict]) -> list[dict]:
    """Per-second channels for meditation/breathwork sessions.

    Only these types: a long ride would add thousands of rows per session for no
    current use. The browser pipeline could never reach this at all — tool output
    truncated at ~1000 chars.
    """
    out = []
    targets = [a for a in acts if a["activity_type"] in MEDITATION_TYPES]
    for a in targets:
        det = mcp.call("get_activity_details", {"activityId": str(a["activity_id"])})
        metrics = (det or {}).get("activityDetailMetrics") or []
        descs = (det or {}).get("metricDescriptors") or []
        # Resolve channels by key — metricsIndex is not stable across activities.
        idx = {d["key"]: d["metricsIndex"] for d in descs
               if d.get("key") in SAMPLE_CHANNELS and d.get("metricsIndex") is not None}
        if "sumDuration" not in idx:
            log(f"  ! {a['activity_id']}: no sumDuration channel, skipping samples")
            continue
        seen = set()
        for m in metrics:
            vals = m.get("metrics") or []

            def pick(key):
                i = idx.get(key)
                return vals[i] if i is not None and i < len(vals) else None

            off = pick("sumDuration")
            if off is None or off in seen:
                continue   # PK is (activity_id, offset_seconds); drop duplicates
            seen.add(off)
            ts = pick("directTimestamp")
            out.append({
                "activity_id": a["activity_id"],
                "offset_seconds": int(off),
                # epoch ms -> timestamptz
                "timestamp_gmt": (dt.datetime.fromtimestamp(ts / 1000, dt.timezone.utc)
                                  .isoformat()) if ts else None,
                "heart_rate": pick("directHeartRate"),
                "respiration_rate": pick("directRespirationRate"),
                # null early in a session: Garmin needs a window before scoring stress
                "stress": pick("directCurrentStress"),
                "body_battery": pick("directBodyBattery"),
            })
        log(f"  {a['activity_type']} {a['activity_id']}: {len(seen)} samples")
    return out


# ------------------------------------------------------------------------ upsert


def upsert_daily(rows: list[dict]) -> None:
    values = ",\n  ".join("(" + ",".join(q(r[c]) for c in DAILY_COLS) + ")" for r in rows)
    run_sql(f"""
insert into public.garmin_daily ({",".join(DAILY_COLS)})
values
  {values}
on conflict (user_id, calendar_date) do update set
 total_kilocalories=excluded.total_kilocalories,total_steps=excluded.total_steps,
 moderate_intensity_minutes=excluded.moderate_intensity_minutes,
 vigorous_intensity_minutes=excluded.vigorous_intensity_minutes,
 avg_stress_level=excluded.avg_stress_level,high_stress_seconds=excluded.high_stress_seconds,
 medium_stress_seconds=excluded.medium_stress_seconds,low_stress_seconds=excluded.low_stress_seconds,
 weight_lbs=coalesce(excluded.weight_lbs, garmin_daily.weight_lbs),
 body_fat_pct=coalesce(excluded.body_fat_pct, garmin_daily.body_fat_pct),
 includes_wellness_data=excluded.includes_wellness_data,
 wellness_end_time_local=excluded.wellness_end_time_local,
 is_partial=excluded.is_partial,
 hrv_last_night_avg=excluded.hrv_last_night_avg,
 hrv_last_night_5min_high=excluded.hrv_last_night_5min_high,
 hrv_weekly_avg=excluded.hrv_weekly_avg,hrv_status=excluded.hrv_status,
 hrv_baseline_low_upper=excluded.hrv_baseline_low_upper,
 hrv_baseline_balanced_low=excluded.hrv_baseline_balanced_low,
 hrv_baseline_balanced_upper=excluded.hrv_baseline_balanced_upper,
 synced_at=now();""")


def upsert_samples(rows: list[dict]) -> None:
    if not rows:
        return
    # Chunked: a 90-minute session would otherwise be one enormous statement.
    for i in range(0, len(rows), 500):
        chunk = rows[i:i + 500]
        values = ",\n  ".join("(" + ",".join(q(r[c]) for c in SAMPLE_COLS) + ")" for r in chunk)
        sets = ",".join(f"{c}=excluded.{c}" for c in SAMPLE_COLS
                        if c not in ("activity_id", "offset_seconds"))
        run_sql(f"""
insert into public.garmin_activity_samples ({",".join(SAMPLE_COLS)})
values
  {values}
on conflict (activity_id, offset_seconds) do update set {sets};""")



def upsert_activities(rows: list[dict]) -> None:
    if not rows:
        return
    values = ",\n  ".join("(" + ",".join(q(r[c]) for c in ACTIVITY_COLS) + ")" for r in rows)
    sets = ",".join(f"{c}=excluded.{c}" for c in ACTIVITY_COLS if c != "activity_id")
    run_sql(f"""
insert into public.garmin_activities ({",".join(ACTIVITY_COLS)})
values
  {values}
on conflict (activity_id) do update set {sets},synced_at=now();""")


# ---------------------------------------------------------------------- summary


def fetch_intake(start: str, end: str) -> dict[str, dict]:
    """Logged calories/protein per eating day.

    Uses the 04:00-03:59 eating day the rest of the system uses (see
    EATING_DAY_START_MIN in sync_journal_to_supabase.py), so a 00:30 snack
    closes the night before rather than opening the next day. Honours
    eaten_at_override for the same reason food_weekly does.
    """
    rows = run_sql(f"""
select ((coalesce(eaten_at_override, eaten_at) at time zone 'America/Los_Angeles')
         - interval '4 hours')::date::text as d,
       round(sum(calories))  as cals,
       round(sum(protein_g)) as protein,
       count(*)              as meals
from public.food_log_entries
where coalesce(eaten_at_override, eaten_at) >= '{start}'::date - 1
  and coalesce(eaten_at_override, eaten_at) <  '{end}'::date + 2
group by 1;""")
    return {r["d"]: r for r in rows}


def pick_comparison_day(daily: list[dict], intake: dict[str, dict], today: str):
    """Most recent day that is complete on BOTH sides.

    Meals are logged the morning after (~29h past midnight, measured over 12
    days), so today's intake does not exist at 22:30 — a today-vs-today
    comparison would read "ate 0". The newest day with a finished burn AND
    logged meals is the only one where in-vs-out means anything.
    """
    for row in reversed(daily):
        d = row["calendar_date"]
        if d == today or row.get("is_partial"):
            continue
        if row.get("total_kilocalories") is None:
            continue
        got = intake.get(d)
        if got and got.get("cals"):
            return row, got
    return None, None


def fmt_num(v, comma=True):
    """Steps get a thousands separator; calories and stress don't (matches the
    original Notion/iMessage convention: "Cals: 2261 | Steps: 11,302")."""
    if v is None:
        return None
    return f"{float(v):,.0f}" if comma else f"{float(v):.0f}"


def compose_summary(day: dict, acts: list[dict], week: dict | None, today: str,
                    cmp_day: dict | None = None, cmp_intake: dict | None = None,
                    cmp_acts: list[dict] | None = None) -> str:
    label = dt.date.fromisoformat(day["calendar_date"]).strftime("%b %-d")
    lines = [f"✅ Garmin synced — {dt.date.fromisoformat(today).strftime('%b %-d')}", ""]
    is_today = day["calendar_date"] == today
    # The 06:10 run fires a few hours into a new day, where "today" is just
    # overnight BMR and a handful of steps. Showing it as a headline reads as
    # a collapse in activity, so skip the block and let the comparison carry
    # the message. 06:00 local is the cut.
    thin_today = (is_today and (day.get("total_steps") or 0) < 1000
                  and (day.get("total_kilocalories") or 0) < 900)
    if not thin_today:
        lines.append(f"📅 {'Today so far' if is_today else 'Yesterday'}")
    else:
        lines.pop()  # drop the blank spacer; the comparison block adds its own

    def activity_lines(rows):
        out = []
        for a in rows or []:
            mins = round((a["duration_seconds"] or 0) / 60)
            name = a["activity_name"] or a["activity_type"]
            if a["activity_type"] in MEDITATION_TYPES:
                extra = []
                if a.get("start_stress") is not None and a.get("end_stress") is not None:
                    extra.append(f"stress {a['start_stress']}→{a['end_stress']}")
                if a.get("avg_respiration_rate") is not None:
                    extra.append(f"{float(a['avg_respiration_rate']):.1f} brpm")
                out.append(f"• {name} {mins}min" + (f" ({', '.join(extra)})" if extra else ""))
            else:
                out.append(f"• {name} {mins}min")
        return out

    if not thin_today:
        bits = []
        for lbl, key, comma in (("Cals", "total_kilocalories", False),
                                ("Steps", "total_steps", True),
                                ("Stress", "avg_stress_level", False)):
            if day.get(key) is not None:
                bits.append(f"{lbl}: {fmt_num(day[key], comma)}")
        if bits:
            lines.append("• " + " | ".join(bits))
        lines += activity_lines(acts) or ["• Rest day"]
        if day.get("weight_lbs") is not None:
            lines.append(f"• Weight: {float(day['weight_lbs']):.1f} lbs")

    # In vs out, for the newest day that is finished on BOTH sides. Meals land
    # in Notion the morning after, so today's intake does not exist at 22:30 —
    # comparing today would always read "ate 0".
    if cmp_day and cmp_intake:
        cdate = cmp_day["calendar_date"]
        clabel = dt.date.fromisoformat(cdate).strftime("%b %-d")
        burned = cmp_day.get("total_kilocalories")
        adj = round(burned * 0.90) if burned is not None else None
        eaten = int(cmp_intake["cals"])
        lines += ["", f"⚖️ {clabel} — final"]
        if adj is not None:
            net = adj - eaten
            word = "deficit" if net > 0 else "surplus"
            lines.append(f"• Burned {adj} adj ({burned} raw) · Ate {eaten} · {abs(net)} {word}")
        else:
            lines.append(f"• Ate {eaten} · burn not recorded")
        if cmp_intake.get("protein") is not None:
            lines.append(f"• Protein {int(cmp_intake['protein'])}g"
                         f" · {int(cmp_intake['meals'])} meals")
        extra = activity_lines(cmp_acts)
        if extra and cdate != day["calendar_date"]:
            lines += extra

    # Stale-watch / partial-day warnings.
    if day["calendar_date"] != today:
        gap = (dt.date.fromisoformat(today) - dt.date.fromisoformat(day["calendar_date"])).days
        if gap >= 1:
            lines += ["", f"⚠️ No wellness data since {label} — sync your watch"]
    elif day.get("is_partial") and not thin_today:
        # Only worth saying when today is actually on screen. The 06:10 run
        # suppresses that block, and "today is partial" at 6am is noise.
        wet = (day.get("wellness_end_time_local") or "")[11:16]
        lines += ["", f"⚠️ Watch last synced {wet} — today is partial, excluded from averages"]

    if week:
        lines += ["", "📊 Week to date (Mon–Sun)"]
        wk = []
        if week.get("training_hours") is not None:
            wk.append(f"Training: {float(week['training_hours']):.2f}h")
        if week.get("strength_minutes"):
            wk.append(f"Strength: {fmt_num(week['strength_minutes'], False)}min")
        if week.get("meditation_sessions"):
            wk.append(f"Meditation: {week['meditation_sessions']}x")
        if wk:
            lines.append("• " + " | ".join(wk))

        av = []
        if week.get("garmin_tdee") is not None:
            av.append(f"Avg TDEE: {fmt_num(week['garmin_tdee'], False)}")
        if week.get("stress_level") is not None:
            av.append(f"Avg Stress: {fmt_num(week['stress_level'], False)}")
        if week.get("step_count") is not None:
            av.append(f"Steps: {fmt_num(week['step_count'])}")
        if av:
            lines.append("• " + " | ".join(av))

        for key, lbl, nd in (("swim_yards", "Swim", 0), ("run_miles", "Run", 2),
                             ("bike_miles", "Bike", 2)):
            v = week.get(key)
            if v and float(v) > 0:
                unit = "yd" if key == "swim_yards" else "mi"
                lines.append(f"• {lbl}: {float(v):.{nd}f}{unit}")

        if week.get("partial_days"):
            lines.append(f"• ({week['partial_days']} partial day(s) excluded from TDEE/steps)")
        full = week.get("full_days")
        if full is not None and int(full) == 0:
            lines.append("• ⚠️ no complete days yet this week — averages pending")
        elif full is not None and int(full) == 1:
            lines.append("• ⚠️ averages rest on a single full day")

    return "\n".join(lines)


def send_imessage(text: str) -> bool:
    if sys.platform != "darwin":
        log("  not macOS — summary is in the log above, no iMessage")
        return False
    if not os.path.exists(os.path.join(HERE, "imessage.sh")):
        log("  imessage.sh not present — summary is in the log above")
        return False
    try:
        subprocess.run([os.path.join(HERE, "imessage.sh"), IMESSAGE_TO],
                       input=text, text=True, check=True, timeout=120,
                       capture_output=True)
        return True
    except Exception as e:
        # Messages.app cannot be driven on a locked screen (AppleEvent -1712).
        # Never let a failed *notification* masquerade as a failed *sync*.
        log(f"  ! iMessage failed ({type(e).__name__}) — summary preserved in log")
        return False


# --------------------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-notify", action="store_true")
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--skip-notion", action="store_true")
    ap.add_argument("--no-samples", action="store_true",
                    help="skip per-second meditation/breathwork session samples")
    args = ap.parse_args()

    load_env()

    if not wait_for_network():
        print("FATAL: no network after 15 minutes", file=sys.stderr)
        return 2

    # Dates computed locally — never derived by a model, and never via a
    # toLocaleString/toISOString round-trip (that shifted the window a day on 10-27).
    today = dt.date.today()
    days = [(today - dt.timedelta(days=k)).isoformat() for k in range(args.days - 1, -1, -1)]
    monday = (today - dt.timedelta(days=today.weekday())).isoformat()
    log(f"window {days[0]} .. {days[-1]}  week_monday={monday}  dry_run={args.dry_run}")

    mcp = MCPClient(MCP_SERVER)
    try:
        daily, acts = fetch(mcp, days)
        samples = [] if args.no_samples else fetch_samples(mcp, acts)
    finally:
        mcp.close()
    log(f"fetched {len(daily)} daily rows, {len(acts)} activities, "
        f"{len(samples)} session samples")
    if not daily:
        print("FATAL: no daily rows returned — refusing to continue", file=sys.stderr)
        return 1

    if args.dry_run:
        for r in daily:
            flag = " (partial)" if r["is_partial"] else ""
            hrv = f", hrv {r['hrv_last_night_avg']}" if r.get("hrv_last_night_avg") else ""
            log(f"  would upsert {r['calendar_date']}: {r['total_kilocalories']} cal, "
                f"{r['total_steps']} steps{hrv}{flag}")
        log(f"  would upsert {len(acts)} activities, {len(samples)} session samples")
    else:
        upsert_daily(daily)
        upsert_activities(acts)
        # Must follow activities: samples FK to garmin_activities(activity_id).
        upsert_samples(samples)
        log(f"upserted {len(daily)} daily rows + {len(acts)} activities "
            f"+ {len(samples)} session samples")

    # Step 5 — Notion (REST API; the Notion MCP server does not exist headlessly).
    if not args.skip_notion:
        notion_script = os.path.join(HERE, "garmin_notion_update.py")
        if not os.path.exists(notion_script):
            notion_script = os.path.join(HERE, "notion_week_update.py")
        cmd = ["python3", notion_script, monday]
        if args.dry_run:
            cmd.append("--dry-run")
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        for ln in (r.stdout or "").splitlines():
            log(f"  notion: {ln}")
        if r.returncode == 2:
            log("  notion: no page for this week yet — skipped (never creates one)")
        elif r.returncode != 0:
            log(f"  ! notion update failed: {(r.stderr or '').strip()[:200]}")

    # Step 6 — summary.
    week_rows = run_sql(f"select * from public.garmin_weekly where week_start = '{monday}';")
    week = week_rows[0] if week_rows else None
    latest = daily[-1]
    latest_acts = [a for a in acts if (a["start_time_local"] or "")[:10] == latest["calendar_date"]]
    intake = fetch_intake(days[0], days[-1])
    cmp_day, cmp_intake = pick_comparison_day(daily, intake, today.isoformat())
    if cmp_day:
        log(f"comparison day: {cmp_day['calendar_date']} "
            f"({cmp_day['total_kilocalories']} burned vs {int(cmp_intake['cals'])} eaten)")
    else:
        log("no day complete on both sides yet — comparison omitted")
    cmp_acts = ([a for a in acts
                 if (a["start_time_local"] or "")[:10] == cmp_day["calendar_date"]]
                if cmp_day else [])
    summary = compose_summary(latest, latest_acts, week, today.isoformat(),
                              cmp_day, cmp_intake, cmp_acts)

    print("\n----- summary -----\n" + summary + "\n-------------------\n", flush=True)
    if args.dry_run or args.no_notify:
        log("notification skipped")
    else:
        send_imessage(summary)

    log("done")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as exc:  # loud, not silent
        print(f"FATAL: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(1)
