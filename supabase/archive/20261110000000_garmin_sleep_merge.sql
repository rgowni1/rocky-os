-- Garmin sleep as a second source behind Oura, merged into one nightly spine.
--
-- Why: Oura is missing ~21% of nights (19 of the last 90). The ring and the
-- watch turn out to be almost perfectly complementary — of 13 Garmin sleep
-- nights between Jun 15 and Aug 20, exactly one also had an Oura reading. You
-- wear one device or the other, so Garmin recovers 8 of those 19 gap nights.
--
-- The flip side of that complementarity: with a single overlap night there is
-- no calibration set, and the two devices do not agree on it (duration +0.46h,
-- score +7, HRV -3 for Garmin). So nights are merged WHOLE, never field-by-
-- field — an Oura night stays entirely Oura, a Garmin night entirely Garmin,
-- and sleep_daily.source says which. Blending a Garmin HRV into an Oura night
-- would manufacture recovery dips that are really just device switches.
--
-- Field mapping is deliberate where the devices use different statistics:
--   oura.lowest_heart_rate  <- garmin_daily.min_heart_rate   (NOT the sleep
--     window's avg_heart_rate, which reads ~8bpm high: on 2026-08-03 Oura
--     logged 55, Garmin avgHeartRate 63, Garmin minHeartRate 54.)
--   oura.average_hrv        <- garmin_daily.hrv_last_night_avg
--   oura.latency_minutes    <- no Garmin equivalent, stays null
--
-- Day alignment is already consistent: Garmin's calendarDate, like Oura's
-- `day`, names the morning you woke (2026-10-06 = slept 10/05 22:49 -> 06:50).

-- ---------------------------------------------------------------- daily HR
-- Resting/min HR live with the rest of the daily-summary data, not with the
-- sleep session — they come from get_daily_summary, not get_sleep_data.
alter table public.garmin_daily
  add column if not exists min_heart_rate     integer,
  add column if not exists resting_heart_rate integer;

-- ------------------------------------------------------- garmin_sleep_daily
create table if not exists public.garmin_sleep_daily (
  user_id              uuid not null default '5be4d262-e35c-436b-86f5-0a6f24956182'
                         references auth.users (id) on delete cascade,
  calendar_date        date not null,          -- morning of waking, as Oura
  sleep_score          integer,                -- sleepScores.overall.value
  total_sleep_hours    numeric(5,2),
  average_breath       numeric(5,2),           -- averageRespirationValue
  lowest_breath        numeric(5,2),
  highest_breath       numeric(5,2),
  avg_heart_rate       integer,                -- sleep-window mean; see note above
  avg_sleep_stress     integer,
  awake_count          integer,
  deep_sleep_seconds   integer,                -- stages: Oura has no equivalent
  light_sleep_seconds  integer,
  rem_sleep_seconds    integer,
  awake_sleep_seconds  integer,
  nap_seconds          integer,
  -- Local clock times (America/Los_Angeles), matching oura_daily's convention.
  sleep_time           text,                   -- HH:MM
  wake_time            text,                   -- HH:MM
  -- Minutes after local midnight. Sleep times before 06:00 are stored as +1440
  -- so weekly means survive midnight-crossing bedtimes — same rule as Oura.
  sleep_time_mins      integer,
  wake_time_mins       integer,
  bedtime_start        timestamptz,
  bedtime_end          timestamptz,
  sleep_window_confirmed boolean,
  garmin_sleep_id      text,
  raw                  jsonb,
  synced_at            timestamptz not null default now(),
  primary key (user_id, calendar_date)
);

create index if not exists garmin_sleep_daily_user_date_idx
  on public.garmin_sleep_daily (user_id, calendar_date desc);

alter table public.garmin_sleep_daily enable row level security;

drop policy if exists "Users can read their own garmin sleep rows" on public.garmin_sleep_daily;
create policy "Users can read their own garmin sleep rows"
  on public.garmin_sleep_daily for select to authenticated
  using ((select auth.uid()) = user_id);

grant select on table public.garmin_sleep_daily to authenticated;
grant all on table public.garmin_sleep_daily to service_role;

-- ------------------------------------------------------------------- upsert
create or replace function public.garmin_upsert_sleep(rows jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare n integer;
begin
  insert into public.garmin_sleep_daily (
    calendar_date, sleep_score, total_sleep_hours,
    average_breath, lowest_breath, highest_breath,
    avg_heart_rate, avg_sleep_stress, awake_count,
    deep_sleep_seconds, light_sleep_seconds, rem_sleep_seconds,
    awake_sleep_seconds, nap_seconds,
    sleep_time, wake_time, sleep_time_mins, wake_time_mins,
    bedtime_start, bedtime_end, sleep_window_confirmed, garmin_sleep_id, raw)
  select r.calendar_date, r.sleep_score, r.total_sleep_hours,
         r.average_breath, r.lowest_breath, r.highest_breath,
         r.avg_heart_rate, r.avg_sleep_stress, r.awake_count,
         r.deep_sleep_seconds, r.light_sleep_seconds, r.rem_sleep_seconds,
         r.awake_sleep_seconds, r.nap_seconds,
         r.sleep_time, r.wake_time, r.sleep_time_mins, r.wake_time_mins,
         r.bedtime_start, r.bedtime_end, r.sleep_window_confirmed,
         r.garmin_sleep_id, r.raw
  from jsonb_populate_recordset(null::public.garmin_sleep_daily, rows) r
  on conflict (user_id, calendar_date) do update set
    sleep_score = excluded.sleep_score,
    total_sleep_hours = excluded.total_sleep_hours,
    average_breath = excluded.average_breath,
    lowest_breath = excluded.lowest_breath,
    highest_breath = excluded.highest_breath,
    avg_heart_rate = excluded.avg_heart_rate,
    avg_sleep_stress = excluded.avg_sleep_stress,
    awake_count = excluded.awake_count,
    deep_sleep_seconds = excluded.deep_sleep_seconds,
    light_sleep_seconds = excluded.light_sleep_seconds,
    rem_sleep_seconds = excluded.rem_sleep_seconds,
    awake_sleep_seconds = excluded.awake_sleep_seconds,
    nap_seconds = excluded.nap_seconds,
    sleep_time = excluded.sleep_time, wake_time = excluded.wake_time,
    sleep_time_mins = excluded.sleep_time_mins,
    wake_time_mins = excluded.wake_time_mins,
    bedtime_start = excluded.bedtime_start, bedtime_end = excluded.bedtime_end,
    sleep_window_confirmed = excluded.sleep_window_confirmed,
    garmin_sleep_id = excluded.garmin_sleep_id, raw = excluded.raw,
    synced_at = now();
  get diagnostics n = row_count; return n;
end $function$;

-- -------------------------------------------------------------- sleep_daily
-- One row per night, whole-night precedence: Oura wins when both devices
-- recorded. The >= 3h floor matches oura_weekly's and keeps Garmin naps out —
-- Garmin reports naps in napTimeSeconds separately, but a short "sleep" on a
-- night the watch was half-worn would otherwise drag a weekly mean down.
create or replace view public.sleep_daily
with (security_invoker = true) as
with o as (
  select user_id, calendar_date, sleep_score, total_sleep_hours, average_hrv,
         lowest_heart_rate, average_breath, latency_minutes,
         sleep_time, wake_time, sleep_time_mins, wake_time_mins,
         bedtime_start, bedtime_end
  from public.oura_daily
  where total_sleep_hours is null or total_sleep_hours >= 3
),
g as (
  select s.user_id, s.calendar_date, s.sleep_score,
         s.total_sleep_hours,
         d.hrv_last_night_avg as average_hrv,
         d.min_heart_rate     as lowest_heart_rate,
         s.average_breath,
         null::numeric        as latency_minutes,
         s.sleep_time, s.wake_time, s.sleep_time_mins, s.wake_time_mins,
         s.bedtime_start, s.bedtime_end,
         s.deep_sleep_seconds, s.light_sleep_seconds, s.rem_sleep_seconds
  from public.garmin_sleep_daily s
  left join public.garmin_daily d
    on d.user_id = s.user_id and d.calendar_date = s.calendar_date
  where s.total_sleep_hours >= 3
)
select
  coalesce(o.user_id, g.user_id)             as user_id,
  coalesce(o.calendar_date, g.calendar_date)  as calendar_date,
  -- Which device this night's numbers actually came from.
  case when o.calendar_date is not null then 'oura' else 'garmin' end as source,
  (o.calendar_date is not null) as has_oura,
  (g.calendar_date is not null) as has_garmin,
  case when o.calendar_date is not null then o.sleep_score        else g.sleep_score        end as sleep_score,
  case when o.calendar_date is not null then o.total_sleep_hours  else g.total_sleep_hours  end as total_sleep_hours,
  case when o.calendar_date is not null then o.average_hrv        else g.average_hrv        end as average_hrv,
  case when o.calendar_date is not null then o.lowest_heart_rate  else g.lowest_heart_rate  end as lowest_heart_rate,
  case when o.calendar_date is not null then o.average_breath     else g.average_breath     end as average_breath,
  case when o.calendar_date is not null then o.latency_minutes    else g.latency_minutes    end as latency_minutes,
  case when o.calendar_date is not null then o.sleep_time         else g.sleep_time         end as sleep_time,
  case when o.calendar_date is not null then o.wake_time          else g.wake_time          end as wake_time,
  case when o.calendar_date is not null then o.sleep_time_mins    else g.sleep_time_mins    end as sleep_time_mins,
  case when o.calendar_date is not null then o.wake_time_mins     else g.wake_time_mins     end as wake_time_mins,
  case when o.calendar_date is not null then o.bedtime_start      else g.bedtime_start      end as bedtime_start,
  case when o.calendar_date is not null then o.bedtime_end        else g.bedtime_end        end as bedtime_end,
  -- Stages are Garmin-only; Oura nights leave them null rather than guessing.
  g.deep_sleep_seconds, g.light_sleep_seconds, g.rem_sleep_seconds
from o
full outer join g
  on g.user_id = o.user_id and g.calendar_date = o.calendar_date;

grant select on public.sleep_daily to authenticated;

-- ------------------------------------------------------------- sleep_weekly
-- Mirrors oura_weekly's output columns exactly so weekly_master only has to
-- swap which view it joins, plus the per-source night counts.
create or replace view public.sleep_weekly
with (security_invoker = true) as
with agg as (
  select
    user_id,
    date_trunc('week', calendar_date)::date as week_start,
    round(avg(total_sleep_hours)::numeric, 2) as slp_hrs,
    round(avg(sleep_score)::numeric, 2) as slp_score,
    round(avg(average_hrv)::numeric, 2) as slp_hrv,
    round(avg(lowest_heart_rate)::numeric, 2) as rhr,
    round(avg(average_breath)::numeric, 2) as breath_rate,
    round(avg(latency_minutes)::numeric, 2) as slp_latency,
    round(avg(sleep_time_mins) filter (where sleep_time_mins is not null))::int as avg_sleep_time_mins,
    round(avg(wake_time_mins) filter (where wake_time_mins is not null))::int as avg_wake_time_mins,
    count(*)::int as nights,
    count(*) filter (where source = 'oura')::int as nights_oura,
    count(*) filter (where source = 'garmin')::int as nights_garmin
  from public.sleep_daily
  group by 1, 2
)
select
  user_id,
  week_start,
  slp_hrs,
  slp_score,
  slp_hrv,
  rhr,
  breath_rate,
  slp_latency,
  avg_sleep_time_mins,
  avg_wake_time_mins,
  case
    when avg_sleep_time_mins is null then null
    else lpad(((avg_sleep_time_mins % 1440) / 60)::text, 2, '0')
      || ':' || lpad((avg_sleep_time_mins % 60)::text, 2, '0')
  end as avg_sleep_time,
  case
    when avg_wake_time_mins is null then null
    else lpad((avg_wake_time_mins / 60)::text, 2, '0')
      || ':' || lpad((avg_wake_time_mins % 60)::text, 2, '0')
  end as avg_wake_time,
  nights,
  nights_oura,
  nights_garmin,
  case
    when nights_garmin = 0 then 'oura'
    when nights_oura = 0 then 'garmin'
    else 'mixed'
  end as sleep_source
from agg;

grant select on public.sleep_weekly to authenticated;

-- --------------------------------------------- garmin_upsert_daily: HR columns
-- Reissued verbatim apart from min_heart_rate / resting_heart_rate, which
-- sleep_daily needs to complete a Garmin night (min_heart_rate stands in for
-- Oura's lowest_heart_rate).
create or replace function public.garmin_upsert_daily(rows jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare n integer;
begin
  insert into public.garmin_daily (
    calendar_date, total_kilocalories, total_steps,
    moderate_intensity_minutes, vigorous_intensity_minutes,
    avg_stress_level, high_stress_seconds, medium_stress_seconds,
    low_stress_seconds, weight_lbs, body_fat_pct,
    includes_wellness_data, wellness_end_time_local, is_partial,
    hrv_last_night_avg, hrv_last_night_5min_high, hrv_weekly_avg,
    hrv_status, hrv_baseline_low_upper, hrv_baseline_balanced_low,
    hrv_baseline_balanced_upper,
    resp_waking_avg, resp_sleep_avg, resp_lowest, resp_highest,
    min_heart_rate, resting_heart_rate)
  select r.calendar_date, r.total_kilocalories, r.total_steps,
         r.moderate_intensity_minutes, r.vigorous_intensity_minutes,
         r.avg_stress_level, r.high_stress_seconds, r.medium_stress_seconds,
         r.low_stress_seconds, r.weight_lbs, r.body_fat_pct,
         r.includes_wellness_data, r.wellness_end_time_local,
         coalesce(r.is_partial, false),
         r.hrv_last_night_avg, r.hrv_last_night_5min_high, r.hrv_weekly_avg,
         r.hrv_status, r.hrv_baseline_low_upper, r.hrv_baseline_balanced_low,
         r.hrv_baseline_balanced_upper,
         r.resp_waking_avg, r.resp_sleep_avg, r.resp_lowest, r.resp_highest,
         r.min_heart_rate, r.resting_heart_rate
  from jsonb_populate_recordset(null::public.garmin_daily, rows) r
  on conflict (user_id, calendar_date) do update set
    total_kilocalories = excluded.total_kilocalories, total_steps = excluded.total_steps,
    moderate_intensity_minutes = excluded.moderate_intensity_minutes,
    vigorous_intensity_minutes = excluded.vigorous_intensity_minutes,
    avg_stress_level = excluded.avg_stress_level, high_stress_seconds = excluded.high_stress_seconds,
    medium_stress_seconds = excluded.medium_stress_seconds, low_stress_seconds = excluded.low_stress_seconds,
    weight_lbs = coalesce(excluded.weight_lbs, garmin_daily.weight_lbs),
    body_fat_pct = coalesce(excluded.body_fat_pct, garmin_daily.body_fat_pct),
    includes_wellness_data = excluded.includes_wellness_data,
    wellness_end_time_local = excluded.wellness_end_time_local, is_partial = excluded.is_partial,
    hrv_last_night_avg = excluded.hrv_last_night_avg,
    hrv_last_night_5min_high = excluded.hrv_last_night_5min_high,
    hrv_weekly_avg = excluded.hrv_weekly_avg, hrv_status = excluded.hrv_status,
    hrv_baseline_low_upper = excluded.hrv_baseline_low_upper,
    hrv_baseline_balanced_low = excluded.hrv_baseline_balanced_low,
    hrv_baseline_balanced_upper = excluded.hrv_baseline_balanced_upper,
    resp_waking_avg = excluded.resp_waking_avg, resp_sleep_avg = excluded.resp_sleep_avg,
    resp_lowest = excluded.resp_lowest, resp_highest = excluded.resp_highest,
    min_heart_rate = excluded.min_heart_rate,
    resting_heart_rate = excluded.resting_heart_rate,
    synced_at = now();
  get diagnostics n = row_count; return n;
end $function$;
