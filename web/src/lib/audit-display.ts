import type { AuditLogEntry } from '@/services/api';

const FIELD_LABELS: Record<string, string> = {
  wage_rates: 'Wage rates',
  pay_rate: 'Pay rate',
  additional_withholding: 'Additional withholding',
  filing_status: 'Filing status',
  employment_type: 'Employment type',
  salary_type: 'Salary type',
  pay_frequency: 'Pay frequency',
  address_line1: 'Address line 1',
  address_line2: 'Address line 2',
  date_of_birth: 'Date of birth',
  hire_date: 'Hire date',
  termination_date: 'Termination date',
  ssn_encrypted: 'SSN',
  ssn: 'SSN',
  run_purpose: 'Run purpose',
  includes_base_salary: 'Includes base salary',
  includes_recurring_items: 'Includes recurring items',
  parallel_run: 'Parallel comparison',
  approved_at: 'Approved at',
  committed_at: 'Committed at',
};

export function humanizeAuditKey(value: string): string {
  return FIELD_LABELS[value] || value.replace(/_/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase());
}

export function formatAuditAction(action: string): string {
  const [area, verb] = action.split('#');
  const cleanedArea = area.replace(/^client_/, 'client ').replace(/^admin_/, 'admin ').replace(/\//g, ' ').replace(/_/g, ' ');
  return `${humanizeAuditKey(cleanedArea)} ${verb ? verb.replace(/_/g, ' ') : ''}`.trim();
}

export function displayAuditAction(log: AuditLogEntry): string {
  return log.display_action || formatAuditAction(log.action);
}

export function formatAuditValue(value: unknown): string {
  if (value === null || value === undefined || value === '') return '—';
  if (typeof value === 'boolean') return value ? 'Yes' : 'No';
  if (typeof value === 'number') return Number.isInteger(value) ? String(value) : value.toFixed(2);
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    if (value.length === 0) return 'None';
    return value
      .map((item) => {
        if (typeof item === 'object' && item !== null) {
          return Object.entries(item as Record<string, unknown>)
            .map(([key, nested]) => `${humanizeAuditKey(key)}: ${formatAuditValue(nested)}`)
            .join(' • ');
        }
        return formatAuditValue(item);
      })
      .join('\n');
  }
  if (typeof value === 'object') {
    return Object.entries(value as Record<string, unknown>)
      .map(([key, nested]) => `${humanizeAuditKey(key)}: ${formatAuditValue(nested)}`)
      .join('\n');
  }
  return String(value);
}
