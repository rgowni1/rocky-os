-- Guard sleep_daily against Garmin's occasional bogus min_heart_rate.
--
-- Across 88 backfilled days exactly one reading is implausible: 2026-10-26
-- reports 30bpm where Oura logged 60 that night. The next-lowest Garmin
-- reading in the whole set is >= 40 and the 5th percentile is 53, so a 40bpm
-- floor drops the bad night and nothing else. On the other three overlap
-- nights Garmin's min_heart_rate sits a steady 2bpm under Oura's
-- lowest_heart_rate, which is why it is the right field to merge on.
--
-- Without the floor a single 30bpm night would pull a Garmin-only week's rhr
-- down several bpm and read as a recovery improvement.

create or replace view public.sleep_daily
with (security_invoker = true) as
with o as (
  select user_id, calendar_date, sleep_score, total_sleep_hours, average_hrv,
         lowest_heart_rate, average_breath, latency_minutes,
         sleep_time, wake_time, sleep_time_mins, wake_time_mins,
         bedtime_start, bedtime_end
  from public.oura_daily
  where total_sleep_hours is null or total_sleep_hours >= 3
),
g as (
  select s.user_id, s.calendar_date, s.sleep_score,
         s.total_sleep_hours,
         d.hrv_last_night_avg as average_hrv,
         case when d.min_heart_rate >= 40 then d.min_heart_rate end as lowest_heart_rate,
         s.average_breath,
         null::numeric        as latency_minutes,
         s.sleep_time, s.wake_time, s.sleep_time_mins, s.wake_time_mins,
         s.bedtime_start, s.bedtime_end,
         s.deep_sleep_seconds, s.light_sleep_seconds, s.rem_sleep_seconds
  from public.garmin_sleep_daily s
  left join public.garmin_daily d
    on d.user_id = s.user_id and d.calendar_date = s.calendar_date
  where s.total_sleep_hours >= 3
)
select
  coalesce(o.user_id, g.user_id)             as user_id,
  coalesce(o.calendar_date, g.calendar_date)  as calendar_date,
  case when o.calendar_date is not null then 'oura' else 'garmin' end as source,
  (o.calendar_date is not null) as has_oura,
  (g.calendar_date is not null) as has_garmin,
  case when o.calendar_date is not null then o.sleep_score        else g.sleep_score        end as sleep_score,
  case when o.calendar_date is not null then o.total_sleep_hours  else g.total_sleep_hours  end as total_sleep_hours,
  case when o.calendar_date is not null then o.average_hrv        else g.average_hrv        end as average_hrv,
  case when o.calendar_date is not null then o.lowest_heart_rate  else g.lowest_heart_rate  end as lowest_heart_rate,
  case when o.calendar_date is not null then o.average_breath     else g.average_breath     end as average_breath,
  case when o.calendar_date is not null then o.latency_minutes    else g.latency_minutes    end as latency_minutes,
  case when o.calendar_date is not null then o.sleep_time         else g.sleep_time         end as sleep_time,
  case when o.calendar_date is not null then o.wake_time          else g.wake_time          end as wake_time,
  case when o.calendar_date is not null then o.sleep_time_mins    else g.sleep_time_mins    end as sleep_time_mins,
  case when o.calendar_date is not null then o.wake_time_mins     else g.wake_time_mins     end as wake_time_mins,
  case when o.calendar_date is not null then o.bedtime_start      else g.bedtime_start      end as bedtime_start,
  case when o.calendar_date is not null then o.bedtime_end        else g.bedtime_end        end as bedtime_end,
  g.deep_sleep_seconds, g.light_sleep_seconds, g.rem_sleep_seconds
from o
full outer join g
  on g.user_id = o.user_id and g.calendar_date = o.calendar_date;

grant select on public.sleep_daily to authenticated;
