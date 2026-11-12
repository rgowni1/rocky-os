"use client";

import {
  LineChart, Line, BarChart, Bar, XAxis, YAxis, CartesianGrid,
  Tooltip, Legend, ResponsiveContainer,
} from "recharts";
import type { WeeklyMetricsRow } from "@/lib/supabase";
import { SERIES, INK, AXIS_TICK } from "@/components/viz/theme";

function weekLabel(week: string): string {
  const d = new Date(week + "T12:00:00");
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

/** Crosshair tooltip. Values wear ink tokens; the colour chip carries identity. */
function ChartTooltip({ active, payload, label }: any) {
  if (!active || !payload?.length) return null;
  return (
    <div className="rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-xs shadow-lg">
      <p className="mb-1.5" style={{ color: INK.muted }}>
        Week of {label}
      </p>
      {payload.map((entry: any) => (
        <p key={entry.name} className="flex items-center justify-between gap-4 py-0.5">
          <span className="flex items-center gap-1.5">
            <span
              className="w-2 h-2 rounded-full shrink-0"
              style={{ background: entry.color }}
              aria-hidden
            />
            <span className="text-zinc-300">{entry.name}</span>
          </span>
          <span className="font-semibold tabular-nums text-zinc-100">
            {entry.value ?? "—"}
          </span>
        </p>
      ))}
    </div>
  );
}

const LEGEND = { fontSize: 12, color: INK.secondary } as const;

const fmtInt = (v: number) => String(Math.round(v));
const fmtPct = (v: number) => `${Math.round(v)}%`;

function Frame({ children, height = 200 }: { children: any; height?: number }) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      {children}
    </ResponsiveContainer>
  );
}

function Grid() {
  return <CartesianGrid stroke={INK.grid} vertical={false} />;
}

function Axes({ unit }: { unit?: string }) {
  return (
    <>
      {/* 26 weekly labels don't fit; minTickGap thins them to what's readable
          and still lands on real week boundaries. */}
      <XAxis
        dataKey="week"
        tick={AXIS_TICK}
        tickLine={false}
        axisLine={{ stroke: INK.axis }}
        minTickGap={28}
      />
      {/* A unit suffix needs the extra room — at 44px "24 mi" lost its leading digit. */}
      <YAxis
        tick={AXIS_TICK}
        tickLine={false}
        axisLine={false}
        width={unit ? 58 : 44}
        unit={unit}
      />
    </>
  );
}

type Props = { data: WeeklyMetricsRow[] };

/** Sleep quality: three indicators that share a 0–100-ish range, so one axis is honest. */
export function SleepQualityChart({ data }: Props) {
  const rows = data.map((d) => ({
    week: weekLabel(d.week),
    "Sleep score": d.slp_score,
    "HRV": d.slp_hrv,
    "Resting HR": d.rhr,
  }));
  return (
    <Frame>
      <LineChart data={rows} margin={{ top: 5, right: 8, left: -12, bottom: 0 }}>
        <Grid />
        <Axes />
        <Tooltip content={<ChartTooltip />} cursor={{ stroke: INK.axis }} />
        <Legend wrapperStyle={LEGEND} iconType="circle" iconSize={8} />
        <Line type="monotone" dataKey="Sleep score" stroke={SERIES[0]} strokeWidth={2} dot={false} connectNulls isAnimationActive={false} />
        <Line type="monotone" dataKey="HRV" stroke={SERIES[1]} strokeWidth={2} dot={false} connectNulls isAnimationActive={false} />
        <Line type="monotone" dataKey="Resting HR" stroke={SERIES[2]} strokeWidth={2} dot={false} connectNulls isAnimationActive={false} />
      </LineChart>
    </Frame>
  );
}

/** Hours slept. One series — the title names it, so no legend box. */
export function SleepHoursChart({ data }: Props) {
  const rows = data.map((d) => ({ week: weekLabel(d.week), "Hours": d.slp_hrs }));
  return (
    <Frame height={170}>
      <LineChart data={rows} margin={{ top: 5, right: 8, left: -12, bottom: 0 }}>
        <Grid />
        <Axes unit="h" />
        <Tooltip content={<ChartTooltip />} cursor={{ stroke: INK.axis }} />
        <Line type="monotone" dataKey="Hours" stroke={SERIES[0]} strokeWidth={2} dot={false} connectNulls isAnimationActive={false} />
      </LineChart>
    </Frame>
  );
}

/**
 * Weight and body fat are plotted apart on purpose. Sharing one axis put ~170 lb
 * against ~20 % and flattened the body-fat line into the baseline.
 */
export function WeightChart({ data }: Props) {
  const rows = data.filter((d) => d.weekly_weight != null)
    .map((d) => ({ week: weekLabel(d.week), "Weight": d.weekly_weight }));
  return (
    <Frame height={170}>
      <LineChart data={rows} margin={{ top: 5, right: 8, left: -12, bottom: 0 }}>
        <Grid />
        {/* Narrow domain so a 2 lb move is visible; unit lives in the panel title
            rather than on every tick, which was clipping at 44px. */}
        <YAxis tick={AXIS_TICK} tickLine={false} axisLine={false} width={52} domain={["dataMin - 2", "dataMax + 2"]} tickFormatter={fmtInt} />
        <XAxis dataKey="week" tick={AXIS_TICK} tickLine={false} axisLine={{ stroke: INK.axis }} minTickGap={28} />
        <Tooltip content={<ChartTooltip />} cursor={{ stroke: INK.axis }} />
        <Line type="monotone" dataKey="Weight" stroke={SERIES[1]} strokeWidth={2} dot={false} connectNulls isAnimationActive={false} />
      </LineChart>
    </Frame>
  );
}

export function BodyFatChart({ data }: Props) {
  const rows = data.filter((d) => d.body_fat != null)
    .map((d) => ({ week: weekLabel(d.week), "Body fat": d.body_fat }));
  return (
    <Frame height={170}>
      <LineChart data={rows} margin={{ top: 5, right: 8, left: -12, bottom: 0 }}>
        <Grid />
        <YAxis tick={AXIS_TICK} tickLine={false} axisLine={false} width={48} tickFormatter={fmtPct} />
        <XAxis dataKey="week" tick={AXIS_TICK} tickLine={false} axisLine={{ stroke: INK.axis }} minTickGap={28} />
        <Tooltip content={<ChartTooltip />} cursor={{ stroke: INK.axis }} />
        <Line type="monotone" dataKey="Body fat" stroke={SERIES[2]} strokeWidth={2} dot={false} connectNulls isAnimationActive={false} />
      </LineChart>
    </Frame>
  );
}

/** Run and bike share a unit, so they belong on one axis. */
export function MilesChart({ data }: Props) {
  const rows = data.map((d) => ({
    week: weekLabel(d.week),
    "Run": d.run_miles,
    "Bike": d.bike_miles,
  }));
  return (
    <Frame>
      <BarChart data={rows} margin={{ top: 5, right: 8, left: -12, bottom: 0 }} barGap={2}>
        <Grid />
        <Axes unit=" mi" />
        <Tooltip content={<ChartTooltip />} cursor={{ fill: "rgba(255,255,255,0.04)" }} />
        <Legend wrapperStyle={LEGEND} iconType="circle" iconSize={8} />
        <Bar dataKey="Run" fill={SERIES[0]} radius={[4, 4, 0, 0]} isAnimationActive={false} />
        <Bar dataKey="Bike" fill={SERIES[1]} radius={[4, 4, 0, 0]} isAnimationActive={false} />
      </BarChart>
    </Frame>
  );
}

export function TrainingHoursChart({ data }: Props) {
  const rows = data.map((d) => ({ week: weekLabel(d.week), "Training": d.training_hrs }));
  return (
    <Frame height={170}>
      <BarChart data={rows} margin={{ top: 5, right: 8, left: -12, bottom: 0 }}>
        <Grid />
        <Axes unit="h" />
        <Tooltip content={<ChartTooltip />} cursor={{ fill: "rgba(255,255,255,0.04)" }} />
        <Bar dataKey="Training" fill={SERIES[2]} radius={[4, 4, 0, 0]} isAnimationActive={false} />
      </BarChart>
    </Frame>
  );
}

/** Reading: three counts of the same kind of thing. */
export function ReadingChart({ data }: Props) {
  const rows = data.map((d) => ({
    week: weekLabel(d.week),
    "Articles": d.articles,
    "Podcasts & video": d.podcasts,
    "Books": d.distinct_books,
  }));
  return (
    <Frame>
      <BarChart data={rows} margin={{ top: 5, right: 8, left: -12, bottom: 0 }} barGap={2}>
        <Grid />
        <Axes />
        <Tooltip content={<ChartTooltip />} cursor={{ fill: "rgba(255,255,255,0.04)" }} />
        <Legend wrapperStyle={LEGEND} iconType="circle" iconSize={8} />
        <Bar dataKey="Articles" fill={SERIES[0]} radius={[4, 4, 0, 0]} isAnimationActive={false} />
        <Bar dataKey="Podcasts & video" fill={SERIES[1]} radius={[4, 4, 0, 0]} isAnimationActive={false} />
        <Bar dataKey="Books" fill={SERIES[2]} radius={[4, 4, 0, 0]} isAnimationActive={false} />
      </BarChart>
    </Frame>
  );
}

export function PickupsChart({ data }: Props) {
  const rows = data.map((d) => ({ week: weekLabel(d.week), "Daily pickups": d.avg_daily_pickups }));
  return (
    <Frame height={170}>
      <BarChart data={rows} margin={{ top: 5, right: 8, left: -12, bottom: 0 }}>
        <Grid />
        <Axes />
        <Tooltip content={<ChartTooltip />} cursor={{ fill: "rgba(255,255,255,0.04)" }} />
        <Bar dataKey="Daily pickups" fill={SERIES[1]} radius={[4, 4, 0, 0]} isAnimationActive={false} />
      </BarChart>
    </Frame>
  );
}

/** Deep-focus blocks. Three thresholds of one measure — a natural 3-series set. */
export function FocusChart({ data }: Props) {
  const rows = data.map((d) => ({
    week: weekLabel(d.week),
    "2h+": d.focus_blocks_2h,
    "3h+": d.focus_blocks_3h,
    "4h+": d.focus_blocks_4h,
  }));
  return (
    <Frame>
      <BarChart data={rows} margin={{ top: 5, right: 8, left: -12, bottom: 0 }} barGap={2}>
        <Grid />
        <Axes />
        <Tooltip content={<ChartTooltip />} cursor={{ fill: "rgba(255,255,255,0.04)" }} />
        <Legend wrapperStyle={LEGEND} iconType="circle" iconSize={8} />
        <Bar dataKey="2h+" fill={SERIES[0]} radius={[4, 4, 0, 0]} isAnimationActive={false} />
        <Bar dataKey="3h+" fill={SERIES[1]} radius={[4, 4, 0, 0]} isAnimationActive={false} />
        <Bar dataKey="4h+" fill={SERIES[2]} radius={[4, 4, 0, 0]} isAnimationActive={false} />
      </BarChart>
    </Frame>
  );
}
