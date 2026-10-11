"use client";

interface MetricCardProps {
  label: string;
  value: string | number | null;
  unit?: string;
  sub?: string;
  trend?: "up" | "down" | "neutral";
  color?: "emerald" | "violet" | "orange" | "sky" | "rose" | "amber";
}

const colorMap = {
  emerald: "text-emerald-400 bg-emerald-400/10 border-emerald-400/20",
  violet: "text-violet-400 bg-violet-400/10 border-violet-400/20",
  orange: "text-orange-400 bg-orange-400/10 border-orange-400/20",
  sky: "text-sky-400 bg-sky-400/10 border-sky-400/20",
  rose: "text-rose-400 bg-rose-400/10 border-rose-400/20",
  amber: "text-amber-400 bg-amber-400/10 border-amber-400/20",
};

export function MetricCard({ label, value, unit, sub, trend, color = "sky" }: MetricCardProps) {
  const colors = colorMap[color];

  return (
    <div className={`rounded-xl border p-4 flex flex-col gap-1 ${colors}`}>
      <span className="text-xs font-medium uppercase tracking-wider opacity-60">{label}</span>
      <div className="flex items-baseline gap-1 mt-1">
        <span className="text-3xl font-bold">
          {value === null || value === undefined ? "—" : value}
        </span>
        {unit && <span className="text-sm opacity-60">{unit}</span>}
      </div>
      {sub && <span className="text-xs opacity-50">{sub}</span>}
    </div>
  );
}
