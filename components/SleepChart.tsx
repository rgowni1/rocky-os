"use client";

import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from "recharts";
import type { MonthlyLog } from "@/lib/types";
import { formatMonth } from "@/lib/utils";

interface Props {
  data: MonthlyLog[];
}

const CustomTooltip = ({ active, payload, label }: any) => {
  if (!active || !payload?.length) return null;
  return (
    <div className="bg-zinc-900 border border-zinc-700 rounded-lg p-3 text-xs">
      <p className="text-zinc-400 mb-2">{label}</p>
      {payload.map((entry: any) => (
        <p key={entry.name} style={{ color: entry.color }} className="flex justify-between gap-4">
          <span>{entry.name}</span>
          <span className="font-semibold">{entry.value ?? "—"}</span>
        </p>
      ))}
    </div>
  );
};

export function SleepChart({ data }: Props) {
  const chartData = data.map((d) => ({
    month: formatMonth(d.monthOf),
    "Sleep Score": d.slpScore,
    "HRV": d.slpHrv,
    "RHR": d.rhr,
  }));

  return (
    <ResponsiveContainer width="100%" height={220}>
      <LineChart data={chartData} margin={{ top: 5, right: 10, left: -20, bottom: 5 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#27272a" />
        <XAxis dataKey="month" tick={{ fill: "#71717a", fontSize: 11 }} tickLine={false} />
        <YAxis tick={{ fill: "#71717a", fontSize: 11 }} tickLine={false} axisLine={false} />
        <Tooltip content={<CustomTooltip />} />
        <Legend
          wrapperStyle={{ fontSize: 12, color: "#a1a1aa" }}
          iconType="circle"
          iconSize={8}
        />
        <Line type="monotone" dataKey="Sleep Score" stroke="#34d399" strokeWidth={2} dot={false} connectNulls />
        <Line type="monotone" dataKey="HRV" stroke="#a78bfa" strokeWidth={2} dot={false} connectNulls />
        <Line type="monotone" dataKey="RHR" stroke="#f87171" strokeWidth={2} dot={false} connectNulls />
      </LineChart>
    </ResponsiveContainer>
  );
}

export function WeightChart({ data }: Props) {
  const chartData = data
    .filter((d) => d.weeklyWeight)
    .map((d) => ({
      month: formatMonth(d.monthOf),
      "Weight (lbs)": d.weeklyWeight,
      "Body Fat %": d.bodyFat,
    }));

  return (
    <ResponsiveContainer width="100%" height={180}>
      <LineChart data={chartData} margin={{ top: 5, right: 10, left: -20, bottom: 5 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#27272a" />
        <XAxis dataKey="month" tick={{ fill: "#71717a", fontSize: 11 }} tickLine={false} />
        <YAxis tick={{ fill: "#71717a", fontSize: 11 }} tickLine={false} axisLine={false} />
        <Tooltip content={<CustomTooltip />} />
        <Legend wrapperStyle={{ fontSize: 12, color: "#a1a1aa" }} iconType="circle" iconSize={8} />
        <Line type="monotone" dataKey="Weight (lbs)" stroke="#fb923c" strokeWidth={2} dot={false} connectNulls />
        <Line type="monotone" dataKey="Body Fat %" stroke="#fbbf24" strokeWidth={2} dot={false} connectNulls />
      </LineChart>
    </ResponsiveContainer>
  );
}
