import { reportPeriodPath } from '@/lib/report-period';

export const FIRST_YEAR_END_TAX_YEAR = 2026;

export type YearEndParty = 'cornerstone' | 'client' | 'external_provider' | 'no_filing';
export type YearEndClientStatus = 'needs_action' | 'check_needed' | 'ready' | 'not_filing';
/** "available": a step of documents to download, outside the checklist's done/needs-action counting. */
export type YearEndStepStatus = 'done' | 'action_needed' | 'waiting' | 'not_needed' | 'available';
export type YearEndStepKey =
  | 'filing_decision'
  | 'employer'
  | 'people'
  | 'form_1099_ready'
  | 'reconciliation'
  | 'review_warnings'
  | 'prior_provider'
  | 'mark_ready'
  | 'print_and_file';

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
  issue_count: number | null;
  efile_check_pending?: boolean;
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
  /** A one-off 1099 payee's key: the row in the people step that fixes it. */
  payee_key?: string;
  /** Contractor records that share one TIN. */
  employee_ids?: number[];
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
  /** below_threshold: a smaller payee, listed only so it can be linked. */
  status: 'needs_identity' | 'identified' | 'below_threshold';
  /** Smaller payees only: linked to the contractor with the largest year total, the 1099 threshold would be reached. */
  could_reach_threshold?: boolean;
  acknowledgement: {
    note: string;
    acknowledged_at: string | null;
    acknowledged_by: { id: number | null; name: string; role: string };
  } | null;
  acknowledgement_stale: boolean;
}

/** A contractor record a one-off payee's checks can be linked to. */
export interface YearEndLinkCandidate {
  employee_id: number;
  name: string;
  business_name: string | null;
  status: string;
  tin_type: 'SSN' | 'EIN' | null;
  tin_last4: string | null;
  has_address: boolean;
  /** Payroll pay plus linked one-off checks this year. */
  year_total?: number;
  /** Its name matches a one-off payee's exactly: suggested, never linked automatically. */
  name_matches: boolean;
}

/** One-off checks already linked to a contractor, so a wrong link can be undone. */
export interface YearEndLinkedChecks {
  employee_id: number;
  name: string | null;
  total: number;
  checks: Array<{ id: number; check_number: string | null; payable_to: string; payment_date: string | null; amount: number }>;
}

/** What "mark 1099s ready" signs off: what each 1099 will show. */
export interface YearEnd1099Payee {
  employee_id: number;
  name: string;
  tin_type: 'SSN' | 'EIN' | null;
  tin_last4: string | null;
  total_compensation: number;
  federal_withheld: number;
  filing_reason: string | null;
  linked_check_count: number;
  edit_path: string;
}

export interface YearEnd1099Readiness {
  tax_year: number;
  status: 'draft' | 'filing_ready' | 'stale';
  stale: boolean;
  marked_ready_at: string | null;
  marked_ready_by: string | null;
  notes: string | null;
  payee_count: number;
  total_compensation: number;
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
  /**
   * "explained": the wage base splits wages and tips differently while Box 3 + Box 7 still equals lines 5a + 5b,
   * or a 941 caps legacy paychecks the payroll records do not. A quarter that differs otherwise is always "mismatch".
   */
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

/** One file to print, keep or send, with the endpoint that downloads it. */
export interface YearEndDocument {
  key: string;
  title: string;
  /** One plain line: what it is for and what to do with it. */
  description: string;
  detail: string;
  format: 'pdf' | 'txt';
  /** Explicit acknowledgement before downloading a test file. */
  draft_confirmation?: string | null;
  contains_full_ssn: boolean;
  /** Full payee TINs (SSNs and EINs): the 1099 payer record. */
  contains_full_tin?: boolean;
  /** Watermarked DRAFT: the W-2s are not marked ready on the current numbers. */
  draft: boolean;
  available: boolean;
  unavailable_reason: string | null;
  download: { path: string; params: Record<string, string | number> };
}

type ActiveStepStatus = Extract<YearEndStepStatus, 'done' | 'action_needed' | 'available'>;

interface StepCommon<K extends YearEndStepKey> {
  key: K;
  number: number;
  title: string;
  summary: string;
  issues: YearEndIssue[];
}

/** A step that ran carries its full data; a waiting or not-needed step carries none. */
type StepBase<K extends YearEndStepKey, D> =
  | (StepCommon<K> & { status: ActiveStepStatus; data: D })
  | (StepCommon<K> & { status: Exclude<YearEndStepStatus, ActiveStepStatus>; data: { [P in keyof D]?: never } });

export type YearEndStep =
  | StepBase<'filing_decision', {
      w2: YearEndDecision | null;
      form_1099: YearEndDecision | null;
      w2_employee_count: number;
      contractor_count: number;
      /** Payees reached only by printed or paid one-off contractor checks. */
      one_off_payee_count: number;
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
      filing_contact_name?: string | null;
      kind_of_employer?: string;
      email: string | null;
    }>
  | StepBase<'people', {
      employees: YearEndPerson[];
      contractors: YearEndPerson[];
      one_off_payees: YearEndOneOffPayee[];
      /** Unlinked one-off payees below the 1099 threshold: never blocking, listed to link. */
      smaller_one_off_payees?: YearEndOneOffPayee[];
      /** Reportable 1099 payees whose W-9 is not on file. */
      w9_missing?: Array<{ employee_id: number; name: string; edit_path: string }>;
      /** Contractor records that share one TIN (they would get two 1099s). */
      duplicate_tins?: Array<Array<{ employee_id: number; name: string }>>;
      link_candidates?: YearEndLinkCandidate[];
      linked_checks?: YearEndLinkedChecks[];
      w2_employee_count: number;
      contractor_count: number;
      contractor_error: string | null;
    }>
  | StepBase<'form_1099_ready', {
      readiness: YearEnd1099Readiness | null;
      /** The inputs this page shows; mark ready is refused if they changed. */
      inputs_fingerprint: string | null;
      can_mark_ready: boolean;
      /** Why this person or workspace can't mark ready, if so. */
      unavailable_reason: string | null;
      blockers: YearEndIssue[];
      remaining_before_ready: number;
      filing_threshold: number | null;
      payee_count: number;
      total_compensation: number;
      no_1099_due_count: number;
      smaller_one_off_count?: number;
      smaller_could_reach_count?: number;
      payees: YearEnd1099Payee[];
    }>
  | StepBase<'reconciliation', YearEndReconciliation>
  | StepBase<'review_warnings', { warnings: YearEndWarning[] }>
  | StepBase<'prior_provider', { prior_provider_through: string | null; overlaps: YearEndOverlap[] }>
  | StepBase<'mark_ready', { filing: YearEndReadiness | null; can_mark_ready: boolean; remaining_before_ready: number }>
  | StepBase<'print_and_file', {
    final: boolean;
    /** Cornerstone files the 1099s, but no payee gets one or could: nothing to file. */
    no_1099_filings?: boolean;
    documents: YearEndDocument[];
  }>;

/** A step that ran, narrowed by key: its data is complete. */
export type ActiveYearEndStep<K extends YearEndStepKey> = Extract<YearEndStep, { key: K; status: ActiveStepStatus }>;

export function isActiveStep<S extends YearEndStep>(step: S): step is Extract<S, { status: ActiveStepStatus }> {
  return step.status === 'done' || step.status === 'action_needed' || step.status === 'available';
}

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

/** The element id of a one-off payee's row in the people step, for links that go straight to it. */
export function oneOffPayeeAnchor(payeeKey: string): string {
  return `payee-${payeeKey.replace(/\W+/g, '-')}`;
}

/** The element id of a person's row in the people step. */
export function personAnchor(kind: 'employee' | 'contractor', employeeId: number): string {
  return `${kind}-${employeeId}`;
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

export type YearEndLookAt = YearEndReconciliationLine['look_at'][number];

/**
 * The report a reconciliation line points to, for the checklist's year: the
 * quarter's Form 941 or W-1 (the quarterly packet), or the W-2GU report.
 */
export function reconciliationTargetLink(target: YearEndLookAt, source: YearEndReconciliationLine['source'], taxYear: number): { to: string; label: string } {
  if (target.kind === 'quarter' && target.quarter) {
    return source === 'w1'
      ? { to: reportPeriodPath('quarterly-compliance-packet', taxYear, target.quarter), label: `Open the Q${target.quarter} W-1` }
      : { to: reportPeriodPath('941-gu', taxYear, target.quarter), label: `Open the Q${target.quarter} Form 941` };
  }
  return { to: reportPeriodPath('w2-gu', taxYear), label: 'Open W-2GU report' };
}

export function clientStatusLabel(row: { status: YearEndClientStatus; issue_count: number | null }): string {
  if (row.status === 'ready') return 'Ready';
  if (row.status === 'not_filing') return 'No forms by Cornerstone';
  if (row.status === 'check_needed') return 'Check needed';
  return `${row.issue_count} ${row.issue_count === 1 ? 'thing' : 'things'} to fix`;
}
