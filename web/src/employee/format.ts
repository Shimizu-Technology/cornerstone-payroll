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

function plural(n: number, one: string, many: string): string {
  return n === 1 ? one : many;
}

/**
 * "$36.45 less than Nov 6. You worked 3.5 fewer hours." When `hideMoney` is
 * true, returns only the hours comparison ("You worked 3.5 fewer hours than
 * Nov 6." or "Same hours as Nov 6."), or null when hours aren't comparable.
 */
export function comparisonLine(
  current: StatementSummary,
  statements: StatementSummary[],
  options: { hideMoney?: boolean } = {},
): string | null {
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

  const when = shortDate(previous.payDate);
  const [hoursNow, hoursBefore] = [toNumber(current.totalHours), toNumber(previous.totalHours)];
  const hasComparableHours = hoursNow !== null && hoursBefore !== null && hoursNow !== 0 && hoursBefore !== 0;

  if (options.hideMoney) {
    if (!hasComparableHours) return null;
    const diff = Math.round((hoursNow - hoursBefore) * 100) / 100;
    if (diff === 0) return `Same hours as ${when}.`;
    const amount = Math.abs(diff);
    return `You worked ${amount} ${diff > 0 ? plural(amount, 'more hour', 'more hours') : plural(amount, 'fewer hour', 'fewer hours')} than ${when}.`;
  }

  const cents = Math.round((now - before) * 100);
  const money = cents === 0 ? `Same take-home pay as ${when}.`
    : `${USD.format(Math.abs(cents) / 100)} ${cents > 0 ? 'more' : 'less'} than ${when}.`;

  if (!hasComparableHours) return money;
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

// Matches currency expressions in free-text notes or imported line labels:
// "$45.00", "-$45.00", "$-45.00", "$.50", "$15.125", "($45.00)", "$(45.00)",
// "45.67 USD", "USD 45.67", "(45.67 USD)", "(USD 45.67)", "US$45.67".
// Leaves dates, hours ("36.5 hrs"), percentages and check numbers untouched.
const CURRENCY_NUMBER = '(?:\\d[\\d,]*(?:\\.\\d+)?|\\.\\d+)';
const CURRENCY_IN_TEXT = new RegExp(
  [
    `\\(\\s*(?:US)?\\$\\s*[-+]?${CURRENCY_NUMBER}\\s*\\)`,
    `\\(\\s*USD\\s*[-+]?${CURRENCY_NUMBER}\\s*\\)`,
    `\\(\\s*[-+]?${CURRENCY_NUMBER}\\s*USD\\s*\\)`,
    `(?:US)?\\$\\(\\s*${CURRENCY_NUMBER}\\s*\\)`,
    `(?:(?<![A-Za-z0-9])[-+]\\s*)?(?:US)?\\$\\s*[-+]?${CURRENCY_NUMBER}`,
    `(?:(?<![A-Za-z0-9])[-+]\\s*)?\\bUSD\\s*[-+]?${CURRENCY_NUMBER}`,
    `(?:(?<![A-Za-z0-9])[-+]\\s*)?${CURRENCY_NUMBER}\\s*USD\\b`,
  ].join('|'),
  'gi',
);

export interface TextSegment {
  text: string;
  isMoney: boolean;
}

/** Splits free-text notes or imported line labels into plain text and currency segments. */
export function splitCurrencySegments(text: string): TextSegment[] {
  const segments: TextSegment[] = [];
  let lastIndex = 0;
  for (const match of text.matchAll(CURRENCY_IN_TEXT)) {
    const start = match.index ?? 0;
    if (start > lastIndex) {
      segments.push({ text: text.slice(lastIndex, start), isMoney: false });
    }
    segments.push({ text: match[0], isMoney: true });
    lastIndex = start + match[0].length;
  }
  if (lastIndex < text.length) {
    segments.push({ text: text.slice(lastIndex), isMoney: false });
  }
  return segments.length > 0 ? segments : [{ text, isMoney: false }];
}
