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
from zoneinfo import ZoneInfo

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
    # All-day respiration. Already present on get_daily_summary, so these cost
    # no extra call. Distinct from the per-second session samples, which cover
    # meditation and breathwork only.
    "resp_waking_avg", "resp_sleep_avg", "resp_lowest", "resp_highest",
    # min_heart_rate is the analog of Oura's lowest_heart_rate, and the one
    # sleep_daily merges on. The sleep payload's own avgHeartRate is a
    # sleep-window MEAN and reads ~8bpm high (2026-08-03: Oura lowest 55,
    # Garmin avgHeartRate 63, Garmin minHeartRate 54) — never substitute it.
    "min_heart_rate", "resting_heart_rate",
]

# Overnight sleep, upserted to garmin_sleep_daily and merged behind Oura by the
# sleep_daily view. Garmin's calendarDate names the morning of waking, matching
# Oura's `day`, so the two tables join directly on calendar_date.
SLEEP_COLS = [
    "calendar_date", "sleep_score", "total_sleep_hours",
    "average_breath", "lowest_breath", "highest_breath",
    "avg_heart_rate", "avg_sleep_stress", "awake_count",
    "deep_sleep_seconds", "light_sleep_seconds", "rem_sleep_seconds",
    "awake_sleep_seconds", "nap_seconds",
    "sleep_time", "wake_time", "sleep_time_mins", "wake_time_mins",
    "bedtime_start", "bedtime_end", "sleep_window_confirmed",
    "garmin_sleep_id", "raw",
]
# Same floor oura_weekly uses, so a short half-worn night can't drag a weekly
# mean down. Garmin reports naps separately in napTimeSeconds, but a 45-minute
# "sleep" (2026-11-07) would otherwise read as a night.
MIN_SLEEP_HOURS = 3

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

PACIFIC = ZoneInfo("America/Los_Angeles")


def log(msg: str) -> None:
    print(f"[{dt.datetime.now():%H:%M:%S}] {msg}", flush=True)


# --------------------------------------------------------------------------- env


REQUIRED_ENV = ("SUPABASE_URL", "SUPABASE_SECRET_KEY",
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
            # The project host, not api.supabase.com — the Management API is no
            # longer on the write path.
            sb_host = os.environ.get("SUPABASE_URL", "").replace("https://", "").strip("/")
            if sb_host:
                socket.create_connection((sb_host, 443), timeout=10).close()
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


def _sb():
    url = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SECRET_KEY")
    if not url or not key:
        die("SUPABASE_URL / SUPABASE_SECRET_KEY missing")
    return url, key


def rpc(fn: str, rows: list[dict]):
    """Call an upsert function over PostgREST.

    Writes used to go through the Supabase Management API, which needs a
    Personal Access Token. That token expired twice in eight days and each time
    it silently broke the scheduled run. SUPABASE_SECRET_KEY does not expire.
    """
    url, key = _sb()
    body = json.dumps({"rows": rows}).encode()
    req = urllib.request.Request(
        f"{url}/rest/v1/rpc/{fn}", data=body, method="POST",
        headers={"apikey": key, "Authorization": f"Bearer {key}",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.read().decode()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{fn}: HTTP {e.code}: {e.read().decode('utf-8','replace')[:400]}")


def query(path: str) -> list:
    """Read via PostgREST. `path` is everything after /rest/v1/."""
    url, key = _sb()
    req = urllib.request.Request(f"{url}/rest/v1/{path}",
                                 headers={"apikey": key, "Authorization": f"Bearer {key}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"[]")
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"query {path}: HTTP {e.code}: {e.read().decode('utf-8','replace')[:300]}")


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
            "resp_waking_avg": o.get("avgWakingRespirationValue"),
            "resp_sleep_avg": o.get("avgSleepRespirationValue"),
            "resp_lowest": o.get("lowestRespirationValue"),
            "resp_highest": o.get("highestRespirationValue"),
            "min_heart_rate": o.get("minHeartRate"),
            "resting_heart_rate": o.get("restingHeartRate"),
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



def _garmin_wall_clock(ms: int) -> dt.datetime:
    """Garmin's *TimestampLocal fields are epoch-millis already shifted by the
    UTC offset, so reading them AS UTC gives the local wall clock. Verified on
    2026-10-06: GMT 05:49:26 / Local 22:49:26 the previous evening, offset 7h.
    Converting them with a real timezone would double-apply the offset."""
    return dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc).replace(tzinfo=None)


def _mins_after_midnight(when: dt.datetime, *, sleep_wrap: bool) -> int:
    """Minutes after local midnight. Bedtimes before 06:00 are pushed to +1440
    so a week mixing 23:40 and 00:20 averages to midnight rather than noon.
    Mirrors oura.py exactly — the two feed the same weekly average."""
    mins = when.hour * 60 + when.minute
    if sleep_wrap and when.hour < 6:
        mins += 1440
    return mins


def fetch_sleep(mcp: MCPClient, days: list[str]) -> list[dict]:
    """Overnight sleep per day. One call per date — get_sleep_data takes no
    range. Days the watch wasn't worn return a DTO full of nulls, which is the
    common case here (Oura is the primary sleep device); those are skipped so
    the table holds only real nights."""
    rows = []
    for date in days:
        r = mcp.call("get_sleep_data", {"date": date})
        dto = (r or {}).get("dailySleepDTO") or {}
        secs = dto.get("sleepTimeSeconds")
        if not secs:
            continue
        hours = round(secs / 3600, 2)
        if hours < MIN_SLEEP_HOURS:
            log(f"  - {date}: garmin sleep {hours}h below {MIN_SLEEP_HOURS}h floor, skipping")
            continue

        sleep_time = wake_time = None
        sleep_mins = wake_mins = None
        bedtime_start = bedtime_end = None
        s_local, e_local = dto.get("sleepStartTimestampLocal"), dto.get("sleepEndTimestampLocal")
        s_gmt, e_gmt = dto.get("sleepStartTimestampGMT"), dto.get("sleepEndTimestampGMT")
        if s_local and e_local:
            start, end = _garmin_wall_clock(s_local), _garmin_wall_clock(e_local)
            sleep_time = f"{start.hour:02d}:{start.minute:02d}"
            wake_time = f"{end.hour:02d}:{end.minute:02d}"
            # Garmin reports no sleep latency, so its bedtime is the window
            # start where Oura's is onset (start + latency). On the one night
            # both devices recorded, that difference is minutes, not hours.
            sleep_mins = _mins_after_midnight(start, sleep_wrap=True)
            wake_mins = _mins_after_midnight(end, sleep_wrap=False)
        if s_gmt and e_gmt:
            bedtime_start = dt.datetime.fromtimestamp(s_gmt / 1000, dt.timezone.utc).isoformat()
            bedtime_end = dt.datetime.fromtimestamp(e_gmt / 1000, dt.timezone.utc).isoformat()

        scores = dto.get("sleepScores") or {}
        rows.append({
            "calendar_date": date,
            "sleep_score": (scores.get("overall") or {}).get("value"),
            "total_sleep_hours": hours,
            "average_breath": dto.get("averageRespirationValue"),
            "lowest_breath": dto.get("lowestRespirationValue"),
            "highest_breath": dto.get("highestRespirationValue"),
            "avg_heart_rate": dto.get("avgHeartRate"),
            "avg_sleep_stress": dto.get("avgSleepStress"),
            "awake_count": dto.get("awakeCount"),
            "deep_sleep_seconds": dto.get("deepSleepSeconds"),
            "light_sleep_seconds": dto.get("lightSleepSeconds"),
            "rem_sleep_seconds": dto.get("remSleepSeconds"),
            "awake_sleep_seconds": dto.get("awakeSleepSeconds"),
            "nap_seconds": dto.get("napTimeSeconds"),
            "sleep_time": sleep_time,
            "wake_time": wake_time,
            "sleep_time_mins": sleep_mins,
            "wake_time_mins": wake_mins,
            "bedtime_start": bedtime_start,
            "bedtime_end": bedtime_end,
            "sleep_window_confirmed": dto.get("sleepWindowConfirmed"),
            "garmin_sleep_id": str(dto["id"]) if dto.get("id") is not None else None,
            "raw": {
                "day": date,
                "sleep_time_seconds": secs,
                "sleep_scores": scores,
                "sleep_window_confirmation_type": dto.get("sleepWindowConfirmationType"),
                "sleep_from_device": dto.get("sleepFromDevice"),
                "retro": dto.get("retro"),
            },
        })
    return rows


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
    rpc("garmin_upsert_daily", rows)


def upsert_sleep(rows: list[dict]) -> None:
    if rows:
        rpc("garmin_upsert_sleep", rows)



def upsert_activities(rows: list[dict]) -> None:
    if rows:
        rpc("garmin_upsert_activities", rows)


def upsert_samples(rows: list[dict]) -> None:
    # Chunked: a long session would otherwise be one very large request body.
    for i in range(0, len(rows), 500):
        rpc("garmin_upsert_samples", rows[i:i + 500])


# ---------------------------------------------------------------------- summary


def fetch_intake(start: str, end: str) -> dict[str, dict]:
    """Logged calories/protein per eating day.

    Uses the 04:00-03:59 eating day the rest of the system uses (see
    EATING_DAY_START_MIN in sync_journal_to_supabase.py), so a 00:30 snack
    closes the night before rather than opening the next day. Honours
    eaten_at_override for the same reason food_weekly does.
    """
    rows = query(
        "food_log_entries"
        "?select=calories,protein_g,eaten_at,eaten_at_override"
        f"&or=(eaten_at.gte.{start},eaten_at_override.gte.{start})"
        f"&eaten_at=lt.{end}T23:59:59")
    out: dict[str, dict] = {}
    for r in rows:
        raw = r.get("eaten_at_override") or r.get("eaten_at")
        if not raw:
            continue
        ts = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
        local = ts.astimezone(PACIFIC)
        # 04:00-03:59 eating day, matching food_weekly and the widget.
        day = (local - dt.timedelta(hours=4)).date().isoformat()
        acc = out.setdefault(day, {"d": day, "cals": 0, "protein": 0, "meals": 0})
        acc["cals"] += r.get("calories") or 0
        acc["protein"] += r.get("protein_g") or 0
        acc["meals"] += 1
    for v in out.values():
        v["cals"] = round(v["cals"]); v["protein"] = round(v["protein"])
    return out


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
        # Only complain when the watch is genuinely behind, not merely because
        # the day has not ended. Scheduled runs land ~3h earlier than the plist
        # asks for (cause not identified), so any fixed clock threshold flags
        # every evening. Comparing against the actual run time survives that.
        wet = (day.get("wellness_end_time_local") or "")[11:16]
        gap_min = None
        raw = day.get("wellness_end_time_local")
        if raw:
            try:
                ended = dt.datetime.fromisoformat(raw.replace("T", " ")[:19])
                gap_min = (dt.datetime.now(PACIFIC).replace(tzinfo=None) - ended).total_seconds() / 60
            except ValueError:
                pass
        if gap_min is not None and gap_min > 180:
            lines += ["", f"⚠️ Watch last synced {wet}, {gap_min/60:.1f}h ago — sync your watch"]

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
        #
        # Log osascript's own stderr. capture_output swallows it, and without
        # it every cause collapses into the same "CalledProcessError" line:
        # -1712 (screen locked) and -1743 (Automation permission revoked) want
        # opposite fixes, and for eleven days running there was no way to tell
        # which one was happening.
        detail = (getattr(e, "stderr", "") or "").strip().replace("\n", " ")
        log(f"  ! iMessage failed ({type(e).__name__}) — summary preserved in log"
            + (f": {detail[:200]}" if detail else ""))
        return False


# --------------------------------------------------------------------------- main


FAILURE_MARKER = os.path.expanduser("~/.garmin-mcp/last-failure")


def take_pending_failure() -> str | None:
    """Read and clear a failure recorded by an earlier run.

    A failed run cannot reliably tell anyone: at 03:21 the screen is locked and
    Messages refuses to start, which is how 2026-11-06 went unnoticed. run.sh
    writes a marker instead and the next successful run reports it.
    """
    try:
        with open(FAILURE_MARKER) as f:
            note = f.read().strip()
        os.remove(FAILURE_MARKER)
        return note or None
    except OSError:
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-notify", action="store_true")
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--skip-notion", action="store_true")
    ap.add_argument("--no-samples", action="store_true",
                    help="skip per-second meditation/breathwork session samples")
    ap.add_argument("--no-sleep", action="store_true",
                    help="skip overnight sleep (one get_sleep_data call per day)")
    args = ap.parse_args()

    load_env()

    if not wait_for_network():
        print("FATAL: no network after 15 minutes", file=sys.stderr)
        return 2

    # Dates computed locally — never derived by a model, and never via a
    # toLocaleString/toISOString round-trip (that shifted the window a day on 10-27).
    # Pacific, not the host clock. Garmin reports wellnessEndTimeLocal and
    # startTimeLocal in local time, and the GitHub runner is UTC — at 06:08 UTC
    # it read "today" as Nov 4 while Pacific was still Nov 3, shifting the whole
    # window a day and silently dropping a session.
    today = dt.datetime.now(PACIFIC).date()
    days = [(today - dt.timedelta(days=k)).isoformat() for k in range(args.days - 1, -1, -1)]
    monday = (today - dt.timedelta(days=today.weekday())).isoformat()
    log(f"window {days[0]} .. {days[-1]}  week_monday={monday}  dry_run={args.dry_run}")

    mcp = MCPClient(MCP_SERVER)
    try:
        daily, acts = fetch(mcp, days)
        sleep = [] if args.no_sleep else fetch_sleep(mcp, days)
        samples = [] if args.no_samples else fetch_samples(mcp, acts)
    finally:
        mcp.close()
    log(f"fetched {len(daily)} daily rows, {len(sleep)} sleep nights, "
        f"{len(acts)} activities, {len(samples)} session samples")
    if not daily:
        print("FATAL: no daily rows returned — refusing to continue", file=sys.stderr)
        return 1

    if args.dry_run:
        for r in daily:
            flag = " (partial)" if r["is_partial"] else ""
            hrv = f", hrv {r['hrv_last_night_avg']}" if r.get("hrv_last_night_avg") else ""
            log(f"  would upsert {r['calendar_date']}: {r['total_kilocalories']} cal, "
                f"{r['total_steps']} steps{hrv}{flag}")
        for s in sleep:
            log(f"  would upsert sleep {s['calendar_date']}: {s['total_sleep_hours']}h, "
                f"{s['sleep_time']}->{s['wake_time']}, score {s['sleep_score']}")
        log(f"  would upsert {len(acts)} activities, {len(samples)} session samples")
    else:
        upsert_daily(daily)
        # Must follow daily: sleep_daily reads HRV and min_heart_rate from
        # garmin_daily for the same date to complete a Garmin night.
        upsert_sleep(sleep)
        upsert_activities(acts)
        # Must follow activities: samples FK to garmin_activities(activity_id).
        upsert_samples(samples)
        log(f"upserted {len(daily)} daily rows + {len(sleep)} sleep nights "
            f"+ {len(acts)} activities + {len(samples)} session samples")

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
    week_rows = query(f"garmin_weekly?select=*&week_start=eq.{monday}")
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
    pending = take_pending_failure()
    if pending:
        log(f"reporting earlier failure: {pending}")
        summary += f"\n\n⚠️ An earlier run failed and could not notify:\n{pending}"

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
