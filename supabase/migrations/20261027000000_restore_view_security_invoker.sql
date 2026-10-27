-- weekly_master, food_weekly and week_time_budget had lost security_invoker,
-- so they ran with the owner's rights and bypassed RLS on every base table.
-- Supabase grants anon SELECT on everything in public by default — safe only
-- while RLS holds — so the publishable key committed in the kanban index.html
-- (public repo, public Pages site) could read all 270 weeks of health metrics
-- without signing in:
--
--   GET /rest/v1/weekly_master?select=week,consumed_cals   → 200
--   content-range: 0-269/270
--
-- journal_entries, a table with RLS, correctly returned [] to the same key.
--
-- The migrations that created these views all specified
-- `with (security_invoker = true)`. CREATE OR REPLACE VIEW without a WITH
-- clause resets reloptions, so a later ad-hoc replace through run_sql.py
-- dropped the flag without touching the SQL that documents it. ALTER VIEW is
-- used here rather than re-creating the views, so the definitions stay put.

alter view public.weekly_master    set (security_invoker = true);
alter view public.food_weekly      set (security_invoker = true);
alter view public.week_time_budget set (security_invoker = true);

-- Guard: re-running CREATE OR REPLACE VIEW on any of these must re-specify the
-- option. Verify with
--   select relname, reloptions from pg_class c
--   join pg_namespace n on n.oid = c.relnamespace
--   where n.nspname = 'public' and c.relkind = 'v';
-- and expect security_invoker=true on every row.
