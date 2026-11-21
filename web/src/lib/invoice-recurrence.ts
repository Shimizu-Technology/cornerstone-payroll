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
  const anchor = (invoice.service_period_start || invoice.invoice_date).slice(0, 10);
  const step = Math.max(1, Math.trunc(count) || 1);
  let intervals = 1;
  let next = addInterval(anchor, unit, step);
  while (next < today && intervals < 1200) {
    intervals += 1;
    next = addInterval(anchor, unit, step * intervals);
  }
  return next;
}
