-- Split journal_entries in two. It had grown to ~49 columns mixing two
-- unrelated things: the weekly reflection (High / Low / who you saw) and ~34
-- quantitative measures (sleep, training, body, nutrition, meals, phone).
--
-- weekly_metrics takes the numbers. journal_entries keeps the text and becomes
-- a reflection table (see 20261011000200). Same grain in both: one row per
-- user per Monday-start week.
--
-- Built with CREATE TABLE AS so column types are copied from the originals
-- rather than retyped by hand; constraints are added back explicitly below.

create table if not exists public.weekly_metrics as
select
  user_id,
  week,
  notion_page_id,
  source_updated_at,
  synced_at,
  -- sleep (written by oura.py from oura_weekly, not from Notion)
  slp_hrs, slp_score, slp_hrv, rhr, avg_sleep_time, avg_wake_time,
  -- training
  run_miles, bike_miles, swim_yards, strength_mins, intensity_mins,
  step_count, training_hrs,
  -- body
  body_fat, weekly_weight,
  -- state
  stress, meditation,
  -- consumption
  articles, podcasts, phone_pickups, avg_daily_pickups,
  -- nutrition
  consumed_cals, avg_protein, calorie_deficit, garmin_tdee,
  -- meals
  non_profile_meals, dcp_meals, cooked_meals, total_meals,
  first_meal_mins, last_meal_mins, eating_window_hrs, meal_days, drinks
from public.journal_entries;

alter table public.weekly_metrics
  alter column user_id set not null,
  alter column week set not null,
  alter column synced_at set not null,
  alter column synced_at set default now();

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'weekly_metrics_pkey'
  ) then
    alter table public.weekly_metrics
      add constraint weekly_metrics_pkey primary key (user_id, week);
  end if;
  if not exists (
    select 1 from pg_constraint where conname = 'weekly_metrics_user_id_fkey'
  ) then
    alter table public.weekly_metrics
      add constraint weekly_metrics_user_id_fkey
      foreign key (user_id) references auth.users (id) on delete cascade;
  end if;
end $$;

create index if not exists weekly_metrics_user_week_idx
  on public.weekly_metrics (user_id, week desc);

alter table public.weekly_metrics enable row level security;

drop policy if exists "Users can read their own weekly metrics" on public.weekly_metrics;
create policy "Users can read their own weekly metrics"
  on public.weekly_metrics for select to authenticated
  using ((select auth.uid()) = user_id);

grant select on table public.weekly_metrics to authenticated;
grant all on table public.weekly_metrics to service_role;

comment on table public.weekly_metrics is
  'Quantitative weekly measures, one row per user per Monday-start week. Split
   out of journal_entries, which now holds only the narrative. Sleep columns are
   written by oura.py from oura_weekly; the rest by journal_sync.py from Notion.';
