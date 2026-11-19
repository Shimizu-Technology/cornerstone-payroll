export const FIRST_YEAR_END_TAX_YEAR = 2026;

export type YearEndParty = 'cornerstone' | 'client' | 'external_provider' | 'no_filing';
export type YearEndClientStatus = 'needs_action' | 'check_needed' | 'ready' | 'not_filing';
export type YearEndStepStatus = 'done' | 'action_needed' | 'waiting' | 'not_needed';
export type YearEndStepKey =
  | 'filing_decision'
  | 'employer'
  | 'people'
  | 'reconciliation'
  | 'review_warnings'
  | 'prior_provider'
  | 'mark_ready';

export interface YearEndDecisionSummary {
  responsible_party: YearEndParty;
  label: string;
  prior_provider_through: string | null;
}

export interface YearEndClientRow {
  company_id: number;
  name: string;
  active: boolean;
  status: YearEndClientStatus;
  issue_count: number;
  issue_summary: Array<{ code: string; label: string; count: number }>;
  w2: YearEndDecisionSummary | null;
  form_1099: YearEndDecisionSummary | null;
  w2_employee_count: number;
  employee_details: { missing_ssn: number; missing_address: number } | null;
  marked_ready_at: string | null;
  /** Why a client that was marked ready needs another look. */
  check_reason: string | null;
  checklist_path: string;
}

export interface YearEndClientsOverview {
  tax_year: number;
  clients: YearEndClientRow[];
  counts: Record<YearEndClientStatus, number>;
  hidden: { test_workspaces: number; inactive_without_payroll: number };
}

export interface YearEndIssue {
  code: string;
  message: string;
  field?: string;
  employee_id?: number;
  line?: string | null;
  warning_code?: string;
  source?: string;
  quarter?: number | null;
}

export interface YearEndDecision {
  id: number;
  filing_type: 'w2_gu' | 'form_1099';
  responsible_party: YearEndParty;
  prior_provider_through: string | null;
  notes: string | null;
  label: string;
  reviewed_at: string | null;
  reviewed_by: { id: number | null; name: string; email: string; role: string };
}

export interface YearEndPerson {
  employee_id: number;
  name: string;
  kind: 'employee' | 'contractor';
  missing_fields: Array<'ssn' | 'address'>;
  address_line1: string | null;
  address_line2: string | null;
  city: string | null;
  state: string | null;
  zip: string | null;
  edit_path: string;
}

/** A payee paid only by one-off contractor checks: no contractor record, so no TIN or address. */
export interface YearEndOneOffPayee {
  code: string;
  payee_key: string;
  name: string;
  total_compensation: number;
  payment_count: number;
  checks: Array<{ id: number; check_number: string | null; payment_date: string | null; amount: number }>;
  checks_path: string;
  digest: string;
  status: 'needs_identity' | 'identified';
  acknowledgement: {
    note: string;
    acknowledged_at: string | null;
    acknowledged_by: { id: number | null; name: string; role: string };
  } | null;
  acknowledgement_stale: boolean;
}

export interface YearEndReconciliationQuarter {
  quarter: number;
  amount: number;
  payroll_records: number;
  difference: number;
}

export interface YearEndReconciliationLine {
  key: string;
  label: string;
  w2_box: string;
  source: 'form_941' | 'w1';
  source_label: string;
  w2_total: number;
  quarters: YearEndReconciliationQuarter[];
  quarterly_total: number;
  opening_balances: number;
  difference: number;
  /** "explained": the wage base splits wages and tips differently, but Box 3 + Box 7 still equals lines 5a + 5b. */
  status: 'match' | 'mismatch' | 'explained';
  look_at: Array<{ kind: 'quarter' | 'w2_report'; quarter?: number; label: string; detail: string }>;
  message: string | null;
  note?: string | null;
}

export interface YearEndForm941Review {
  quarter: number;
  status: 'unexplained' | 'residual';
  employee_difference: number;
  expected_employee_total: number;
  recorded_employee_total: number;
  recorded_liability_residual: number;
  message: string;
}

export interface YearEndReconciliation {
  status: 'match' | 'mismatch' | 'unavailable';
  tolerance: number;
  quarters: Array<{ quarter: number; label: string; record_count: number; form_941_filed_by: YearEndParty | null }>;
  opening_balances: { present: boolean; first_pay_date: string | null; last_pay_date: string | null };
  lines: YearEndReconciliationLine[];
  form_941_reviews?: YearEndForm941Review[];
  error?: string;
}

export interface YearEndWarning {
  code: string;
  kind: 'blocker' | 'acknowledge';
  title: string;
  explanation: string;
  status: 'blocked' | 'needs_review' | 'reviewed';
  digest: string;
  period: [string | null, string | null] | null;
  /** Per-quarter specifics, for warnings that are not about employees. */
  details?: string[];
  employees: Array<{ employee_id: number; name: string | null; edit_path: string }>;
  acknowledgement: {
    note: string;
    acknowledged_at: string | null;
    acknowledged_by: { id: number | null; name: string; role: string };
  } | null;
  acknowledgement_stale: boolean;
}

export interface YearEndOverlap {
  source: 'opening_balances' | 'imported_payroll' | 'cornerstone_payroll';
  count: number;
  first_date: string | null;
  last_date: string | null;
  message: string;
}

export interface YearEndReadiness {
  status: 'draft' | 'preflight_passed' | 'filing_ready' | 'stale';
  stale: boolean;
  marked_ready_at: string | null;
  notes: string | null;
}

interface StepBase<K extends YearEndStepKey, D> {
  key: K;
  number: number;
  title: string;
  status: YearEndStepStatus;
  summary: string;
  issues: YearEndIssue[];
  data: Partial<D>;
}

export type YearEndStep =
  | StepBase<'filing_decision', {
      w2: YearEndDecision | null;
      form_1099: YearEndDecision | null;
      w2_employee_count: number;
      contractor_count: number;
      has_imported_history: boolean;
    }>
  | StepBase<'employer', {
      name: string;
      ein: string | null;
      address_line1: string | null;
      address_line2: string | null;
      city: string | null;
      state: string | null;
      zip: string | null;
      phone: string | null;
      email: string | null;
    }>
  | StepBase<'people', {
      employees: YearEndPerson[];
      contractors: YearEndPerson[];
      one_off_payees: YearEndOneOffPayee[];
      w2_employee_count: number;
      contractor_count: number;
      contractor_error: string | null;
    }>
  | StepBase<'reconciliation', YearEndReconciliation>
  | StepBase<'review_warnings', { warnings: YearEndWarning[] }>
  | StepBase<'prior_provider', { prior_provider_through: string | null; overlaps: YearEndOverlap[] }>
  | StepBase<'mark_ready', { filing: YearEndReadiness | null; can_mark_ready: boolean; remaining_before_ready: number }>;

export interface YearEndChecklist {
  company: { id: number; name: string; active: boolean; test_workspace: boolean };
  tax_year: number;
  status: YearEndClientStatus;
  issue_count: number;
  next_step: YearEndStepKey | null;
  files_w2: boolean;
  files_1099: boolean;
  permissions: { can_record_decision: boolean; can_acknowledge: boolean; can_mark_ready: boolean };
  steps: YearEndStep[];
}

export function findStep<K extends YearEndStepKey>(checklist: YearEndChecklist, key: K): Extract<YearEndStep, { key: K }> | undefined {
  return checklist.steps.find((step): step is Extract<YearEndStep, { key: K }> => step.key === key);
}

/** The tax year whose forms staff are preparing: this year from July, last year before then. */
export function defaultYearEndTaxYear(today = new Date()): number {
  const year = today.getMonth() >= 6 ? today.getFullYear() : today.getFullYear() - 1;
  return Math.max(year, FIRST_YEAR_END_TAX_YEAR);
}

export function yearEndTaxYears(today = new Date()): number[] {
  const last = Math.max(today.getFullYear(), FIRST_YEAR_END_TAX_YEAR);
  const years: number[] = [];
  for (let year = last; year >= FIRST_YEAR_END_TAX_YEAR; year -= 1) years.push(year);
  return years;
}

export function parseYearEndTaxYear(value: string | null, today = new Date()): number {
  const year = Number(value);
  return yearEndTaxYears(today).includes(year) ? year : defaultYearEndTaxYear(today);
}

export function clientStatusLabel(row: { status: YearEndClientStatus; issue_count: number }): string {
  if (row.status === 'ready') return 'Ready';
  if (row.status === 'not_filing') return 'No forms by Cornerstone';
  if (row.status === 'check_needed') return 'Check needed';
  return `${row.issue_count} ${row.issue_count === 1 ? 'thing' : 'things'} to fix`;
}
