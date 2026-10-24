

import { formatCurrency } from '@/lib/utils';

import { capturedSourceContext, capturedSourceHoursLocked } from '@/lib/captured-source-worksheet';

import type { PayPeriod, PayrollItem, Employee, PayrollItemWageRateHours, TaxSyncStatus, PayrollAdjustmentTreatment, PayRunPurpose } from '@/types';

export const payrollHoursInputLabel = (employee: Employee, kind: 'Regular' | 'Overtime', rate?: PayrollItemWageRateHours) => (
  [`${kind} hours for ${employee.first_name} ${employee.last_name}`, rate?.label, rate && capturedSourceContext(rate)]
    .filter(Boolean).join(' · ')
);

export interface HoursEntry {
  regular: number;
  overtime: number;
  wage_rates?: PayrollItemWageRateHours[];
}

export interface PayrollFieldDraftEntry {
  mode: 'default' | 'override';
  amount: number | null;
  replace_request?: boolean;
}

export const TABLE_STICKY_TOP_CLASS = 'top-0';

export const MAX_HOURS_PER_PERIOD = 200;

export const runPurposeLabels: Record<PayRunPurpose, string> = {
  regular: 'Regular payroll',
  off_cycle_tips: 'Off-cycle tips',
  bonus: 'Bonus',
  commission: 'Commission',
  correction: 'Correction',
  final: 'Final paycheck',
  adjustment: 'Adjustment',
};

export const adjustmentTreatmentLabels: Record<PayrollAdjustmentTreatment, string> = {
  taxable_addition: 'Taxable add.',
  non_taxable_addition: 'Non-taxable add.',
  pre_tax_deduction: 'Pre-tax ded.',
  post_tax_deduction: 'Post-tax ded.',
};

export const toNumber = (value: unknown): number => {
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};

export const payrollFieldAmountsEqual = (left: number | null, right: number | null) => {
  if (left == null || right == null) return left == null && right == null;
  return Math.abs(left - right) < 0.005;
};

export const effectiveLoanDeduction = (item: PayrollItem): number => {
  const calculatedLoanPayment = toNumber(item.loan_payment);
  return calculatedLoanPayment > 0 ? calculatedLoanPayment : toNumber(item.loan_deduction);
};

export const comparisonMetricLabels: Record<string, string> = {
  employee_count: 'Employees',
  gross_pay: 'Gross pay',
  net_pay: 'Net pay',
  fit: 'FIT',
  social_security: 'Social Security',
  medicare: 'Medicare',
  total_deductions: 'Total deductions',
  reported_tips: 'Reported Tips',
  tips_paid_out: 'Tips Paid Out',
  loan_deduction: 'Loan Deduction',
  loan_payment: 'Loan Payment',
};

export function formatSignedCurrency(value: number) {
  const formatted = formatCurrency(Math.abs(value));
  if (value > 0) return `+${formatted}`;
  if (value < 0) return `-${formatted}`;
  return formatted;
}

export function formatSignedNumber(value: number) {
  if (value > 0) return `+${value}`;
  if (value < 0) return String(value);
  return '0';
}

export function templateWageRates(employee: Employee | undefined, payrollItem?: PayrollItem): PayrollItemWageRateHours[] {
  const existing = payrollItem?.wage_rate_hours;
  if ((payrollItem?.correction_pay_basis_hold || payrollItem?.import_source?.startsWith('time_tracking:')) && !existing?.length) return [];
  if ((payrollItem?.timekeeping_source === 'correction_reference' || payrollItem?.import_source?.startsWith('time_tracking:')) && existing?.length) {
    return existing.map(entry => ({
      ...entry,
      rate: toNumber(entry.rate),
      regular_hours: toNumber(entry.regular_hours),
      overtime_hours: toNumber(entry.overtime_hours),
      holiday_hours: toNumber(entry.holiday_hours),
      pto_hours: toNumber(entry.pto_hours),
      is_primary: entry.is_primary ?? false,
      active: entry.active ?? true,
    }));
  }
  const configuredRates = employee?.wage_rates || [];
  if (configuredRates.length > 0) {
    const existingById = new Map(
      (existing || []).flatMap((entry) => (
        entry.employee_wage_rate_id != null ? [[entry.employee_wage_rate_id, entry]] : []
      ))
    );
    const existingByLabel = new Map(
      (existing || []).map((entry) => [entry.label.trim().toLowerCase(), entry])
    );
    const defaultPrimaryHours = configuredRates.length > 1 ? 0 : toNumber(payrollItem?.hours_worked ?? 0);

    return configuredRates.map((rate) => {
      const matchedExisting =
        (rate.id != null ? existingById.get(rate.id) : undefined) ||
        existingByLabel.get(rate.label.trim().toLowerCase());

      return {
        employee_wage_rate_id: rate.id,
        label: rate.label,
        rate: toNumber(rate.rate),
        regular_hours: matchedExisting ? toNumber(matchedExisting.regular_hours) : (rate.is_primary ? defaultPrimaryHours : 0),
        overtime_hours: matchedExisting ? toNumber(matchedExisting.overtime_hours) : (rate.is_primary ? toNumber(payrollItem?.overtime_hours ?? 0) : 0),
        holiday_hours: matchedExisting ? toNumber(matchedExisting.holiday_hours) : (rate.is_primary ? toNumber(payrollItem?.holiday_hours ?? 0) : 0),
        pto_hours: matchedExisting ? toNumber(matchedExisting.pto_hours) : (rate.is_primary ? toNumber(payrollItem?.pto_hours ?? 0) : 0),
        is_primary: rate.is_primary,
        active: rate.active,
      };
    });
  }

  if (existing && existing.length > 0) {
    return existing.map((entry) => ({
      employee_wage_rate_id: entry.employee_wage_rate_id,
      label: entry.label,
      rate: toNumber(entry.rate),
      regular_hours: toNumber(entry.regular_hours),
      overtime_hours: toNumber(entry.overtime_hours),
      holiday_hours: toNumber(entry.holiday_hours),
      pto_hours: toNumber(entry.pto_hours),
      is_primary: entry.is_primary ?? false,
      active: entry.active ?? true,
    }));
  }

  return configuredRates.map((rate) => ({
    employee_wage_rate_id: rate.id,
    label: rate.label,
    rate: toNumber(rate.rate),
    regular_hours: rate.is_primary ? toNumber(payrollItem?.hours_worked ?? 0) : 0,
    overtime_hours: rate.is_primary ? toNumber(payrollItem?.overtime_hours ?? 0) : 0,
    holiday_hours: rate.is_primary ? toNumber(payrollItem?.holiday_hours ?? 0) : 0,
    pto_hours: rate.is_primary ? toNumber(payrollItem?.pto_hours ?? 0) : 0,
    is_primary: rate.is_primary,
    active: rate.active,
  }));
}

export function buildHoursMap(payrollItems: PayrollItem[], employees: Employee[]): Record<string, HoursEntry> {
  const hours: Record<string, HoursEntry> = {};
  const employeeMap = new Map(employees.map((emp) => [emp.id, emp]));

  payrollItems.forEach((item) => {
    const employee = employeeMap.get(item.employee_id);
    const noHours = employee?.employment_type === 'contractor' && employee?.contractor_pay_type !== 'hourly';
    const wageRates = (capturedSourceHoursLocked(item) || item.correction_pay_basis_hold)
      ? templateWageRates(employee, item)
      : employee && (employee.employment_type === 'hourly' || (employee.employment_type === 'contractor' && employee.contractor_pay_type === 'hourly'))
      ? templateWageRates(employee, item)
      : [];
    hours[String(item.employee_id)] = {
      regular: noHours && !capturedSourceHoursLocked(item) && !item.correction_pay_basis_hold ? 0 : (item.hours_worked || 0),
      overtime: noHours && !capturedSourceHoursLocked(item) && !item.correction_pay_basis_hold ? 0 : (item.overtime_hours || 0),
      wage_rates: wageRates.length > 0 ? wageRates : undefined,
    };
  });

  employees.forEach((emp) => {
    if (!hours[String(emp.id)]) {
      const wageRates = emp.employment_type === 'hourly' || (emp.employment_type === 'contractor' && emp.contractor_pay_type === 'hourly')
        ? templateWageRates(emp)
        : [];
      const regularDefault = wageRates.length > 1
        ? wageRates.reduce((sum, rate) => sum + toNumber(rate.regular_hours), 0)
        : 0;
      hours[String(emp.id)] = {
        regular: regularDefault,
        overtime: 0,
        wage_rates: wageRates.length > 0 ? wageRates : undefined,
      };
    }
  });

  return hours;
}

export function derivePayrollUiState(payrollItems: PayrollItem[]) {
  const salaryOverrides: Record<string, number> = {};
  const tips: Record<string, { amount: number; pool: string }> = {};
  const tipsPaidOut: Record<string, number> = {};
  const loans: Record<string, number> = {};
  const bonuses: Record<string, number> = {};

  payrollItems.forEach((item) => {
    bonuses[String(item.employee_id)] = toNumber(item.bonus);
    if (item.salary_override && toNumber(item.salary_override) > 0) {
      salaryOverrides[String(item.employee_id)] = toNumber(item.salary_override);
    }

    const tipAmount = toNumber(item.reported_tips);
    if (tipAmount > 0) {
      tips[String(item.employee_id)] = { amount: tipAmount, pool: item.tip_pool || '' };
    }

    const tipsPaidOutAmount = toNumber(item.tips_paid_out);
    if (tipsPaidOutAmount > 0) {
      tipsPaidOut[String(item.employee_id)] = tipsPaidOutAmount;
    }

    const loanAmount = toNumber(item.loan_deduction);
    if (loanAmount > 0) {
      loans[String(item.employee_id)] = loanAmount;
    }
  });

  return {
    salaryOverrides,
    bonuses,
    tips,
    tipsPaidOut,
    loans,
    showTipsLoans: Object.keys(tips).length > 0 || Object.keys(tipsPaidOut).length > 0 || Object.keys(loans).length > 0,
  };
}

export function numericRecordsEqual(left: Record<string, number>, right: Record<string, number>): boolean {
  const keys = new Set([...Object.keys(left), ...Object.keys(right)]);
  return [...keys].every((key) => Math.abs(toNumber(left[key]) - toNumber(right[key])) < 0.005);
}

export function tipRecordsEqual(
  left: Record<string, { amount: number; pool: string }>,
  right: Record<string, { amount: number; pool: string }>,
): boolean {
  const keys = new Set([...Object.keys(left), ...Object.keys(right)]);
  return [...keys].every((key) => (
    Math.abs(toNumber(left[key]?.amount) - toNumber(right[key]?.amount)) < 0.005
    && (left[key]?.pool || '') === (right[key]?.pool || '')
  ));
}

export function hoursRecordsEqual(left: Record<string, HoursEntry>, right: Record<string, HoursEntry>): boolean {
  const keys = new Set([...Object.keys(left), ...Object.keys(right)]);
  return [...keys].every((key) => {
    const leftEntry = left[key];
    const rightEntry = right[key];
    if (!leftEntry || !rightEntry) return false;
    if (Math.abs(toNumber(leftEntry.regular) - toNumber(rightEntry.regular)) >= 0.005) return false;
    if (Math.abs(toNumber(leftEntry.overtime) - toNumber(rightEntry.overtime)) >= 0.005) return false;

    const leftRates = leftEntry.wage_rates || [];
    const rightRates = rightEntry.wage_rates || [];
    if (leftRates.length !== rightRates.length) return false;

    return leftRates.every((rate, index) => {
      const comparison = rightRates[index];
      return comparison
        && rate.employee_wage_rate_id === comparison.employee_wage_rate_id
        && rate.label === comparison.label
        && Math.abs(toNumber(rate.rate) - toNumber(comparison.rate)) < 0.005
        && Math.abs(toNumber(rate.regular_hours) - toNumber(comparison.regular_hours)) < 0.005
        && Math.abs(toNumber(rate.overtime_hours) - toNumber(comparison.overtime_hours)) < 0.005
        && Math.abs(toNumber(rate.holiday_hours) - toNumber(comparison.holiday_hours)) < 0.005
        && Math.abs(toNumber(rate.pto_hours) - toNumber(comparison.pto_hours)) < 0.005;
    });
  });
}

export const taxSyncStatusConfig: Record<TaxSyncStatus, { label: string; variant: 'default' | 'success' | 'warning' | 'danger' | 'info' }> = {
  pending: { label: 'Tax Sync Pending', variant: 'default' },
  syncing: { label: 'Tax Syncing...', variant: 'info' },
  synced: { label: 'Tax Synced', variant: 'success' },
  failed: { label: 'Tax Sync Failed', variant: 'danger' },
};

export interface PayPeriodDetailProps {
  active?: boolean;
  activeTab?: import('@/lib/routes').PayRunWorkspaceTab;
  navigation?: import('react').ReactNode;
  checksContent?: (options: { refreshToken: number; searchTerm: string; onChecksLoaded: (checks: import('@/types').NonEmployeeCheck[]) => void }) => import('react').ReactNode;
  activityContent?: import('react').ReactNode;
  initialPayPeriod?: PayPeriod;
  onPayPeriodChange?: (payPeriod: PayPeriod) => void;
  refreshToken?: number;
}

export type CoverageAcknowledgement = { source_coverage_reason: string; source_coverage_acknowledged: true };

export type EmploymentGroup = 'w2' | 'contractor';
