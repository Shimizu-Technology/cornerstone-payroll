import api from './api';

export interface SharedEmailReportEntry {
  email: string;
  total_count: number;
  active_count: number;
  inactive_count: number;
  companies_count: number;
  organization_total_count: number;
  reasons: string[];
  classification: 'placeholder' | 'shared_inbox' | 'shared';
  clearable: boolean;
  marked_placeholder: boolean;
  unmarkable?: boolean;
}

export interface SharedEmailCompanySummary {
  company_id: number;
  company_name: string;
  total_flagged_records: number;
  active_flagged_records: number;
  emails: SharedEmailReportEntry[];
}

export interface SharedEmailReportResponse {
  summary: {
    companies_affected: number;
    distinct_flagged_emails: number;
    total_employee_records: number;
    active_employee_records: number;
  };
  can_manage_placeholders?: boolean;
  /** False when the selected company is a test workspace. */
  can_clear?: boolean;
  marked_placeholders?: string[];
  /** Every marked address, even one no employee uses any more. */
  placeholder_marks?: PlaceholderMark[];
  companies: SharedEmailCompanySummary[];
}

export interface PlaceholderMark {
  email: string;
  /** False for an address set in server configuration, which staff can't unmark here. */
  unmarkable: boolean;
}

export interface ClearSharedEmailResponse {
  data: {
    company_id: number;
    company_name: string;
    email: string;
    cleared_count: number;
    active_cleared_count: number;
    inactive_cleared_count: number;
  };
  message: string;
}

export interface PlaceholderEmailMutationResponse {
  data: {
    email: string;
    reason?: string | null;
    marked: boolean;
    changed: boolean;
  };
  message: string;
}

export const staffContactHygieneApi = {
  sharedEmails: (params?: { company_id?: number }) =>
    api.get<SharedEmailReportResponse>('/admin/employee_contact_hygiene/shared_emails', params),
  markPlaceholderEmail: (data: { email: string; reason?: string }) =>
    api.post<PlaceholderEmailMutationResponse>('/admin/employee_contact_hygiene/placeholder_emails', data),
  unmarkPlaceholderEmail: (data: { email: string }) =>
    api.delete<PlaceholderEmailMutationResponse>('/admin/employee_contact_hygiene/placeholder_emails', { data }),
  // Sent as the selected company, which the server requires to be the live
  // clear target, so a test workspace can't clear its live source.
  clearSharedEmails: (data: { company_id: number; email: string }, selectedCompanyId: number) =>
    api.post<ClearSharedEmailResponse>('/admin/employee_contact_hygiene/clear_shared_emails', data, { companyId: selectedCompanyId }),
};
