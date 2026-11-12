-- One weekly read surface, and an end to the duplicated aggregation.
--
-- Before this, oura.py and readwise_sync.py each recomputed a weekly rollup and
-- wrote ~9 columns into weekly_metrics that oura_weekly / readwise_weekly
-- already derived from the daily tables. Two copies of the same number, free to
-- drift, plus a sync step each to maintain them.
--
-- The obvious fix — drop the copies and join the views — loses history:
--   * 101 weeks have sleep in weekly_metrics but no oura_weekly row. The Oura
--     API only reaches back to 2025-03-09; earlier weeks were hand-entered in
--     Notion and cannot be recomputed from oura_daily.
--   * 1 week (2026-03-29) has article/podcast counts with no surviving
--     highlights behind them.
--
-- So the stored columns are kept but frozen: renamed *_legacy, no longer
-- written by any sync, and used only as the fallback arm of a coalesce. Live
-- weeks come from the views; pre-Oura history still resolves. The duplication
-- is gone because nothing writes these again.

alter table public.weekly_metrics rename column slp_hrs        to slp_hrs_legacy;
alter table public.weekly_metrics rename column slp_score      to slp_score_legacy;
alter table public.weekly_metrics rename column slp_hrv        to slp_hrv_legacy;
alter table public.weekly_metrics rename column rhr            to rhr_legacy;
alter table public.weekly_metrics rename column avg_sleep_time to avg_sleep_time_legacy;
alter table public.weekly_metrics rename column avg_wake_time  to avg_wake_time_legacy;
alter table public.weekly_metrics rename column highlights     to highlights_legacy;
alter table public.weekly_metrics rename column articles       to articles_legacy;
alter table public.weekly_metrics rename column podcasts       to podcasts_legacy;

comment on table public.weekly_metrics is
  'Weekly quantitative measures sourced from Notion by journal_sync.py. The
   *_legacy columns are frozen pre-Oura / pre-Readwise history — no sync writes
   them; read public.weekly_master instead, which coalesces them under the
   live view data.';

-- weekly_metrics is a superset of both view spines (every oura_weekly and
-- readwise_weekly week already has a row), so LEFT JOIN is sufficient.
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

  -- everything below is Notion-sourced, written by journal_sync.py
  m.run_miles, m.bike_miles, m.swim_yards, m.strength_mins, m.intensity_mins,
  m.step_count, m.training_hrs,
  m.body_fat, m.weekly_weight,
  m.stress, m.meditation,
  m.phone_pickups, m.avg_daily_pickups,
  m.consumed_cals, m.avg_protein, m.calorie_deficit, m.garmin_tdee,
  m.non_profile_meals, m.dcp_meals, m.cooked_meals, m.total_meals,
  m.first_meal_mins, m.last_meal_mins, m.eating_window_hrs, m.meal_days,
  m.drinks,
  m.notion_page_id, m.source_updated_at, m.synced_at
from public.weekly_metrics m
left join public.oura_weekly     o on o.user_id = m.user_id and o.week_start = m.week
left join public.readwise_weekly r on r.user_id = m.user_id and r.week_start = m.week;

comment on view public.weekly_master is
  'The weekly read surface. Sleep from oura_weekly, reading from
   readwise_weekly, the rest from weekly_metrics, with frozen legacy values
   underneath. Apps should read this, not the parts.';

grant select on public.weekly_master to authenticated;
grant select on public.weekly_master to service_role;
