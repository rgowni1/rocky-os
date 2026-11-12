-- All-day respiration rate from Garmin, alongside the Oura sleep figure.
--
-- Garmin already returns these on get_daily_summary -- the sync was discarding
-- them, so capturing them costs no extra API calls:
--     avgWakingRespirationValue   daytime average, awake
--     avgSleepRespirationValue    overnight average
--     lowest/highestRespirationValue
--
-- weekly_master already carried `breath_rate` from Oura (a SLEEP figure, ~17.3
-- and trending down) but nothing rendered it. These are a different measure --
-- Garmin's waking average was 15 on 11-02 against Oura's 17.2 asleep -- so both
-- are kept rather than one standing in for the other.
--
-- Note these are whole-day aggregates Garmin computes itself, unrelated to the
-- per-second session samples behind garmin_breath_zones. Those cover
-- meditation and breathwork only.

begin;

alter table public.garmin_daily
  add column if not exists resp_waking_avg  smallint,  -- avgWakingRespirationValue
  add column if not exists resp_sleep_avg   smallint,  -- avgSleepRespirationValue
  add column if not exists resp_lowest      smallint,  -- lowestRespirationValue
  add column if not exists resp_highest     smallint;  -- highestRespirationValue

comment on column public.garmin_daily.resp_waking_avg is
  'Garmin all-day waking respiration (brpm). Distinct from Oura breath_rate, which is measured during sleep.';

create or replace view public.garmin_respiration_weekly
with (security_invoker = true) as
select user_id,
       date_trunc('week', calendar_date::timestamp)::date as week,
       round(avg(resp_waking_avg), 1) as resp_waking_avg,
       round(avg(resp_sleep_avg), 1)  as resp_sleep_avg,
       round(avg(resp_lowest), 1)     as resp_lowest
from public.garmin_daily
where resp_waking_avg is not null or resp_sleep_avg is not null
group by user_id, date_trunc('week', calendar_date::timestamp)::date;

create or replace view public.weekly_master
with (security_invoker = true) as
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
                     LEFT JOIN oura_weekly o ON o.user_id = s.user_id AND o.week_start = s.week
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
    rsp.resp_lowest
   FROM wm_base
     LEFT JOIN garmin_breath_weekly b ON b.user_id = wm_base.user_id AND b.week = wm_base.week
     LEFT JOIN garmin_respiration_weekly rsp ON rsp.user_id = wm_base.user_id AND rsp.week = wm_base.week;

commit;
