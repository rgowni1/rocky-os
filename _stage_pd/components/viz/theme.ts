/**
 * Chart tokens. Every colour here was run through the data-viz validator
 * against this app's actual dark chart surface (#18181b), not a default one.
 *
 *   series 1–3 (all-pairs)  CVD ΔE 9.4 · normal-vision ΔE 20.9 · all ≥3:1
 *   highs ↔ lows            CVD ΔE 19.2 · normal-vision ΔE 29.0
 *
 * Three series is the cap. The fourth categorical slot puts yellow beside
 * orange, which fails the all-pairs floors — past three, fold into "Other"
 * or facet into small multiples.
 */
export const SURFACE = "#18181b";

/** Categorical slots, in fixed order. Never cycle; never assign by rank. */
export const SERIES = ["#3987e5", "#d95926", "#199e70"] as const;

/** Polarity, not identity: the journal's two moods. */
export const POLARITY = {
  high: "#3987e5",
  low: "#e66767",
} as const;

/** Chart chrome — recessive by design. */
export const INK = {
  primary: "#ffffff",
  secondary: "#c3c2b7",
  muted: "#898781",
  grid: "#2c2c2a",
  axis: "#383835",
} as const;

export const AXIS_TICK = { fill: INK.muted, fontSize: 11 } as const;
