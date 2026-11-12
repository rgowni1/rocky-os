-- Garmin gets the same treatment Oura and Readwise got in 20261011000400.
--
-- The garmin-sync routine writes garmin_daily / garmin_activities, reads
-- garmin_weekly, and pushes that rollup to the Notion journal. journal_sync.py
-- then read those same Notion properties back into weekly_metrics: a
-- Supabase → Notion → Supabase loop that left a second, rounded, one-run-stale
-- copy of every Garmin number. The copies had already drifted — 2026-09-07
-- reads 0.63 training hours in weekly_metrics against 7.30 in garmin_weekly.
--
-- garmin_daily only reaches back to 2026-09-01, while weekly_metrics holds
-- Garmin numbers from 2025-05-18 (69 weeks), hand- or routine-entered in Notion
-- before the daily table existed. So, as with sleep, the stored columns are
-- frozen as *_legacy rather than dropped, and nothing writes them again.
--
-- Unlike sleep, legacy is not a per-column coalesce. A week garmin_weekly
-- covers is taken from garmin_weekly whole: a week with no weigh-in should
-- read null weight, not a stale Notion figure mixed in with live numbers.
--
-- calorie_deficit stays a live Notion column. It is a Notion formula over
-- Garmin TDEE and consumed calories, which is why the routine still pushes the
-- rollup to Notion.

alter table public.weekly_metrics rename column garmin_tdee    to garmin_tdee_legacy;
alter table public.weekly_metrics rename column step_count     to step_count_legacy;
alter table public.weekly_metrics rename column intensity_mins to intensity_mins_legacy;
alter table public.weekly_metrics rename column stress         to stress_legacy;
alter table public.weekly_metrics rename column weekly_weight  to weekly_weight_legacy;
alter table public.weekly_metrics rename column body_fat       to body_fat_legacy;
alter table public.weekly_metrics rename column training_hrs   to training_hrs_legacy;
alter table public.weekly_metrics rename column strength_mins  to strength_mins_legacy;
alter table public.weekly_metrics rename column swim_yards     to swim_yards_legacy;
alter table public.weekly_metrics rename column run_miles      to run_miles_legacy;
alter table public.weekly_metrics rename column bike_miles     to bike_miles_legacy;
alter table public.weekly_metrics rename column meditation     to meditation_legacy;

comment on table public.weekly_metrics is
  'Weekly quantitative measures sourced from Notion by journal_sync.py. The
   *_legacy columns are frozen pre-Oura / pre-Readwise / pre-garmin_daily
   history — no sync writes them; read public.weekly_master instead, which
   puts the live view data over them.';

-- Column names, order and types are unchanged from 20261011000400 so this can
-- replace in place; the Garmin coverage columns are appended at the end.
create or replace view public.weekly_master
with (security_invoker = true) as
select
  m.user_id,
  m.week,

  -- sleep: oura_weekly where the ring reaches, frozen Notion history before it
  coalesce(o.slp_hrs,         m.slp_hrs_legacy)        as slp_hrs,
  coalesce(o.slp_score,       m.slp_score_legacy)      as slp_score,
  coalesce(o.slp_hrv,         m.slp_hrv_legacy)        as slp_hrv,
  coalesce(o.rhr,             m.rhr_legacy)            as rhr,
  coalesce(o.avg_sleep_time,  m.avg_sleep_time_legacy) as avg_sleep_time,
  coalesce(o.avg_wake_time,   m.avg_wake_time_legacy)  as avg_wake_time,
  o.breath_rate,
  o.slp_latency,
  o.nights,

  -- reading
  coalesce(r.highlights,                m.highlights_legacy) as highlights,
  coalesce(r.distinct_articles,         m.articles_legacy)   as articles,
  coalesce(r.distinct_podcasts_videos,  m.podcasts_legacy)   as podcasts,
  r.distinct_books,

  -- training / body / state: garmin_weekly for any week it covers, else legacy
  case when g.week_start is not null then g.run_miles                    else m.run_miles_legacy      end as run_miles,
  case when g.week_start is not null then g.bike_miles                   else m.bike_miles_legacy     end as bike_miles,
  case when g.week_start is not null then g.swim_yards                   else m.swim_yards_legacy     end as swim_yards,
  case when g.week_start is not null then g.strength_minutes             else m.strength_mins_legacy  end as strength_mins,
  case when g.week_start is not null then g.intensity_minutes::numeric   else m.intensity_mins_legacy end as intensity_mins,
  case when g.week_start is not null then g.step_count                   else m.step_count_legacy     end as step_count,
  case when g.week_start is not null then g.training_hours               else m.training_hrs_legacy   end as training_hrs,
  case when g.week_start is not null then g.body_fat_pct                 else m.body_fat_legacy       end as body_fat,
  case when g.week_start is not null then g.weekly_weight                else m.weekly_weight_legacy  end as weekly_weight,
  case when g.week_start is not null then g.stress_level                 else m.stress_legacy         end as stress,
  case when g.week_start is not null then g.meditation_sessions::numeric else m.meditation_legacy     end as meditation,

  -- everything below is Notion-sourced, written by journal_sync.py
  m.phone_pickups, m.avg_daily_pickups,
  m.consumed_cals, m.avg_protein, m.calorie_deficit,
  case when g.week_start is not null then g.garmin_tdee                  else m.garmin_tdee_legacy    end as garmin_tdee,
  m.non_profile_meals, m.dcp_meals, m.cooked_meals, m.total_meals,
  m.first_meal_mins, m.last_meal_mins, m.eating_window_hrs, m.meal_days,
  m.drinks,
  m.notion_page_id, m.source_updated_at, m.synced_at,

  -- Garmin coverage; null for weeks served from legacy
  g.adjusted_tdee,
  g.full_days    as garmin_full_days,
  g.partial_days as garmin_partial_days
from public.weekly_metrics m
left join public.oura_weekly     o on o.user_id = m.user_id and o.week_start = m.week
left join public.readwise_weekly r on r.user_id = m.user_id and r.week_start = m.week
left join public.garmin_weekly   g on g.user_id = m.user_id and g.week_start = m.week;

comment on view public.weekly_master is
  'The weekly read surface. Sleep from oura_weekly, reading from
   readwise_weekly, training/body/stress from garmin_weekly, the rest from
   weekly_metrics, with frozen legacy values underneath. Apps should read
   this, not the parts.';
