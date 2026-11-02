-- All-day stress + body battery at Garmin's native 3-minute cadence.
--
-- garmin_daily already stores the four daily stress aggregates (avg plus
-- high/medium/low seconds). This is the underlying curve those are computed
-- from: 480 samples per day, covering the whole day rather than just logged
-- activities (garmin_activity_samples covers the inside of a session at 1s).
--
-- Applied 2026-11-01. Written by sync.py on every run; not retired.
--
-- Sentinels: Garmin reports -1 (not worn / insufficient data) and -2 (during an
-- activity — it does not score stress while you exercise). Those rows are NOT
-- stored; absence means unmeasured. On a full day only ~190 of the 480 slots
-- carry a real reading, so storing the sentinels would be mostly noise.

create table if not exists public.garmin_stress_samples (
  user_id      uuid        not null default '5be4d262-e35c-436b-86f5-0a6f24956182'
                 references auth.users (id) on delete cascade,
  measured_at  timestamptz not null,
  calendar_date date       not null,
  stress       smallint,          -- 0-100; null if only body battery was present
  body_battery smallint,          -- bodyBatteryLevel
  primary key (user_id, measured_at)
);

create index if not exists garmin_stress_samples_date_idx
  on public.garmin_stress_samples (user_id, calendar_date);

alter table public.garmin_stress_samples enable row level security;

drop policy if exists "Users can read their own garmin stress samples"
  on public.garmin_stress_samples;
create policy "Users can read their own garmin stress samples"
  on public.garmin_stress_samples for select to authenticated
  using ((select auth.uid()) = user_id);

-- Hourly rollup for charting, plus a coverage figure so a sparse day is
-- visibly sparse rather than quietly averaging three readings into an "hour".
--
-- Hours are LOCAL. date_trunc on a timestamptz renders in the session timezone,
-- which is UTC over the REST/Management API — the first cut of this view put
-- every bucket 7-8 hours off, so "midnight" showed up as 07:00.
drop view if exists public.garmin_stress_hourly;
create view public.garmin_stress_hourly
with (security_invoker = true) as
select user_id,
       calendar_date,
       date_trunc('hour', measured_at at time zone 'America/Los_Angeles') as hour_local,
       extract(hour from measured_at at time zone 'America/Los_Angeles')::int as hour_of_day,
       round(avg(stress))       as avg_stress,
       max(stress)              as max_stress,
       round(avg(body_battery)) as avg_body_battery,
       count(stress)            as readings,
       -- 20 three-minute slots make a full hour
       round(count(stress) / 20.0, 2) as coverage
from public.garmin_stress_samples
group by user_id, calendar_date,
         date_trunc('hour', measured_at at time zone 'America/Los_Angeles'),
         extract(hour from measured_at at time zone 'America/Los_Angeles');
