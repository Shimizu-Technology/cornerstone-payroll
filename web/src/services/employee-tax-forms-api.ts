import { apiClient } from '@/services/api';

export type W2Delivery = 'mailed' | 'handed_out';

export interface EmployeeTaxFormCopy {
  id: number;
  employee_id: number;
  employee_name: string | null;
  status: 'posted' | 'withdrawn';
  posted_at: string;
  withdrawal_note: string | null;
  inputs_changed_since_posting: boolean;
  notice: {
    status: 'pending' | 'sent' | 'skipped' | 'failed';
    delivery_status: 'unknown' | 'delivered' | 'delayed' | 'bounced' | 'complained';
  } | null;
}

export interface EmployeeTaxForms {
  can_post: boolean;
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
    withdraw: (id: number, reason: string) =>
      apiClient.post<{ document: EmployeeTaxFormCopy }>(`${path}/${id}/withdraw`, { reason }, options),
    setDelivery: (delivery: W2Delivery | null) =>
      apiClient.patch<{ data: { w2_delivery: W2Delivery | null } }>('/admin/employee_app_settings/w2_delivery', { w2_delivery: delivery }, options),
  };
}
