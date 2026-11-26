// Plain-language formatting for the employee screens: money, dates, hours,
// tax labels and the "vs last check" line.
import { parseDay, shortDate } from '@/lib/display-date';
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

export { formatDate as longDate, shortDate, weekdayDate } from '@/lib/display-date';

/** Whole calendar days from `from` to `to` (both YYYY-MM-DD), or null if either isn't a date. */
export function daysBetween(from: string, to: string): number | null {
  const [a, b] = [parseDay(from), parseDay(to)];
  if (!a || !b) return null;
  return (b.getTime() - a.getTime()) / 86_400_000;
}

/** "Today", "Tomorrow" or "In 9 days" until a date; null once it has passed. */
export function daysUntilLabel(date: string, todayDate: string): string | null {
  const days = daysBetween(todayDate, date);
  if (days === null || days < 0) return null;
  return days === 0 ? 'Today' : days === 1 ? 'Tomorrow' : `In ${days} days`;
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
 * worked out: no earlier regular check (the API's `previous`, or the list
 * when the API didn't say), missing amounts, or a bonus, correction or
 * voided check on either side.
 */
export function comparisonLine(current: StatementSummary, statements: StatementSummary[]): string | null {
  const comparable = (s: StatementSummary): boolean => s.source === 'payroll' && s.payment.status !== 'voided' && s.runPurpose === 'regular';
  if (!comparable(current)) return null;
  // The API names the previous regular check, even one on another page.
  let previous: Pick<StatementSummary, 'payDate' | 'netPay' | 'totalHours'> | null | undefined = current.previous;
  if (previous === undefined) {
    const index = statements.findIndex((s) => s.id === current.id);
    previous = index < 0 ? null : statements.slice(index + 1).find(comparable);
  }
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

/**
 * Labels a PDF download button. Downloads stay available while amounts are
 * masked, and warn that the downloaded PDF shows dollar amounts.
 */
export function pdfDownloadLabel(baseLabel: string, hidden: boolean): string {
  if (!hidden) return baseLabel;
  return `${baseLabel.replace(/\s*\(PDF\)$/i, ' PDF')} (shows amounts)`;
}
