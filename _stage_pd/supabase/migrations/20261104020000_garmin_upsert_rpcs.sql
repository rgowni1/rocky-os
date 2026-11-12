-- Upsert RPCs so garmin_sync.py can write over PostgREST instead of the
-- Supabase Management API.
--
-- The sync ran every write through api.supabase.com with a Personal Access
-- Token. That token expired twice in eight days (2026-10-27 and 2026-11-04),
-- and each time the scheduled GitHub Action breaks with no warning. These
-- functions are reachable with SUPABASE_SECRET_KEY, which does not expire, so
-- the Management API is no longer on the critical path for the daily sync.
--
-- Each takes a jsonb array of row objects and applies the same ON CONFLICT
-- logic the inline SQL used. jsonb_populate_recordset does the type coercion,
-- so the caller sends plain JSON and nothing has to be quoted into a SQL
-- literal -- which also removes the hand-rolled escaping the old path needed.
--
-- SECURITY DEFINER with a pinned search_path: these are called by the service
-- role, and leaving search_path mutable on a definer function is a known
-- privilege-escalation shape.

begin;

create or replace function public.garmin_upsert_daily(rows jsonb)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
    hrv_baseline_balanced_upper)
  select r.calendar_date, r.total_kilocalories, r.total_steps,
         r.moderate_intensity_minutes, r.vigorous_intensity_minutes,
         r.avg_stress_level, r.high_stress_seconds, r.medium_stress_seconds,
         r.low_stress_seconds, r.weight_lbs, r.body_fat_pct,
         r.includes_wellness_data, r.wellness_end_time_local, r.is_partial,
         r.hrv_last_night_avg, r.hrv_last_night_5min_high, r.hrv_weekly_avg,
         r.hrv_status, r.hrv_baseline_low_upper, r.hrv_baseline_balanced_low,
         r.hrv_baseline_balanced_upper
  from jsonb_populate_recordset(null::public.garmin_daily, rows) r
  on conflict (user_id, calendar_date) do update set
    total_kilocalories = excluded.total_kilocalories,
    total_steps = excluded.total_steps,
    moderate_intensity_minutes = excluded.moderate_intensity_minutes,
    vigorous_intensity_minutes = excluded.vigorous_intensity_minutes,
    avg_stress_level = excluded.avg_stress_level,
    high_stress_seconds = excluded.high_stress_seconds,
    medium_stress_seconds = excluded.medium_stress_seconds,
    low_stress_seconds = excluded.low_stress_seconds,
    -- coalesce, not overwrite: a day with no weigh-in must not erase one
    -- already recorded for that date.
    weight_lbs = coalesce(excluded.weight_lbs, garmin_daily.weight_lbs),
    body_fat_pct = coalesce(excluded.body_fat_pct, garmin_daily.body_fat_pct),
    includes_wellness_data = excluded.includes_wellness_data,
    wellness_end_time_local = excluded.wellness_end_time_local,
    is_partial = excluded.is_partial,
    hrv_last_night_avg = excluded.hrv_last_night_avg,
    hrv_last_night_5min_high = excluded.hrv_last_night_5min_high,
    hrv_weekly_avg = excluded.hrv_weekly_avg,
    hrv_status = excluded.hrv_status,
    hrv_baseline_low_upper = excluded.hrv_baseline_low_upper,
    hrv_baseline_balanced_low = excluded.hrv_baseline_balanced_low,
    hrv_baseline_balanced_upper = excluded.hrv_baseline_balanced_upper,
    synced_at = now();
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.garmin_upsert_activities(rows jsonb)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare n integer;
begin
  insert into public.garmin_activities (
    activity_id, activity_name, activity_type, start_time_local,
    duration_seconds, distance_meters, calories, avg_hr, max_hr,
    avg_respiration_rate, min_respiration_rate, max_respiration_rate,
    start_stress, end_stress, avg_stress, max_stress, stress_change)
  select r.activity_id, r.activity_name, r.activity_type, r.start_time_local,
         r.duration_seconds, r.distance_meters, r.calories, r.avg_hr, r.max_hr,
         r.avg_respiration_rate, r.min_respiration_rate, r.max_respiration_rate,
         r.start_stress, r.end_stress, r.avg_stress, r.max_stress, r.stress_change
  from jsonb_populate_recordset(null::public.garmin_activities, rows) r
  on conflict (activity_id) do update set
    activity_name = excluded.activity_name,
    activity_type = excluded.activity_type,
    start_time_local = excluded.start_time_local,
    duration_seconds = excluded.duration_seconds,
    distance_meters = excluded.distance_meters,
    calories = excluded.calories,
    avg_hr = excluded.avg_hr,
    max_hr = excluded.max_hr,
    avg_respiration_rate = excluded.avg_respiration_rate,
    min_respiration_rate = excluded.min_respiration_rate,
    max_respiration_rate = excluded.max_respiration_rate,
    start_stress = excluded.start_stress,
    end_stress = excluded.end_stress,
    avg_stress = excluded.avg_stress,
    max_stress = excluded.max_stress,
    stress_change = excluded.stress_change,
    synced_at = now();
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.garmin_upsert_samples(rows jsonb)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare n integer;
begin
  insert into public.garmin_activity_samples (
    activity_id, offset_seconds, timestamp_gmt,
    heart_rate, respiration_rate, stress, body_battery)
  select r.activity_id, r.offset_seconds, r.timestamp_gmt,
         r.heart_rate, r.respiration_rate, r.stress, r.body_battery
  from jsonb_populate_recordset(null::public.garmin_activity_samples, rows) r
  on conflict (activity_id, offset_seconds) do update set
    timestamp_gmt = excluded.timestamp_gmt,
    heart_rate = excluded.heart_rate,
    respiration_rate = excluded.respiration_rate,
    stress = excluded.stress,
    body_battery = excluded.body_battery;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.garmin_upsert_daily(jsonb)      from public, anon, authenticated;
revoke all on function public.garmin_upsert_activities(jsonb) from public, anon, authenticated;
revoke all on function public.garmin_upsert_samples(jsonb)    from public, anon, authenticated;
grant execute on function public.garmin_upsert_daily(jsonb)      to service_role;
grant execute on function public.garmin_upsert_activities(jsonb) to service_role;
grant execute on function public.garmin_upsert_samples(jsonb)    to service_role;

commit;
