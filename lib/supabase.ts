const url = process.env.SUPABASE_URL?.replace(/\/$/, "");
const key = process.env.SUPABASE_SECRET_KEY ?? process.env.SUPABASE_ANON_KEY;
const userId = process.env.KANBAN_USER_ID ?? process.env.SUPABASE_USER_ID;

export type OuraDailyRow = {
  calendar_date: string;
  sleep_score: number | null;
  total_sleep_hours: number | null;
  average_hrv: number | null;
  lowest_heart_rate: number | null;
  average_breath: number | null;
};

function assertConfig() {
  if (!url || !key) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_SECRET_KEY");
  }
}

/** The narrative half of a journal week — the text a word cloud is built from. */
export type JournalTextRow = {
  week: string;
  journal_title: string | null;
  journal_high: string | null;
  journal_low: string | null;
  journal_high_of_week: string | null;
  journal_stressors: string | null;
  journal_bud: string | null;
};

/** Which of those columns actually hold prose, in the order they're worth reading. */
export const JOURNAL_TEXT_FIELDS = [
  "journal_high",
  "journal_low",
  "journal_high_of_week",
  "journal_stressors",
  "journal_bud",
] as const satisfies readonly (keyof JournalTextRow)[];

export async function fetchOuraDaily(startDate: string, endDate: string): Promise<OuraDailyRow[]> {
  assertConfig();
  const qs =
    `select=calendar_date,sleep_score,total_sleep_hours,average_hrv,lowest_heart_rate,average_breath` +
    `&calendar_date=gte.${startDate}` +
    `&calendar_date=lte.${endDate}` +
    `&order=calendar_date.asc` +
    (userId ? `&user_id=eq.${userId}` : "");

  const res = await fetch(`${url}/rest/v1/oura_daily?${qs}`, {
    headers: {
      apikey: key!,
      Authorization: `Bearer ${key}`,
    },
    cache: "no-store",
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`oura_daily fetch failed ${res.status}: ${text}`);
  }
  return res.json();
}

/**
 * Weekly journal narrative from Supabase, populated by journal_sync.py.
 *
 * `week` is the Monday the journal week starts on, so both bounds are Mondays.
 * Coverage runs 2023-01-07 → present. In practice only journal_high and
 * journal_low are consistently filled (~200 of 204 weeks); the other three
 * columns exist but are near-empty in Notion today.
 */
export async function fetchJournalText(
  startWeek: string,
  endWeek: string,
): Promise<JournalTextRow[]> {
  assertConfig();
  const qs =
    `select=week,journal_title,${JOURNAL_TEXT_FIELDS.join(",")}` +
    `&week=gte.${startWeek}` +
    `&week=lte.${endWeek}` +
    `&order=week.asc` +
    (userId ? `&user_id=eq.${userId}` : "");

  const res = await fetch(`${url}/rest/v1/journal_entries?${qs}`, {
    headers: {
      apikey: key!,
      Authorization: `Bearer ${key}`,
    },
    cache: "no-store",
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`journal_entries fetch failed ${res.status}: ${text}`);
  }
  return res.json();
}
