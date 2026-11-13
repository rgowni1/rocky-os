-- Rocky OS — schema baseline, dumped from the live database on 2026-11-12.
--
-- Why this file exists: kanban and personal-dashboard each kept their own
-- supabase/migrations directory pointed at the same Postgres, and the live
-- database had 19 applied migrations against 34 files on disk. Neither set
-- replayed to what was actually running. The pre-merge files are kept
-- verbatim in supabase/archive/ for history; this is the only one that
-- describes the real schema.
--
-- Generated from the catalogs (pg_get_constraintdef / viewdef / functiondef /
-- triggerdef), not hand-written. Replays clean onto an empty Supabase project.
-- auth.users must exist first — every user_id FK points at it.

-- ============================================================ extensions

create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_stat_statements with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists supabase_vault with schema vault;

-- ============================================================ tables

create table public.tasks (
    id uuid default gen_random_uuid() not null,
    user_id uuid not null,
    title text not null,
    status text default 'inbox'::text not null,
    context text,
    source text,
    source_link text,
    notion_id text,
    created_at timestamp with time zone default now() not null,
    updated_at timestamp with time zone default now() not null,
    description text,
    effort text,
    timing text,
    subtasks jsonb default '[]'::jsonb not null,
    completed_at timestamp with time zone,
    archived boolean default false not null,
    parent_id uuid
);

create table public.journal_entries (
    id uuid default gen_random_uuid() not null,
    user_id uuid not null,
    week date not null,
    notion_page_id text,
    source_updated_at timestamp with time zone,
    synced_at timestamp with time zone default now() not null,
    journal_high text,
    journal_low text,
    journal_bud text,
    journal_raw_text text,
    journal_summary_of text
);

create table public.food_log_entries (
    id uuid default gen_random_uuid() not null,
    user_id uuid not null,
    notion_page_id text not null,
    name text not null,
    eaten_at timestamp with time zone,
    meal_type text,
    source text,
    calories numeric,
    protein_g numeric,
    carbs_g numeric,
    fat_g numeric,
    is_non_profile boolean default false not null,
    is_dcp boolean default false not null,
    is_cooked boolean default false not null,
    source_updated_at timestamp with time zone,
    synced_at timestamp with time zone default now() not null,
    eaten_at_override timestamp with time zone,
    is_cooked_override boolean,
    drinks numeric,
    has_creatine boolean default false not null,
    has_pumpkin_seeds boolean default false not null
);

create table public.oura_daily (
    user_id uuid default '5be4d262-e35c-436b-86f5-0a6f24956182'::uuid not null,
    calendar_date date not null,
    sleep_score numeric(5,2),
    total_sleep_hours numeric(5,2),
    average_hrv numeric(6,2),
    lowest_heart_rate numeric(5,2),
    average_breath numeric(5,2),
    latency_minutes numeric(6,2),
    sleep_time text,
    wake_time text,
    sleep_time_mins integer,
    wake_time_mins integer,
    bedtime_start timestamp with time zone,
    bedtime_end timestamp with time zone,
    oura_sleep_id text,
    raw jsonb,
    synced_at timestamp with time zone default now() not null
);

create table public.garmin_daily (
    user_id uuid default '5be4d262-e35c-436b-86f5-0a6f24956182'::uuid not null,
    calendar_date date not null,
    total_kilocalories integer,
    total_steps integer,
    moderate_intensity_minutes integer,
    vigorous_intensity_minutes integer,
    intensity_minutes integer default (COALESCE(moderate_intensity_minutes, 0) + (2 * COALESCE(vigorous_intensity_minutes, 0))),
    avg_stress_level integer,
    high_stress_seconds integer,
    medium_stress_seconds integer,
    low_stress_seconds integer,
    weight_lbs numeric(6,2),
    body_fat_pct numeric(5,2),
    includes_wellness_data boolean,
    wellness_end_time_local timestamp without time zone,
    is_partial boolean default false not null,
    raw jsonb,
    synced_at timestamp with time zone default now() not null,
    adjusted_kilocalories integer default (round(((total_kilocalories)::numeric * 0.90)))::integer,
    hrv_last_night_avg integer,
    hrv_last_night_5min_high integer,
    hrv_weekly_avg integer,
    hrv_status text,
    hrv_baseline_low_upper integer,
    hrv_baseline_balanced_low integer,
    hrv_baseline_balanced_upper integer,
    resp_waking_avg smallint,
    resp_sleep_avg smallint,
    resp_lowest smallint,
    resp_highest smallint,
    min_heart_rate integer,
    resting_heart_rate integer
);

create table public.garmin_sleep_daily (
    user_id uuid default '5be4d262-e35c-436b-86f5-0a6f24956182'::uuid not null,
    calendar_date date not null,
    sleep_score integer,
    total_sleep_hours numeric(5,2),
    average_breath numeric(5,2),
    lowest_breath numeric(5,2),
    highest_breath numeric(5,2),
    avg_heart_rate integer,
    avg_sleep_stress integer,
    awake_count integer,
    deep_sleep_seconds integer,
    light_sleep_seconds integer,
    rem_sleep_seconds integer,
    awake_sleep_seconds integer,
    nap_seconds integer,
    sleep_time text,
    wake_time text,
    sleep_time_mins integer,
    wake_time_mins integer,
    bedtime_start timestamp with time zone,
    bedtime_end timestamp with time zone,
    sleep_window_confirmed boolean,
    garmin_sleep_id text,
    raw jsonb,
    synced_at timestamp with time zone default now() not null
);

create table public.garmin_activities (
    activity_id bigint not null,
    user_id uuid default '5be4d262-e35c-436b-86f5-0a6f24956182'::uuid not null,
    activity_name text,
    activity_type text not null,
    start_time_local timestamp without time zone not null,
    calendar_date date default (start_time_local)::date,
    duration_seconds numeric(10,2),
    distance_meters numeric(12,2),
    calories numeric(8,2),
    avg_hr integer,
    max_hr integer,
    raw jsonb,
    synced_at timestamp with time zone default now() not null,
    min_hr integer,
    avg_respiration_rate numeric(5,2),
    min_respiration_rate numeric(5,2),
    max_respiration_rate numeric(5,2),
    start_stress integer,
    end_stress integer,
    avg_stress integer,
    max_stress integer,
    stress_change integer
);

create table public.garmin_activity_samples (
    activity_id bigint not null,
    user_id uuid default '5be4d262-e35c-436b-86f5-0a6f24956182'::uuid not null,
    offset_seconds integer not null,
    timestamp_gmt timestamp with time zone,
    heart_rate integer,
    respiration_rate numeric(5,2),
    stress integer,
    body_battery integer
);

create table public.readwise_daily (
    user_id uuid not null,
    calendar_date date not null,
    book_id bigint not null,
    book_title text,
    author text,
    category text,
    source text,
    source_url text,
    is_youtube boolean default false not null,
    highlight_count integer default 0 not null,
    synced_at timestamp with time zone default now() not null
);

create table public.bodyspec_scans (
    result_id text not null,
    user_id uuid default '5be4d262-e35c-436b-86f5-0a6f24956182'::uuid not null,
    scan_date date not null,
    location text,
    raw jsonb not null,
    total_mass_lb numeric(6,1) default ((raw #>> '{composition,total,total_mass,lb}'::text[]))::numeric,
    fat_mass_lb numeric(6,1) default ((raw #>> '{composition,total,fat_mass,lb}'::text[]))::numeric,
    lean_mass_lb numeric(6,1) default ((raw #>> '{composition,total,lean_mass,lb}'::text[]))::numeric,
    bone_mass_lb numeric(5,1) default ((raw #>> '{composition,total,bone_mass,lb}'::text[]))::numeric,
    body_fat_pct numeric(4,1) default ((raw #>> '{composition,total,region_fat_pct}'::text[]))::numeric,
    trunk_lean_lb numeric(5,1) default ((raw #>> '{composition,trunk,lean_mass,lb}'::text[]))::numeric,
    trunk_fat_lb numeric(5,1) default ((raw #>> '{composition,trunk,fat_mass,lb}'::text[]))::numeric,
    arms_lean_lb numeric(5,1) default ((raw #>> '{composition,arms,lean_mass,lb}'::text[]))::numeric,
    legs_lean_lb numeric(5,1) default ((raw #>> '{composition,legs,lean_mass,lb}'::text[]))::numeric,
    l_arm_lean_lb numeric(5,1) default ((raw #>> '{composition,l_arm,lean_mass,lb}'::text[]))::numeric,
    r_arm_lean_lb numeric(5,1) default ((raw #>> '{composition,r_arm,lean_mass,lb}'::text[]))::numeric,
    l_leg_lean_lb numeric(5,1) default ((raw #>> '{composition,l_leg,lean_mass,lb}'::text[]))::numeric,
    r_leg_lean_lb numeric(5,1) default ((raw #>> '{composition,r_leg,lean_mass,lb}'::text[]))::numeric,
    android_fat_pct numeric(4,1) default ((raw #>> '{composition,android,region_fat_pct}'::text[]))::numeric,
    gynoid_fat_pct numeric(4,1) default ((raw #>> '{composition,gynoid,region_fat_pct}'::text[]))::numeric,
    vat_mass_lb numeric(5,2) default ((raw #>> '{visceral_fat,vat_mass,lb}'::text[]))::numeric,
    vat_volume_in3 numeric(6,2) default ((raw #>> '{visceral_fat,vat_volume,in3}'::text[]))::numeric,
    bmd_total_g_cm2 numeric(5,3) default ((raw #>> '{bone_density,total,bmd_g_cm2}'::text[]))::numeric,
    body_fat_percentile integer default ((raw #>> '{percentiles,metrics,total_body_fat_pct,percentile}'::text[]))::integer,
    vat_percentile integer default ((raw #>> '{percentiles,metrics,vat_mass_kg,percentile}'::text[]))::integer,
    lmi_kg_m2 numeric(5,2) default ((raw #>> '{percentiles,metrics,total_lmi_kg_m2,value}'::text[]))::numeric,
    lmi_percentile integer default ((raw #>> '{percentiles,metrics,total_lmi_kg_m2,percentile}'::text[]))::integer,
    limb_lmi_percentile integer default ((raw #>> '{percentiles,metrics,limb_lmi_kg_m2,percentile}'::text[]))::integer,
    bmd_percentile integer default ((raw #>> '{percentiles,metrics,bone_density_g_cm2,percentile}'::text[]))::integer,
    synced_at timestamp with time zone default now() not null
);

create table public.screentime_weekly (
    user_id uuid default '5be4d262-e35c-436b-86f5-0a6f24956182'::uuid not null,
    week_start date not null,
    period_start date,
    total_pickups numeric,
    avg_daily_pickups numeric,
    source text default 'screen_time'::text not null,
    synced_at timestamp with time zone default now() not null
);

create table public.calendar_weekly (
    user_id uuid default '5be4d262-e35c-436b-86f5-0a6f24956182'::uuid not null,
    week_start date not null,
    focus_blocks_4h integer,
    focus_blocks_3h integer,
    focus_blocks_2h integer,
    longest_focus_hrs numeric,
    free_workday_hrs numeric,
    work_meetings integer,
    work_hrs numeric,
    social_events integer,
    social_hrs numeric,
    fitness_events integer,
    fitness_hrs numeric,
    personal_events integer,
    personal_hrs numeric,
    commute_hrs numeric,
    flights integer,
    untagged_events integer,
    untagged_hrs numeric,
    notes text,
    source text default 'vimcal'::text not null,
    synced_at timestamp with time zone default now() not null,
    inferred jsonb
);

create table public.rocket_money_transactions (
    row_key text not null,
    txn_date date not null,
    name text not null,
    category text,
    amount numeric(12,2) not null,
    is_pending boolean default false not null,
    account text,
    inserted_at timestamp with time zone default now() not null
);

-- Frozen pre-per-source weekly numbers. Nothing writes this; weekly_master
-- reads its *_legacy columns only for weeks the live views do not cover.
create table public.legacy_notion_table (
    user_id uuid not null,
    week date not null,
    notion_page_id text,
    source_updated_at timestamp with time zone,
    synced_at timestamp with time zone default now() not null,
    slp_hrs_legacy numeric,
    slp_score_legacy numeric,
    slp_hrv_legacy numeric,
    rhr_legacy numeric,
    avg_sleep_time_legacy text,
    avg_wake_time_legacy text,
    run_miles_legacy numeric,
    bike_miles_legacy numeric,
    swim_yards_legacy numeric,
    strength_mins_legacy numeric,
    intensity_mins_legacy numeric,
    step_count_legacy numeric,
    training_hrs_legacy numeric,
    body_fat_legacy numeric,
    weekly_weight_legacy numeric,
    stress_legacy numeric,
    meditation_legacy numeric,
    articles_legacy numeric,
    podcasts_legacy numeric,
    phone_pickups_legacy numeric,
    avg_daily_pickups_legacy numeric,
    consumed_cals_legacy numeric,
    avg_protein_legacy numeric,
    calorie_deficit_legacy numeric,
    garmin_tdee_legacy numeric,
    non_profile_meals_legacy numeric,
    dcp_meals_legacy numeric,
    cooked_meals_legacy numeric,
    total_meals_legacy numeric,
    first_meal_mins_legacy numeric,
    last_meal_mins_legacy numeric,
    eating_window_hrs_legacy numeric,
    meal_days_legacy numeric,
    drinks_legacy numeric,
    highlights_legacy numeric
);

-- ============================================================ constraints

alter table public.tasks add constraint tasks_pkey PRIMARY KEY (id);
alter table public.tasks add constraint tasks_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.tasks add constraint tasks_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES tasks(id) ON DELETE CASCADE;
alter table public.tasks add constraint tasks_status_check CHECK ((status = ANY (ARRAY['inbox'::text, 'not-started'::text, 'in-progress'::text, 'focus'::text, 'done'::text])));
alter table public.tasks add constraint tasks_timing_check CHECK ((timing = ANY (ARRAY['this-week'::text, 'next-week'::text, 'next-30-days'::text, 'ongoing'::text])));

alter table public.journal_entries add constraint journal_entries_pkey PRIMARY KEY (id);
alter table public.journal_entries add constraint journal_entries_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.journal_entries add constraint journal_entries_user_week_key UNIQUE (user_id, week);

alter table public.food_log_entries add constraint food_log_entries_pkey PRIMARY KEY (id);
alter table public.food_log_entries add constraint food_log_entries_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.food_log_entries add constraint food_log_entries_user_id_notion_page_id_key UNIQUE (user_id, notion_page_id);

alter table public.oura_daily add constraint oura_daily_pkey PRIMARY KEY (user_id, calendar_date);
alter table public.oura_daily add constraint oura_daily_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table public.garmin_daily add constraint garmin_daily_pkey PRIMARY KEY (user_id, calendar_date);
alter table public.garmin_daily add constraint garmin_daily_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table public.garmin_sleep_daily add constraint garmin_sleep_daily_pkey PRIMARY KEY (user_id, calendar_date);
alter table public.garmin_sleep_daily add constraint garmin_sleep_daily_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table public.garmin_activities add constraint garmin_activities_pkey PRIMARY KEY (activity_id);
alter table public.garmin_activities add constraint garmin_activities_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table public.garmin_activity_samples add constraint garmin_activity_samples_pkey PRIMARY KEY (activity_id, offset_seconds);
alter table public.garmin_activity_samples add constraint garmin_activity_samples_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES garmin_activities(activity_id) ON DELETE CASCADE;
alter table public.garmin_activity_samples add constraint garmin_activity_samples_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table public.readwise_daily add constraint readwise_daily_pkey PRIMARY KEY (user_id, calendar_date, book_id);
alter table public.readwise_daily add constraint readwise_daily_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table public.bodyspec_scans add constraint bodyspec_scans_pkey PRIMARY KEY (result_id);
alter table public.bodyspec_scans add constraint bodyspec_scans_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table public.screentime_weekly add constraint screentime_weekly_pkey PRIMARY KEY (user_id, week_start);
alter table public.screentime_weekly add constraint screentime_weekly_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

alter table public.calendar_weekly add constraint calendar_weekly_pkey PRIMARY KEY (user_id, week_start);

alter table public.rocket_money_transactions add constraint rocket_money_transactions_pkey PRIMARY KEY (row_key);

-- Constraint names still say weekly_metrics; the table was renamed, they were not.
alter table public.legacy_notion_table add constraint weekly_metrics_pkey PRIMARY KEY (user_id, week);
alter table public.legacy_notion_table add constraint weekly_metrics_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- ============================================================ indexes

CREATE INDEX tasks_user_status_idx ON public.tasks USING btree (user_id, status);
CREATE INDEX tasks_notion_id_idx ON public.tasks USING btree (notion_id) WHERE (notion_id IS NOT NULL);
CREATE INDEX idx_tasks_parent ON public.tasks USING btree (parent_id);
CREATE INDEX journal_entries_user_week_idx ON public.journal_entries USING btree (user_id, week);
CREATE INDEX food_log_entries_user_eaten_idx ON public.food_log_entries USING btree (user_id, eaten_at DESC);
CREATE INDEX oura_daily_user_date_idx ON public.oura_daily USING btree (user_id, calendar_date DESC);
CREATE INDEX garmin_daily_user_date_idx ON public.garmin_daily USING btree (user_id, calendar_date);
CREATE INDEX garmin_sleep_daily_user_date_idx ON public.garmin_sleep_daily USING btree (user_id, calendar_date DESC);
CREATE INDEX garmin_activities_user_date_idx ON public.garmin_activities USING btree (user_id, calendar_date);
CREATE INDEX garmin_activity_samples_user_idx ON public.garmin_activity_samples USING btree (user_id, activity_id);
CREATE INDEX readwise_daily_user_date_idx ON public.readwise_daily USING btree (user_id, calendar_date DESC);
CREATE INDEX bodyspec_scans_user_date_idx ON public.bodyspec_scans USING btree (user_id, scan_date DESC);
CREATE INDEX legacy_notion_table_user_week_idx ON public.legacy_notion_table USING btree (user_id, week DESC);

-- ============================================================ functions

create or replace function public.set_updated_at()
 returns trigger
 language plpgsql
as $function$
  begin
    new.updated_at = now();
    return new;
  end $function$;

create or replace function public.set_completed_at()
 returns trigger
 language plpgsql
as $function$
begin
  if TG_OP = 'INSERT' then
    if NEW.status = 'done' and NEW.completed_at is null then NEW.completed_at = now(); end if;
  elsif TG_OP = 'UPDATE' then
    if NEW.status = 'done' and (OLD.status is distinct from 'done') then NEW.completed_at = now();
    elsif NEW.status <> 'done' and OLD.status = 'done' then NEW.completed_at = null;
    end if;
  end if;
  return NEW;
end; $function$;

-- Dead as written: `timing` is CHECK-constrained to
-- this-week/next-week/next-30-days/ongoing, so the 'today'/'tomorrow' values
-- this looks for can no longer exist. Kept because the pg_cron job at the
-- bottom of this file still calls it every Monday; it matches zero rows.
create or replace function public.weekly_today_rollover()
 returns integer
 language plpgsql
as $function$
declare moved integer;
begin
  update tasks
     set timing = 'this-week', updated_at = now()
   where timing in ('today','tomorrow')
     and status <> 'done'
     and archived = false;
  get diagnostics moved = row_count;
  raise notice 'weekly_today_rollover moved % task(s)', moved;
  return moved;
end;
$function$;

-- The real guard behind the "corrected meals" feature. The column-level GRANT
-- the old docs describe is a no-op — Supabase's stock grants already give
-- `authenticated` UPDATE on every column — so this trigger is the only thing
-- stopping a browser session from overwriting synced data.
--
-- NOTE: `drinks`, `has_creatine` and `has_pumpkin_seeds` were added to
-- food_log_entries after this function was written and are NOT pinned below.
-- The sync writes all three, so an authenticated client can currently clobber
-- them. Add them to the pin list when touching this.
create or replace function public.food_log_entries_guard_client_update()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  -- service_role runs the sync and may write anything. An authenticated browser
  -- session may only move eaten_at_override / is_cooked_override; every other
  -- column is pinned to its old value.
  if current_setting('request.jwt.claims', true) is null
     or coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') <> 'authenticated' then
    return new;
  end if;
  new.id                := old.id;
  new.user_id           := old.user_id;
  new.notion_page_id    := old.notion_page_id;
  new.name              := old.name;
  new.eaten_at          := old.eaten_at;
  new.meal_type         := old.meal_type;
  new.source            := old.source;
  new.calories          := old.calories;
  new.protein_g         := old.protein_g;
  new.carbs_g           := old.carbs_g;
  new.fat_g             := old.fat_g;
  new.is_non_profile    := old.is_non_profile;
  new.is_dcp            := old.is_dcp;
  new.is_cooked         := old.is_cooked;
  new.source_updated_at := old.source_updated_at;
  new.synced_at         := old.synced_at;
  return new;
end;
$function$;

-- garmin_sync.py writes through these rather than PostgREST: each takes the
-- whole batch as one jsonb argument, so a day's sync is one round trip and one
-- transaction. SECURITY DEFINER because they fill user_id from the table
-- default rather than trusting the caller.

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
    -- coalesce, not overwrite: Garmin reports weight only on days the scale
    -- synced, and a null there must not erase the last real reading.
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

create or replace function public.garmin_upsert_activities(rows jsonb)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
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
end $function$;

create or replace function public.garmin_upsert_samples(rows jsonb)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
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
end $function$;

-- ============================================================ views
-- Dependency order: leaf views first, weekly_master last.

create or replace view public.readwise_weekly as
 SELECT user_id,
    date_trunc('week'::text, calendar_date::timestamp with time zone)::date AS week_start,
    sum(highlight_count)::integer AS highlights,
    count(DISTINCT book_id) FILTER (WHERE category = 'articles'::text AND NOT is_youtube)::integer AS distinct_articles,
    count(DISTINCT book_id) FILTER (WHERE category = 'podcasts'::text OR is_youtube)::integer AS distinct_podcasts_videos,
    count(DISTINCT book_id) FILTER (WHERE category = 'books'::text)::integer AS distinct_books,
    count(DISTINCT book_id)::integer AS distinct_sources
   FROM readwise_daily
  GROUP BY user_id, (date_trunc('week'::text, calendar_date::timestamp with time zone)::date);

create or replace view public.bodyspec_scan_deltas as
 SELECT user_id,
    scan_date,
    lag(scan_date) OVER w AS prev_scan_date,
    total_mass_lb,
    fat_mass_lb,
    lean_mass_lb,
    body_fat_pct,
    vat_mass_lb,
    total_mass_lb - lag(total_mass_lb) OVER w AS total_mass_change_lb,
    fat_mass_lb - lag(fat_mass_lb) OVER w AS fat_mass_change_lb,
    lean_mass_lb - lag(lean_mass_lb) OVER w AS lean_mass_change_lb,
    body_fat_pct - lag(body_fat_pct) OVER w AS body_fat_pct_change,
    vat_mass_lb - lag(vat_mass_lb) OVER w AS vat_mass_change_lb,
    r_leg_lean_lb - l_leg_lean_lb AS leg_lean_asymmetry_lb
   FROM bodyspec_scans
  WINDOW w AS (PARTITION BY user_id ORDER BY scan_date);

create or replace view public.garmin_respiration_weekly as
 SELECT user_id,
    date_trunc('week'::text, calendar_date::timestamp without time zone)::date AS week,
    round(avg(resp_waking_avg), 1) AS resp_waking_avg,
    round(avg(resp_sleep_avg), 1) AS resp_sleep_avg,
    round(avg(resp_lowest), 1) AS resp_lowest
   FROM garmin_daily
  WHERE resp_waking_avg IS NOT NULL OR resp_sleep_avg IS NOT NULL
  GROUP BY user_id, (date_trunc('week'::text, calendar_date::timestamp without time zone)::date);

-- Per-second respiration samples collapsed to one row per breathwork session.
create or replace view public.garmin_breath_zones as
 SELECT a.activity_id,
    s.user_id,
    a.activity_name,
    a.activity_type,
    a.start_time_local,
    a.calendar_date,
    count(*) AS samples,
    count(*) FILTER (WHERE s.respiration_rate <= 5.5) AS sec_at_5_5,
    count(*) FILTER (WHERE s.respiration_rate <= 6::numeric) AS sec_at_6,
    count(*) FILTER (WHERE s.respiration_rate <= 8::numeric) AS sec_at_8,
    round(100.0 * count(*) FILTER (WHERE s.respiration_rate <= 8::numeric)::numeric / NULLIF(count(*), 0)::numeric) AS pct_at_8,
    round(min(s.respiration_rate), 1) AS lowest_rate,
    round(avg(s.respiration_rate) FILTER (WHERE s.offset_seconds >= 60), 1) AS rate_after_60s,
    min(s.offset_seconds) FILTER (WHERE s.respiration_rate <= 8::numeric) AS settle_seconds,
    round(avg(s.heart_rate) FILTER (WHERE s.offset_seconds < 60)) AS hr_first_min,
    round(avg(s.heart_rate) FILTER (WHERE s.offset_seconds >= 60)) AS hr_after_60s
   FROM garmin_activity_samples s
     JOIN garmin_activities a USING (activity_id)
  WHERE s.respiration_rate IS NOT NULL
  GROUP BY a.activity_id, s.user_id, a.activity_name, a.activity_type, a.start_time_local, a.calendar_date;

create or replace view public.garmin_breath_weekly as
 SELECT user_id,
    date_trunc('week'::text, start_time_local)::date AS week,
    count(*) FILTER (WHERE activity_type = 'breathwork'::text) AS breathwork_sessions,
    count(*) FILTER (WHERE activity_type = ANY (ARRAY['meditation'::text, 'mindfulness'::text])) AS meditation_sessions,
    round(sum(sec_at_8) / 60.0, 1) AS mins_under_8,
    round(sum(sec_at_6) / 60.0, 1) AS mins_under_6,
    round(min(rate_after_60s), 1) AS best_settled_rate,
    round(avg(rate_after_60s), 1) AS avg_settled_rate,
    round(avg(settle_seconds)) AS avg_settle_seconds,
    count(*) AS total_sessions
   FROM garmin_breath_zones
  GROUP BY user_id, (date_trunc('week'::text, start_time_local)::date);

-- The eating day runs 04:00 -> 03:59 local, hence the '- 4 hours' before the
-- date cast: a 00:30 snack closes the night before rather than opening the
-- next day. EATING_DAY_START_MIN in sync/food_sync.py, web/index.html and
-- web/scriptable/agentos-food.js must agree with this or the charts and the
-- drill-down disagree about which day a late meal belongs to.
-- Date-only Notion entries arrive as UTC midnight and are bucketed as-is
-- rather than guessed into a local day.
create or replace view public.food_meals as
 WITH e AS (
         SELECT f.user_id,
            COALESCE(f.eaten_at_override, f.eaten_at) AS at,
            f.meal_type,
            f.calories,
            f.protein_g,
            f.carbs_g,
            f.fat_g,
            f.is_dcp,
            f.drinks,
            f.name
           FROM food_log_entries f
          WHERE COALESCE(f.eaten_at_override, f.eaten_at) IS NOT NULL
        )
 SELECT user_id,
        CASE
            WHEN (at AT TIME ZONE 'UTC'::text)::time without time zone = '00:00:00'::time without time zone THEN (at AT TIME ZONE 'UTC'::text)::date
            ELSE ((at AT TIME ZONE 'America/Los_Angeles'::text) - '04:00:00'::interval)::date
        END AS eating_day,
    meal_type,
    count(*) AS entries,
    string_agg(name, ' | '::text ORDER BY at) AS items,
    sum(calories) AS calories,
    sum(protein_g) AS protein_g,
    sum(carbs_g) AS carbs_g,
    sum(fat_g) AS fat_g,
    round(100::numeric * sum(protein_g) * 4::numeric / NULLIF(sum(calories), 0::numeric), 1) AS protein_pct,
    (sum(protein_g) * 4::numeric / NULLIF(sum(calories), 0::numeric)) < 0.25 AS is_non_profile,
    bool_or(is_dcp) AS is_dcp,
    sum(drinks) AS drinks
   FROM e
  GROUP BY user_id, (
        CASE
            WHEN (at AT TIME ZONE 'UTC'::text)::time without time zone = '00:00:00'::time without time zone THEN (at AT TIME ZONE 'UTC'::text)::date
            ELSE ((at AT TIME ZONE 'America/Los_Angeles'::text) - '04:00:00'::interval)::date
        END), meal_type;

-- Nights under 3h are dropped as non-sleep (naps, a ring worn for an hour),
-- not averaged in. A null total_sleep_hours is kept — that is a missing
-- measurement, not a short night.
create or replace view public.oura_weekly as
 WITH days AS (
         SELECT oura_daily.user_id,
            oura_daily.calendar_date,
            oura_daily.sleep_score,
            oura_daily.total_sleep_hours,
            oura_daily.average_hrv,
            oura_daily.lowest_heart_rate,
            oura_daily.average_breath,
            oura_daily.latency_minutes,
            oura_daily.sleep_time,
            oura_daily.wake_time,
            oura_daily.sleep_time_mins,
            oura_daily.wake_time_mins,
            oura_daily.bedtime_start,
            oura_daily.bedtime_end,
            oura_daily.oura_sleep_id,
            oura_daily.raw,
            oura_daily.synced_at
           FROM oura_daily
          WHERE oura_daily.total_sleep_hours IS NULL OR oura_daily.total_sleep_hours >= 3::numeric
        ), agg AS (
         SELECT days.user_id,
            date_trunc('week'::text, days.calendar_date::timestamp with time zone)::date AS week_start,
            round(avg(days.total_sleep_hours), 2) AS slp_hrs,
            round(avg(days.sleep_score), 2) AS slp_score,
            round(avg(days.average_hrv), 2) AS slp_hrv,
            round(avg(days.lowest_heart_rate), 2) AS rhr,
            round(avg(days.average_breath), 2) AS breath_rate,
            round(avg(days.latency_minutes), 2) AS slp_latency,
            round(avg(days.sleep_time_mins) FILTER (WHERE days.sleep_time_mins IS NOT NULL))::integer AS avg_sleep_time_mins,
            round(avg(days.wake_time_mins) FILTER (WHERE days.wake_time_mins IS NOT NULL))::integer AS avg_wake_time_mins,
            count(*)::integer AS nights
           FROM days
          GROUP BY days.user_id, (date_trunc('week'::text, days.calendar_date::timestamp with time zone)::date)
        )
 SELECT user_id,
    week_start,
    slp_hrs,
    slp_score,
    slp_hrv,
    rhr,
    breath_rate,
    slp_latency,
    avg_sleep_time_mins,
    avg_wake_time_mins,
        CASE
            WHEN avg_sleep_time_mins IS NULL THEN NULL::text
            ELSE (lpad((avg_sleep_time_mins % 1440 / 60)::text, 2, '0'::text) || ':'::text) || lpad((avg_sleep_time_mins % 60)::text, 2, '0'::text)
        END AS avg_sleep_time,
        CASE
            WHEN avg_wake_time_mins IS NULL THEN NULL::text
            ELSE (lpad((avg_wake_time_mins / 60)::text, 2, '0'::text) || ':'::text) || lpad((avg_wake_time_mins % 60)::text, 2, '0'::text)
        END AS avg_wake_time,
    nights
   FROM agg;

-- Oura and Garmin both measure sleep; Oura wins any night both saw. The FULL
-- JOIN is what lets a Garmin-only night (ring off the charger) still show up.
-- Garmin has no latency equivalent, so that column is null on those nights.
create or replace view public.sleep_daily as
 WITH o AS (
         SELECT oura_daily.user_id,
            oura_daily.calendar_date,
            oura_daily.sleep_score,
            oura_daily.total_sleep_hours,
            oura_daily.average_hrv,
            oura_daily.lowest_heart_rate,
            oura_daily.average_breath,
            oura_daily.latency_minutes,
            oura_daily.sleep_time,
            oura_daily.wake_time,
            oura_daily.sleep_time_mins,
            oura_daily.wake_time_mins,
            oura_daily.bedtime_start,
            oura_daily.bedtime_end
           FROM oura_daily
          WHERE oura_daily.total_sleep_hours IS NULL OR oura_daily.total_sleep_hours >= 3::numeric
        ), g AS (
         SELECT s.user_id,
            s.calendar_date,
            s.sleep_score,
            s.total_sleep_hours,
            d.hrv_last_night_avg AS average_hrv,
                CASE
                    WHEN d.min_heart_rate >= 40 THEN d.min_heart_rate
                    ELSE NULL::integer
                END AS lowest_heart_rate,
            s.average_breath,
            NULL::numeric AS latency_minutes,
            s.sleep_time,
            s.wake_time,
            s.sleep_time_mins,
            s.wake_time_mins,
            s.bedtime_start,
            s.bedtime_end,
            s.deep_sleep_seconds,
            s.light_sleep_seconds,
            s.rem_sleep_seconds
           FROM garmin_sleep_daily s
             LEFT JOIN garmin_daily d ON d.user_id = s.user_id AND d.calendar_date = s.calendar_date
          WHERE s.total_sleep_hours >= 3::numeric
        )
 SELECT COALESCE(o.user_id, g.user_id) AS user_id,
    COALESCE(o.calendar_date, g.calendar_date) AS calendar_date,
        CASE
            WHEN o.calendar_date IS NOT NULL THEN 'oura'::text
            ELSE 'garmin'::text
        END AS source,
    o.calendar_date IS NOT NULL AS has_oura,
    g.calendar_date IS NOT NULL AS has_garmin,
        CASE
            WHEN o.calendar_date IS NOT NULL THEN o.sleep_score
            ELSE g.sleep_score::numeric
        END AS sleep_score,
        CASE
            WHEN o.calendar_date IS NOT NULL THEN o.total_sleep_hours
            ELSE g.total_sleep_hours
        END AS total_sleep_hours,
        CASE
            WHEN o.calendar_date IS NOT NULL THEN o.average_hrv
            ELSE g.average_hrv::numeric
        END AS average_hrv,
        CASE
            WHEN o.calendar_date IS NOT NULL THEN o.lowest_heart_rate
            ELSE g.lowest_heart_rate::numeric
        END AS lowest_heart_rate,
        CASE
            WHEN o.calendar_date IS NOT NULL THEN o.average_breath
            ELSE g.average_breath
        END AS average_breath,
        CASE
            WHEN o.calendar_date IS NOT NULL THEN o.latency_minutes
            ELSE g.latency_minutes
        END AS latency_minutes,
        CASE
            WHEN o.calendar_date IS NOT NULL THEN o.sleep_time
            ELSE g.sleep_time
        END AS sleep_time,
        CASE
            WHEN o.calendar_date IS NOT NULL THEN o.wake_time
            ELSE g.wake_time
        END AS wake_time,
        CASE
            WHEN o.calendar_date IS NOT NULL THEN o.sleep_time_mins
            ELSE g.sleep_time_mins
        END AS sleep_time_mins,
        CASE
            WHEN o.calendar_date IS NOT NULL THEN o.wake_time_mins
            ELSE g.wake_time_mins
        END AS wake_time_mins,
        CASE
            WHEN o.calendar_date IS NOT NULL THEN o.bedtime_start
            ELSE g.bedtime_start
        END AS bedtime_start,
        CASE
            WHEN o.calendar_date IS NOT NULL THEN o.bedtime_end
            ELSE g.bedtime_end
        END AS bedtime_end,
    g.deep_sleep_seconds,
    g.light_sleep_seconds,
    g.rem_sleep_seconds
   FROM o
     FULL JOIN g ON g.user_id = o.user_id AND g.calendar_date = o.calendar_date;

-- sleep_source tells the dashboard whether a week's averages are comparable
-- to the ones either side of it: 'mixed' weeks blend two devices' scoring.
create or replace view public.sleep_weekly as
 WITH agg AS (
         SELECT sleep_daily.user_id,
            date_trunc('week'::text, sleep_daily.calendar_date::timestamp with time zone)::date AS week_start,
            round(avg(sleep_daily.total_sleep_hours), 2) AS slp_hrs,
            round(avg(sleep_daily.sleep_score), 2) AS slp_score,
            round(avg(sleep_daily.average_hrv), 2) AS slp_hrv,
            round(avg(sleep_daily.lowest_heart_rate), 2) AS rhr,
            round(avg(sleep_daily.average_breath), 2) AS breath_rate,
            round(avg(sleep_daily.latency_minutes), 2) AS slp_latency,
            round(avg(sleep_daily.sleep_time_mins) FILTER (WHERE sleep_daily.sleep_time_mins IS NOT NULL))::integer AS avg_sleep_time_mins,
            round(avg(sleep_daily.wake_time_mins) FILTER (WHERE sleep_daily.wake_time_mins IS NOT NULL))::integer AS avg_wake_time_mins,
            count(*)::integer AS nights,
            count(*) FILTER (WHERE sleep_daily.source = 'oura'::text)::integer AS nights_oura,
            count(*) FILTER (WHERE sleep_daily.source = 'garmin'::text)::integer AS nights_garmin
           FROM sleep_daily
          GROUP BY sleep_daily.user_id, (date_trunc('week'::text, sleep_daily.calendar_date::timestamp with time zone)::date)
        )
 SELECT user_id,
    week_start,
    slp_hrs,
    slp_score,
    slp_hrv,
    rhr,
    breath_rate,
    slp_latency,
    avg_sleep_time_mins,
    avg_wake_time_mins,
        CASE
            WHEN avg_sleep_time_mins IS NULL THEN NULL::text
            ELSE (lpad((avg_sleep_time_mins % 1440 / 60)::text, 2, '0'::text) || ':'::text) || lpad((avg_sleep_time_mins % 60)::text, 2, '0'::text)
        END AS avg_sleep_time,
        CASE
            WHEN avg_wake_time_mins IS NULL THEN NULL::text
            ELSE (lpad((avg_wake_time_mins / 60)::text, 2, '0'::text) || ':'::text) || lpad((avg_wake_time_mins % 60)::text, 2, '0'::text)
        END AS avg_wake_time,
    nights,
    nights_oura,
    nights_garmin,
        CASE
            WHEN nights_garmin = 0 THEN 'oura'::text
            WHEN nights_oura = 0 THEN 'garmin'::text
            ELSE 'mixed'::text
        END AS sleep_source
   FROM agg;

-- The >= 1500 kcal and NOT is_partial filters exclude days the watch was off
-- or only half worn, which would otherwise drag TDEE down. step_count uses a
-- median rather than a mean for the same reason: one 400-step day shouldn't
-- move the week. adjusted_tdee is garmin_tdee * 0.90 — Garmin's TDEE reads
-- consistently high against measured intake.
create or replace view public.garmin_weekly as
 WITH days AS (
         SELECT garmin_daily.user_id,
            date_trunc('week'::text, garmin_daily.calendar_date::timestamp with time zone)::date AS week_start,
            garmin_daily.total_kilocalories,
            garmin_daily.total_steps,
            garmin_daily.intensity_minutes,
            garmin_daily.avg_stress_level,
            garmin_daily.weight_lbs,
            garmin_daily.body_fat_pct,
            garmin_daily.is_partial,
            garmin_daily.includes_wellness_data
           FROM garmin_daily
        ), day_agg AS (
         SELECT days.user_id,
            days.week_start,
            round(avg(days.total_kilocalories) FILTER (WHERE NOT days.is_partial AND days.total_kilocalories >= 1500)) AS garmin_tdee,
            round(percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (days.total_steps::double precision)) FILTER (WHERE NOT days.is_partial AND days.total_kilocalories >= 1500)::numeric) AS step_count,
            sum(days.intensity_minutes) FILTER (WHERE days.includes_wellness_data) AS intensity_minutes,
            round(avg(days.avg_stress_level)) AS stress_level,
            round(avg(days.weight_lbs), 1) AS weekly_weight,
            round(avg(days.body_fat_pct), 1) AS body_fat_pct,
            count(*) FILTER (WHERE days.includes_wellness_data AND NOT days.is_partial) AS full_days,
            count(*) FILTER (WHERE days.is_partial) AS partial_days,
            round(avg(days.total_kilocalories) FILTER (WHERE NOT days.is_partial AND days.total_kilocalories >= 1500) * 0.90) AS adjusted_tdee
           FROM days
          GROUP BY days.user_id, days.week_start
        ), act_agg AS (
         SELECT garmin_activities.user_id,
            date_trunc('week'::text, garmin_activities.calendar_date::timestamp with time zone)::date AS week_start,
            sum(garmin_activities.duration_seconds) FILTER (WHERE garmin_activities.activity_type <> ALL (ARRAY['meditation'::text, 'mindfulness'::text, 'breathwork'::text])) / 3600.0 AS training_hours,
            sum(garmin_activities.duration_seconds) FILTER (WHERE garmin_activities.activity_type ~~ '%strength%'::text) / 60.0 AS strength_minutes,
            sum(garmin_activities.distance_meters) FILTER (WHERE garmin_activities.activity_type ~~ '%swim%'::text) * 1.09361 AS swim_yards,
            sum(garmin_activities.distance_meters) FILTER (WHERE garmin_activities.activity_type ~~ '%run%'::text) / 1609.34 AS run_miles,
            sum(garmin_activities.distance_meters) FILTER (WHERE garmin_activities.activity_type ~ '(cycling|biking|ride)'::text) / 1609.34 AS bike_miles,
            count(*) FILTER (WHERE garmin_activities.activity_type = ANY (ARRAY['meditation'::text, 'mindfulness'::text, 'breathwork'::text])) AS meditation_sessions
           FROM garmin_activities
          GROUP BY garmin_activities.user_id, (date_trunc('week'::text, garmin_activities.calendar_date::timestamp with time zone)::date)
        )
 SELECT COALESCE(d.user_id, a.user_id) AS user_id,
    COALESCE(d.week_start, a.week_start) AS week_start,
    d.garmin_tdee,
    d.step_count,
    d.intensity_minutes,
    d.stress_level,
    d.weekly_weight,
    d.body_fat_pct,
    round(COALESCE(a.training_hours, 0::numeric), 2) AS training_hours,
    round(COALESCE(a.strength_minutes, 0::numeric)) AS strength_minutes,
    round(COALESCE(a.swim_yards, 0::numeric)) AS swim_yards,
    round(COALESCE(a.run_miles, 0::numeric), 2) AS run_miles,
    round(COALESCE(a.bike_miles, 0::numeric), 2) AS bike_miles,
    COALESCE(a.meditation_sessions, 0::bigint) AS meditation_sessions,
    COALESCE(d.full_days, 0::bigint) AS full_days,
    COALESCE(d.partial_days, 0::bigint) AS partial_days,
    d.adjusted_tdee
   FROM day_agg d
     FULL JOIN act_agg a ON a.user_id = d.user_id AND a.week_start = d.week_start;

-- Where did the 168 hours go. Sleep from Oura, the rest from Vimcal tags plus
-- the inferred jsonb layer; fitness is reconciled (Garmin duration where an
-- activity matches a calendar block, calendar duration where Garmin saw
-- nothing). unaccounted_hrs is the residual — the gaps between blocks.
create or replace view public.week_time_budget as
 SELECT c.user_id,
    c.week_start,
    168::numeric AS denominator_hrs,
    o.slp_hrs AS sleep_hrs,
    c.work_hrs,
    COALESCE((c.inferred #>> '{reconciled,fitness_hrs}'::text[])::numeric, c.fitness_hrs) AS fitness_hrs,
    c.fitness_hrs AS fitness_hrs_tagged,
    g.training_hours AS fitness_hrs_garmin,
    c.social_hrs + COALESCE((c.inferred #>> '{adds,social,hrs}'::text[])::numeric, 0::numeric) AS social_hrs,
    c.personal_hrs + COALESCE((c.inferred #>> '{adds,personal,hrs}'::text[])::numeric, 0::numeric) AS personal_hrs,
    c.commute_hrs,
    COALESCE((c.inferred #>> '{budget,unresolved_hrs}'::text[])::numeric, 0::numeric) AS unresolved_hrs,
    COALESCE(o.slp_hrs, 0::numeric) + COALESCE(c.work_hrs, 0::numeric) + COALESCE((c.inferred #>> '{reconciled,fitness_hrs}'::text[])::numeric, c.fitness_hrs, 0::numeric) + COALESCE(c.social_hrs, 0::numeric) + COALESCE((c.inferred #>> '{adds,social,hrs}'::text[])::numeric, 0::numeric) + COALESCE(c.personal_hrs, 0::numeric) + COALESCE((c.inferred #>> '{adds,personal,hrs}'::text[])::numeric, 0::numeric) + COALESCE(c.commute_hrs, 0::numeric) + COALESCE((c.inferred #>> '{budget,unresolved_hrs}'::text[])::numeric, 0::numeric) AS accounted_hrs,
    168::numeric - (COALESCE(o.slp_hrs, 0::numeric) + COALESCE(c.work_hrs, 0::numeric) + COALESCE((c.inferred #>> '{reconciled,fitness_hrs}'::text[])::numeric, c.fitness_hrs, 0::numeric) + COALESCE(c.social_hrs, 0::numeric) + COALESCE((c.inferred #>> '{adds,social,hrs}'::text[])::numeric, 0::numeric) + COALESCE(c.personal_hrs, 0::numeric) + COALESCE((c.inferred #>> '{adds,personal,hrs}'::text[])::numeric, 0::numeric) + COALESCE(c.commute_hrs, 0::numeric) + COALESCE((c.inferred #>> '{budget,unresolved_hrs}'::text[])::numeric, 0::numeric)) AS unaccounted_hrs,
    o.nights AS sleep_nights,
    c.inferred IS NOT NULL AS has_semantic_layer
   FROM calendar_weekly c
     LEFT JOIN oura_weekly o ON o.user_id = c.user_id AND o.week_start = c.week_start
     LEFT JOIN garmin_weekly g ON g.user_id = c.user_id AND g.week_start = c.week_start;

-- Weekly food rollup. Three guards worth knowing before changing anything:
--   * The current (incomplete) eating day is excluded from the per-day
--     averages via `eating_day < today`, so a week in progress is not dragged
--     down by a day that has only had breakfast.
--   * Weeks averaging under 900 kcal/day are treated as unlogged, not as a
--     fast: the intake columns go null rather than reporting a wrong number.
--   * Meal timing needs >= 3 timed days, otherwise one 20:00 meal reads as a
--     20:00 first meal and a 0-hour eating window.
-- cooked_meals uses coalesce(is_cooked_override, is_cooked) — see the override
-- notes in CLAUDE.md. non_profile_pct is over a fixed 28 (4 meals x 7 days),
-- not over meals actually logged.
create or replace view public.food_weekly as
 WITH meals AS (
         SELECT f.user_id,
            COALESCE(f.eaten_at_override, f.eaten_at) AS at,
            (COALESCE(f.eaten_at_override, f.eaten_at) AT TIME ZONE 'UTC'::text)::time without time zone = '00:00:00'::time without time zone AS date_only,
            f.calories,
            f.protein_g,
            f.carbs_g,
            f.fat_g,
            f.is_non_profile,
            f.is_dcp,
            COALESCE(f.is_cooked_override, f.is_cooked) AS is_cooked,
            f.drinks,
            f.has_creatine,
            f.has_pumpkin_seeds
           FROM food_log_entries f
          WHERE COALESCE(f.eaten_at_override, f.eaten_at) IS NOT NULL
        ), slotted AS (
         SELECT m.user_id,
            m.at,
            m.date_only,
            m.calories,
            m.protein_g,
            m.carbs_g,
            m.fat_g,
            m.is_non_profile,
            m.is_dcp,
            m.is_cooked,
            m.drinks,
            m.has_creatine,
            m.has_pumpkin_seeds,
                CASE
                    WHEN m.date_only THEN (m.at AT TIME ZONE 'UTC'::text)::date
                    ELSE ((m.at AT TIME ZONE 'America/Los_Angeles'::text) - '04:00:00'::interval)::date
                END AS eating_day,
                CASE
                    WHEN m.date_only THEN NULL::numeric
                    ELSE EXTRACT(epoch FROM ((m.at AT TIME ZONE 'America/Los_Angeles'::text) - '04:00:00'::interval)::time without time zone) / 60::numeric + 240::numeric
                END AS minutes
           FROM meals m
        ), today AS (
         SELECT ((now() AT TIME ZONE 'America/Los_Angeles'::text) - '04:00:00'::interval)::date AS eating_day
        ), days AS (
         SELECT s.user_id,
            s.eating_day,
            min(s.minutes) AS first_mins,
            max(s.minutes) AS last_mins
           FROM slotted s
          GROUP BY s.user_id, s.eating_day
        ), timing AS (
         SELECT d.user_id,
            date_trunc('week'::text, d.eating_day::timestamp with time zone)::date AS week_start,
            count(*) AS meal_days,
            count(d.first_mins) AS timed_days,
            round(avg(d.first_mins), 1) AS first_meal_mins,
            round(avg(d.last_mins), 1) AS last_meal_mins,
            round(avg(d.last_mins - d.first_mins) / 60::numeric, 2) AS eating_window_hrs
           FROM days d
          GROUP BY d.user_id, (date_trunc('week'::text, d.eating_day::timestamp with time zone)::date)
        ), meal_np AS (
         SELECT fm.user_id,
            date_trunc('week'::text, fm.eating_day::timestamp with time zone)::date AS week_start,
            count(*) FILTER (WHERE fm.is_non_profile AND (fm.meal_type = ANY (ARRAY['Breakfast'::text, 'Lunch'::text, 'Dinner'::text, 'Snack'::text]))) AS non_profile_meals
           FROM food_meals fm
          GROUP BY fm.user_id, (date_trunc('week'::text, fm.eating_day::timestamp with time zone)::date)
        ), intake AS (
         SELECT s.user_id,
            date_trunc('week'::text, s.eating_day::timestamp with time zone)::date AS week_start,
            count(*) AS total_meals,
            count(*) FILTER (WHERE s.is_cooked) AS cooked_meals,
            count(*) FILTER (WHERE s.is_dcp) AS dcp_meals,
            sum(s.drinks) AS drinks,
            sum(s.calories) FILTER (WHERE s.eating_day < t_1.eating_day) AS complete_cals,
            sum(s.protein_g) FILTER (WHERE s.eating_day < t_1.eating_day) AS complete_protein,
            sum(s.carbs_g) FILTER (WHERE s.eating_day < t_1.eating_day) AS complete_carbs,
            sum(s.fat_g) FILTER (WHERE s.eating_day < t_1.eating_day) AS complete_fat,
            LEAST(7, GREATEST(0, t_1.eating_day - date_trunc('week'::text, s.eating_day::timestamp with time zone)::date)) AS complete_days,
            count(DISTINCT s.eating_day) FILTER (WHERE s.has_creatine) AS creatine_days,
            count(DISTINCT s.eating_day) FILTER (WHERE s.has_pumpkin_seeds) AS pumpkin_seed_days
           FROM slotted s
             CROSS JOIN today t_1
          GROUP BY s.user_id, (date_trunc('week'::text, s.eating_day::timestamp with time zone)::date), t_1.eating_day
        ), averaged AS (
         SELECT i.user_id,
            i.week_start,
            i.total_meals,
            i.cooked_meals,
            COALESCE(np.non_profile_meals, 0::bigint) AS non_profile_meals,
            i.dcp_meals,
            i.drinks,
            i.complete_cals,
            i.complete_protein,
            i.complete_carbs,
            i.complete_fat,
            i.complete_days,
            round(i.complete_cals / NULLIF(i.complete_days, 0)::numeric) AS consumed_cals,
            round(i.complete_protein / NULLIF(i.complete_days, 0)::numeric) AS avg_protein,
            round(i.complete_carbs / NULLIF(i.complete_days, 0)::numeric) AS avg_carbs,
            round(i.complete_fat / NULLIF(i.complete_days, 0)::numeric) AS avg_fat,
            i.creatine_days,
            i.pumpkin_seed_days
           FROM intake i
             LEFT JOIN meal_np np ON np.user_id = i.user_id AND np.week_start = i.week_start
        )
 SELECT a.user_id,
    a.week_start,
        CASE
            WHEN a.consumed_cals >= 900::numeric THEN a.consumed_cals
            ELSE NULL::numeric
        END AS consumed_cals,
        CASE
            WHEN a.consumed_cals >= 900::numeric THEN a.avg_protein
            ELSE NULL::numeric
        END AS avg_protein,
        CASE
            WHEN a.consumed_cals >= 900::numeric THEN a.avg_carbs
            ELSE NULL::numeric
        END AS avg_carbs,
        CASE
            WHEN a.consumed_cals >= 900::numeric THEN a.avg_fat
            ELSE NULL::numeric
        END AS avg_fat,
        CASE
            WHEN a.consumed_cals >= 900::numeric THEN a.non_profile_meals
            ELSE NULL::bigint
        END AS non_profile_meals,
        CASE
            WHEN a.consumed_cals >= 900::numeric THEN a.dcp_meals
            ELSE NULL::bigint
        END AS dcp_meals,
        CASE
            WHEN a.consumed_cals >= 900::numeric THEN a.drinks
            ELSE NULL::numeric
        END AS drinks,
    a.cooked_meals,
    a.total_meals,
    t.meal_days,
        CASE
            WHEN t.timed_days >= 3 THEN t.first_meal_mins
            ELSE NULL::numeric
        END AS first_meal_mins,
        CASE
            WHEN t.timed_days >= 3 THEN t.last_meal_mins
            ELSE NULL::numeric
        END AS last_meal_mins,
        CASE
            WHEN t.timed_days >= 3 THEN t.eating_window_hrs
            ELSE NULL::numeric
        END AS eating_window_hrs,
    a.complete_days AS intake_days,
    a.creatine_days,
    a.pumpkin_seed_days,
    round(100.0 * a.non_profile_meals::numeric / 28::numeric) AS non_profile_pct
   FROM averaged a
     JOIN timing t ON t.user_id = a.user_id AND t.week_start = a.week_start;

-- The dashboard's single read surface: one row per user per week, every metric
-- resolved from its live source with legacy_notion_table as the fallback for
-- weeks predating that source's own table. Two fallback idioms appear, and the
-- difference matters:
--   COALESCE(live, legacy)              -- used where a null means "no data"
--   CASE WHEN <source>_week IS NOT NULL -- used where the source covers the
--                                          week but the value is legitimately
--                                          null (e.g. an unlogged food week)
-- Using COALESCE for the second case would resurrect a stale legacy number on
-- top of a week the live source has already answered for.
create or replace view public.weekly_master as
 WITH wm_base AS (
         WITH spine AS (
                 SELECT legacy_notion_table.user_id,
                    legacy_notion_table.week
                   FROM legacy_notion_table
                UNION
                 SELECT journal_entries.user_id,
                    journal_entries.week
                   FROM journal_entries
                UNION
                 SELECT screentime_weekly.user_id,
                    screentime_weekly.week_start
                   FROM screentime_weekly
                UNION
                 SELECT calendar_weekly.user_id,
                    calendar_weekly.week_start
                   FROM calendar_weekly
                ), resolved AS (
                 SELECT s.user_id,
                    s.week,
                    l.slp_hrs_legacy,
                    l.slp_score_legacy,
                    l.slp_hrv_legacy,
                    l.rhr_legacy,
                    l.avg_sleep_time_legacy,
                    l.avg_wake_time_legacy,
                    l.highlights_legacy,
                    l.articles_legacy,
                    l.podcasts_legacy,
                    l.run_miles_legacy,
                    l.bike_miles_legacy,
                    l.swim_yards_legacy,
                    l.strength_mins_legacy,
                    l.intensity_mins_legacy,
                    l.step_count_legacy,
                    l.training_hrs_legacy,
                    l.body_fat_legacy,
                    l.weekly_weight_legacy,
                    l.stress_legacy,
                    l.meditation_legacy,
                    l.consumed_cals_legacy,
                    l.avg_protein_legacy,
                    l.calorie_deficit_legacy,
                    l.non_profile_meals_legacy,
                    l.dcp_meals_legacy,
                    l.cooked_meals_legacy,
                    l.total_meals_legacy,
                    l.first_meal_mins_legacy,
                    l.last_meal_mins_legacy,
                    l.eating_window_hrs_legacy,
                    l.meal_days_legacy,
                    l.drinks_legacy,
                    COALESCE(j.notion_page_id, l.notion_page_id) AS notion_page_id,
                    COALESCE(j.source_updated_at, l.source_updated_at) AS source_updated_at,
                    COALESCE(j.synced_at, l.synced_at) AS synced_at,
                    g.week_start AS g_week,
                    f.week_start AS f_week,
                        CASE
                            WHEN g.week_start IS NOT NULL THEN g.garmin_tdee
                            ELSE l.garmin_tdee_legacy
                        END AS tdee,
                    o.slp_hrs AS o_slp_hrs,
                    o.slp_score AS o_slp_score,
                    o.slp_hrv AS o_slp_hrv,
                    o.rhr AS o_rhr,
                    o.avg_sleep_time AS o_avg_sleep_time,
                    o.avg_wake_time AS o_avg_wake_time,
                    o.breath_rate,
                    o.slp_latency,
                    o.nights,
                    o.nights_oura,
                    o.avg_sleep_time_mins AS o_avg_sleep_time_mins,
                    o.avg_wake_time_mins AS o_avg_wake_time_mins,
                    o.nights_garmin,
                    o.sleep_source,
                    r.highlights AS r_highlights,
                    r.distinct_articles,
                    r.distinct_podcasts_videos,
                    r.distinct_books,
                    g.run_miles AS g_run_miles,
                    g.bike_miles AS g_bike_miles,
                    g.swim_yards AS g_swim_yards,
                    g.strength_minutes,
                    g.intensity_minutes,
                    g.step_count AS g_step_count,
                    g.training_hours,
                    g.body_fat_pct,
                    g.weekly_weight AS g_weekly_weight,
                    g.stress_level,
                    g.meditation_sessions,
                        CASE
                            WHEN g.week_start IS NOT NULL THEN g.adjusted_tdee
                            ELSE round(l.garmin_tdee_legacy * 0.90)
                        END AS adjusted_tdee,
                    g.full_days AS g_full_days,
                    g.partial_days AS g_partial_days,
                    f.consumed_cals AS f_consumed_cals,
                    f.avg_protein AS f_avg_protein,
                    f.avg_carbs AS f_avg_carbs,
                    f.avg_fat AS f_avg_fat,
                    f.non_profile_meals AS f_non_profile_meals,
                    f.dcp_meals AS f_dcp_meals,
                    f.cooked_meals AS f_cooked_meals,
                    f.total_meals AS f_total_meals,
                    f.first_meal_mins AS f_first_meal_mins,
                    f.last_meal_mins AS f_last_meal_mins,
                    f.eating_window_hrs AS f_eating_window_hrs,
                    f.meal_days AS f_meal_days,
                    f.drinks AS f_drinks,
                    p.total_pickups,
                    p.avg_daily_pickups,
                    c.focus_blocks_4h,
                    c.focus_blocks_3h,
                    c.focus_blocks_2h,
                    c.longest_focus_hrs,
                    c.free_workday_hrs,
                    c.work_meetings,
                    c.work_hrs,
                    c.social_events,
                    c.social_hrs,
                    c.fitness_events,
                    c.fitness_hrs,
                    c.personal_events,
                    c.personal_hrs,
                    c.commute_hrs,
                    c.flights,
                    c.untagged_events,
                    c.untagged_hrs
                   FROM spine s
                     LEFT JOIN legacy_notion_table l ON l.user_id = s.user_id AND l.week = s.week
                     LEFT JOIN journal_entries j ON j.user_id = s.user_id AND j.week = s.week
                     LEFT JOIN sleep_weekly o ON o.user_id = s.user_id AND o.week_start = s.week
                     LEFT JOIN readwise_weekly r ON r.user_id = s.user_id AND r.week_start = s.week
                     LEFT JOIN garmin_weekly g ON g.user_id = s.user_id AND g.week_start = s.week
                     LEFT JOIN food_weekly f ON f.user_id = s.user_id AND f.week_start = s.week
                     LEFT JOIN screentime_weekly p ON p.user_id = s.user_id AND p.week_start = s.week
                     LEFT JOIN calendar_weekly c ON c.user_id = s.user_id AND c.week_start = s.week
                )
         SELECT resolved.user_id,
            resolved.week,
            COALESCE(resolved.o_slp_hrs, resolved.slp_hrs_legacy) AS slp_hrs,
            COALESCE(resolved.o_slp_score, resolved.slp_score_legacy) AS slp_score,
            COALESCE(resolved.o_slp_hrv, resolved.slp_hrv_legacy) AS slp_hrv,
            COALESCE(resolved.o_rhr, resolved.rhr_legacy) AS rhr,
            COALESCE(resolved.o_avg_sleep_time, resolved.avg_sleep_time_legacy) AS avg_sleep_time,
            COALESCE(resolved.o_avg_wake_time, resolved.avg_wake_time_legacy) AS avg_wake_time,
            resolved.breath_rate,
            resolved.slp_latency,
            resolved.nights,
            resolved.nights_oura,
            COALESCE(resolved.o_avg_sleep_time_mins,
                CASE
                    WHEN resolved.avg_sleep_time_legacy ~ '^[0-9]{1,2}:[0-9]{2}$'::text THEN split_part(resolved.avg_sleep_time_legacy, ':'::text, 1)::integer * 60 + split_part(resolved.avg_sleep_time_legacy, ':'::text, 2)::integer +
                    CASE
                        WHEN split_part(resolved.avg_sleep_time_legacy, ':'::text, 1)::integer < 6 THEN 1440
                        ELSE 0
                    END
                    ELSE NULL::integer
                END) AS avg_sleep_time_mins,
            COALESCE(resolved.o_avg_wake_time_mins,
                CASE
                    WHEN resolved.avg_wake_time_legacy ~ '^[0-9]{1,2}:[0-9]{2}$'::text THEN split_part(resolved.avg_wake_time_legacy, ':'::text, 1)::integer * 60 + split_part(resolved.avg_wake_time_legacy, ':'::text, 2)::integer
                    ELSE NULL::integer
                END) AS avg_wake_time_mins,
            resolved.nights_garmin,
            resolved.sleep_source,
            COALESCE(resolved.r_highlights::numeric, resolved.highlights_legacy) AS highlights,
            COALESCE(resolved.distinct_articles::numeric, resolved.articles_legacy) AS articles,
            COALESCE(resolved.distinct_podcasts_videos::numeric, resolved.podcasts_legacy) AS podcasts,
            resolved.distinct_books,
                CASE
                    WHEN resolved.g_week IS NOT NULL THEN resolved.g_run_miles
                    ELSE resolved.run_miles_legacy
                END AS run_miles,
                CASE
                    WHEN resolved.g_week IS NOT NULL THEN resolved.g_bike_miles
                    ELSE resolved.bike_miles_legacy
                END AS bike_miles,
                CASE
                    WHEN resolved.g_week IS NOT NULL THEN resolved.g_swim_yards
                    ELSE resolved.swim_yards_legacy
                END AS swim_yards,
                CASE
                    WHEN resolved.g_week IS NOT NULL THEN resolved.strength_minutes
                    ELSE resolved.strength_mins_legacy
                END AS strength_mins,
                CASE
                    WHEN resolved.g_week IS NOT NULL THEN resolved.intensity_minutes::numeric
                    ELSE resolved.intensity_mins_legacy
                END AS intensity_mins,
                CASE
                    WHEN resolved.g_week IS NOT NULL THEN resolved.g_step_count
                    ELSE resolved.step_count_legacy
                END AS step_count,
                CASE
                    WHEN resolved.g_week IS NOT NULL THEN resolved.training_hours
                    ELSE resolved.training_hrs_legacy
                END AS training_hrs,
                CASE
                    WHEN resolved.g_week IS NOT NULL THEN resolved.body_fat_pct
                    ELSE resolved.body_fat_legacy
                END AS body_fat,
                CASE
                    WHEN resolved.g_week IS NOT NULL THEN resolved.g_weekly_weight
                    ELSE resolved.weekly_weight_legacy
                END AS weekly_weight,
                CASE
                    WHEN resolved.g_week IS NOT NULL THEN resolved.stress_level
                    ELSE resolved.stress_legacy
                END AS stress,
                CASE
                    WHEN resolved.g_week IS NOT NULL THEN resolved.meditation_sessions::numeric
                    ELSE resolved.meditation_legacy
                END AS meditation,
            resolved.total_pickups AS phone_pickups,
            resolved.avg_daily_pickups,
                CASE
                    WHEN resolved.f_week IS NOT NULL THEN resolved.f_consumed_cals
                    ELSE resolved.consumed_cals_legacy
                END AS consumed_cals,
                CASE
                    WHEN resolved.f_week IS NOT NULL THEN resolved.f_avg_protein
                    ELSE resolved.avg_protein_legacy
                END AS avg_protein,
            resolved.f_avg_carbs AS avg_carbs,
            resolved.f_avg_fat AS avg_fat,
                CASE
                    WHEN resolved.f_week IS NOT NULL THEN resolved.adjusted_tdee - resolved.f_consumed_cals
                    ELSE resolved.calorie_deficit_legacy
                END AS calorie_deficit,
            resolved.tdee AS garmin_tdee,
                CASE
                    WHEN resolved.f_week IS NOT NULL THEN resolved.f_non_profile_meals::numeric
                    ELSE resolved.non_profile_meals_legacy
                END AS non_profile_meals,
                CASE
                    WHEN resolved.f_week IS NOT NULL THEN resolved.f_dcp_meals::numeric
                    ELSE resolved.dcp_meals_legacy
                END AS dcp_meals,
                CASE
                    WHEN resolved.f_week IS NOT NULL THEN resolved.f_cooked_meals::numeric
                    ELSE resolved.cooked_meals_legacy
                END AS cooked_meals,
                CASE
                    WHEN resolved.f_week IS NOT NULL THEN resolved.f_total_meals::numeric
                    ELSE resolved.total_meals_legacy
                END AS total_meals,
                CASE
                    WHEN resolved.f_week IS NOT NULL THEN resolved.f_first_meal_mins
                    ELSE resolved.first_meal_mins_legacy
                END AS first_meal_mins,
                CASE
                    WHEN resolved.f_week IS NOT NULL THEN resolved.f_last_meal_mins
                    ELSE resolved.last_meal_mins_legacy
                END AS last_meal_mins,
                CASE
                    WHEN resolved.f_week IS NOT NULL THEN resolved.f_eating_window_hrs
                    ELSE resolved.eating_window_hrs_legacy
                END AS eating_window_hrs,
                CASE
                    WHEN resolved.f_week IS NOT NULL THEN resolved.f_meal_days::numeric
                    ELSE resolved.meal_days_legacy
                END AS meal_days,
                CASE
                    WHEN resolved.f_week IS NOT NULL THEN resolved.f_drinks
                    ELSE resolved.drinks_legacy
                END AS drinks,
            resolved.notion_page_id,
            resolved.source_updated_at,
            resolved.synced_at,
            resolved.adjusted_tdee,
            resolved.g_full_days AS garmin_full_days,
            resolved.g_partial_days AS garmin_partial_days,
            resolved.focus_blocks_4h,
            resolved.focus_blocks_3h,
            resolved.focus_blocks_2h,
            resolved.longest_focus_hrs,
            resolved.free_workday_hrs,
            resolved.work_meetings,
            resolved.work_hrs,
            resolved.social_events,
            resolved.social_hrs,
            resolved.fitness_events,
            resolved.fitness_hrs,
            resolved.personal_events,
            resolved.personal_hrs,
            resolved.commute_hrs,
            resolved.flights,
            resolved.untagged_events,
            resolved.untagged_hrs
           FROM resolved
        )
 SELECT wm_base.user_id,
    wm_base.week,
    wm_base.slp_hrs,
    wm_base.slp_score,
    wm_base.slp_hrv,
    wm_base.rhr,
    wm_base.avg_sleep_time,
    wm_base.avg_wake_time,
    wm_base.breath_rate,
    wm_base.slp_latency,
    wm_base.nights,
    wm_base.highlights,
    wm_base.articles,
    wm_base.podcasts,
    wm_base.distinct_books,
    wm_base.run_miles,
    wm_base.bike_miles,
    wm_base.swim_yards,
    wm_base.strength_mins,
    wm_base.intensity_mins,
    wm_base.step_count,
    wm_base.training_hrs,
    wm_base.body_fat,
    wm_base.weekly_weight,
    wm_base.stress,
    wm_base.meditation,
    wm_base.phone_pickups,
    wm_base.avg_daily_pickups,
    wm_base.consumed_cals,
    wm_base.avg_protein,
    wm_base.avg_carbs,
    wm_base.avg_fat,
    wm_base.calorie_deficit,
    wm_base.garmin_tdee,
    wm_base.non_profile_meals,
    wm_base.dcp_meals,
    wm_base.cooked_meals,
    wm_base.total_meals,
    wm_base.first_meal_mins,
    wm_base.last_meal_mins,
    wm_base.eating_window_hrs,
    wm_base.meal_days,
    wm_base.drinks,
    wm_base.notion_page_id,
    wm_base.source_updated_at,
    wm_base.synced_at,
    wm_base.adjusted_tdee,
    wm_base.garmin_full_days,
    wm_base.garmin_partial_days,
    wm_base.focus_blocks_4h,
    wm_base.focus_blocks_3h,
    wm_base.focus_blocks_2h,
    wm_base.longest_focus_hrs,
    wm_base.free_workday_hrs,
    wm_base.work_meetings,
    wm_base.work_hrs,
    wm_base.social_events,
    wm_base.social_hrs,
    wm_base.fitness_events,
    wm_base.fitness_hrs,
    wm_base.personal_events,
    wm_base.personal_hrs,
    wm_base.commute_hrs,
    wm_base.flights,
    wm_base.untagged_events,
    wm_base.untagged_hrs,
    b.breathwork_sessions,
    b.meditation_sessions AS meditation_only_sessions,
    b.mins_under_8,
    b.mins_under_6,
    b.best_settled_rate,
    b.avg_settled_rate,
    rsp.resp_waking_avg,
    rsp.resp_sleep_avg,
    rsp.resp_lowest,
    b.total_sessions AS breath_sessions,
    wm_base.nights_oura,
    wm_base.nights_garmin,
    wm_base.sleep_source,
    wm_base.avg_sleep_time_mins,
    wm_base.avg_wake_time_mins
   FROM wm_base
     LEFT JOIN garmin_breath_weekly b ON b.user_id = wm_base.user_id AND b.week = wm_base.week
     LEFT JOIN garmin_respiration_weekly rsp ON rsp.user_id = wm_base.user_id AND rsp.week = wm_base.week;

-- ============================================================ triggers

CREATE TRIGGER tasks_updated_at BEFORE UPDATE ON public.tasks FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER set_completed_at_trigger BEFORE INSERT OR UPDATE ON public.tasks FOR EACH ROW EXECUTE FUNCTION set_completed_at();
CREATE TRIGGER food_log_entries_guard_client_update BEFORE UPDATE ON public.food_log_entries FOR EACH ROW EXECUTE FUNCTION food_log_entries_guard_client_update();

-- ============================================================ row level security

alter table public.tasks enable row level security;
alter table public.journal_entries enable row level security;
alter table public.food_log_entries enable row level security;
alter table public.oura_daily enable row level security;
alter table public.garmin_daily enable row level security;
alter table public.garmin_sleep_daily enable row level security;
alter table public.garmin_activities enable row level security;
alter table public.garmin_activity_samples enable row level security;
alter table public.readwise_daily enable row level security;
alter table public.bodyspec_scans enable row level security;
alter table public.screentime_weekly enable row level security;
alter table public.calendar_weekly enable row level security;
alter table public.legacy_notion_table enable row level security;
alter table public.rocket_money_transactions enable row level security;

-- RLS is the only thing protecting this data. Supabase's stock grants (below)
-- give anon and authenticated full table privileges on everything in public;
-- the policies are what actually scope access to the owning user. Creating a
-- table here without enabling RLS exposes it to anyone holding the anon key,
-- which is committed in web/index.html.

create policy "select own tasks" on public.tasks as permissive for select to public
  using ((auth.uid() = user_id));
create policy "insert own tasks" on public.tasks as permissive for insert to public
  with check ((auth.uid() = user_id));
create policy "update own tasks" on public.tasks as permissive for update to public
  using ((auth.uid() = user_id));
create policy "delete own tasks" on public.tasks as permissive for delete to public
  using ((auth.uid() = user_id));

create policy "Users can read their own journal entries" on public.journal_entries as permissive for select to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id));

create policy "Users can read their own food log entries" on public.food_log_entries as permissive for select to public
  using ((( SELECT auth.uid() AS uid) = user_id));
-- The write half of the "corrected meals" feature. Scoping it to the two
-- override columns is the trigger's job, not this policy's — a policy cannot
-- restrict an UPDATE to specific columns.
create policy "Users can correct their own meal times" on public.food_log_entries as permissive for update to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id))
  with check ((( SELECT auth.uid() AS uid) = user_id));

create policy "Users can read their own oura daily rows" on public.oura_daily as permissive for select to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id));
create policy "Users can read their own garmin daily rows" on public.garmin_daily as permissive for select to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id));
create policy "Users can read their own garmin sleep rows" on public.garmin_sleep_daily as permissive for select to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id));
create policy "Users can read their own garmin activities" on public.garmin_activities as permissive for select to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id));
create policy "Users can read their own garmin activity samples" on public.garmin_activity_samples as permissive for select to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id));
create policy "Users can read their own readwise rows" on public.readwise_daily as permissive for select to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id));
create policy "Users can read their own bodyspec scans" on public.bodyspec_scans as permissive for select to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id));
create policy "Users can read their own screen time" on public.screentime_weekly as permissive for select to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id));
create policy "Users can read their own weekly metrics" on public.legacy_notion_table as permissive for select to authenticated
  using ((( SELECT auth.uid() AS uid) = user_id));

create policy "calendar_weekly owner" on public.calendar_weekly as permissive for all to authenticated
  using ((user_id = auth.uid()))
  with check ((user_id = auth.uid()));

-- UNAUTHENTICATED WRITE. Anyone holding the anon key (public, committed in
-- web/index.html) can insert arbitrary rows here. It exists because the
-- Rocket Money importer posts without a session. There is no matching select
-- policy, so the rows cannot be read back by anon — but they can be created.
-- Narrow or remove this when the importer can authenticate.
create policy "anon can insert" on public.rocket_money_transactions as permissive for insert to anon
  with check (true);

-- ============================================================ grants
--
-- Stock Supabase grants: anon, authenticated and service_role hold full
-- privileges on every table and view in public, and RLS does the gating.
-- Reproduced here so a replay onto a fresh project matches production.

grant all on all tables in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
grant all on all functions in schema public to anon, authenticated, service_role;

-- Except: anon holds only INSERT on rocket_money_transactions.
revoke all on public.rocket_money_transactions from anon;
grant insert on public.rocket_money_transactions to anon;

-- ============================================================ comments

comment on table public.journal_entries is 'Weekly reflection, one row per user per Monday-start week. Narrative only —
   quantitative measures moved to weekly_metrics on 2026-10-11. In practice
   journal_high and journal_low are the populated fields; the others are
   modelled but near-empty in Notion.';
comment on table public.legacy_notion_table is 'Frozen weekly numbers read off the Notion journal before each source had its
   own table (formerly weekly_metrics). Nothing writes it. weekly_master reads
   its *_legacy columns only for weeks the live views do not cover.';
comment on table public.screentime_weekly is 'Weekly phone pickups from Screen Time, one row per journal week. Written by
   the screentime-pickups-sync task alongside the Notion Log page.';
comment on table public.calendar_weekly is 'Weekly calendar shape read off the Vimcal desktop app (both the personal and
   tidemarkcap accounts), one row per journal week starting Monday. Written by the
   vimcal-week-review task. Hours are derived from on-screen block geometry snapped
   to 15 minutes, so counts are exact but hours carry roughly a quarter-hour of
   per-event slop. untagged_* covers events with no Vimcal tag; those are never
   folded into another bucket.';
comment on view public.week_time_budget is 'Where did the 168 hours go. Sleep from Oura, work/social/personal/commute from Vimcal tags plus the inferred layer, fitness reconciled (Garmin duration where an activity matches a calendar block, calendar duration where Garmin saw nothing). unaccounted_hrs is the residual: gaps between calendar blocks.';

comment on column public.journal_entries.journal_high is 'Generated by journal_sync.py from journal_raw_text (pre-2026-10-11 weeks:
   the Notion High property).';
comment on column public.journal_entries.journal_low is 'Generated by journal_sync.py from journal_raw_text (pre-2026-10-11 weeks:
   the Notion Low property).';
comment on column public.journal_entries.journal_bud is 'Generated by journal_sync.py from journal_raw_text: something emerging or
   worth building on.';
comment on column public.journal_entries.journal_raw_text is 'Notion journal page body as indented plain text. Excludes the synced
   quarterly-goals block and empty template labels.';
comment on column public.journal_entries.journal_summary_of is 'md5 of the journal_raw_text that journal_high/low/bud were generated from.
   journal_sync.py regenerates when it no longer matches.';
comment on column public.food_log_entries.is_cooked_override is 'Manual correction to is_cooked. null = use Notion''s flag. Never written by the sync.';
comment on column public.garmin_daily.hrv_last_night_avg is 'Overnight average HRV in ms. Garmin exposes no per-activity HRV; this is sleep-window only.';
comment on column public.garmin_daily.resp_waking_avg is 'Garmin all-day waking respiration (brpm). Distinct from Oura breath_rate, which is measured during sleep.';
comment on column public.legacy_notion_table.highlights_legacy is 'Readwise highlights captured that week. From readwise_weekly, not Notion.';
comment on column public.calendar_weekly.focus_blocks_4h is 'Count of contiguous free blocks of 4h or more inside the working window. The 3h
   and 2h counts exist because the 4h figure is 0 in most weeks and needs a ladder
   to be readable as a trend.';
comment on column public.calendar_weekly.inferred is 'Semantic layer over untagged Vimcal events plus Garmin/Oura reconciliation. Derived, not measured: the tagged *_hrs/*_events columns remain pure tag measurement. Shape: {version, rules[], events[{day,title,start,end,hrs,buckets[],confidence,source}], adds{bucket:{events,hrs}}, reconciled{fitness_hrs,method,garmin_matched[],garmin_only[],calendar_only[]}, budget{sleep_hrs,work_hrs,fitness_hrs,social_hrs,personal_hrs,commute_hrs,unresolved_hrs,accounted_hrs,unaccounted_hrs,denominator_hrs}, caveats[]}';

-- ============================================================ scheduled jobs
--
-- One pg_cron job runs inside the database, documented in neither repo before
-- the merge. It calls weekly_today_rollover(), which matches zero rows — see
-- the note on that function. Recreated here so the baseline is complete;
-- delete both if you want the dead path gone.
--
--   select cron.schedule('weekly-today-rollover', '0 8 * * 1',
--                        $$ select public.weekly_today_rollover(); $$);
