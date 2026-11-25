// Treat ISO calendar days as dates in their own right. For an instant that
// needs to be shown on the Guam calendar, use formatGuamDate instead.
export function parseDay(value?: string | null): Date | null {
  if (!value) return null;
  const day = value.match(/^\d{4}-\d{2}-\d{2}(?=$|T)/)?.[0];
  if (!day || !Number.isFinite(Date.parse(value))) return null;

  const date = new Date(`${day}T00:00:00Z`);
  return date.toISOString().slice(0, 10) === day ? date : null;
}

const MONTH_DAY = new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', month: 'short', day: 'numeric' });
const FULL_DATE = new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' });
const FULL_DATE_WITH_WEEKDAY = new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });
const WEEKDAY = new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', weekday: 'long', month: 'short', day: 'numeric' });

export function formatDate(value?: string | null, { includeWeekday = false } = {}): string {
  const date = parseDay(value);
  const formatter = includeWeekday ? FULL_DATE_WITH_WEEKDAY : FULL_DATE;
  return date ? formatter.format(date) : '';
}

export function shortDate(value?: string | null): string {
  const date = parseDay(value);
  return date ? MONTH_DAY.format(date) : '';
}

export function weekdayDate(value?: string | null): string {
  const date = parseDay(value);
  return date ? WEEKDAY.format(date) : '';
}

export function formatDateRange(start?: string | null, end?: string | null): string {
  const first = parseDay(start);
  const last = parseDay(end);
  if (!first || !last) return '';
  if (first.getTime() === last.getTime()) return FULL_DATE.format(first);

  const year = last.getUTCFullYear();
  if (first.getUTCFullYear() !== year) {
    return `${FULL_DATE.format(first)} – ${FULL_DATE.format(last)}`;
  }
  if (first.getUTCMonth() === last.getUTCMonth()) {
    return `${MONTH_DAY.format(first)} – ${last.getUTCDate()}, ${year}`;
  }
  return `${MONTH_DAY.format(first)} – ${FULL_DATE.format(last)}`;
}
