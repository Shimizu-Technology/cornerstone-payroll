import { apiClient } from '@/services/api';
import { formatEmployeeAppDate } from '@/services/employee-app-rollout-api';

// GET /{admin,client}/employee_app_status/:company_id (+ /csv, /xlsx): who has
// an employee app account and what they agreed to (EmployeeAppStatusReport).

/** EmployeeAppRollout#display_status: the one status rule for the report and the employee panel. */
export type AppAccountStatus = 'not_invited' | 'invited' | 'reinvited' | 'invite_expired' | 'locked' | 'active' | 'deactivated' | 'former' | 'revoked';
export type DeliveryAnswer = 'paperless' | 'keep_paper' | 'not_answered';
export type AppStatusFilter = 'not_signed_up' | 'signed_up_no_opens' | 'invite_expired' | 'terms_not_accepted' | 'no_paperless_answer' | 'kept_paper';

export interface AppAccount {
  status: AppAccountStatus;
  label: string;
  /** An active link with its login turned on, now. */
  signed_up: boolean;
  invite_sent_at: string | null;
  invite_expires_at?: string | null;
  invite_expired?: boolean;
  signed_up_at: string | null;
  last_opened_at: string | null;
  locked_until?: string | null;
}

export interface TermsAcceptance {
  version: string | null;
  accepted_at: string | null;
  /** True only when the accepted version is the current one. */
  current: boolean;
}

export interface AnswerFact {
  answer: DeliveryAnswer;
  answered_at: string | null;
}

export interface AppStatusRow {
  id: number;
  name: string;
  department: { id: number; name: string } | null;
  role: string | null;
  account: AppAccount;
  terms: TermsAcceptance;
  pay_statements: AnswerFact;
  w2gu: AnswerFact;
}

export interface AppStatusReport {
  enabled: boolean;
  delivery_consent_enabled: boolean;
  current_terms_version: string | null;
  /** App opens are recorded from this Guam day on. */
  opens_recorded_since: string;
  summary: Record<AppStatusFilter, number> & { total: number; signed_up: number; opened: number };
  departments: { id: number; name: string }[];
  roles: string[];
  employees: AppStatusRow[];
}

/** The per-employee facts on the profile panel (EmployeeAppRolloutActions#agreements_payload). */
export interface EmployeeAgreements {
  account: Pick<AppAccount, 'status' | 'label' | 'signed_up' | 'invite_sent_at' | 'signed_up_at' | 'last_opened_at'>;
  terms: TermsAcceptance;
  pay_statements: AnswerFact;
  w2gu: AnswerFact;
  current_terms_version: string | null;
  opens_recorded_since: string;
  delivery_consent_enabled: boolean;
}

export interface AppStatusQuery {
  filter?: AppStatusFilter;
  department_id?: string;
  role?: string;
  q?: string;
}

export const answerLabels: Record<DeliveryAnswer, string> = {
  paperless: 'Paperless',
  keep_paper: 'Keep paper',
  not_answered: 'Not answered',
};

export function employeeAppStatusApi(companyId: number, audience: 'admin' | 'client') {
  const path = `/${audience}/employee_app_status/${companyId}`;
  const options = { companyId };
  const params = (query: AppStatusQuery) => Object.fromEntries(Object.entries(query).filter(([, value]) => value));
  return {
    get: (query: AppStatusQuery = {}) => apiClient.get<{ data: AppStatusReport }>(path, params(query), options),
    download: (format: 'csv' | 'xlsx', query: AppStatusQuery = {}) => apiClient.getBlobWithParams(`${path}/${format}`, params(query), options),
  };
}

/** App opens are recorded since a known day, so "none" is "No recorded opens", never "Never". */
export function lastOpenedText(lastOpenedAt: string | null, includeTime = false): string {
  return lastOpenedAt ? `Last opened ${formatEmployeeAppDate(lastOpenedAt, includeTime)}` : 'No recorded opens';
}

export function opensCoverageNote(since: string): string {
  return `App opens are recorded since ${formatEmployeeAppDate(since)}.`;
}

export function accountTone(status: AppAccountStatus): 'success' | 'warning' | 'default' {
  if (status === 'active') return 'success';
  return status === 'invite_expired' || status === 'locked' || status === 'deactivated' ? 'warning' : 'default';
}
