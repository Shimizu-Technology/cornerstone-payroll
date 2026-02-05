import { clsx, type ClassValue } from 'clsx';

/**
 * Merge class names with clsx
 */
export function cn(...inputs: ClassValue[]) {
  return clsx(inputs);
}

/**
 * Format a number as currency (USD)
 */
export function formatCurrency(amount: number): string {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
  }).format(amount);
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
export function formatDate(dateString: string, options?: Intl.DateTimeFormatOptions): string {
  const date = new Date(dateString);
  return date.toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    ...options,
  });
}

/**
 * Format a date range (e.g., "Jan 1 - Jan 15, 2026")
 */
export function formatDateRange(startDate: string, endDate: string): string {
  const start = new Date(startDate);
  const end = new Date(endDate);
  
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
    color: 'bg-gray-100 text-gray-800',
    dotColor: 'bg-gray-400',
  },
  calculated: {
    label: 'Calculated',
    color: 'bg-yellow-100 text-yellow-800',
    dotColor: 'bg-yellow-400',
  },
  approved: {
    label: 'Approved',
    color: 'bg-blue-100 text-blue-800',
    dotColor: 'bg-blue-400',
  },
  committed: {
    label: 'Committed',
    color: 'bg-green-100 text-green-800',
    dotColor: 'bg-green-400',
  },
};

/**
 * Employee status display
 */
export const employeeStatusConfig = {
  active: {
    label: 'Active',
    color: 'bg-green-100 text-green-800',
  },
  inactive: {
    label: 'Inactive',
    color: 'bg-gray-100 text-gray-800',
  },
  terminated: {
    label: 'Terminated',
    color: 'bg-red-100 text-red-800',
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
export const employmentTypeLabels = {
  hourly: 'Hourly',
  salary: 'Salary',
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
