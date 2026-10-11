-- Readwise gets the same shape as Oura: source → daily granular table →
-- weekly view → weekly_metrics + Notion. Until now Readwise had no Supabase
-- presence at all; oura.py computed weekly counts in memory and wrote them
-- straight to Notion, and journal_sync.py then read them back out of Notion
-- into weekly_metrics. Nothing was stored at day grain.
--
-- Grain is (user_id, calendar_date, book_id), not (user_id, calendar_date).
-- A week's "distinct articles" is COUNT(DISTINCT book_id), which cannot be
-- recovered by summing per-day distinct counts — a source highlighted across
-- three days would count three times. Keeping the book id lets the weekly view
-- dedupe properly.

create table if not exists public.readwise_daily (
  user_id         uuid not null references auth.users (id) on delete cascade,
  calendar_date   date not null,            -- America/Los_Angeles, matching oura_daily
  book_id         bigint not null,          -- Readwise source id
  book_title      text,
  author          text,
  category        text,                     -- books | articles | podcasts | tweets | supplementals
  source          text,                     -- kindle, reader, airr, …
  source_url      text,
  is_youtube      boolean not null default false,
  highlight_count integer not null default 0,
  synced_at       timestamptz not null default now(),
  primary key (user_id, calendar_date, book_id)
);

create index if not exists readwise_daily_user_date_idx
  on public.readwise_daily (user_id, calendar_date desc);

alter table public.readwise_daily enable row level security;

drop policy if exists "Users can read their own readwise rows" on public.readwise_daily;
create policy "Users can read their own readwise rows"
  on public.readwise_daily for select to authenticated
  using ((select auth.uid()) = user_id);

grant select on table public.readwise_daily to authenticated;
grant all on table public.readwise_daily to service_role;

-- Weekly rollup. Classification mirrors what oura.py wrote to Notion:
-- a YouTube source counts as video regardless of its Readwise category, and
-- "Podcasts & Videos" is the two combined.
create or replace view public.readwise_weekly
with (security_invoker = true) as
select
  user_id,
  date_trunc('week', calendar_date)::date as week_start,
  sum(highlight_count)::int as highlights,
  count(distinct book_id) filter (
    where category = 'articles' and not is_youtube
  )::int as distinct_articles,
  count(distinct book_id) filter (
    where category = 'podcasts' or is_youtube
  )::int as distinct_podcasts_videos,
  count(distinct book_id) filter (where category = 'books')::int as distinct_books,
  count(distinct book_id)::int as distinct_sources
from public.readwise_daily
group by 1, 2;

-- weekly_metrics already carries articles and podcasts; highlights was only
-- ever a Notion property.
alter table public.weekly_metrics
  add column if not exists highlights numeric;

comment on column public.weekly_metrics.highlights is
  'Readwise highlights captured that week. From readwise_weekly, not Notion.';
