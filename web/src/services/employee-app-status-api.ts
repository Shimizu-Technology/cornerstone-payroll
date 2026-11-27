import { apiClient } from '@/services/api';

// GET /{admin,client}/employee_app_status/:company_id (+ /csv, /xlsx): who has
// an employee app account and what they agreed to (EmployeeAppStatusReport).

export type AppAccountStatus = 'not_invited' | 'invited' | 'invite_expired' | 'locked' | 'active' | 'deactivated' | 'former' | 'revoked';
export type DeliveryAnswer = 'paperless' | 'keep_paper' | 'not_answered';
export type AppStatusFilter = 'never_signed_in' | 'invite_expired' | 'terms_not_accepted' | 'no_paperless_answer' | 'kept_paper';

export interface AppAccount {
  status: AppAccountStatus;
  label: string;
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
  summary: Record<AppStatusFilter, number> & { total: number; signed_up: number };
  departments: { id: number; name: string }[];
  roles: string[];
  employees: AppStatusRow[];
}

/** The per-employee facts on the profile panel (EmployeeAppRolloutActions#agreements_payload). */
export interface EmployeeAgreements {
  account: Pick<AppAccount, 'status' | 'label' | 'invite_sent_at' | 'signed_up_at' | 'last_opened_at'>;
  terms: TermsAcceptance;
  pay_statements: AnswerFact;
  w2gu: AnswerFact;
  current_terms_version: string | null;
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
