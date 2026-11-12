-- Second half of the split (see 20261011000100_weekly_metrics.sql). The metric
-- columns now live in weekly_metrics, so drop them here and leave
-- journal_entries as what its name says: the weekly reflection.
--
-- Run only after confirming weekly_metrics holds the same row count.

alter table public.journal_entries
  drop column if exists slp_hrs,
  drop column if exists slp_score,
  drop column if exists slp_hrv,
  drop column if exists rhr,
  drop column if exists avg_sleep_time,
  drop column if exists avg_wake_time,
  drop column if exists run_miles,
  drop column if exists bike_miles,
  drop column if exists swim_yards,
  drop column if exists strength_mins,
  drop column if exists intensity_mins,
  drop column if exists step_count,
  drop column if exists training_hrs,
  drop column if exists body_fat,
  drop column if exists weekly_weight,
  drop column if exists stress,
  drop column if exists meditation,
  drop column if exists articles,
  drop column if exists podcasts,
  drop column if exists phone_pickups,
  drop column if exists avg_daily_pickups,
  drop column if exists consumed_cals,
  drop column if exists avg_protein,
  drop column if exists calorie_deficit,
  drop column if exists garmin_tdee,
  drop column if exists non_profile_meals,
  drop column if exists dcp_meals,
  drop column if exists cooked_meals,
  drop column if exists total_meals,
  drop column if exists first_meal_mins,
  drop column if exists last_meal_mins,
  drop column if exists eating_window_hrs,
  drop column if exists meal_days,
  drop column if exists drinks;

comment on table public.journal_entries is
  'Weekly reflection, one row per user per Monday-start week. Narrative only —
   quantitative measures moved to weekly_metrics on 2026-10-11. In practice
   journal_high and journal_low are the populated fields; the others are
   modelled but near-empty in Notion.';
