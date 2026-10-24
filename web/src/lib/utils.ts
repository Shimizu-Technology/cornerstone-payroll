import { clsx, type ClassValue } from 'clsx';
import type { PayPeriod } from '@/types';

/**
 * Merge class names with clsx
 */
export function cn(...inputs: ClassValue[]) {
  return clsx(inputs);
}

/**
 * Format a number or fixed-point decimal string as currency (USD)
 */
export function formatCurrency(amount: number | string): string {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
  }).format(Number(amount));
}

/**
 * Format a number as a percentage
 */
export function formatPercent(value: number, decimals = 1): string {
  return `${(value * 100).toFixed(decimals)}%`;
}

/**
 * Format a date string for display
 */
function parseCalendarDate(dateString: string): Date {
  return new Date(dateString.includes('T') ? dateString : `${dateString}T00:00:00`);
}

export function formatDate(dateString: string, options?: Intl.DateTimeFormatOptions): string {
  const date = parseCalendarDate(dateString);
  return date.toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    ...options,
  });
}

export function formatGuamDateTime(dateString?: string | null, options?: Intl.DateTimeFormatOptions): string {
  if (!dateString) return 'Not recorded';

  return new Intl.DateTimeFormat('en-US', {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    second: '2-digit',
    ...options,
    timeZone: 'Pacific/Guam',
    timeZoneName: undefined,
  }).format(new Date(dateString)) + ' ChST';
}

export function formatGuamDateTimeShort(dateString?: string | null): string {
  if (!dateString) return 'Not processed';

  return new Intl.DateTimeFormat('en-US', {
    timeZone: 'Pacific/Guam',
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(new Date(dateString)) + ' ChST';
}

/**
 * Format a date range (e.g., "Jan 1 - Jan 15, 2026")
 */
export function formatDateRange(startDate: string, endDate: string): string {
  const start = parseCalendarDate(startDate);
  const end = parseCalendarDate(endDate);
  
  const startMonth = start.toLocaleDateString('en-US', { month: 'short' });
  const endMonth = end.toLocaleDateString('en-US', { month: 'short' });
  const startDay = start.getDate();
  const endDay = end.getDate();
  const year = end.getFullYear();
  
  if (startMonth === endMonth) {
    return `${startMonth} ${startDay} - ${endDay}, ${year}`;
  }
  return `${startMonth} ${startDay} - ${endMonth} ${endDay}, ${year}`;
}

function parseDateForSort(dateString?: string | null): number | null {
  if (!dateString) return null;
  const parsed = Date.parse(dateString);
  return Number.isNaN(parsed) ? null : parsed;
}

function compareDatesNullsLast(
  leftDate?: string | null,
  rightDate?: string | null,
  direction: 'asc' | 'desc' = 'asc'
): number {
  const leftTime = parseDateForSort(leftDate);
  const rightTime = parseDateForSort(rightDate);

  if (leftTime === null && rightTime === null) return 0;
  if (leftTime === null) return 1;
  if (rightTime === null) return -1;

  const directionMultiplier = direction === 'asc' ? 1 : -1;
  return (leftTime - rightTime) * directionMultiplier;
}

export function comparePayPeriodsByPeriod(
  left: Pick<PayPeriod, 'id' | 'start_date' | 'end_date' | 'pay_date'>,
  right: Pick<PayPeriod, 'id' | 'start_date' | 'end_date' | 'pay_date'>,
  direction: 'asc' | 'desc' = 'asc'
): number {
  return (
    compareDatesNullsLast(left.start_date, right.start_date, direction) ||
    compareDatesNullsLast(left.end_date, right.end_date, direction) ||
    compareDatesNullsLast(left.pay_date, right.pay_date, direction) ||
    right.id - left.id
  );
}

/**
 * Get initials from a name
 */
export function getInitials(firstName: string, lastName: string): string {
  return `${firstName.charAt(0)}${lastName.charAt(0)}`.toUpperCase();
}

/**
 * Format hours with decimals
 */
export function formatHours(hours: number): string {
  return hours.toFixed(2);
}

/**
 * Calculate gross pay for hourly employees
 */
export function calculateGrossPay(
  regularHours: number,
  overtimeHours: number,
  hourlyRate: number,
  tips = 0,
  bonus = 0
): number {
  const regularPay = regularHours * hourlyRate;
  const overtimePay = overtimeHours * hourlyRate * 1.5;
  return regularPay + overtimePay + tips + bonus;
}

/**
 * Pay period status display
 */
export const payPeriodStatusConfig = {
  draft: {
    label: 'Draft',
    color: 'bg-neutral-100 text-neutral-800',
    dotColor: 'bg-neutral-400',
  },
  calculated: {
    label: 'Calculated',
    color: 'bg-warning-100 text-warning-800',
    dotColor: 'bg-warning-400',
  },
  approved: {
    label: 'Approved',
    color: 'bg-primary-100 text-primary-800',
    dotColor: 'bg-primary-400',
  },
  committed: {
    label: 'Committed',
    color: 'bg-success-100 text-success-800',
    dotColor: 'bg-success-400',
  },
};

/**
 * Employee status display
 */
export const employeeStatusConfig = {
  active: {
    label: 'Active',
    color: 'bg-success-100 text-success-800',
  },
  inactive: {
    label: 'Inactive',
    color: 'bg-neutral-100 text-neutral-800',
  },
  terminated: {
    label: 'Terminated',
    color: 'bg-danger-100 text-danger-800',
  },
};

/**
 * Filing status labels
 */
export const filingStatusLabels = {
  single: 'Single',
  married: 'Married Filing Jointly',
  married_separate: 'Married Filing Separately',
  head_of_household: 'Head of Household',
};

/**
 * Employment type labels
 */
export const employmentTypeLabels: Record<string, string> = {
  hourly: 'Hourly',
  salary: 'Salary',
  contractor: '1099 Contractor',
};

/**
 * Pay frequency labels
 */
export const payFrequencyLabels = {
  weekly: 'Weekly',
  biweekly: 'Biweekly',
  semimonthly: 'Semi-monthly',
  monthly: 'Monthly',
};
