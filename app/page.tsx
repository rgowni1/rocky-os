import { MetricCard } from "@/components/MetricCard";
import { SectionHeader } from "@/components/SectionHeader";
import { GoalsSection } from "@/components/GoalsSection";
import { WordCloud } from "@/components/WordCloud";
import {
  SleepQualityChart, SleepHoursChart, WeightChart, BodyFatChart,
  MilesChart, TrainingHoursChart, ReadingChart, PickupsChart, FocusChart,
} from "@/components/WeeklyCharts";
import { fetchWeeklyMetrics, fetchJournalText } from "@/lib/supabase";
import type { Goal } from "@/lib/types";

const NAV = [
  { label: "Overview", href: "#overview" },
  { label: "Health", href: "#health" },
  { label: "Fitness", href: "#fitness" },
  { label: "Focus", href: "#focus" },
  { label: "Journal", href: "#journal" },
  { label: "Goals", href: "#goals" },
];

/** Monday of the week containing `d`, which is the grain of every weekly table. */
function mondayOf(d: Date): string {
  const copy = new Date(d);
  copy.setDate(copy.getDate() - ((copy.getDay() + 6) % 7));
  return copy.toISOString().slice(0, 10);
}

async function getData() {
  const end = mondayOf(new Date());
  const start = "2023-01-01";

  // Supabase is the source of truth; Notion is downstream of it. Goals are the
  // one thing with no Supabase equivalent, so they still come from the API route.
  const base = process.env.NEXT_PUBLIC_BASE_URL ?? "http://localhost:3000";
  const [weekly, journal, goals] = await Promise.all([
    fetchWeeklyMetrics(start, end).catch(() => []),
    fetchJournalText(start, end).catch(() => []),
    fetch(`${base}/api/goals`, { cache: "no-store" })
      .then((r) => (r.ok ? r.json() : []))
      .catch(() => []) as Promise<Goal[]>,
  ]);

  return { weekly, journal, goals };
}

function num(v: number | null | undefined, decimals = 0): number | null {
  if (v === null || v === undefined) return null;
  return decimals > 0 ? +Number(v).toFixed(decimals) : Math.round(Number(v));
}

export default async function Page() {
  const { weekly, journal, goals } = await getData();

  // Recharts reads left-to-right, and the fetch is already week-ascending.
  const recent = weekly.slice(-26);
  const latest = weekly[weekly.length - 1] ?? null;

  const latestLabel = latest
    ? new Date(latest.week + "T12:00:00").toLocaleDateString("en-US", {
        month: "long",
        day: "numeric",
        year: "numeric",
      })
    : "No data";

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100">
      <header className="sticky top-0 z-10 border-b border-zinc-800 bg-zinc-950/90 backdrop-blur-sm">
        <div className="max-w-6xl mx-auto px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-7 h-7 rounded-lg bg-gradient-to-br from-violet-500 to-indigo-600 flex items-center justify-center text-xs font-bold">
              P
            </div>
            <span className="font-semibold text-zinc-100 hidden sm:block">Personal Intelligence</span>
          </div>
          <nav className="flex gap-1 flex-wrap">
            {NAV.map((item) => (
              <a
                key={item.href}
                href={item.href}
                className="text-sm text-zinc-400 hover:text-zinc-100 px-3 py-1.5 rounded-lg hover:bg-zinc-800 transition-colors"
              >
                {item.label}
              </a>
            ))}
          </nav>
        </div>
      </header>

      <main className="max-w-6xl mx-auto px-4 py-8 space-y-14">
        <section id="overview">
          <SectionHeader title="Latest Week" subtitle={`Week of ${latestLabel}`} />
          <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
            <MetricCard label="Sleep Score" value={num(latest?.slp_score)} unit="/100" color="emerald" />
            <MetricCard label="Sleep" value={num(latest?.slp_hrs, 1)} unit="hrs" color="sky" />
            <MetricCard label="HRV" value={num(latest?.slp_hrv)} unit="ms" color="violet" />
            <MetricCard label="Training" value={num(latest?.training_hrs, 1)} unit="hrs" color="orange" />
            <MetricCard label="Weight" value={num(latest?.weekly_weight, 1)} unit="lbs" color="amber" />
            <MetricCard label="Pickups/day" value={num(latest?.avg_daily_pickups)} color="rose" />
          </div>
        </section>

        <section id="health">
          <SectionHeader
            title="Health & Sleep"
            subtitle="Sleep quality and body composition, by week"
          />
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
            <MetricCard label="RHR" value={num(latest?.rhr)} unit="bpm" color="rose" />
            <MetricCard label="Breath Rate" value={num(latest?.breath_rate, 1)} unit="rpm" color="sky" />
            <MetricCard label="Sleep Latency" value={num(latest?.slp_latency)} unit="min" color="amber" />
            <MetricCard label="Body Fat" value={num(latest?.body_fat, 1)} unit="%" color="violet" />
          </div>
          {recent.length ? (
            <div className="space-y-4">
              <Panel title={`Sleep score · HRV · resting HR — last ${recent.length} weeks`}>
                <SleepQualityChart data={recent} />
              </Panel>
              <Panel title="Hours slept">
                <SleepHoursChart data={recent} />
              </Panel>
              <div className="grid md:grid-cols-2 gap-4">
                <Panel title="Weight (lb)">
                  <WeightChart data={recent} />
                </Panel>
                <Panel title="Body fat (%)">
                  <BodyFatChart data={recent} />
                </Panel>
              </div>
            </div>
          ) : (
            <EmptyState message="No weekly data yet — check that the Oura and journal syncs have run." />
          )}
        </section>

        <section id="fitness">
          <SectionHeader title="Fitness & Activity" subtitle="Weekly mileage and training volume" />
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
            <MetricCard label="Run Miles" value={num(latest?.run_miles, 1)} color="emerald" />
            <MetricCard label="Bike Miles" value={num(latest?.bike_miles, 1)} color="sky" />
            <MetricCard label="Strength" value={num(latest?.strength_mins)} unit="min" color="violet" />
            <MetricCard
              label="Steps/day"
              value={latest?.step_count ? `${(Number(latest.step_count) / 1000).toFixed(1)}k` : null}
              color="orange"
            />
          </div>
          {recent.length ? (
            <div className="space-y-4">
              <Panel title="Miles by activity">
                <MilesChart data={recent} />
              </Panel>
              <Panel title="Logged training hours">
                <TrainingHoursChart data={recent} />
              </Panel>
            </div>
          ) : (
            <EmptyState message="No weekly data yet." />
          )}
        </section>

        <section id="focus">
          <SectionHeader
            title="Focus & Attention"
            subtitle="Uninterrupted work blocks, reading, and screen habits"
          />
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
            <MetricCard label="Focus Blocks 2h+" value={num(latest?.focus_blocks_2h)} color="violet" />
            <MetricCard label="Longest Block" value={num(latest?.longest_focus_hrs, 1)} unit="hrs" color="emerald" />
            <MetricCard label="Highlights" value={num(latest?.highlights)} color="amber" />
            <MetricCard label="Meditation" value={num(latest?.meditation)} unit="sessions" color="sky" />
          </div>
          {recent.length ? (
            <div className="space-y-4">
              <Panel title="Uninterrupted focus blocks, by length">
                <FocusChart data={recent} />
              </Panel>
              <Panel title="Reading & listening">
                <ReadingChart data={recent} />
              </Panel>
              <Panel title="Average daily phone pickups — lower is better">
                <PickupsChart data={recent} />
              </Panel>
            </div>
          ) : (
            <EmptyState message="No weekly data yet." />
          )}
        </section>

        <section id="journal">
          <SectionHeader title="Journal" subtitle="What the weeks have been about" />
          {journal.length ? (
            <WordCloud journal={journal} />
          ) : (
            <EmptyState message="No journal text yet — run journal_sync.py." />
          )}
        </section>

        <section id="goals">
          <SectionHeader title="Goals" subtitle="Progress by life category" />
          {goals.length ? (
            <GoalsSection goals={goals} />
          ) : (
            <EmptyState message="No goals found. Check the Goals database is shared with the Notion integration." />
          )}
        </section>
      </main>

      <footer className="border-t border-zinc-800 mt-16 py-6 text-center text-xs text-zinc-600">
        Personal Intelligence · {weekly.length} weeks from Supabase
      </footer>
    </div>
  );
}

function Panel({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4">
      <p className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-4">{title}</p>
      {children}
    </div>
  );
}

function EmptyState({ message }: { message: string }) {
  return (
    <div className="bg-zinc-900 border border-dashed border-zinc-700 rounded-xl p-8 text-center text-zinc-500 text-sm">
      {message}
    </div>
  );
}
