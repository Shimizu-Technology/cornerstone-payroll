import { apiClient } from '@/services/api';

export type W2Delivery = 'mailed' | 'handed_out';

export interface EmployeeTaxFormCopy {
  id: number;
  employee_id: number;
  employee_name: string | null;
  status: 'posted' | 'withdrawn';
  revision: number;
  posted_at: string;
  withdrawn_at: string | null;
  withdrawn_by: string | null;
  withdrawal_note: string | null;
  inputs_changed_since_posting: boolean;
  paper_follow_up?: {
    status: 'required' | 'overdue' | 'mailed';
    bounced_on: string;
    due_on: string;
    mailed_on: string | null;
    mailed_by: string | null;
  } | null;
  notice: {
    status: 'pending' | 'sent' | 'skipped' | 'failed';
    skip_reason?: string | null;
    delivery_status: 'unknown' | 'delivered' | 'delayed' | 'bounced' | 'complained';
  } | null;
}

export interface EmployeeTaxForms {
  can_post: boolean;
  blocker?: 'feature_off' | 'unsupported_year' | 'not_filed' | 'not_final' | null;
  blocker_message: string | null;
  w2_delivery: W2Delivery | null;
  documents: EmployeeTaxFormCopy[];
}

const path = '/admin/employee_tax_forms';

export function employeeTaxFormsApi(companyId: number, year: number) {
  const options = { companyId };
  return {
    list: (signal: AbortSignal) => apiClient.get<EmployeeTaxForms>(path, { year }, { ...options, signal }),
    postCopies: () => apiClient.post(`${path}/post_copies`, { year }, options),
    markPaperMailed: (id: number) =>
      apiClient.post<{ document: EmployeeTaxFormCopy }>(`${path}/${id}/mark_paper_mailed`, {}, options),
    withdraw: (id: number, reason: string) =>
      apiClient.post<{ document: EmployeeTaxFormCopy }>(`${path}/${id}/withdraw`, { reason }, options),
    setDelivery: (delivery: W2Delivery | null) =>
      apiClient.patch<{ data: { w2_delivery: W2Delivery | null } }>('/admin/employee_app_settings/w2_delivery', { w2_delivery: delivery }, options),
  };
}
