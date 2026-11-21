const currency = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });
const hoursFormat = new Intl.NumberFormat('en-US', { minimumFractionDigits: 1, maximumFractionDigits: 2 });

export function money(value: string | null | undefined): string {
  if (value === null || value === undefined) return '—';
  return currency.format(Number(value));
}

export function hours(value: string | null | undefined): string {
  if (value === null || value === undefined) return '—';
  return hoursFormat.format(Number(value));
}

export function percent(value: string | null | undefined): string {
  return value === null || value === undefined ? '—' : `${value}%`;
}

export function isNegative(value: string | null | undefined): boolean {
  return value !== null && value !== undefined && Number(value) < 0;
}

export function isZero(value: string | null | undefined): boolean {
  return value === null || value === undefined || Number(value) === 0;
}

const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

export function monthKey(year: number, month: number): string {
  return `${year}-${String(month).padStart(2, '0')}`;
}

export function monthLabel(key: string): string {
  const [year, month] = key.split('-').map(Number);
  return `${MONTH_NAMES[month - 1]} ${year}`;
}

/** The last `count` months, newest first, as "YYYY-MM". */
export function recentMonths(today: Date, count = 36): string[] {
  const months: string[] = [];
  let year = today.getFullYear();
  let month = today.getMonth() + 1;
  for (let index = 0; index < count; index += 1) {
    months.push(monthKey(year, month));
    month -= 1;
    if (month === 0) { month = 12; year -= 1; }
  }
  return months;
}

export interface QuarterOption { key: string; label: string; from: string; through: string }

export function recentQuarters(today: Date, count = 12): QuarterOption[] {
  const quarters: QuarterOption[] = [];
  let year = today.getFullYear();
  let quarter = Math.floor(today.getMonth() / 3) + 1;
  for (let index = 0; index < count; index += 1) {
    const first = (quarter - 1) * 3 + 1;
    quarters.push({
      key: `${year}-Q${quarter}`,
      label: `Q${quarter} ${year} (${MONTH_NAMES[first - 1].slice(0, 3)}–${MONTH_NAMES[first + 1].slice(0, 3)})`,
      from: monthKey(year, first),
      through: monthKey(year, first + 2),
    });
    quarter -= 1;
    if (quarter === 0) { quarter = 4; year -= 1; }
  }
  return quarters;
}

export function formatDateTime(value: string | null): string {
  if (!value) return '—';
  return new Intl.DateTimeFormat('en-US', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value));
}

export function formatDate(value: string | null): string {
  if (!value) return '—';
  const [year, month, day] = value.split('-').map(Number);
  return new Intl.DateTimeFormat('en-US', { dateStyle: 'medium' }).format(new Date(year, month - 1, day));
}
