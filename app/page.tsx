import { MetricCard } from "@/components/MetricCard";
import { SectionHeader } from "@/components/SectionHeader";
import { SleepChart, WeightChart } from "@/components/SleepChart";
import { ActivityMilesChart, TrainingHoursChart } from "@/components/FitnessChart";
import { FocusChart, PhonePickupsChart } from "@/components/FocusChart";
import { GoalsSection } from "@/components/GoalsSection";
import type { MonthlyLog, Goal, TaskSummary } from "@/lib/types";

const NAV = [
  { label: "Overview", href: "#overview" },
  { label: "Health", href: "#health" },
  { label: "Fitness", href: "#fitness" },
  { label: "Focus", href: "#focus" },
  { label: "Goals", href: "#goals" },
];

async function getData() {
  const base = process.env.NEXT_PUBLIC_BASE_URL ?? "http://localhost:3000";
  const [logRes, goalsRes, tasksRes] = await Promise.all([
    fetch(`${base}/api/log`, { cache: "no-store" }),
    fetch(`${base}/api/goals`, { cache: "no-store" }),
    fetch(`${base}/api/tasks`, { cache: "no-store" }),
  ]);

  const logs: MonthlyLog[] = logRes.ok ? await logRes.json() : [];
  const goals: Goal[] = goalsRes.ok ? await goalsRes.json() : [];
  const tasks: TaskSummary = tasksRes.ok
    ? await tasksRes.json()
    : { total: 0, done: 0, inProgress: 0, notStarted: 0, byPriority: {} };

  return { logs, goals, tasks };
}

function num(v: number | null | undefined, decimals = 0): number | null {
  if (v === null || v === undefined) return null;
  return decimals > 0 ? +v.toFixed(decimals) : Math.round(v);
}

export default async function Page() {
  const { logs, goals, tasks } = await getData();

  const recent = logs.slice(-12);
  const latest = logs[logs.length - 1] ?? null;

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100">
      {/* Header */}
      <header className="sticky top-0 z-10 border-b border-zinc-800 bg-zinc-950/90 backdrop-blur-sm">
        <div className="max-w-6xl mx-auto px-4 py-3 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-7 h-7 rounded-lg bg-gradient-to-br from-violet-500 to-indigo-600 flex items-center justify-center text-xs font-bold">
              P
            </div>
            <span className="font-semibold text-zinc-100 hidden sm:block">Personal Intelligence</span>
          </div>
          <nav className="flex gap-1">
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
          <div className="text-xs text-zinc-500">
            {new Date().toLocaleDateString("en-US", {
              month: "short",
              day: "numeric",
              year: "numeric",
            })}
          </div>
        </div>
      </header>

      <main className="max-w-6xl mx-auto px-4 py-8 space-y-14">
        {/* Overview */}
        <section id="overview">
          <SectionHeader
            title="This Month"
            subtitle={
              latest?.monthOf
                ? new Date(latest.monthOf + "T00:00:00").toLocaleDateString("en-US", { month: "long", year: "numeric" })
                : "Latest entry"
            }
          />
          <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
            <MetricCard label="Sleep Score" value={num(latest?.slpScore)} unit="/100" color="emerald" />
            <MetricCard label="HRV" value={num(latest?.slpHrv)} unit="ms" color="violet" />
            <MetricCard label="Training" value={num(latest?.loggedTrainingHrs, 1)} unit="hrs" color="orange" />
            <MetricCard label="Deep Work" value={num(latest?.deepWork)} unit="days" color="sky" />
            <MetricCard label="Weight" value={num(latest?.weeklyWeight, 1)} unit="lbs" color="amber" />
            <MetricCard label="Phone Picks" value={num(latest?.totalPhPickUps)} color="rose" />
          </div>

          {tasks.total > 0 && (
            <div className="mt-4 grid grid-cols-3 gap-3">
              <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4 text-center">
                <p className="text-2xl font-bold text-zinc-100">{tasks.total}</p>
                <p className="text-xs text-zinc-500 mt-1">Total Tasks</p>
              </div>
              <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4 text-center">
                <p className="text-2xl font-bold text-violet-400">{tasks.inProgress}</p>
                <p className="text-xs text-zinc-500 mt-1">In Progress</p>
              </div>
              <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4 text-center">
                <p className="text-2xl font-bold text-emerald-400">{tasks.done}</p>
                <p className="text-xs text-zinc-500 mt-1">Done</p>
              </div>
            </div>
          )}
        </section>

        {/* Health & Sleep */}
        <section id="health">
          <SectionHeader
            title="Health & Sleep"
            subtitle="Sleep quality, heart rate variability, and body composition"
          />
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
            <MetricCard label="Sleep Hrs" value={num(latest?.slpHrs, 1)} unit="hrs" color="emerald" />
            <MetricCard label="RHR" value={num(latest?.rhr)} unit="bpm" color="rose" />
            <MetricCard label="Breath Rate" value={num(latest?.breathRate)} unit="rpm" color="sky" />
            <MetricCard label="Stress" value={num(latest?.stressLevel)} unit="/10" color="amber" />
          </div>
          {recent.length > 0 ? (
            <div className="space-y-4">
              <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4">
                <p className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-4">
                  Sleep Score · HRV · RHR (last {recent.length} months)
                </p>
                <SleepChart data={recent} />
              </div>
              <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4">
                <p className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-4">
                  Weight & Body Fat
                </p>
                <WeightChart data={recent} />
              </div>
            </div>
          ) : (
            <EmptyState message="No log data yet — add entries to your Notion Log database." />
          )}
        </section>

        {/* Fitness */}
        <section id="fitness">
          <SectionHeader
            title="Fitness & Activity"
            subtitle="Monthly mileage, training volume, and movement"
          />
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
            <MetricCard label="Run Miles" value={num(latest?.runMiles, 1)} color="emerald" />
            <MetricCard label="Bike Miles" value={num(latest?.bikeMiles, 1)} color="sky" />
            <MetricCard label="Swim Yards" value={num(latest?.swimYards)} color="violet" />
            <MetricCard
              label="Steps"
              value={latest?.stepCount ? `${(latest.stepCount / 1000).toFixed(1)}k` : null}
              color="orange"
            />
          </div>
          {recent.length > 0 ? (
            <div className="space-y-4">
              <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4">
                <p className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-4">
                  Miles by Activity (Run · Bike · Swim)
                </p>
                <ActivityMilesChart data={recent} />
              </div>
              <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4">
                <p className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-4">
                  Training Hours & Daily Steps
                </p>
                <TrainingHoursChart data={recent} />
              </div>
            </div>
          ) : (
            <EmptyState message="No log data yet." />
          )}
        </section>

        {/* Focus */}
        <section id="focus">
          <SectionHeader
            title="Focus & Productivity"
            subtitle="Deep work sessions, meditation, reading, and screen habits"
          />
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-4">
            <MetricCard label="Deep Work" value={num(latest?.deepWork)} unit="days" color="violet" />
            <MetricCard label="Meditation" value={num(latest?.meditationSessions)} unit="sessions" color="emerald" />
            <MetricCard label="Articles" value={num(latest?.articles)} color="amber" />
            <MetricCard label="Podcasts/Videos" value={num(latest?.podcastsVideos)} color="sky" />
          </div>
          {recent.length > 0 ? (
            <div className="space-y-4">
              <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4">
                <p className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-4">
                  Deep Work · Meditation · Articles
                </p>
                <FocusChart data={recent} />
              </div>
              <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4">
                <p className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-4">
                  Monthly Phone Pickups (lower is better)
                </p>
                <PhonePickupsChart data={recent} />
              </div>
            </div>
          ) : (
            <EmptyState message="No log data yet." />
          )}
        </section>

        {/* Goals */}
        <section id="goals">
          <SectionHeader title="Q2 2026 Goals" subtitle="Progress by life category" />
          {goals.length > 0 ? (
            <GoalsSection goals={goals} />
          ) : (
            <EmptyState message="No goals found. Make sure your Goals database is shared with the Notion integration." />
          )}
        </section>
      </main>

      <footer className="border-t border-zinc-800 mt-16 py-6 text-center text-xs text-zinc-600">
        Personal Intelligence · Synced from Notion
      </footer>
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
