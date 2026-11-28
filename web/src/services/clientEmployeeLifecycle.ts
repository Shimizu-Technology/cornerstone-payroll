import { apiClient, clientEmployeesApi, type BoundedListMeta } from '@/services/api';
import { maskTaxIdsInText as maskLifecycleNote } from '@/lib/employee-profile';
import type { EmployeeFormData } from '@/types';

export { maskLifecycleNote };

export const ownEmployeeReviewNotice = 'This is your own employee record. Changes to your pay, tax details, payment method, name, birth date, hire date, or email go to Cornerstone for review. Address-only changes can be reviewed by another manager or Cornerstone.';

export type EmployeeLifecycleMode = 'approval_first' | 'client_managed';
export type ClientEmployeeCreateInput = Pick<EmployeeFormData, 'first_name' | 'last_name' | 'employment_type'> & Partial<EmployeeFormData>;

export type ReadinessKey =
  | 'legal_name' | 'tax_id' | 'date_of_birth' | 'hire_date' | 'home_address'
  | 'pay_setup' | 'tax_form' | 'payment_method';

export interface EmployeeReadiness {
  status: 'ready' | 'incomplete' | 'missing_items';
  rates_on: string;
  w4_on: string;
  missing_keys: ReadinessKey[];
  reason: string | null;
  direct_deposit_missing_bank_details: boolean;
  items: {
    key: ReadinessKey;
    label: string;
    complete: boolean;
    applicable: boolean;
    missing_label: string | null;
  }[];
}

export interface LifecycleEditContext {
  own_record: boolean;
  today: string;
  compensation_default_on: string;
  earliest_compensation_effective_on?: string | null;
  calculated_through: string | null;
  calculated_pay_date: string | null;
  approved_pay_date: string | null;
  approved_runs: { start_date: string; end_date: string }[];
  last_committed_period_end: string | null;
  former_access_years: number;
  rehire_readiness: EmployeeReadiness | null;
}

export interface ReturnedVerificationItem {
  id: number;
  employee_id: number;
  event_kind: string;
  return_note: string | null;
}

type VerificationResponse = { data: ReturnedVerificationItem & { status: 'pending_verification' } };

interface TerminationInput {
  last_worked_on: string;
  effective_date: string;
  reason_category: string;
  final_pay_notes?: string;
  notes?: string;
}

interface TransitionResponse {
  data: Awaited<ReturnType<typeof clientEmployeesApi.get>>['data'];
  warnings?: string[];
  message: string;
}

async function returnedPage(employeeId?: number, page?: number, perPage?: number) {
  return apiClient.get<{ data: ReturnedVerificationItem[]; meta: BoundedListMeta }>('/client/verification_items', {
    status: 'returned_to_client', employee_id: employeeId, page, per_page: perPage,
  });
}

export const clientEmployeeLifecycleApi = {
  returnedCount: async () => (await returnedPage(undefined, 1, 1)).meta.total_count,
  returnedForEmployee: async (employeeId: number) => {
    const first = await returnedPage(employeeId, 1);
    const items = first.data.slice();
    for (let page = 2; page <= first.meta.total_pages; page += 1) {
      const next = await returnedPage(employeeId, page);
      items.push(...next.data);
    }
    return items;
  },
  respond: (id: number, note: string) =>
    apiClient.post<VerificationResponse>(`/client/verification_items/${id}/respond`, { note: maskLifecycleNote(note) }),
  terminate: (id: number, termination: TerminationInput) =>
    apiClient.post<TransitionResponse>(`/client/employees/${id}/terminate`, { termination: {
      ...termination,
      notes: termination.notes && maskLifecycleNote(termination.notes),
      final_pay_notes: termination.final_pay_notes && maskLifecycleNote(termination.final_pay_notes),
    } }),
  rehire: (id: number, rehire: { effective_date: string; notes?: string }) =>
    apiClient.post<TransitionResponse>(`/client/employees/${id}/rehire`, { rehire: { ...rehire, notes: rehire.notes && maskLifecycleNote(rehire.notes) } }),
};

export function lifecycleErrorCode(error: unknown): string | undefined {
  if (!(error instanceof Error) || !('data' in error)) return undefined;
  const data = error.data;
  return data && typeof data === 'object' && 'code' in data && typeof data.code === 'string' ? data.code : undefined;
}

export function lifecycleModeChanged(error: unknown): boolean {
  if (lifecycleErrorCode(error) !== 'lifecycle_mode_changed' || !(error instanceof Error) || !('data' in error)) return false;
  const data = error.data;
  return Boolean(data && typeof data === 'object' && 'employee_lifecycle_mode' in data && data.employee_lifecycle_mode === 'client_managed');
}

const withholdingFields = [
  'filing_status', 'allowances', 'additional_withholding', 'w4_dependent_credit', 'w4_step2_multiple_jobs',
  'w4_step4a_other_income', 'w4_step4b_deductions', 'w4_form_version', 'w4_effective_on', 'w4_signed_on',
  'w4_source_reference', 'w4_election_received', 'w4_change_reason',
] as const;

export function clientManagedEmployeePayload(data: ClientEmployeeCreateInput, withholdingDate: string | null): ClientEmployeeCreateInput {
  if (withholdingDate) return {
    ...data, w4_effective_on: withholdingDate, w4_election_received: true,
    w4_source_reference: data.w4_source_reference && maskLifecycleNote(data.w4_source_reference),
  };

  // An untouched W-4 must not save the form's default filing status or replace a dated election.
  const fields = { ...data };
  withholdingFields.forEach((field) => { delete fields[field]; });
  return fields;
}
