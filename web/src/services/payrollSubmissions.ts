import api, { adminClientDocumentsApi, adminPortalThreadsApi, clientDocumentsApi, clientEmployeesApi, clientPortalThreadsApi, employeesApi } from './api';
import type { ClientDocument, ClientPortalMessage } from './api';

export type SubmissionStatus = 'waiting_for_files' | 'submitted' | 'received' | 'in_review' | 'draft_ready' | 'approved' | 'changes_requested' | 'paid';
export type ChangeKind = 'extra_hours' | 'owner_pay' | 'paid_leave' | 'new_hire' | 'wage_change' | 'deduction' | 'direct_deposit_addition';
export type ChangeRow = {
  kind: ChangeKind;
  label?: string;
  employee_id?: number;
  employee_name?: string;
  employee_ids?: number[];
  employee_names?: string[];
  hours?: string;
  amount?: string;
  basis?: 'total' | 'each';
  name?: string;
  starting_wage?: string;
  new_wage?: string;
  wage_unit?: 'hourly' | 'salary';
  start_date?: string;
  effective_date?: string;
  deduction_action?: 'start' | 'continue' | 'stop';
  description?: string;
  note?: string;
};
export type SubmissionDocumentRole = 'revel_payroll' | 'changes_workbook' | 'attachment';
export type SubmissionDocument = { role: SubmissionDocumentRole; file_name: string; file_size: number; sha256?: string; document?: ClientDocument | null };
export type SubmissionRevision = {
  id: number; revision: number; current: boolean; superseded: boolean;
  submitted_at: string; submitted_by_name?: string | null;
  acknowledged_at?: string | null; acknowledged_by_name?: string | null;
  no_changes: boolean; notes?: string | null; changes_link_url?: string | null;
  changes: ChangeRow[]; documents: SubmissionDocument[];
};
export type SubmissionDraft = {
  id: number; revision: number; current: boolean; superseded: boolean; posted: boolean;
  posted_at?: string | null; posted_by_name?: string | null; created_by_name?: string | null; note?: string | null;
  paycheck_document?: ClientDocument | null; direct_deposit_document?: ClientDocument | null;
};
export type SubmissionHistoryEvent = {
  id: number; event: string; from_status: SubmissionStatus; to_status: SubmissionStatus; to_status_label: string;
  actor_name: string; actor_audience: 'client' | 'staff'; note?: string | null; submission_id?: number | null; draft_id?: number | null; created_at: string;
};
export type PeriodSummary = {
  ref: string; id: number | null; start_date: string; end_date: string; label: string; pay_date: string | null;
  status: SubmissionStatus; status_label: string; open_for_files: boolean; opens_on: string;
  current_revision: number | null; last_submitted_at: string | null; status_changed_at: string | null;
  pay_period_id?: number | null; source?: 'pay_period' | 'schedule'; unread?: boolean;
};
export type PeriodAction = 'submit' | 'approve' | 'request_changes' | 'message' | 'acknowledge' | 'start_review' | 'post_draft' | 'save_draft' | 'mark_paid';
export type PeriodDetail = PeriodSummary & {
  schedule_note: string; thread_id: number | null; allowed_actions: PeriodAction[];
  submissions: SubmissionRevision[]; drafts: SubmissionDraft[]; history: SubmissionHistoryEvent[];
};
export type PickerEmployee = { id: number; name: string };
type Detail = { data: PeriodDetail };

const encode = (ref: string) => encodeURIComponent(ref);
const pickerEmployees = (rows: { id: number; first_name: string; last_name: string }[]): PickerEmployee[] =>
  rows.map(row => ({ id: row.id, name: `${row.first_name} ${row.last_name}`.trim() }));

function sharedApi(base: '/client' | '/admin') {
  const root = `${base}/payroll_submission_periods`;
  return {
    list: () => api.get<{ data: PeriodSummary[]; meta: { derives_from_schedule: boolean } }>(root),
    get: (ref: string) => api.get<Detail>(`${root}/${encode(ref)}`),
    message: (ref: string, data: { body: string; idempotency_key: string }) =>
      api.post<{ data: ClientPortalMessage; thread_id: number }>(`${root}/${encode(ref)}/messages`, data),
  };
}

export const clientPayrollSubmissionsApi = {
  ...sharedApi('/client'),
  submit: (ref: string, form: FormData) => api.postForm<Detail & { outcome: 'created' | 'replayed' | 'duplicate' }>(`/client/payroll_submission_periods/${encode(ref)}/submissions`, form),
  decide: (ref: string, data: { decision: 'approve' | 'request_changes'; draft_id: number; note?: string }) =>
    api.post<Detail>(`/client/payroll_submission_periods/${encode(ref)}/decision`, data),
  threads: clientPortalThreadsApi,
  documents: clientDocumentsApi,
  employees: async (): Promise<PickerEmployee[]> =>
    pickerEmployees((await clientEmployeesApi.list({ status: 'active', per_page: 200, sort_by: 'name' })).data),
};

export const adminPayrollSubmissionsApi = {
  ...sharedApi('/admin'),
  acknowledge: (ref: string, submissionId: number) => api.post<Detail>(`/admin/payroll_submission_periods/${encode(ref)}/acknowledge`, { submission_id: submissionId }),
  startReview: (ref: string) => api.post<Detail>(`/admin/payroll_submission_periods/${encode(ref)}/start_review`),
  markPaid: (ref: string, note?: string) => api.post<Detail>(`/admin/payroll_submission_periods/${encode(ref)}/mark_paid`, { note }),
  createDraft: (ref: string, form: FormData) => api.postForm<Detail>(`/admin/payroll_submission_periods/${encode(ref)}/drafts`, form),
  postDraft: (ref: string, draftId: number) => api.post<Detail>(`/admin/payroll_submission_periods/${encode(ref)}/drafts/${draftId}/post`),
  seen: (ref: string) => api.post<void>(`/admin/payroll_submission_periods/${encode(ref)}/seen`),
  threads: adminPortalThreadsApi,
  documents: adminClientDocumentsApi,
  employees: async (): Promise<PickerEmployee[]> =>
    pickerEmployees((await employeesApi.list({ status: 'active', per_page: 200, sort_by: 'name' })).data),
};

export type PayrollSubmissionsApi = typeof clientPayrollSubmissionsApi | typeof adminPayrollSubmissionsApi;

export const STATUS_STEPS: { status: SubmissionStatus; label: string }[] = [
  { status: 'waiting_for_files', label: 'Waiting for files' },
  { status: 'received', label: 'Received' },
  { status: 'in_review', label: 'In review' },
  { status: 'draft_ready', label: 'Draft ready' },
  { status: 'approved', label: 'Approved' },
  { status: 'paid', label: 'Paid' },
];

export const CHANGE_KINDS: { kind: ChangeKind; label: string; hint: string }[] = [
  { kind: 'extra_hours', label: 'Extra or manual hours', hint: 'Hours not in the Revel report' },
  { kind: 'owner_pay', label: 'Owner pay', hint: 'Say whether the amount is the total or for each owner' },
  { kind: 'paid_leave', label: 'Paid leave', hint: 'Leave hours to add' },
  { kind: 'new_hire', label: 'New hire', hint: 'Name and starting wage' },
  { kind: 'wage_change', label: 'Wage change', hint: 'New wage for an employee' },
  { kind: 'deduction', label: 'Deduction', hint: 'Start, continue or stop a deduction' },
  { kind: 'direct_deposit_addition', label: 'Direct deposit addition', hint: 'Employee newly on direct deposit. Send bank details on the signed form, not here.' },
];
