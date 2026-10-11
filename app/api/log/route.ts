import { NextResponse } from "next/server";
import { queryAll, getNumber, getDate, DB } from "@/lib/notion";
import { fetchOuraDaily } from "@/lib/supabase";
import type { MonthlyLog } from "@/lib/types";

function avgNulls(vals: (number | null)[]): number | null {
  const nums = vals.filter((v): v is number => v !== null);
  if (!nums.length) return null;
  return +(nums.reduce((a, b) => a + b, 0) / nums.length).toFixed(1);
}

function sumNulls(vals: (number | null)[]): number | null {
  const nums = vals.filter((v): v is number => v !== null);
  if (!nums.length) return null;
  return +nums.reduce((a, b) => a + b, 0).toFixed(1);
}

type MonthBucket = {
  pages: any[];
  oura: {
    sleep_score: (number | null)[];
    total_sleep_hours: (number | null)[];
    average_hrv: (number | null)[];
    lowest_heart_rate: (number | null)[];
    average_breath: (number | null)[];
  };
};

function emptyOura() {
  return {
    sleep_score: [] as (number | null)[],
    total_sleep_hours: [] as (number | null)[],
    average_hrv: [] as (number | null)[],
    lowest_heart_rate: [] as (number | null)[],
    average_breath: [] as (number | null)[],
  };
}

export async function GET() {
  try {
    const pages = await queryAll(
      DB.log,
      undefined,
      [{ property: "Week of Journal", direction: "ascending" }]
    );

    const byMonth: Record<string, MonthBucket> = {};
    for (const page of pages) {
      const dateStr = getDate(page, "Week of Journal");
      if (!dateStr) continue;
      const monthKey = dateStr.slice(0, 7);
      if (!byMonth[monthKey]) byMonth[monthKey] = { pages: [], oura: emptyOura() };
      byMonth[monthKey].pages.push(page);
    }

    // Sleep / recovery from Supabase oura_daily (source of truth).
    try {
      const yearStart = `${new Date().getFullYear() - 1}-01-01`;
      const today = new Date().toISOString().slice(0, 10);
      const ouraRows = await fetchOuraDaily(yearStart, today);
      for (const row of ouraRows) {
        const monthKey = row.calendar_date.slice(0, 7);
        if (!byMonth[monthKey]) byMonth[monthKey] = { pages: [], oura: emptyOura() };
        byMonth[monthKey].oura.sleep_score.push(row.sleep_score);
        byMonth[monthKey].oura.total_sleep_hours.push(row.total_sleep_hours);
        byMonth[monthKey].oura.average_hrv.push(row.average_hrv);
        byMonth[monthKey].oura.lowest_heart_rate.push(row.lowest_heart_rate);
        byMonth[monthKey].oura.average_breath.push(row.average_breath);
      }
    } catch (e: any) {
      console.warn("oura_daily unavailable, falling back to Notion sleep fields:", e.message);
    }

    const logs: MonthlyLog[] = Object.entries(byMonth)
      .sort(([a], [b]) => (a > b ? 1 : -1))
      .map(([monthKey, bucket]) => {
        const entries = bucket.pages;
        const g = (prop: string) => entries.map((p) => getNumber(p, prop));
        const ouraAvg = (vals: (number | null)[]) => avgNulls(vals);
        const hasOura = bucket.oura.sleep_score.some((v) => v != null);

        return {
          id: monthKey,
          name: new Date(monthKey + "-01T00:00:00").toLocaleDateString("en-US", {
            month: "long",
            year: "numeric",
          }),
          monthOf: monthKey + "-01",
          // Health — Oura from Supabase when present, else Notion weekly averages
          slpHrs: hasOura ? ouraAvg(bucket.oura.total_sleep_hours) : avgNulls(g("Slp Hrs")),
          slpScore: hasOura ? ouraAvg(bucket.oura.sleep_score) : avgNulls(g("Slp Score")),
          slpHrv: hasOura ? ouraAvg(bucket.oura.average_hrv) : avgNulls(g("Slp HRV")),
          rhr: hasOura ? ouraAvg(bucket.oura.lowest_heart_rate) : avgNulls(g("RHR")),
          breathRate: hasOura ? ouraAvg(bucket.oura.average_breath) : avgNulls(g("Breath Rate")),
          stressLevel: avgNulls(g("Stress Level")),
          weeklyWeight: avgNulls(g("Weekly Weight")),
          bodyFat: avgNulls(g("Body Fat %")),
          mbs: avgNulls(g("MBs")),
          // Fitness — summed across weeks
          runMiles: sumNulls(g("Run Miles")),
          bikeMiles: sumNulls(g("Bike Miles")),
          swimYards: sumNulls(g("Swim Yards")),
          loggedTrainingHrs: sumNulls(g("Logged Training Hrs")),
          stepCount: sumNulls(g("Step Count")),
          intensityMinutes: sumNulls(g("Intensity Minutes")),
          strengthMinutes: sumNulls(g("Strength Minutes")),
          // Focus — summed across weeks
          deepWork: sumNulls(g("Deep Work Check")),
          meditationSessions: sumNulls(g("Meditation Sessions")),
          totalPhPickUps: sumNulls(g("Total Ph Pick Ups")),
          articles: sumNulls(g("Articles")),
          podcastsVideos: sumNulls(g("Podcasts & Videos")),
        };
      });

    return NextResponse.json(logs);
  } catch (e: any) {
    return NextResponse.json({ error: e.message }, { status: 500 });
  }
}
