-- Drop all-day stress sampling; replace the session-curves view with time-in-zone.
--
-- The 3-minute all-day stress series (added 2026-11-01) did not survive contact
-- with the data. Checked over two weeks:
--   * the weekday signal is noise -- 2-3 distinct days per weekday
--   * stress averages 45 within 2h of a workout vs 32 otherwise, so the
--     afternoon "peak" tracks training, not anything actionable
--   * Garmin reports -2 during activity (it refuses to score while you move),
--     so the workout itself is missing and only its recovery tail counts --
--     a bias that cannot be corrected after the fact
-- It was ~4,400 rows, the bulk of the Garmin data, for no decision it could drive.
--
-- garmin_activity_samples stays. It is the only thing that shows what a
-- breathwork session actually does: the 10-27 session reads avg 8.97 / min 6.0
-- / max 18.0 on garmin_activities, which understates it -- the max is the first
-- minute settling, and the real result was 7.0 brpm held for four minutes.
--
-- garmin_session_curves is replaced rather than kept. Splitting a 6-minute
-- session into thirds buries the settle-in period in the first bucket. Time at
-- or below a target rate is the measure that tracks progress toward the ~5.5
-- brpm resonance target.

begin;

drop view if exists public.garmin_stress_hourly;
drop table if exists public.garmin_stress_samples;

drop view if exists public.garmin_session_curves;

create view public.garmin_breath_zones
with (security_invoker = true) as
select a.activity_id,
       s.user_id,
       a.activity_name,
       a.activity_type,
       a.start_time_local,
       a.calendar_date,
       count(*)                                              as samples,
       count(*) filter (where s.respiration_rate <= 5.5)     as sec_at_5_5,
       count(*) filter (where s.respiration_rate <= 6)       as sec_at_6,
       count(*) filter (where s.respiration_rate <= 8)       as sec_at_8,
       round(100.0 * count(*) filter (where s.respiration_rate <= 8)
             / nullif(count(*), 0))                          as pct_at_8,
       round(min(s.respiration_rate), 1)                     as lowest_rate,
       -- Rate once settled. The opening minute is the transition from ordinary
       -- breathing (16.8 -> 7.0 on 10-27) and drags the session average up.
       round(avg(s.respiration_rate)
             filter (where s.offset_seconds >= 60), 1)       as rate_after_60s,
       -- First moment the rate reaches the target band, i.e. how long it takes
       -- to drop in.
       min(s.offset_seconds) filter (where s.respiration_rate <= 8)
                                                             as settle_seconds,
       round(avg(s.heart_rate) filter (where s.offset_seconds < 60))  as hr_first_min,
       round(avg(s.heart_rate) filter (where s.offset_seconds >= 60)) as hr_after_60s
from public.garmin_activity_samples s
join public.garmin_activities a using (activity_id)
where s.respiration_rate is not null
group by a.activity_id, s.user_id, a.activity_name, a.activity_type,
         a.start_time_local, a.calendar_date;

commit;
