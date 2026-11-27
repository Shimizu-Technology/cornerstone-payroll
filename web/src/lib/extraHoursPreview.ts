const DECIMAL_RE = /^\d{1,9}(\.\d{1,2})?$/;
const HOURS_PER_WEEK_BEFORE_OT_HUNDREDTHS = 4000; // 40.00 hours
const MAX_WEEK_HOURS_HUNDREDTHS = 16800; // 168.00 hours
const MAX_EXTRA_HOURS_HUNDREDTHS = 100000; // 1000.00 hours

export type ExtraHoursMode = 'split' | 'workweek' | 'straight_time';

export interface ExtraHoursWorkweek {
  index: number;
  start_date: string;
  end_date: string;
  label: string;
}

export interface ExtraHoursPreviewResult {
  valid: boolean;
  error?: string;
  totalHours: number;
  deltaRegularHours: number;
  deltaOvertimeHours: number;
  resultingRegularHours: number;
  resultingOvertimeHours: number;
  grossPayDelta: number | null;
}

export function parseDecimalHundredths(value: string | number | undefined | null): number | null {
  if (value === undefined || value === null) return null;
  const text = String(value).trim();
  if (!text || !DECIMAL_RE.test(text)) return null;
  const [whole, frac = ''] = text.split('.');
  const padded = (frac + '00').slice(0, 2);
  return Number(whole) * 100 + Number(padded);
}

export function formatHoursHundredths(hundredths: number): string {
  const sign = hundredths < 0 ? '-' : '';
  const abs = Math.abs(Math.round(hundredths));
  const whole = Math.floor(abs / 100);
  const frac = String(abs % 100).padStart(2, '0');
  return `${sign}${whole}.${frac}`;
}

export function formatCompactHours(hundredths: number): string {
  const formatted = formatHoursHundredths(hundredths);
  return formatted.replace(/\.00$/, '').replace(/(\.\d)0$/, '$1');
}

export function splitWeeklyHundredths(week1: number, week2: number): { regular: number; overtime: number } {
  const reg1 = Math.min(week1, HOURS_PER_WEEK_BEFORE_OT_HUNDREDTHS);
  const ot1 = Math.max(week1 - HOURS_PER_WEEK_BEFORE_OT_HUNDREDTHS, 0);
  const reg2 = Math.min(week2, HOURS_PER_WEEK_BEFORE_OT_HUNDREDTHS);
  const ot2 = Math.max(week2 - HOURS_PER_WEEK_BEFORE_OT_HUNDREDTHS, 0);
  return { regular: reg1 + reg2, overtime: ot1 + ot2 };
}

function roundCentsFromExact(hoursHundredths: number, rateCents: number, multiplierTenths: number): number {
  // hours = hoursHundredths / 100, rate = rateCents / 100, multiplier = multiplierTenths / 10
  // cents = (hoursHundredths * rateCents * multiplierTenths) / 1000
  const numerator = hoursHundredths * rateCents * multiplierTenths;
  return Math.round(numerator / 1000);
}

export function computeExtraHoursPreview(params: {
  mode: ExtraHoursMode;
  rate?: string | number | null;
  baselineRegularHours?: string | number | null;
  baselineOvertimeHours?: string | number | null;
  baselineWeek1Hours?: string | number | null;
  baselineWeek2Hours?: string | number | null;
  hours?: string;
  regularHours?: string;
  overtimeHours?: string;
  workweek?: number | null;
  workweekCount?: number;
}): ExtraHoursPreviewResult {
  const baseReg = parseDecimalHundredths(params.baselineRegularHours) ?? 0;
  const baseOt = parseDecimalHundredths(params.baselineOvertimeHours) ?? 0;
  const rateCents = parseDecimalHundredths(params.rate);

  if (params.mode === 'straight_time') {
    const hours = parseDecimalHundredths(params.hours);
    if (hours === null || hours <= 0 || hours > MAX_EXTRA_HOURS_HUNDREDTHS) {
      return {
        valid: false,
        error: 'Enter extra hours greater than zero.',
        totalHours: 0,
        deltaRegularHours: 0,
        deltaOvertimeHours: 0,
        resultingRegularHours: baseReg / 100,
        resultingOvertimeHours: baseOt / 100,
        grossPayDelta: null,
      };
    }
    const grossCents = rateCents === null ? null : roundCentsFromExact(hours, rateCents, 10);
    return {
      valid: true,
      totalHours: hours / 100,
      deltaRegularHours: hours / 100,
      deltaOvertimeHours: 0,
      resultingRegularHours: (baseReg + hours) / 100,
      resultingOvertimeHours: baseOt / 100,
      grossPayDelta: grossCents === null ? null : grossCents / 100,
    };
  }

  if (params.mode === 'split') {
    const regRaw = (params.regularHours ?? '').trim();
    const otRaw = (params.overtimeHours ?? '').trim();
    if (!regRaw && !otRaw) {
      return {
        valid: false,
        error: 'Enter regular hours and/or overtime hours before approving.',
        totalHours: 0,
        deltaRegularHours: 0,
        deltaOvertimeHours: 0,
        resultingRegularHours: baseReg / 100,
        resultingOvertimeHours: baseOt / 100,
        grossPayDelta: null,
      };
    }
    const reg = regRaw ? parseDecimalHundredths(regRaw) : 0;
    const ot = otRaw ? parseDecimalHundredths(otRaw) : 0;
    if (reg === null || ot === null) {
      return {
        valid: false,
        error: 'Enter valid non-negative regular and overtime hours.',
        totalHours: 0,
        deltaRegularHours: 0,
        deltaOvertimeHours: 0,
        resultingRegularHours: baseReg / 100,
        resultingOvertimeHours: baseOt / 100,
        grossPayDelta: null,
      };
    }
    const total = reg + ot;
    if (total <= 0 || total > MAX_EXTRA_HOURS_HUNDREDTHS) {
      return {
        valid: false,
        error: 'Regular and overtime hours must total more than zero (up to 1,000 hours).',
        totalHours: 0,
        deltaRegularHours: 0,
        deltaOvertimeHours: 0,
        resultingRegularHours: baseReg / 100,
        resultingOvertimeHours: baseOt / 100,
        grossPayDelta: null,
      };
    }
    const grossCents = rateCents === null
      ? null
      : roundCentsFromExact(reg, rateCents, 10) + roundCentsFromExact(ot, rateCents, 15);
    return {
      valid: true,
      totalHours: total / 100,
      deltaRegularHours: reg / 100,
      deltaOvertimeHours: ot / 100,
      resultingRegularHours: (baseReg + reg) / 100,
      resultingOvertimeHours: (baseOt + ot) / 100,
      grossPayDelta: grossCents === null ? null : grossCents / 100,
    };
  }

  // workweek mode
  const hours = parseDecimalHundredths(params.hours);
  if (hours === null || hours <= 0 || hours > MAX_EXTRA_HOURS_HUNDREDTHS) {
    return {
      valid: false,
      error: 'Enter extra hours greater than zero.',
      totalHours: 0,
      deltaRegularHours: 0,
      deltaOvertimeHours: 0,
      resultingRegularHours: baseReg / 100,
      resultingOvertimeHours: baseOt / 100,
      grossPayDelta: null,
    };
  }
  const weekCount = params.workweekCount ?? 2;
  const week = weekCount === 1 ? 1 : (params.workweek ?? null);
  if (!week || week < 1 || week > weekCount) {
    return {
      valid: false,
      error: 'Choose which workweek these hours belong to before approving.',
      totalHours: hours / 100,
      deltaRegularHours: 0,
      deltaOvertimeHours: 0,
      resultingRegularHours: baseReg / 100,
      resultingOvertimeHours: baseOt / 100,
      grossPayDelta: null,
    };
  }

  const baseW1 = parseDecimalHundredths(params.baselineWeek1Hours) ?? 0;
  const baseW2 = parseDecimalHundredths(params.baselineWeek2Hours) ?? 0;
  const newW1 = week === 1 ? baseW1 + hours : baseW1;
  const newW2 = week === 2 ? baseW2 + hours : baseW2;
  if (newW1 > MAX_WEEK_HOURS_HUNDREDTHS || newW2 > MAX_WEEK_HOURS_HUNDREDTHS) {
    return {
      valid: false,
      error: `Workweek ${week} total hours cannot exceed 168 hours.`,
      totalHours: hours / 100,
      deltaRegularHours: 0,
      deltaOvertimeHours: 0,
      resultingRegularHours: baseReg / 100,
      resultingOvertimeHours: baseOt / 100,
      grossPayDelta: null,
    };
  }

  const { regular: newReg, overtime: newOt } = splitWeeklyHundredths(newW1, newW2);
  const deltaReg = newReg - baseReg;
  const deltaOt = newOt - baseOt;
  const grossCents = rateCents === null
    ? null
    : roundCentsFromExact(deltaReg, rateCents, 10) + roundCentsFromExact(deltaOt, rateCents, 15);
  return {
    valid: true,
    totalHours: hours / 100,
    deltaRegularHours: deltaReg / 100,
    deltaOvertimeHours: deltaOt / 100,
    resultingRegularHours: newReg / 100,
    resultingOvertimeHours: newOt / 100,
    grossPayDelta: grossCents === null ? null : grossCents / 100,
  };
}
