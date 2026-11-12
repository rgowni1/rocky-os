-- Food intake gets the Garmin / Oura / Readwise shape: a granular log is the
-- source, a view does the weekly rollup, Notion's weekly page is a waypoint.
--
-- Until now the weekly nutrition numbers in weekly_metrics came off the Notion
-- journal page (Consumed Cals / Avg Protein / Calorie Deficit formulas, FL
-- Non Profile / DCP / Drinks rollups) via journal_sync.py, and the timing and
-- cooked counts from kanban's sync. Both are aggregations of the same meals
-- already sitting in food_log_entries, so they become one view over it.
--
-- Rules carried over from kanban/sync_journal_to_supabase.py so the numbers
-- mean what they meant before:
--   * An eating day runs 04:00 -> 03:59 America/Los_Angeles; a 00:30 snack is
--     the tail of the night before. The week is the Monday of the eating day.
--   * Dashboard corrections win: coalesce(eaten_at_override, eaten_at) and
--     coalesce(is_cooked_override, is_cooked).
--   * A meal stored at exactly 00:00 UTC is a date-only Notion entry. It counts
--     toward intake and flags, but has no time to contribute to meal timing.
--   * Timing averages need >= 3 logged days (MIN_TIMING_DAYS).
--   * A week averaging < 900 kcal/day is an abandoned log, not a fast:
--     calories, protein and the meal-flag counts go null together.
--
-- Daily averages divide by complete days: 7 for a finished week, days elapsed
-- for the current one, and the in-progress eating day is left out of both
-- sides. (Notion's formula divides by days elapsed but still sums today's
-- meals, so mid-week it reads slightly high.)
--
-- weekly_metrics' food columns are frozen as *_legacy, like Garmin's. The log
-- starts 2026-01-19, so legacy only serves weeks before that.

create or replace view public.food_weekly
with (security_invoker = true) as
with meals as (
  select
    f.user_id,
    coalesce(f.eaten_at_override, f.eaten_at) as at,
    (coalesce(f.eaten_at_override, f.eaten_at) at time zone 'UTC')::time = '00:00' as date_only,
    f.calories,
    f.protein_g,
    f.is_non_profile,
    f.is_dcp,
    coalesce(f.is_cooked_override, f.is_cooked) as is_cooked,
    f.drinks
  from public.food_log_entries f
  where coalesce(f.eaten_at_override, f.eaten_at) is not null
), slotted as (
  select
    m.*,
    case
      when m.date_only then (m.at at time zone 'UTC')::date
      else ((m.at at time zone 'America/Los_Angeles') - interval '4 hours')::date
    end as eating_day,
    case
      when m.date_only then null
      else extract(epoch from ((m.at at time zone 'America/Los_Angeles') - interval '4 hours')::time) / 60 + 240
    end as minutes
  from meals m
), today as (
  select ((now() at time zone 'America/Los_Angeles') - interval '4 hours')::date as eating_day
), days as (
  select
    s.user_id,
    s.eating_day,
    min(s.minutes) as first_mins,
    max(s.minutes) as last_mins
  from slotted s
  group by s.user_id, s.eating_day
), timing as (
  select
    d.user_id,
    date_trunc('week', d.eating_day)::date as week_start,
    count(*) as meal_days,
    count(d.first_mins) as timed_days,
    round(avg(d.first_mins), 1) as first_meal_mins,
    round(avg(d.last_mins), 1) as last_meal_mins,
    round(avg(d.last_mins - d.first_mins) / 60, 2) as eating_window_hrs
  from days d
  group by d.user_id, date_trunc('week', d.eating_day)::date
), intake as (
  select
    s.user_id,
    date_trunc('week', s.eating_day)::date as week_start,
    count(*) as total_meals,
    count(*) filter (where s.is_cooked) as cooked_meals,
    count(*) filter (where s.is_non_profile) as non_profile_meals,
    count(*) filter (where s.is_dcp) as dcp_meals,
    sum(s.drinks) as drinks,
    sum(s.calories)  filter (where s.eating_day < t.eating_day) as complete_cals,
    sum(s.protein_g) filter (where s.eating_day < t.eating_day) as complete_protein,
    least(7, greatest(0, t.eating_day - date_trunc('week', s.eating_day)::date)) as complete_days
  from slotted s
  cross join today t
  group by s.user_id, date_trunc('week', s.eating_day)::date, t.eating_day
), averaged as (
  select
    i.*,
    round(i.complete_cals / nullif(i.complete_days, 0)) as consumed_cals,
    round(i.complete_protein / nullif(i.complete_days, 0)) as avg_protein
  from intake i
)
select
  a.user_id,
  a.week_start,
  case when a.consumed_cals >= 900 then a.consumed_cals end as consumed_cals,
  case when a.consumed_cals >= 900 then a.avg_protein end as avg_protein,
  case when a.consumed_cals >= 900 then a.non_profile_meals end as non_profile_meals,
  case when a.consumed_cals >= 900 then a.dcp_meals end as dcp_meals,
  case when a.consumed_cals >= 900 then a.drinks end as drinks,
  a.cooked_meals,
  a.total_meals,
  t.meal_days,
  case when t.timed_days >= 3 then t.first_meal_mins end as first_meal_mins,
  case when t.timed_days >= 3 then t.last_meal_mins end as last_meal_mins,
  case when t.timed_days >= 3 then t.eating_window_hrs end as eating_window_hrs,
  a.complete_days as intake_days
from averaged a
join timing t on t.user_id = a.user_id and t.week_start = a.week_start;

comment on view public.food_weekly is
  'Weekly food rollup over food_log_entries. Eating day 04:00-03:59 Pacific;
   daily averages over complete days only; dashboard overrides respected.';

grant select on public.food_weekly to authenticated;
grant select on public.food_weekly to service_role;

alter table public.weekly_metrics rename column consumed_cals     to consumed_cals_legacy;
alter table public.weekly_metrics rename column avg_protein       to avg_protein_legacy;
alter table public.weekly_metrics rename column calorie_deficit   to calorie_deficit_legacy;
alter table public.weekly_metrics rename column non_profile_meals to non_profile_meals_legacy;
alter table public.weekly_metrics rename column dcp_meals         to dcp_meals_legacy;
alter table public.weekly_metrics rename column cooked_meals      to cooked_meals_legacy;
alter table public.weekly_metrics rename column total_meals       to total_meals_legacy;
alter table public.weekly_metrics rename column first_meal_mins   to first_meal_mins_legacy;
alter table public.weekly_metrics rename column last_meal_mins    to last_meal_mins_legacy;
alter table public.weekly_metrics rename column eating_window_hrs to eating_window_hrs_legacy;
alter table public.weekly_metrics rename column meal_days         to meal_days_legacy;
alter table public.weekly_metrics rename column drinks            to drinks_legacy;

comment on table public.weekly_metrics is
  'Weekly measures sourced from Notion by journal_sync.py (phone pickups). The
   *_legacy columns are frozen history from before the daily sources existed —
   no sync writes them; read public.weekly_master instead, which puts the live
   view data over them.';

-- Calorie deficit was a Notion formula (Garmin TDEE − Consumed Cals). Both
-- inputs now resolve here, so it is computed rather than read back. It uses the
-- unadjusted TDEE, as the Notion formula did.
create or replace view public.weekly_master
with (security_invoker = true) as
with resolved as (
  select
    m.*,
    g.week_start as g_week,
    f.week_start as f_week,
    case when g.week_start is not null then g.garmin_tdee else m.garmin_tdee_legacy end as tdee,
    o.slp_hrs as o_slp_hrs, o.slp_score as o_slp_score, o.slp_hrv as o_slp_hrv, o.rhr as o_rhr,
    o.avg_sleep_time as o_avg_sleep_time, o.avg_wake_time as o_avg_wake_time,
    o.breath_rate, o.slp_latency, o.nights,
    r.highlights as r_highlights, r.distinct_articles, r.distinct_podcasts_videos, r.distinct_books,
    g.run_miles as g_run_miles, g.bike_miles as g_bike_miles, g.swim_yards as g_swim_yards,
    g.strength_minutes, g.intensity_minutes, g.step_count as g_step_count, g.training_hours,
    g.body_fat_pct, g.weekly_weight as g_weekly_weight, g.stress_level, g.meditation_sessions,
    g.adjusted_tdee, g.full_days as g_full_days, g.partial_days as g_partial_days,
    f.consumed_cals as f_consumed_cals, f.avg_protein as f_avg_protein,
    f.non_profile_meals as f_non_profile_meals, f.dcp_meals as f_dcp_meals,
    f.cooked_meals as f_cooked_meals, f.total_meals as f_total_meals,
    f.first_meal_mins as f_first_meal_mins, f.last_meal_mins as f_last_meal_mins,
    f.eating_window_hrs as f_eating_window_hrs, f.meal_days as f_meal_days,
    f.drinks as f_drinks
  from public.weekly_metrics m
  left join public.oura_weekly     o on o.user_id = m.user_id and o.week_start = m.week
  left join public.readwise_weekly r on r.user_id = m.user_id and r.week_start = m.week
  left join public.garmin_weekly   g on g.user_id = m.user_id and g.week_start = m.week
  left join public.food_weekly     f on f.user_id = m.user_id and f.week_start = m.week
)
select
  user_id,
  week,

  -- sleep: oura_weekly where the ring reaches, frozen Notion history before it
  coalesce(o_slp_hrs,         slp_hrs_legacy)        as slp_hrs,
  coalesce(o_slp_score,       slp_score_legacy)      as slp_score,
  coalesce(o_slp_hrv,         slp_hrv_legacy)        as slp_hrv,
  coalesce(o_rhr,             rhr_legacy)            as rhr,
  coalesce(o_avg_sleep_time,  avg_sleep_time_legacy) as avg_sleep_time,
  coalesce(o_avg_wake_time,   avg_wake_time_legacy)  as avg_wake_time,
  breath_rate,
  slp_latency,
  nights,

  -- reading
  coalesce(r_highlights,              highlights_legacy) as highlights,
  coalesce(distinct_articles,         articles_legacy)   as articles,
  coalesce(distinct_podcasts_videos,  podcasts_legacy)   as podcasts,
  distinct_books,

  -- training / body / state: garmin_weekly for any week it covers, else legacy
  case when g_week is not null then g_run_miles                  else run_miles_legacy      end as run_miles,
  case when g_week is not null then g_bike_miles                 else bike_miles_legacy     end as bike_miles,
  case when g_week is not null then g_swim_yards                 else swim_yards_legacy     end as swim_yards,
  case when g_week is not null then strength_minutes             else strength_mins_legacy  end as strength_mins,
  case when g_week is not null then intensity_minutes::numeric   else intensity_mins_legacy end as intensity_mins,
  case when g_week is not null then g_step_count                 else step_count_legacy     end as step_count,
  case when g_week is not null then training_hours               else training_hrs_legacy   end as training_hrs,
  case when g_week is not null then body_fat_pct                 else body_fat_legacy       end as body_fat,
  case when g_week is not null then g_weekly_weight              else weekly_weight_legacy  end as weekly_weight,
  case when g_week is not null then stress_level                 else stress_legacy         end as stress,
  case when g_week is not null then meditation_sessions::numeric else meditation_legacy     end as meditation,

  -- phone: Notion-sourced, written by journal_sync.py
  phone_pickups, avg_daily_pickups,

  -- food: food_weekly for any week it covers, else legacy
  case when f_week is not null then f_consumed_cals else consumed_cals_legacy end as consumed_cals,
  case when f_week is not null then f_avg_protein   else avg_protein_legacy   end as avg_protein,
  case when f_week is not null then tdee - f_consumed_cals else calorie_deficit_legacy end as calorie_deficit,
  tdee as garmin_tdee,
  case when f_week is not null then f_non_profile_meals::numeric else non_profile_meals_legacy end as non_profile_meals,
  case when f_week is not null then f_dcp_meals::numeric         else dcp_meals_legacy         end as dcp_meals,
  case when f_week is not null then f_cooked_meals::numeric      else cooked_meals_legacy      end as cooked_meals,
  case when f_week is not null then f_total_meals::numeric       else total_meals_legacy       end as total_meals,
  case when f_week is not null then f_first_meal_mins            else first_meal_mins_legacy   end as first_meal_mins,
  case when f_week is not null then f_last_meal_mins             else last_meal_mins_legacy    end as last_meal_mins,
  case when f_week is not null then f_eating_window_hrs          else eating_window_hrs_legacy end as eating_window_hrs,
  case when f_week is not null then f_meal_days::numeric         else meal_days_legacy         end as meal_days,
  case when f_week is not null then f_drinks                     else drinks_legacy            end as drinks,

  notion_page_id, source_updated_at, synced_at,

  -- Garmin coverage; null for weeks served from legacy
  adjusted_tdee,
  g_full_days    as garmin_full_days,
  g_partial_days as garmin_partial_days
from resolved;

comment on view public.weekly_master is
  'The weekly read surface. Sleep from oura_weekly, reading from
   readwise_weekly, training/body/stress from garmin_weekly, food from
   food_weekly, phone pickups from weekly_metrics, with frozen legacy values
   underneath. Apps should read this, not the parts.';
