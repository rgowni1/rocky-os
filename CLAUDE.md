# Rocky OS

Personal operating system. One Supabase database holds every health and life
metric; a static dashboard on GitHub Pages reads it; a set of scheduled Python
syncs keep it current from Oura, Garmin, Readwise, Notion and Beeminder.

Merged on 2026-11-12 from two repos that had grown into each other:
`kanban` (the dashboard surface, 95 commits) and `personal-dashboard` (the ETL
layer). Full history from both is preserved in this repo.

## Layout

```
web/        Static dashboard (GitHub Pages) + the iOS Scriptable widget
sync/       Scheduled ETL — every script here is run by a GitHub Actions workflow
tools/      Local-only operator scripts (SQL runner, password reset)
mcp/        stdio MCP server exposing the task tools to Claude Code
supabase/   Schema: one baseline migration + archive/ of the pre-merge history
legacy/     Dead code kept for reference. Nothing runs from here.
```

Every script sits **exactly one directory below the repo root** and resolves
`.env` as `parents[1]/.env`. That invariant is load-bearing — moving a script
up or down a level silently breaks local runs while CI keeps passing, because
CI gets its values from Actions secrets rather than from a file.

## Data flow

```
Oura ──────────┐
Garmin ────────┤
Readwise ──────┼──> sync/*.py ──> Supabase Postgres ──> web/index.html (Pages)
Notion Journal ┤                       │                web/scriptable/ (iOS widget)
Beeminder <────┘                       └──> Notion (writeback of weekly rollups)
```

Supabase is the source of truth. Notion is both an input (the hand-written
Logging Journal) and an output (weekly rollups pushed back onto the same page).
Auth is Supabase email+password, single user. The anon publishable key is
committed in `web/index.html`; RLS enforces per-user access.

## Sync scripts

| Script | Role | Schedule |
|---|---|---|
| `sync/oura.py` | Oura → `oura_daily` → `oura_weekly` view → Notion | 16:23 UTC Mon–Fri + 19:23 UTC daily |
| `sync/readwise_sync.py` | Readwise → `readwise_daily` → weekly → Notion | 17:20 UTC daily |
| `sync/garmin_sync.py` | Garmin Connect → Supabase → Notion → notification | **manual only** (see below) |
| `sync/garmin_notion_update.py` | Pushes one week's `garmin_weekly` rollup into the Notion Log page | called by `garmin_sync.py` |
| `sync/food_sync.py` | Notion Logging Journal → `journal_entries` + `food_log_entries`, derives meal timing | every 3h at :17 |
| `sync/journal_sync.py` | Weekly journal prose → `journal_entries`, High/Low/Bud generated with Claude | 07:10 UTC Monday |
| `sync/beeminder_sync.py` | Notion weekly tracking → Beeminder datapoints | 20:00 UTC Sunday |
| `sync/eow_digest.py` | End-of-week Slack nudge: Work tasks done with no effort tagged | not scheduled |
| `sync/imessage.sh` | Sends an iMessage via local Messages.app. macOS only, never runs in CI. | — |

`food_sync.py`, `garmin_sync.py`, `garmin_notion_update.py` and `eow_digest.py`
are **stdlib-only by design** — their workflows deliberately skip `pip install`.
Don't add a third-party import to them without also adding the install step.
The rest install `sync/requirements.txt`.

### Garmin runs on the Mac, not on Actions — but that may be changing

`garmin-sync.yml` has its schedules commented out. Garmin was rate-limiting
GitHub's Azure egress ranges: every MCP call came back `429`, while the same
token worked from a residential IP seconds later. Not auth, and no amount of
backoff fixed it from our side. The live path is the launchd job on the Mac
(`com.rockygowni.garmin-sync`, 06:10 and 22:30 Pacific).

**The first dispatch from rocky-os on 2026-11-12 succeeded outright** — no 429,
14 daily rows + 2 sleep nights + 17 activities + 1470 samples upserted, 13
properties written to Notion. The throttle is evidently not permanent. It is
still not re-enabled on the strength of one run; dispatch it manually a few
more times, and if it keeps passing, uncomment the crons and retire the launchd
job. Every write is an idempotent upsert, so running both during a trial
period costs nothing but duplicate log lines.

If Garmin auth itself fails, the OAuth1 token (≈1 year life) has been revoked,
and the only fix is `npm run setup` locally with a password and MFA code:

```bash
cd ~/garmin-connect-mcp
read -rs "pw?Garmin password: " && GARMIN_EMAIL='...' GARMIN_PASSWORD="$pw" npm run setup; unset pw
gh secret set GARMIN_TOKENS -R rgowni1/rocky-os < ~/.garmin-mcp/tokens.json
```

## Dashboard (`web/index.html`)

Static SPA, no build step, no bundler. Supabase JS client, 5-column task board,
detail drawer, filter toolbar, plus the Personal Intelligence charts. Edit the
file and refresh the browser. Serve locally with `python3 -m http.server 8000`.

The task board still exists but is no longer the product surface — the metrics
dashboard is. MCP task tools remain for optional Claude use.

### Schema (`tasks`)

```
id           uuid          PK
user_id      uuid          FK auth.users, RLS gate
title        text          NOT NULL
status       text          NOT NULL  -- inbox | not-started | in-progress | focus | done
context      text                    -- Personal | Work
source       text                    -- e.g. "Manual", "Notion"
source_link  text
notion_id    text                    -- import dedup key (legacy)
description  text                    -- markdown
timing       text                    -- this-week | next-week | next-30-days ("Later") | ongoing; planning horizon only
effort       text                    -- S | M | L | XL
parent_id    uuid          FK tasks(id) ON DELETE CASCADE  -- 2-level hierarchy
subtasks     jsonb         NOT NULL  -- LEGACY. Migrated to child tasks; kept at '[]'. Do not write new data here.
created_at   timestamptz   NOT NULL
updated_at   timestamptz   NOT NULL
completed_at timestamptz             -- auto-set by `set_completed_at` trigger on status → done; cleared on status → not-done
```

`timing` and `effort` are CHECK-constrained enums. `status` is enforced in app
code; the server-side constraint may or may not exist. `description` renders as
markdown in the drawer via `marked` + `DOMPurify` (CDN-loaded).

### Projects (2-level hierarchy)

`parent_id` makes any task nestable. A **project** is a top-level task
(`parent_id IS NULL`) with ≥1 child; a **child task** has `parent_id` set. Only
2 levels are allowed — a child can't have children, a project can't be nested
(enforced in `mcp/mcp_server.py:validate_parent` and the drawer UI).

- **Board scope** (`state.project`): `null` = "All Tasks", top-level only
  (children hidden, projects show a 📁 done/total chip). Selecting a project
  scopes the board to its children; new tasks there inherit `parent_id` + context.
- **MCP**: `create_task`/`update_task` take `parent_id` (empty string detaches).
  `list_tasks` takes `parent` (a project id, or `'none'` for top-level only).

### Views & filters

The toolbar exposes **filters** (Context / Due / Age — multi-pill pattern) and a
**group-by toggle** (Status / Due / Age / Context), independently: filters
AND-narrow the visible set, group-by chooses which dimension drives the columns.
Drag-drop reassigns the grouping field where that makes sense (status / timing /
context); under Age grouping it's a no-op, since staleness derives from `created_at`.

### Automations (on-open rollovers)

Two weekly rollovers run client-side in `loadTasks()`, once per week on the
first app open after the boundary (tracked in `localStorage`, skipping their
first-ever run so nothing is swept retroactively; optimistic local update +
background persist):

- **Focus → In Progress** after Sunday 6pm (`maybeWeeklyFocusReset`, key `kanban.lastFocusReset`)
- **Next Week → This Week** on/after Monday 00:00 (`maybeNextWeekRollover`, key `kanban.lastNextWeekRoll`)

There is no server-side scheduler. Whichever machine opens the app first that
week runs the rollover, and it's idempotent across devices.

## Food log & nutrition

Two tables, two grains. `journal_entries` holds the **weekly** rollup;
`food_log_entries` holds the **individual meals** behind it, so the dashboard
can drill from "3 non-profile meals" into which three.

Some weekly food columns are Notion rollups copied verbatim (`FL Non Profile` →
`non_profile_meals`, `FL DCP` → `dcp_meals`). `FL Cooked` deliberately is not —
see below. Notion still has `FL Drinks`, `FL Milk Drinks`, `FL Total Cals` and
`FL Total Protein` that nothing reads yet.

**Meal timing and the cooked count are derived, not synced.**
`weekly_meal_stats()` computes `first_meal_mins`, `last_meal_mins`,
`eating_window_hrs`, `meal_days`, `total_meals` and `cooked_meals` from the meal
rows. Stored as minutes after local midnight so the numeric chart machinery can
draw them; the UI formats back to a clock.

- **An eating day runs 04:00 → 03:59.** A 00:30 snack closes the night before
  rather than opening the next day. `EATING_DAY_START_MIN` in `sync/food_sync.py`
  and the same constant in `web/index.html` and `web/scriptable/agentos-food.js`
  **must agree** — if they drift, the charts and the drill-down will disagree
  about which day a late meal belongs to.
- Times resolve to `FOOD_LOG_TZ` (default `America/Los_Angeles`). Notion returns
  a real UTC offset on every timed entry; date-only entries are skipped rather
  than guessed at as midnight.
- Weeks with fewer than `MIN_TIMING_DAYS` (3) logged days report coverage but no
  averages — one 20:00 meal would otherwise read as a 20:00 first meal and a
  0-hour window. Same spirit as the `MIN_PLAUSIBLE_DAILY_CALS` floor on calories.

**`is_cooked` is just `Source == "Home"`** in Notion — nothing about cooking.
Leftovers, trail mix and a hot chocolate all count. Nothing in the row separates
those from a real cooked meal, so it's treated as a *default* rather than an
answer: `cooked_meals` is derived in the sync as
`coalesce(is_cooked_override, is_cooked)`, **not** copied from the `FL Cooked`
rollup. Mark a meal "not cooked" in the drill-down and the weekly count follows
on the next sync.

### Corrected meals

The frontend is static on GitHub Pages, so it cannot hold the Notion token and
write a fix upstream. Instead:

- Two override columns, both owned by the browser and **never** written by the
  sync: `eaten_at_override` (timestamptz) and `is_cooked_override` (boolean,
  tri-state — `null` defers to Notion, `false` demotes, `true` promotes).
- Everything reading either value uses `coalesce(override, notion_value)` — in
  the drill-downs, in the widget, and in the sync's own derivation
  (`fetch_meal_overrides` → `weekly_meal_stats`) — so a correction is not undone
  by the next run.
- `food_log_entries` has an update policy for `authenticated` plus a
  `before update` trigger (`food_log_entries_guard_client_update`) pinning every
  other column to its old value for browser sessions, and a column-level
  `grant update (eaten_at_override, is_cooked_override)`. `service_role` (the
  sync) keeps full write access. The policy alone cannot scope an update to one
  column — **a new override column needs adding to that grant**, or the browser
  write fails silently.

An edit shows immediately in the drill-down (computed client-side) and reaches
the weekly charts on the next sync.

## Schema

`supabase/migrations/20261112000000_baseline.sql` is the entire schema, dumped
from the live database. The pre-merge migration files in `supabase/archive/`
are history only — **do not replay them**; see `supabase/README.md` for why.

14 tables, 13 views. `weekly_master` is the dashboard's single read surface:
one row per user per week, every metric resolved from its live source with
`legacy_notion_table` as the fallback for weeks predating that source's own
table.

Three things in the database that no repo documented before the merge, all now
captured in the baseline:

- **A `pg_cron` job runs every Monday 08:00 UTC**, calling
  `weekly_today_rollover()`. That function looks for `timing IN
  ('today','tomorrow')`, values the CHECK constraint no longer permits, so it
  matches zero rows every week. Harmless, but it is dead.
- **`food_log_entries_guard_client_update` has drifted.** It pins the synced
  columns against browser writes, but `drinks`, `has_creatine` and
  `has_pumpkin_seeds` were added to the table afterwards and are not in the pin
  list. An authenticated client can currently overwrite all three, and the sync
  writes them. Add them when you next touch that trigger.
- **`rocket_money_transactions` has an `anon can insert` policy with
  `check (true)`.** Anyone holding the anon key — which is committed in
  `web/index.html` — can insert arbitrary rows. There is no matching select
  policy so they can't read anything back, but the write is open.

RLS is the only thing protecting this data: Supabase's stock grants give `anon`
and `authenticated` full privileges on everything in `public`, and the policies
do the gating. **A new table without RLS enabled is public.**

## Secrets

`.env` at the repo root, gitignored, 20 keys. `.env.example` lists the names.
Every key is mirrored as a GitHub Actions secret on `rgowni1/rocky-os` — a
missing one makes the script exit on its own `Missing environment variables:`
guard, which reads as a generic step failure in the Actions UI.

Two pre-merge gotchas, both resolved:

- **One Notion token.** The repos used two different integrations, "Kanban" and
  "WeeklyTrackingBot". Verified by API that Kanban's reads a strict superset and
  has write capability; it's the one in `.env`. If a Notion read 404s, check
  that the database is shared with the Kanban integration.
- **`SUPABASE_ACCESS_TOKEN` is gone.** The Management API needed a PAT that
  expired three times, twice inside eight days, silently breaking whatever was
  mid-flight. A database password doesn't expire.

`SUPABASE_DB_URL` (needed only by `tools/run_sql.py`) is **not yet set** — paste
the session-pooler URI from Supabase → Project Settings → Database.

## Common commands

```bash
# Serve the dashboard locally
python3 -m http.server 8000 --directory web     # then open http://localhost:8000

# Run a sync by hand (all take --dry-run)
python3 sync/oura.py
python3 sync/food_sync.py --dry-run
python3 sync/garmin_sync.py --dry-run

# Run SQL / apply a migration (needs SUPABASE_DB_URL + psycopg2-binary)
python3 tools/run_sql.py "SELECT count(*) FROM tasks;"
python3 tools/run_sql.py < supabase/migrations/<file>.sql

# Set the dashboard user's password (one-time)
python3 tools/set_password.py

# Check a scheduled sync is actually running
gh run list --workflow food-sync.yml --limit 5
```

## Conventions

- **Keep every script one level below the root.** `.env` resolution depends on it.
- **Never extend `legacy/server.py`.** New backend logic goes in
  `mcp/mcp_server.py` (Claude write-paths) or `web/index.html` (UI).
- **MCP tool changes need a Claude Code reload** — the server spawns at session start.
- **Don't echo `SUPABASE_SECRET_KEY` or `SUPABASE_DB_URL`** in chat or commits.
- **Use the session-pooler URI, not the direct one.** `db.<ref>.supabase.co`
  publishes only an AAAA record since Supabase deprecated IPv4, and this Mac has
  no global IPv6 address, so the direct URI cannot connect. The pooler has IPv4.
- **Frontend is fully static** — no build step. Edit and refresh.
- **Schema changes**: write the SQL into `supabase/migrations/`, apply with
  `python3 tools/run_sql.py < supabase/migrations/<file>.sql`, update
  `mcp/mcp_server.py` field lists and `web/index.html` (rowToTask / patchToRow /
  drawer / badges / filters) in the same commit.

## Not yet implemented

- **File attachments on tasks.** No Storage bucket, no `attachments` table or
  column, no upload UI. Only `source_link` (URL string) exists.
- **`sync_inbox` MCP tool** to pull Outlook-flagged emails. Blocked on Sonar
  exposing flag status — see `tools/mail.py` in
  `~/tm_workspace/tidemark-backend/tidemark_backend/sonar_mcp/`: add `flag` to
  the Graph `$select` and a `flagged_only` arg.
- **Remote MCP** for browser Claude / phone. `mcp/mcp_server.py` is stdio-only;
  would need an HTTP/SSE transport and somewhere to host it.
