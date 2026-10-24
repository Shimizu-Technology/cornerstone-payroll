import Decimal from 'decimal.js';
import type { Employee, PayPeriod, PayrollItem, PayrollItemWageRateHours } from '@/types';

type Earning = { label: string; amount: number; treatment?: string; active?: boolean; notes?: string };
export interface DraftGrossField {
  id: number;
  amountType: string;
  amount?: number | null;
  percentage?: number | null;
  currentAmount?: number | null;
  currentActive?: boolean | null;
  source?: string | null;
  editable: boolean;
  automatic?: boolean;
  mode: 'default' | 'override';
  taxTreatment?: string;
}
export interface DraftGrossInput {
  employee: Pick<Employee, 'employment_type' | 'pay_rate' | 'pay_frequency'> & Partial<Employee>;
  item?: Partial<PayrollItem>;
  period: Pick<PayPeriod, 'run_purpose' | 'includes_base_salary' | 'includes_recurring_items'>;
  hours?: { regular: number; overtime: number; wage_rates?: PayrollItemWageRateHours[] };
  salaryOverride?: number;
  bonus?: number;
  reportedTips?: number;
  tipsPaidOut?: number;
  fields?: DraftGrossField[];
}
const decimal = (value: unknown): Decimal => {
  if (typeof value !== 'string' && typeof value !== 'number') return new Decimal(0);
  try {
    const result = new Decimal(value || 0);
    return result.isFinite() ? result : new Decimal(0);
  } catch { return new Decimal(0); }
};
const money = (value: unknown): Decimal => decimal(value).toDecimalPlaces(2, Decimal.ROUND_HALF_UP);
const sum = (values: Decimal[]): Decimal => values.reduce((total, value) => total.plus(value), new Decimal(0));
function normalized(entries: Earning[] = []): Earning[] {
  return entries.filter(entry => typeof entry.label === 'string' && entry.label.trim() && decimal(entry.amount).gt(0)).map(entry => ({
    label: entry.label.trim(), amount: money(entry.amount).toNumber(),
    ...(entry.treatment ? { treatment: entry.treatment, active: entry.active !== false, ...(entry.notes?.trim() ? { notes: entry.notes.trim() } : {}) } : {}),
  }));
}
function syncedEntries(defaults: Earning[] | undefined, current: Earning[] | undefined, manual: boolean, source: string | null | undefined, recurring: boolean): Earning[] {
  const employeeDefaults = normalized(defaults);
  const saved = normalized(current);
  if (manual) return saved;
  const remaining = [...employeeDefaults];
  const subset = saved.every(entry => {
    const index = remaining.findIndex(candidate => JSON.stringify(candidate) === JSON.stringify(entry));
    if (index < 0) return false;
    remaining.splice(index, 1);
    return true;
  });
  return !saved.length || source === 'employee_default' || subset ? recurring ? employeeDefaults : [] : saved;
}

/** Gross estimate only. Saved/calculated amounts and server guards remain authoritative.
 * Mirrors the hourly/salary/contractor gross phases, default-sync rules and per-field
 * rounding; the shared JSON contract is also executed against those Ruby calculators.
 */
export function estimateDraftGross(input: DraftGrossInput): number | null {
  const { employee, item = {}, period, fields = [] } = input;
  const hours = input.hours ?? { regular: item.hours_worked ?? 0, overtime: item.overtime_hours ?? 0, wage_rates: item.wage_rate_hours };
  const isSalary = employee.employment_type === 'salary';
  const isContractor = employee.employment_type === 'contractor';
  const hourly = employee.employment_type === 'hourly' || (isContractor && employee.contractor_pay_type === 'hourly');
  const captured = item.timekeeping_source === 'correction_reference' || item.import_source?.startsWith('time_tracking:');
  const employeeRates = (employee.wage_rates || []).filter(rate => rate.active !== false);
  const primary = employeeRates.find(rate => rate.is_primary) ?? employeeRates[0];
  const rate = money(captured ? item.pay_rate ?? employee.pay_rate : hourly ? primary?.rate ?? employee.pay_rate : employee.pay_rate);
  const override = money(input.salaryOverride ?? item.salary_override);
  const periods = ({ weekly: 52, biweekly: 26, semimonthly: 24, monthly: 12 } as Record<string, number>)[employee.pay_frequency] ?? 26;
  let base = new Decimal(0);
  if (isSalary) {
    if (period.includes_base_salary !== false) base = override.gt(0) ? override
      : employee.salary_type === 'variable' ? new Decimal(0)
      : employee.salary_type === 'per_period' ? rate : rate.div(periods);
    const snapshot = item.timekeeping_context_snapshot ?? {};
    if (snapshot.overtime_status === 'nonexempt') {
      const coveredHours = decimal(snapshot.salary_covers_weekly_hours);
      const covered = decimal(snapshot.salary_covered_overtime_hours);
      const uncovered = decimal(snapshot.salary_uncovered_overtime_hours);
      if (coveredHours.lt(40) || coveredHours.gt(168) || !covered.plus(uncovered).eq(decimal(hours.overtime))) return null;
      const snapshotPeriods = ({ weekly: 52, biweekly: 26, semimonthly: 24, monthly: 12 } as Record<string, number>)[String(snapshot.pay_frequency)] ?? 26;
      const weekly = snapshot.salary_type === 'annual' ? rate.div(52)
        : ['per_period', 'variable'].includes(String(snapshot.salary_type)) ? (snapshot.salary_type === 'variable' ? override : rate).mul(snapshotPeriods).div(52) : new Decimal(0);
      base = base.plus(weekly.div(coveredHours).mul(covered.mul('0.5').plus(uncovered.mul('1.5'))).toDecimalPlaces(2, Decimal.ROUND_HALF_UP));
    }
  } else if (isContractor && period.run_purpose === 'off_cycle_tips') {
    base = new Decimal(0);
  } else if (isContractor && override.gt(0)) {
    base = override;
  } else if (hourly) {
    // Include every transmitted earned bucket, even an inactive profile rate.
    // A single ordinary bucket is sent as scalar hours; captured source buckets stay intact.
    const buckets = hours.wage_rates ?? [];
    base = buckets.length > 1 || (captured && buckets.length > 0) ? sum(buckets.map(row =>
      decimal(row.rate).mul(decimal(row.regular_hours).plus(decimal(row.overtime_hours).mul('1.5')).plus(decimal(row.holiday_hours)).plus(decimal(row.pto_hours)))
    )) : rate.mul(decimal(hours.regular).plus(decimal(hours.overtime).mul('1.5')).plus(isContractor ? 0 : decimal(item.holiday_hours).plus(decimal(item.pto_hours))));
  } else {
    base = rate;
  }
  const sources = item.draft_earning_sources;
  const recurring = period.includes_recurring_items !== false;
  const custom = syncedEntries(employee.default_custom_earnings, item.custom_earnings, sources?.custom_earnings === 'manual', sources?.custom_earnings, recurring);
  const adjustments = syncedEntries(employee.default_payroll_adjustments, item.payroll_adjustments, sources?.payroll_adjustments_overridden === true, sources?.payroll_adjustments, recurring);
  const tips = isContractor ? new Decimal(0) : Decimal.max(money(input.reportedTips ?? item.reported_tips), money(input.tipsPaidOut ?? item.tips_paid_out));
  const beforeFields = base.plus(tips).plus(money(input.bonus ?? item.bonus)).plus(money(item.service_charge_wages))
    .plus(sum(custom.map(entry => money(entry.amount))))
    .plus(sum(adjustments.filter(entry => entry.active !== false && entry.treatment === 'taxable_addition').map(entry => money(entry.amount))));
  // The server rounds base gross before computing percentage additions. Each field
  // rounds independently; all percentages use the same base, not each other's totals.
  const roundedBase = beforeFields.toDecimalPlaces(2, Decimal.ROUND_HALF_UP);
  const handledIds = new Set(fields.map(field => field.id));
  const fieldAmounts = fields.filter(field => !field.taxTreatment || field.taxTreatment === 'taxable_addition').map(field => {
    if (!field.editable && ['manual', 'import'].includes(field.source ?? '')) return field.currentActive === false ? new Decimal(0) : money(field.currentAmount);
    if (!field.editable && !field.automatic) return new Decimal(0);
    if (field.mode === 'override') return Decimal.max(0, money(field.amount));
    if (!recurring) return new Decimal(0);
    return field.amountType === 'percentage' ? roundedBase.mul(decimal(field.percentage)).div(100).toDecimalPlaces(2, Decimal.ROUND_HALF_UP) : Decimal.max(0, money(field.amount));
  });
  const preserved = (item.payroll_field_entries ?? []).filter(entry => !handledIds.has(entry.payroll_field_definition_id ?? -1)
    && entry.active !== false && entry.tax_treatment === 'taxable_addition' && ['manual', 'import'].includes(entry.source ?? ''));
  return beforeFields.plus(sum(fieldAmounts)).plus(sum(preserved.map(entry => money(entry.amount)))).toDecimalPlaces(2, Decimal.ROUND_HALF_UP).toNumber();
}
