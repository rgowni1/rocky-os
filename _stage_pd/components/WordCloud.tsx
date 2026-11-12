"use client";

import { useMemo, useState } from "react";
import type { JournalTextRow } from "@/lib/supabase";
import { countTerms } from "@/lib/words";
import { POLARITY, INK } from "@/components/viz/theme";

type Scope = "all" | "year" | "quarter";

const SCOPES: { key: Scope; label: string }[] = [
  { key: "quarter", label: "This quarter" },
  { key: "year", label: "Year to date" },
  { key: "all", label: "All time" },
];

function inScope(week: string, scope: Scope, latest: string): boolean {
  if (scope === "all") return true;
  const d = new Date(week + "T12:00:00");
  const ref = new Date(latest + "T12:00:00");
  if (d.getFullYear() !== ref.getFullYear()) return false;
  if (scope === "year") return true;
  return Math.floor(d.getMonth() / 3) === Math.floor(ref.getMonth() / 3);
}

function Cloud({ terms, color }: { terms: ReturnType<typeof countTerms>; color: string }) {
  if (!terms.length) {
    return (
      <p className="text-sm" style={{ color: INK.muted }}>
        No journal text in this window yet.
      </p>
    );
  }
  return (
    // Baseline-aligned so wildly different sizes still sit on a common line.
    <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
      {terms.map((t) => (
        <span
          key={t.text}
          title={`${t.text} — ${t.count}×`}
          style={{
            // weight is already sqrt-compressed; 13→30px reads at both ends
            fontSize: `${(13 + t.weight * 17).toFixed(1)}px`,
            fontWeight: t.weight > 0.66 ? 700 : t.weight > 0.33 ? 600 : 500,
            // Never below 0.6: the tail has to stay legible, not fade out
            color,
            opacity: (0.6 + t.weight * 0.4).toFixed(2),
            lineHeight: 1.25,
          }}
        >
          {t.text}
        </span>
      ))}
    </div>
  );
}

export function WordCloud({ journal }: { journal: JournalTextRow[] }) {
  const [scope, setScope] = useState<Scope>("year");
  const [showTable, setShowTable] = useState(false);

  const latest = journal.length ? journal[journal.length - 1].week : null;

  const { highs, lows, weeks } = useMemo(() => {
    if (!latest) return { highs: [], lows: [], weeks: 0 };
    const rows = journal.filter((r) => inScope(r.week, scope, latest));
    return {
      highs: countTerms(rows.map((r) => r.journal_high), 45),
      lows: countTerms(rows.map((r) => r.journal_low), 45),
      weeks: rows.filter((r) => r.journal_high || r.journal_low).length,
    };
  }, [journal, scope, latest]);

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5">
      <div className="flex flex-wrap items-center justify-between gap-3 mb-1">
        <div>
          <h3 className="text-zinc-100 font-semibold">Journal themes</h3>
          <p className="text-xs" style={{ color: INK.muted }}>
            Recurring words and phrases across {weeks} weeks of High / Low notes
          </p>
        </div>
        {/* Filters in one row above the marks */}
        <div className="flex gap-1">
          {SCOPES.map((s) => (
            <button
              key={s.key}
              onClick={() => setScope(s.key)}
              className={`text-xs px-2.5 py-1 rounded-lg transition-colors ${
                scope === s.key
                  ? "bg-zinc-700 text-zinc-100"
                  : "text-zinc-400 hover:bg-zinc-800"
              }`}
            >
              {s.label}
            </button>
          ))}
        </div>
      </div>

      <div className="grid md:grid-cols-2 gap-6 mt-4">
        <section>
          {/* Identity carried by the heading, not colour alone */}
          <div className="flex items-center gap-2 mb-2">
            <span
              className="w-2.5 h-2.5 rounded-full shrink-0"
              style={{ background: POLARITY.high }}
              aria-hidden
            />
            <h4 className="text-sm font-medium text-zinc-300">Highs &amp; energizers</h4>
          </div>
          <Cloud terms={highs} color={POLARITY.high} />
        </section>

        <section>
          <div className="flex items-center gap-2 mb-2">
            <span
              className="w-2.5 h-2.5 rounded-full shrink-0"
              style={{ background: POLARITY.low }}
              aria-hidden
            />
            <h4 className="text-sm font-medium text-zinc-300">Lows &amp; stressors</h4>
          </div>
          <Cloud terms={lows} color={POLARITY.low} />
        </section>
      </div>

      <button
        onClick={() => setShowTable((v) => !v)}
        className="mt-4 text-xs text-zinc-400 hover:text-zinc-200 underline underline-offset-2"
      >
        {showTable ? "Hide counts" : "Show counts as a table"}
      </button>

      {/* Size encodes magnitude; the table is how you read exact values. */}
      {showTable && (
        <div className="grid md:grid-cols-2 gap-6 mt-3 text-xs">
          {[
            { label: "Highs", terms: highs },
            { label: "Lows", terms: lows },
          ].map(({ label, terms }) => (
            <table key={label} className="w-full">
              <caption className="text-left text-zinc-400 mb-1">{label}</caption>
              <thead>
                <tr className="text-zinc-500">
                  <th className="text-left font-normal py-1">Term</th>
                  <th className="text-right font-normal py-1">Count</th>
                </tr>
              </thead>
              <tbody>
                {terms.slice(0, 20).map((t) => (
                  <tr key={t.text} className="border-t border-zinc-800">
                    <td className="py-1 text-zinc-300">{t.text}</td>
                    <td className="py-1 text-right text-zinc-400 tabular-nums">{t.count}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          ))}
        </div>
      )}
    </div>
  );
}
