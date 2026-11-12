-- Daily-average carbs and fat alongside protein.
--
-- food_log_entries has carried carbs_g and fat_g all along (100% populated
-- wherever protein_g is), but food_weekly only ever surfaced avg_protein, so
-- nothing downstream could chart them.
--
-- Both follow the avg_protein rules exactly:
--   * averaged over COMPLETE eating days only -- the in-progress day is excluded
--     so a partially logged today doesn't drag the weekly average down
--   * suppressed when the week's consumed_cals < 900, same as protein: a barely
--     logged week should report nothing rather than a misleading daily average
--
-- No legacy fallback. Carbs and fat exist only from the food log onward, so
-- weeks before it are null rather than borrowing a Notion column that never
-- tracked them.
--
-- Both views are dropped and recreated rather than CREATE OR REPLACE'd: the new
-- columns land mid-list, which replace cannot do. weekly_master is the only
-- dependent of food_weekly, and nothing depends on weekly_master.

begin;

drop view if exists public.weekly_master;
drop view if exists public.food_weekly;

create view public.food_weekly with (security_invoker = true) as
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

create view public.weekly_master with (security_invoker = true) as
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
        f_avg_carbs AS avg_carbs,
        f_avg_fat AS avg_fat,
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

commit;
