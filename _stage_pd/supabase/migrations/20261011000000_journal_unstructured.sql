-- The remaining unstructured (non-numeric) fields of the weekly Notion Logging
-- Journal. journal_entries was built almost entirely out of numbers; the only
-- narrative columns were journal_high / journal_low (20261006000000). Everything
-- else a week is actually *about* — who you saw, what was stressing you, the
-- high of the week — stayed in Notion and never reached Supabase, so nothing
-- downstream could read it.
--
-- Extends journal_entries rather than adding a weekly_journal table: same grain
-- (one row per user per Monday-start week, unique on user_id, week), and the
-- high/low columns already live here. A separate table would be a strict 1:1.

alter table public.journal_entries
  add column if not exists journal_high_of_week text,
  add column if not exists journal_stressors    text,
  add column if not exists journal_bud          text,
  add column if not exists people_met           text[],
  add column if not exists people_tagged        text[],
  add column if not exists journal_title        text,
  -- Catch-all so a new Notion text property can be captured without a
  -- migration. Shape: {"<Notion property name>": "<plain text>"}. Promote a key
  -- to a real column once something actually queries it.
  add column if not exists unstructured         jsonb;

comment on column public.journal_entries.journal_high_of_week is
  'Notion "High Of the Week" rich_text. Distinct from journal_high ("High").';
comment on column public.journal_entries.journal_stressors is
  'Notion "Stressors" rich_text — free text, not the numeric stress column.';
comment on column public.journal_entries.journal_bud is
  'Notion "Bud" rich_text.';
comment on column public.journal_entries.people_met is
  'Notion "People Met" (people property), flattened to display names.';
comment on column public.journal_entries.people_tagged is
  'Notion "Person" (people property), flattened to display names. Appears to be
   the older of the two people fields; kept separate rather than merged into
   people_met so a sync can tell them apart.';
comment on column public.journal_entries.journal_title is
  'Notion page title ("Name").';
comment on column public.journal_entries.unstructured is
  'Any other Notion text property, keyed by its Notion name. Escape hatch.';

-- GIN index so the catch-all stays queryable as it fills up.
create index if not exists journal_entries_unstructured_idx
  on public.journal_entries using gin (unstructured);
