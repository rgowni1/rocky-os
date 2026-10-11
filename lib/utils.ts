export function formatMonth(dateStr: string | null): string {
  if (!dateStr) return "";
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-US", { month: "short", year: "2-digit" });
}

export function last<T>(arr: T[], n = 1): T | undefined {
  return arr[arr.length - n];
}

export function avg(arr: (number | null)[], key?: undefined): number | null {
  const vals = arr.filter((v): v is number => v !== null);
  if (!vals.length) return null;
  return +(vals.reduce((a, b) => a + b, 0) / vals.length).toFixed(1);
}

export function delta(curr: number | null, prev: number | null): string {
  if (curr === null || prev === null) return "";
  const d = curr - prev;
  return d > 0 ? `+${d.toFixed(1)}` : d.toFixed(1);
}
