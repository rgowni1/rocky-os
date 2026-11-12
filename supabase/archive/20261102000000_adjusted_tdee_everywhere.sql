-- Calories expended / deficit now measured against the ADJUSTED TDEE.
--
-- Garmin overestimates expenditure; adjusted_tdee (garmin_tdee * 0.90) is the
-- corrected figure. The dashboard and the deficit were both still reading raw
-- garmin_tdee, which overstated the weekly deficit by ~250 kcal/day and showed
-- a deficit for two weeks that were actually at or above maintenance
-- (wk 2026-10-26: 242 "deficit" -> 10 surplus; wk 2026-10-19: 87 -> 163 surplus).
--
-- Two changes:
--   1. adjusted_tdee gains a legacy fallback (garmin_tdee_legacy * 0.90). It
--      previously came only from garmin_weekly, so it was null for 62 of the 71
--      weeks that have a TDEE -- switching the chart to it would have blanked
--      all history before 2026-08-31.
--   2. calorie_deficit subtracts intake from adjusted_tdee, not raw tdee.
--      The pre-food-log legacy branch is left alone: those values are frozen
--      Notion history, not recomputable.
--
-- garmin_tdee stays the raw Garmin number under its own name.

create or replace view public.weekly_master with (security_invoker = true) as
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
 SELECT user_id,
    week,
    COALESCE(o_slp_hrs, slp_hrs_legacy) AS slp_hrs,
    COALESCE(o_slp_score, slp_score_legacy) AS slp_score,
    COALESCE(o_slp_hrv, slp_hrv_legacy) AS slp_hrv,
    COALESCE(o_rhr, rhr_legacy) AS rhr,
    COALESCE(o_avg_sleep_time, avg_sleep_time_legacy) AS avg_sleep_time,
    COALESCE(o_avg_wake_time, avg_wake_time_legacy) AS avg_wake_time,
    breath_rate,
    slp_latency,
    nights,
    COALESCE(r_highlights::numeric, highlights_legacy) AS highlights,
    COALESCE(distinct_articles::numeric, articles_legacy) AS articles,
    COALESCE(distinct_podcasts_videos::numeric, podcasts_legacy) AS podcasts,
    distinct_books,
        CASE
            WHEN g_week IS NOT NULL THEN g_run_miles
            ELSE run_miles_legacy
        END AS run_miles,
        CASE
            WHEN g_week IS NOT NULL THEN g_bike_miles
            ELSE bike_miles_legacy
        END AS bike_miles,
        CASE
            WHEN g_week IS NOT NULL THEN g_swim_yards
            ELSE swim_yards_legacy
        END AS swim_yards,
        CASE
            WHEN g_week IS NOT NULL THEN strength_minutes
            ELSE strength_mins_legacy
        END AS strength_mins,
        CASE
            WHEN g_week IS NOT NULL THEN intensity_minutes::numeric
            ELSE intensity_mins_legacy
        END AS intensity_mins,
        CASE
            WHEN g_week IS NOT NULL THEN g_step_count
            ELSE step_count_legacy
        END AS step_count,
        CASE
            WHEN g_week IS NOT NULL THEN training_hours
            ELSE training_hrs_legacy
        END AS training_hrs,
        CASE
            WHEN g_week IS NOT NULL THEN body_fat_pct
            ELSE body_fat_legacy
        END AS body_fat,
        CASE
            WHEN g_week IS NOT NULL THEN g_weekly_weight
            ELSE weekly_weight_legacy
        END AS weekly_weight,
        CASE
            WHEN g_week IS NOT NULL THEN stress_level
            ELSE stress_legacy
        END AS stress,
        CASE
            WHEN g_week IS NOT NULL THEN meditation_sessions::numeric
            ELSE meditation_legacy
        END AS meditation,
    total_pickups AS phone_pickups,
    avg_daily_pickups,
        CASE
            WHEN f_week IS NOT NULL THEN f_consumed_cals
            ELSE consumed_cals_legacy
        END AS consumed_cals,
        CASE
            WHEN f_week IS NOT NULL THEN f_avg_protein
            ELSE avg_protein_legacy
        END AS avg_protein,
        CASE
            WHEN f_week IS NOT NULL THEN adjusted_tdee - f_consumed_cals
            ELSE calorie_deficit_legacy
        END AS calorie_deficit,
    tdee AS garmin_tdee,
        CASE
            WHEN f_week IS NOT NULL THEN f_non_profile_meals::numeric
            ELSE non_profile_meals_legacy
        END AS non_profile_meals,
        CASE
            WHEN f_week IS NOT NULL THEN f_dcp_meals::numeric
            ELSE dcp_meals_legacy
        END AS dcp_meals,
        CASE
            WHEN f_week IS NOT NULL THEN f_cooked_meals::numeric
            ELSE cooked_meals_legacy
        END AS cooked_meals,
        CASE
            WHEN f_week IS NOT NULL THEN f_total_meals::numeric
            ELSE total_meals_legacy
        END AS total_meals,
        CASE
            WHEN f_week IS NOT NULL THEN f_first_meal_mins
            ELSE first_meal_mins_legacy
        END AS first_meal_mins,
        CASE
            WHEN f_week IS NOT NULL THEN f_last_meal_mins
            ELSE last_meal_mins_legacy
        END AS last_meal_mins,
        CASE
            WHEN f_week IS NOT NULL THEN f_eating_window_hrs
            ELSE eating_window_hrs_legacy
        END AS eating_window_hrs,
        CASE
            WHEN f_week IS NOT NULL THEN f_meal_days::numeric
            ELSE meal_days_legacy
        END AS meal_days,
        CASE
            WHEN f_week IS NOT NULL THEN f_drinks
            ELSE drinks_legacy
        END AS drinks,
    notion_page_id,
    source_updated_at,
    synced_at,
    adjusted_tdee,
    g_full_days AS garmin_full_days,
    g_partial_days AS garmin_partial_days,
    focus_blocks_4h,
    focus_blocks_3h,
    focus_blocks_2h,
    longest_focus_hrs,
    free_workday_hrs,
    work_meetings,
    work_hrs,
    social_events,
    social_hrs,
    fitness_events,
    fitness_hrs,
    personal_events,
    personal_hrs,
    commute_hrs,
    flights,
    untagged_events,
    untagged_hrs
   FROM resolved;