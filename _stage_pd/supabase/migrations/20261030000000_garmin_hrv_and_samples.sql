-- Overnight HRV on garmin_daily, plus per-second session samples for
-- meditation/breathwork activities.
--
-- Applied 2026-10-30 against the Supabase "kanban" project by the garmin-sync
-- task (~/.claude/scheduled-tasks/garmin-sync/sync.py). Unlike the older garmin
-- migration files in this directory, this one is NOT retired — sync.py writes
-- these objects on every run.
--
-- Why these two:
--   * Garmin does not compute HRV per activity. get_activity_details on a
--     meditation exposes only heart rate, respiration, stress and body battery
--     (no hrv/rmssd/rrInterval channel anywhere in the payload). The only HRV
--     Garmin produces is the overnight figure, so that is what we store, daily.
--   * The per-second channels it DOES expose were previously unreachable: the
--     browser pipeline truncated tool output at ~1000 chars. Driving the MCP
--     server directly makes the full ~127-sample series available per session.

-- ---------------------------------------------------------------- overnight HRV

alter table public.garmin_daily
  add column if not exists hrv_last_night_avg        integer,  -- hrvSummary.lastNightAvg (ms)
  add column if not exists hrv_last_night_5min_high  integer,  -- hrvSummary.lastNight5MinHigh
  add column if not exists hrv_weekly_avg            integer,  -- hrvSummary.weeklyAvg (null until enough history)
  add column if not exists hrv_status                text,     -- BALANCED | UNBALANCED | LOW | NONE ...
  add column if not exists hrv_baseline_low_upper    integer,  -- baseline.lowUpper
  add column if not exists hrv_baseline_balanced_low integer,  -- baseline.balancedLow
  add column if not exists hrv_baseline_balanced_upper integer;-- baseline.balancedUpper

comment on column public.garmin_daily.hrv_last_night_avg is
  'Overnight average HRV in ms. Garmin exposes no per-activity HRV; this is sleep-window only.';

-- ------------------------------------------------------- intraday session samples

create table if not exists public.garmin_activity_samples (
  activity_id      bigint  not null
                     references public.garmin_activities (activity_id) on delete cascade,
  user_id          uuid    not null default '5be4d262-e35c-436b-86f5-0a6f24956182'
                     references auth.users (id) on delete cascade,
  offset_seconds   integer not null,          -- sumDuration: seconds from session start
  timestamp_gmt    timestamptz,               -- directTimestamp (epoch ms)
  heart_rate       integer,                   -- directHeartRate
  respiration_rate numeric(5,2),              -- directRespirationRate
  stress           integer,                   -- directCurrentStress (null early in a session:
                                              --   Garmin needs a window before it scores stress)
  body_battery     integer,                   -- directBodyBattery
  primary key (activity_id, offset_seconds)
);

create index if not exists garmin_activity_samples_user_idx
  on public.garmin_activity_samples (user_id, activity_id);

alter table public.garmin_activity_samples enable row level security;

drop policy if exists "Users can read their own garmin activity samples"
  on public.garmin_activity_samples;
create policy "Users can read their own garmin activity samples"
  on public.garmin_activity_samples for select to authenticated
  using ((select auth.uid()) = user_id);

-- Per-session rollup. Splits each session into thirds so the shape of a session
-- is queryable without pulling every sample: does respiration actually settle,
-- and when does stress turn over.
create or replace view public.garmin_session_curves
with (security_invoker = true) as
with bounds as (
  select activity_id, user_id,
         min(offset_seconds) as t0,
         nullif(max(offset_seconds), 0) as t_end
  from public.garmin_activity_samples
  group by activity_id, user_id
),
binned as (
  select s.activity_id, s.user_id,
         least(2, ((s.offset_seconds - b.t0) * 3) / nullif(b.t_end - b.t0, 0)) as third,
         s.heart_rate, s.respiration_rate, s.stress
  from public.garmin_activity_samples s
  join bounds b using (activity_id, user_id)
)
select a.activity_id, b.user_id, a.activity_name, a.activity_type,
       a.start_time_local, a.calendar_date,
       round(avg(b.respiration_rate) filter (where b.third = 0), 2) as resp_first_third,
       round(avg(b.respiration_rate) filter (where b.third = 2), 2) as resp_last_third,
       round(avg(b.heart_rate)       filter (where b.third = 0))    as hr_first_third,
       round(avg(b.heart_rate)       filter (where b.third = 2))    as hr_last_third,
       round(avg(b.stress)           filter (where b.third = 0))    as stress_first_third,
       round(avg(b.stress)           filter (where b.third = 2))    as stress_last_third,
       count(*) as samples
from binned b
join public.garmin_activities a using (activity_id)
group by a.activity_id, b.user_id, a.activity_name, a.activity_type,
         a.start_time_local, a.calendar_date;
