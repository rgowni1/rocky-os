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
