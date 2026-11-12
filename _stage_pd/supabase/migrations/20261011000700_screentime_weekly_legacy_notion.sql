-- Phone pickups get their own table, and weekly_metrics retires.
--
-- Pickups were the last number journal_sync.py still read off the Notion
-- journal page. The screentime-pickups-sync task already reads one weekly
-- figure (Screen Time has no useful daily export), so the task now writes it
-- to Notion and to screentime_weekly at the same time. There is no daily table
-- to roll up from; the weekly row is the grain.
--
-- With pickups gone nothing writes weekly_metrics any more: every column is
-- frozen history from before a source had its own table. It is renamed
-- legacy_notion_table to say so. The reflection text lives in journal_entries,
-- which journal_sync.py still fills, and is untouched here.

create table if not exists public.screentime_weekly (
  user_id            uuid not null default '5be4d262-e35c-436b-86f5-0a6f24956182'
                     references auth.users (id) on delete cascade,
  -- The journal week this belongs to (the Notion Log page's Week of Journal).
  -- Screen Time's "Last Week" runs Sunday–Saturday, so a live row is keyed on
  -- the Monday after period_start. Backfilled rows keep the legacy page's key,
  -- which is a Sunday for some 2023–2026 pages.
  week_start         date not null,
  period_start       date,      -- Screen Time's Sunday; null for backfilled rows
  total_pickups      numeric,   -- "Total Pickups" for the week
  avg_daily_pickups  numeric,   -- "X per day"
  source             text not null default 'screen_time',  -- screen_time | notion_backfill
  synced_at          timestamptz not null default now(),
  primary key (user_id, week_start)
);

alter table public.screentime_weekly enable row level security;

drop policy if exists "Users can read their own screen time" on public.screentime_weekly;
create policy "Users can read their own screen time"
  on public.screentime_weekly for select to authenticated
  using ((select auth.uid()) = user_id);

grant select on table public.screentime_weekly to authenticated;
grant all on table public.screentime_weekly to service_role;

comment on table public.screentime_weekly is
  'Weekly phone pickups from Screen Time, one row per journal week. Written by
   the screentime-pickups-sync task alongside the Notion Log page.';

insert into public.screentime_weekly (user_id, week_start, total_pickups, avg_daily_pickups, source)
select user_id, week, phone_pickups, avg_daily_pickups, 'notion_backfill'
from public.weekly_metrics
where phone_pickups is not null or avg_daily_pickups is not null
on conflict (user_id, week_start) do nothing;

alter table public.weekly_metrics rename column phone_pickups     to phone_pickups_legacy;
alter table public.weekly_metrics rename column avg_daily_pickups to avg_daily_pickups_legacy;

alter table public.weekly_metrics rename to legacy_notion_table;
alter index if exists public.weekly_metrics_user_week_idx rename to legacy_notion_table_user_week_idx;

comment on table public.legacy_notion_table is
  'Frozen weekly numbers read off the Notion journal before each source had its
   own table (formerly weekly_metrics). Nothing writes it. weekly_master reads
   its *_legacy columns only for weeks the live views do not cover.';

-- The week spine can no longer be the legacy table alone, since it stops
-- growing. journal_entries (still synced weekly) and screentime_weekly carry
-- new weeks forward; today their keys are a subset of the legacy table's, so
-- the set of weeks the dashboard sees is unchanged.
drop view if exists public.weekly_master;

create view public.weekly_master
with (security_invoker = true) as
with spine as (
  select user_id, week from public.legacy_notion_table
  union
  select user_id, week from public.journal_entries
  union
  select user_id, week_start from public.screentime_weekly
), resolved as (
  select
    s.user_id,
    s.week,
    l.slp_hrs_legacy, l.slp_score_legacy, l.slp_hrv_legacy, l.rhr_legacy,
    l.avg_sleep_time_legacy, l.avg_wake_time_legacy,
    l.highlights_legacy, l.articles_legacy, l.podcasts_legacy,
    l.run_miles_legacy, l.bike_miles_legacy, l.swim_yards_legacy,
    l.strength_mins_legacy, l.intensity_mins_legacy, l.step_count_legacy,
    l.training_hrs_legacy, l.body_fat_legacy, l.weekly_weight_legacy,
    l.stress_legacy, l.meditation_legacy,
    l.consumed_cals_legacy, l.avg_protein_legacy, l.calorie_deficit_legacy,
    l.non_profile_meals_legacy, l.dcp_meals_legacy, l.cooked_meals_legacy,
    l.total_meals_legacy, l.first_meal_mins_legacy, l.last_meal_mins_legacy,
    l.eating_window_hrs_legacy, l.meal_days_legacy, l.drinks_legacy,
    coalesce(j.notion_page_id, l.notion_page_id)       as notion_page_id,
    coalesce(j.source_updated_at, l.source_updated_at) as source_updated_at,
    coalesce(j.synced_at, l.synced_at)                 as synced_at,
    g.week_start as g_week,
    f.week_start as f_week,
    case when g.week_start is not null then g.garmin_tdee else l.garmin_tdee_legacy end as tdee,
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
    f.drinks as f_drinks,
    p.total_pickups, p.avg_daily_pickups
  from spine s
  left join public.legacy_notion_table l on l.user_id = s.user_id and l.week = s.week
  left join public.journal_entries     j on j.user_id = s.user_id and j.week = s.week
  left join public.oura_weekly         o on o.user_id = s.user_id and o.week_start = s.week
  left join public.readwise_weekly     r on r.user_id = s.user_id and r.week_start = s.week
  left join public.garmin_weekly       g on g.user_id = s.user_id and g.week_start = s.week
  left join public.food_weekly         f on f.user_id = s.user_id and f.week_start = s.week
  left join public.screentime_weekly   p on p.user_id = s.user_id and p.week_start = s.week
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

  -- phone: screentime_weekly holds the full history (backfilled from Notion)
  total_pickups as phone_pickups,
  avg_daily_pickups,

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
   food_weekly, phone pickups from screentime_weekly, with frozen
   legacy_notion_table values underneath. Apps should read this, not the parts.';

grant select on public.weekly_master to authenticated;
grant select on public.weekly_master to service_role;
