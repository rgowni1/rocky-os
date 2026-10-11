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

/**
 * The quantitative half of a week. Every flow lands here:
 * Oura → oura_daily → oura_weekly → sleep columns;
 * Readwise → readwise_daily → readwise_weekly → highlights/articles/podcasts;
 * Notion → journal_sync → everything else.
 */
export type WeeklyMetricsRow = {
  week: string;
  slp_hrs: number | null;
  slp_score: number | null;
  slp_hrv: number | null;
  rhr: number | null;
  avg_sleep_time: string | null;
  avg_wake_time: string | null;
  run_miles: number | null;
  bike_miles: number | null;
  swim_yards: number | null;
  strength_mins: number | null;
  intensity_mins: number | null;
  step_count: number | null;
  training_hrs: number | null;
  body_fat: number | null;
  weekly_weight: number | null;
  stress: number | null;
  meditation: number | null;
  highlights: number | null;
  articles: number | null;
  podcasts: number | null;
  phone_pickups: number | null;
  avg_daily_pickups: number | null;
  consumed_cals: number | null;
  avg_protein: number | null;
  calorie_deficit: number | null;
};

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
 * Weekly metrics from Supabase. Both bounds are Mondays.
 *
 * Prefer this over reading Notion or oura_daily directly from the app —
 * Supabase is the source of truth and Notion is downstream of it.
 */
export async function fetchWeeklyMetrics(
  startWeek: string,
  endWeek: string,
): Promise<WeeklyMetricsRow[]> {
  assertConfig();
  const qs =
    `select=*` +
    `&week=gte.${startWeek}` +
    `&week=lte.${endWeek}` +
    `&order=week.asc` +
    (userId ? `&user_id=eq.${userId}` : "");

  const res = await fetch(`${url}/rest/v1/weekly_metrics?${qs}`, {
    headers: {
      apikey: key!,
      Authorization: `Bearer ${key}`,
    },
    cache: "no-store",
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`weekly_metrics fetch failed ${res.status}: ${text}`);
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
