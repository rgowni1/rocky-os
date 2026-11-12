"use client";

import type { Goal } from "@/lib/types";

interface Props {
  goals: Goal[];
}

const CATEGORIES = [
  "Academic & Learning",
  "Professional & Career",
  "Personal",
  "Relationships",
];

const CATEGORY_COLORS: Record<string, string> = {
  "Academic & Learning": "bg-pink-500",
  "Professional & Career": "bg-yellow-500",
  "Personal": "bg-blue-500",
  "Relationships": "bg-red-500",
};

const STATUS_ORDER = ["Planning", "Backlog", "In Progress", "Paused", "Succeeded", "Done", "Failed", "Canceled"];

const isComplete = (status: string | null) =>
  status === "Succeeded" || status === "Done";

const isActive = (status: string | null) =>
  status === "In Progress" || status === "Planning" || status === "Backlog";

function ProgressBar({ value, color }: { value: number; color: string }) {
  return (
    <div className="h-2 bg-zinc-800 rounded-full overflow-hidden">
      <div
        className={`h-full ${color} rounded-full transition-all duration-500`}
        style={{ width: `${Math.min(100, value)}%` }}
      />
    </div>
  );
}

function GoalRow({ goal }: { goal: Goal }) {
  const complete = isComplete(goal.status);
  return (
    <div className="flex items-start gap-3 py-2">
      <div
        className={`w-2 h-2 rounded-full mt-1.5 flex-shrink-0 ${
          complete
            ? "bg-emerald-400"
            : goal.status === "In Progress"
            ? "bg-violet-400"
            : "bg-zinc-600"
        }`}
      />
      <div className="flex-1 min-w-0">
        <p className={`text-sm ${complete ? "line-through text-zinc-500" : "text-zinc-200"}`}>
          {goal.name}
        </p>
        <div className="flex gap-2 mt-0.5">
          {goal.priority && (
            <span className="text-xs text-zinc-500">{goal.priority}</span>
          )}
          {goal.status && (
            <span
              className={`text-xs px-1.5 py-0.5 rounded ${
                complete
                  ? "bg-emerald-400/10 text-emerald-400"
                  : goal.status === "In Progress"
                  ? "bg-violet-400/10 text-violet-400"
                  : "bg-zinc-700 text-zinc-400"
              }`}
            >
              {goal.status}
            </span>
          )}
        </div>
      </div>
      {goal.taskCount > 0 && (
        <span className="text-xs text-zinc-500 flex-shrink-0">{goal.taskCount} tasks</span>
      )}
    </div>
  );
}

export function GoalsSection({ goals }: Props) {
  const byCategory: Record<string, Goal[]> = {};
  for (const cat of CATEGORIES) byCategory[cat] = [];

  for (const goal of goals) {
    for (const cat of goal.lifeCategories) {
      if (byCategory[cat]) byCategory[cat].push(goal);
    }
    if (goal.lifeCategories.length === 0) {
      // uncategorized — skip
    }
  }

  const totalActive = goals.filter((g) => isActive(g.status)).length;
  const totalComplete = goals.filter((g) => isComplete(g.status)).length;
  const totalAll = goals.length;
  const pct = totalAll > 0 ? Math.round((totalComplete / totalAll) * 100) : 0;

  return (
    <div>
      {/* Summary bar */}
      <div className="grid grid-cols-3 gap-3 mb-6">
        <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4 text-center">
          <p className="text-2xl font-bold text-zinc-100">{totalAll}</p>
          <p className="text-xs text-zinc-500 mt-1">Total Goals</p>
        </div>
        <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4 text-center">
          <p className="text-2xl font-bold text-violet-400">{totalActive}</p>
          <p className="text-xs text-zinc-500 mt-1">In Progress</p>
        </div>
        <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4 text-center">
          <p className="text-2xl font-bold text-emerald-400">{pct}%</p>
          <p className="text-xs text-zinc-500 mt-1">Complete</p>
        </div>
      </div>

      {/* By category */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {CATEGORIES.map((cat) => {
          const catGoals = byCategory[cat];
          if (catGoals.length === 0) return null;
          const done = catGoals.filter((g) => isComplete(g.status)).length;
          const pct = Math.round((done / catGoals.length) * 100);
          const color = CATEGORY_COLORS[cat] ?? "bg-zinc-500";

          return (
            <div key={cat} className="bg-zinc-900 border border-zinc-800 rounded-xl p-4">
              <div className="flex items-center justify-between mb-2">
                <h3 className="text-sm font-medium text-zinc-300">{cat}</h3>
                <span className="text-xs text-zinc-500">
                  {done}/{catGoals.length}
                </span>
              </div>
              <ProgressBar value={pct} color={color} />
              <div className="mt-3 divide-y divide-zinc-800/50">
                {catGoals
                  .sort((a, b) => {
                    const ai = STATUS_ORDER.indexOf(a.status ?? "");
                    const bi = STATUS_ORDER.indexOf(b.status ?? "");
                    return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
                  })
                  .map((g) => (
                    <GoalRow key={g.id} goal={g} />
                  ))}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
