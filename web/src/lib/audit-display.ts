import type { AuditLogEntry } from '@/services/api';

export interface AuditChange {
  field: string;
  before: unknown;
  after: unknown;
  redacted: boolean;
}

export interface AuditFact {
  label: string;
  value: string;
}

export interface AuditEntryGroup {
  key: string;
  primary: AuditLogEntry;
  entries: AuditLogEntry[];
}

const ACCESS_GROUP_WINDOW_MS = 10 * 60 * 1_000;

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
  return FIELD_LABELS[value] || value.replace(/[._]/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase());
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

function objectValue(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function stringList(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : [];
}

function owns(object: Record<string, unknown>, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(object, key);
}

function valuesDiffer(before: unknown, after: unknown): boolean {
  return JSON.stringify(before) !== JSON.stringify(after);
}

export function meaningfulAuditChanges(log: AuditLogEntry): AuditChange[] {
  const beforeValues = objectValue(log.metadata?.before_values);
  const afterValues = objectValue(log.metadata?.after_values);
  const redactedFields = new Set(stringList(log.metadata?.redacted_fields));

  return stringList(log.metadata?.changed_fields)
    .filter((field) => field !== 'id')
    .filter((field) => redactedFields.has(field) || (
      (owns(beforeValues, field) || owns(afterValues, field)) &&
      valuesDiffer(beforeValues[field], afterValues[field])
    ))
    .map((field) => ({
      field,
      before: beforeValues[field],
      after: afterValues[field],
      redacted: redactedFields.has(field),
    }));
}

export function auditBusinessFacts(log: AuditLogEntry): AuditFact[] {
  const summary = objectValue(log.metadata?.business_summary);
  const facts: AuditFact[] = [];
  const add = (key: string, label: string, formatter: (value: unknown) => string = formatAuditValue): void => {
    if (!owns(summary, key) || summary[key] === null || summary[key] === undefined || summary[key] === '') return;
    facts.push({ label, value: formatter(summary[key]) });
  };
  const currency = (value: unknown): string => {
    const amount = Number(value);
    if (!Number.isFinite(amount)) return formatAuditValue(value);

    return new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: 'USD',
    }).format(amount);
  };

  add('employees_processed', 'Processed');
  if (Number(summary.employees_failed) > 0) add('employees_failed', 'Needs attention');
  if (!owns(summary, 'employees_processed')) add('employee_count', 'Employees');
  add('total_gross', 'Gross payroll', currency);
  add('total_net', 'Net payroll', currency);
  add('total_deductions', 'Deductions', currency);
  add('employer_payroll_taxes', 'Employer payroll taxes', currency);
  add('outcome', 'Outcome', (value) => humanizeAuditKey(String(value)));
  add('status', 'Result', (value) => humanizeAuditKey(String(value)));
  return facts;
}

export function isDocumentAccess(log: AuditLogEntry): boolean {
  if (log.event_category === 'document_access') return true;
  if (log.event_category !== 'export') return false;

  const actionVerb = log.action.split('#').at(-1) || log.action;
  return typeof log.metadata?.access_type === 'string'
    || /(download|export|pdf|csv|xlsx|ascii|print|preview)/i.test(actionVerb);
}

function groupIdentity(log: AuditLogEntry): string {
  // Older access records did not retain a pay-period target. They can still be
  // presented as a short burst of similar access activity because every raw
  // occurrence remains available in the expanded evidence list.
  const target = log.metadata?.report_target_key ?? log.metadata?.pay_period_id ?? log.record_id ?? 'legacy-unlinked';
  const report = log.metadata?.report_key ?? log.metadata?.report_name ?? log.action;
  const format = log.metadata?.report_format ?? '';
  return [log.user_id ?? log.actor_email ?? log.user_name, log.company_id, report, format, target].join('|');
}

function guamCalendarDay(timestamp: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Pacific/Guam',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date(timestamp));
}

function canJoinAccessGroup(group: AuditEntryGroup, log: AuditLogEntry): boolean {
  if (!isDocumentAccess(group.primary) || !isDocumentAccess(log)) return false;
  if (groupIdentity(group.primary) !== groupIdentity(log)) return false;
  if (guamCalendarDay(group.primary.created_at) !== guamCalendarDay(log.created_at)) return false;

  const previous = group.entries.at(-1) ?? group.primary;
  return Math.abs(new Date(previous.created_at).getTime() - new Date(log.created_at).getTime()) <= ACCESS_GROUP_WINDOW_MS;
}

export function groupAuditEntries(logs: AuditLogEntry[]): AuditEntryGroup[] {
  return logs.reduce<AuditEntryGroup[]>((groups, log) => {
    const current = groups.at(-1);
    if (current && canJoinAccessGroup(current, log)) {
      current.entries.push(log);
      return groups;
    }

    groups.push({ key: `audit-${log.id}`, primary: log, entries: [log] });
    return groups;
  }, []);
}

export function displayAuditGroupAction(group: AuditEntryGroup): string {
  const headline = displayAuditAction(group.primary);
  if (group.entries.length === 1) return headline;

  return `${headline} · ${group.entries.length} access records`;
}
