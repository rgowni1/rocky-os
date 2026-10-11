"use client";

import {
  BarChart,
  Bar,
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

interface Props {
  data: MonthlyLog[];
}

export function FocusChart({ data }: Props) {
  const chartData = data.map((d) => ({
    month: formatMonth(d.monthOf),
    "Deep Work": d.deepWork ?? 0,
    "Meditation": d.meditationSessions ?? 0,
    "Articles": d.articles ?? 0,
  }));

  return (
    <ResponsiveContainer width="100%" height={220}>
      <BarChart data={chartData} margin={{ top: 5, right: 10, left: -20, bottom: 5 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#27272a" />
        <XAxis dataKey="month" tick={{ fill: "#71717a", fontSize: 11 }} tickLine={false} />
        <YAxis tick={{ fill: "#71717a", fontSize: 11 }} tickLine={false} axisLine={false} />
        <Tooltip content={<CustomTooltip />} />
        <Legend wrapperStyle={{ fontSize: 12, color: "#a1a1aa" }} iconType="circle" iconSize={8} />
        <Bar dataKey="Deep Work" fill="#a78bfa" radius={[2, 2, 0, 0]} />
        <Bar dataKey="Meditation" fill="#34d399" radius={[2, 2, 0, 0]} />
        <Bar dataKey="Articles" fill="#fbbf24" radius={[2, 2, 0, 0]} />
      </BarChart>
    </ResponsiveContainer>
  );
}

export function PhonePickupsChart({ data }: Props) {
  const chartData = data.map((d) => ({
    month: formatMonth(d.monthOf),
    "Phone Pickups": d.totalPhPickUps ?? 0,
  }));

  return (
    <ResponsiveContainer width="100%" height={160}>
      <LineChart data={chartData} margin={{ top: 5, right: 10, left: -20, bottom: 5 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#27272a" />
        <XAxis dataKey="month" tick={{ fill: "#71717a", fontSize: 11 }} tickLine={false} />
        <YAxis tick={{ fill: "#71717a", fontSize: 11 }} tickLine={false} axisLine={false} />
        <Tooltip content={<CustomTooltip />} />
        <Legend wrapperStyle={{ fontSize: 12, color: "#a1a1aa" }} iconType="circle" iconSize={8} />
        <Line type="monotone" dataKey="Phone Pickups" stroke="#f87171" strokeWidth={2} dot={false} connectNulls />
      </LineChart>
    </ResponsiveContainer>
  );
}
