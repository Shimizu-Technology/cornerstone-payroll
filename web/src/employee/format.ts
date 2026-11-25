// Plain-language formatting for the employee screens: money, dates, hours,
// tax labels and the "vs last check" line.
import type { Money, StatementPayment, StatementSummary } from './contracts';

const USD = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });

export function toNumber(value: Money | null | undefined): number | null {
  if (value === null || value === undefined) return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

/** "$1,234.50". Null when the amount is missing, so the caller can hide the row. */
export function formatMoney(value: Money | null | undefined): string | null {
  const n = toNumber(value);
  return n === null ? null : USD.format(n);
}

/** "32.5" hours: no trailing zeros, at most two decimals. */
export function formatHours(value: string | null | undefined): string | null {
  const n = toNumber(value);
  if (n === null) return null;
  return String(Math.round(n * 100) / 100);
}

export function hoursLabel(value: string | null | undefined): string | null {
  const hours = formatHours(value);
  if (hours === null) return null;
  return `${hours} ${hours === '1' ? 'hour' : 'hours'}`;
}

/**
 * A YYYY-MM-DD date (or the date part of an ISO datetime) read as a calendar
 * day, never shifted by the device's time zone. Null for anything else, so a
 * malformed date never reaches Intl (which throws on an invalid Date).
 */
export function parseDay(value: string | null | undefined): Date | null {
  const match = typeof value === 'string' ? /^(\d{4})-(\d{2})-(\d{2})/.exec(value) : null;
  if (!match) return null;
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  const date = new Date(year, month - 1, day);
  return date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day ? date : null;
}

const SHORT = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });
const LONG = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
const WEEKDAY = new Intl.DateTimeFormat('en-US', { weekday: 'long', month: 'short', day: 'numeric' });

function formatDay(format: Intl.DateTimeFormat, value: string): string {
  const day = parseDay(value);
  return day ? format.format(day) : '';
}

/** "Nov 14" */
export function shortDate(value: string): string {
  return formatDay(SHORT, value);
}

/** "Nov 14, 2026" */
export function longDate(value: string): string {
  return formatDay(LONG, value);
}

/** "Friday, Nov 28" */
export function weekdayDate(value: string): string {
  return formatDay(WEEKDAY, value);
}

/** Whole calendar days from `from` to `to` (both YYYY-MM-DD), or null if either isn't a date. */
export function daysBetween(from: string, to: string): number | null {
  const [a, b] = [parseDay(from), parseDay(to)];
  if (!a || !b) return null;
  // UTC midnights, so a daylight-saving change on the device can't make a day 23 hours.
  const utc = (d: Date): number => Date.UTC(d.getFullYear(), d.getMonth(), d.getDate());
  return Math.round((utc(b) - utc(a)) / 86_400_000);
}

/** "Today", "Tomorrow" or "In 9 days" until a date; null once it has passed. */
export function daysUntilLabel(date: string, todayDate: string): string | null {
  const days = daysBetween(todayDate, date);
  if (days === null || days < 0) return null;
  return days === 0 ? 'Today' : days === 1 ? 'Tomorrow' : `In ${days} days`;
}

/** "Nov 1 – 14" or "Oct 25 – Nov 7". */
export function periodLabel(start: string | null, end: string | null): string | null {
  const [a, b] = [parseDay(start), parseDay(end)];
  if (!a || !b) return null;
  if (a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth()) {
    return `${SHORT.format(a)} – ${b.getDate()}`;
  }
  return `${SHORT.format(a)} – ${SHORT.format(b)}`;
}

/** How the check was paid, in the words the frozen PDF prints (M4-4). */
export function paymentLine(payment: StatementPayment): string | null {
  if (payment.method === 'direct_deposit') return 'Direct deposit';
  if (payment.method === 'paper_check') return payment.checkNumberLast4 ? `Check #${payment.checkNumberLast4}` : 'Paper check';
  return null;
}

/**
 * The status chip. Only states that are certain show: a check that's issued,
 * printed or voided. A direct deposit the company records outside Payroll
 * stays "pending" there for good, so pending shows nothing.
 */
export function paymentStatus(payment: StatementPayment): { label: string; tone: 'good' | 'neutral' | 'bad' } | null {
  switch (payment.status) {
    case 'issued': return { label: payment.method === 'paper_check' ? 'Check delivered' : 'Paid', tone: 'good' };
    case 'prepared': return payment.method === 'paper_check' ? { label: 'Check ready', tone: 'neutral' } : null;
    case 'voided': return { label: 'Voided', tone: 'bad' };
    default: return null;
  }
}

/**
 * Plain labels with the technical term in small print (§8a). Guam income tax
 * is never called "Federal", even though the printed stub's label reads
 * "Federal/Guam Income Tax".
 */
export function taxLabel(label: string): { label: string; term: string | null } {
  const lower = label.toLowerCase();
  if (lower.startsWith('additional withholding')) return { label: 'Extra Guam income tax you asked for', term: 'Additional withholding (W-4 4c)' };
  if (lower.includes('income tax') || lower.includes('withholding')) return { label: 'Guam income tax', term: 'Withholding' };
  if (lower.startsWith('social security')) return { label: 'Social Security', term: 'FICA' };
  if (lower.startsWith('medicare')) return { label: 'Medicare', term: 'FICA' };
  return { label: label.replace(/\bfederal\b\s*\/?\s*/gi, '').trim() || label, term: null };
}

function plural(n: number, one: string, many: string): string {
  return n === 1 ? one : many;
}

/**
 * "$36.45 less than Nov 5. You worked 3.5 fewer hours." Null when it can't be
 * worked out: no earlier regular check in the list, missing amounts, or a
 * bonus, correction or voided check on either side.
 */
export function comparisonLine(current: StatementSummary, statements: StatementSummary[]): string | null {
  const comparable = (s: StatementSummary): boolean => s.source === 'payroll' && s.payment.status !== 'voided' && s.runPurpose === 'regular';
  if (!comparable(current)) return null;
  const index = statements.findIndex((s) => s.id === current.id);
  if (index < 0) return null;
  const previous = statements.slice(index + 1).find(comparable);
  if (!previous) return null;
  const [now, before] = [toNumber(current.netPay), toNumber(previous.netPay)];
  if (now === null || before === null) return null;

  const cents = Math.round((now - before) * 100);
  const when = shortDate(previous.payDate);
  const money = cents === 0 ? `Same take-home pay as ${when}.`
    : `${USD.format(Math.abs(cents) / 100)} ${cents > 0 ? 'more' : 'less'} than ${when}.`;

  const [hoursNow, hoursBefore] = [toNumber(current.totalHours), toNumber(previous.totalHours)];
  if (hoursNow === null || hoursBefore === null || hoursNow === 0 || hoursBefore === 0) return money;
  const diff = Math.round((hoursNow - hoursBefore) * 100) / 100;
  if (diff === 0) return `${money} Same hours.`;
  const amount = Math.abs(diff);
  return `${money} You worked ${amount} ${diff > 0 ? plural(amount, 'more hour', 'more hours') : plural(amount, 'fewer hour', 'fewer hours')}.`;
}

/** (671) 555-0100 for Guam and US numbers; anything else as entered. */
export { formatPhone } from '@/lib/employee-app-text';

export function telHref(phone: string): string {
  const digits = phone.replace(/[^\d+]/g, '');
  return `tel:${digits}`;
}

export function smsHref(phone: string): string {
  return `sms:${phone.replace(/[^\d+]/g, '')}`;
}

/** Each address line, skipping blanks: ["123 Marine Corps Dr", "Apt 4", "Tamuning, GU 96913"]. */
export function addressLines(address: { line1: string; line2: string; city: string; state: string; zip: string }): string[] {
  const place = [address.city, [address.state, address.zip].filter(Boolean).join(' ')].filter(Boolean).join(', ');
  return [address.line1, address.line2, place].filter((line) => line.trim() !== '');
}
