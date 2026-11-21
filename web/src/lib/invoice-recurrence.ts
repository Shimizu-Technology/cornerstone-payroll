/** Days from invoice date to due date that recognized terms set: "Net 15" is 15, "Due on receipt" is 0, anything else is null. */
export function termsDueDays(terms?: string | null): number | null {
  const text = (terms || '').trim();
  const days = text.match(/^Net\s+(\d+)$/i)?.[1];
  if (days) return Number(days);
  return text.toLowerCase() === 'due on receipt' ? 0 : null;
}

function addInterval(date: string, unit: 'week' | 'month', amount: number): string {
  const [year, month, day] = date.split('-').map(Number);
  if (unit === 'week') {
    const next = new Date(Date.UTC(year, month - 1, day + amount * 7));
    return next.toISOString().slice(0, 10);
  }
  // Same rule as Rails' Date#advance: Jan 31 + 1 month is Feb 28.
  const target = new Date(Date.UTC(year, month - 1 + amount, 1));
  const lastDay = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0)).getUTCDate();
  target.setUTCDate(Math.min(day, lastDay));
  return target.toISOString().slice(0, 10);
}

/**
 * The first date for a new recurrence: the period after the source
 * invoice's (its service period start, else its invoice date, plus one
 * interval), moved forward whole intervals until it isn't before today.
 * Each recurring draft covers its date to the day before the next one.
 */
export function nextRecurrenceStart(
  invoice: { invoice_date: string; service_period_start?: string | null },
  unit: 'week' | 'month',
  count: number,
  today: string,
): string {
  const anchor = (invoice.service_period_start || invoice.invoice_date || '').slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(anchor) || !/^\d{4}-\d{2}-\d{2}$/.test(today)) return today;
  const step = Math.max(1, Math.trunc(count) || 1);
  // Start from the number of whole intervals between the anchor and today,
  // so an old anchor needs no long loop; the loop below only finishes the
  // last step or two (month lengths vary).
  let intervals: number;
  if (unit === 'week') {
    const days = (Date.parse(`${today}T00:00:00Z`) - Date.parse(`${anchor}T00:00:00Z`)) / 86_400_000;
    intervals = Math.max(1, Math.ceil(days / (7 * step)));
  } else {
    const [anchorYear, anchorMonth] = anchor.split('-').map(Number);
    const [todayYear, todayMonth] = today.split('-').map(Number);
    intervals = Math.max(1, Math.floor(((todayYear - anchorYear) * 12 + (todayMonth - anchorMonth)) / step));
  }
  let next = addInterval(anchor, unit, step * intervals);
  while (next < today) {
    intervals += 1;
    next = addInterval(anchor, unit, step * intervals);
  }
  return next;
}
