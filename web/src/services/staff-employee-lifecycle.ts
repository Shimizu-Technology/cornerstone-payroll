import type { Employee } from '@/types';
import api, { getApiBaseUrl } from '@/services/api';
import type { OperatingProfileResponse, OperatingProfileVersion } from '@/services/operating-profile';

export const LIFECYCLE_MODE_KEY = 'client_portal.employee_lifecycle_mode';

export type VerificationStatus = 'pending_verification' | 'returned_to_client' | 'verified' | 'superseded';
export type VerificationEvent = 'new_hire' | 'compensation_change' | 'w4_change' | 'payment_method_change'
  | 'identity_tax_change' | 'contractor_tax_change' | 'termination' | 'rehire' | 'profile_change';

export interface VerificationRow {
  id: number;
  company_id: number;
  employee_id: number;
  employee_name: string;
  event_kind: VerificationEvent;
  status: VerificationStatus;
  affects_pay: boolean;
  source_actor_name: string | null;
  effective_on: string | null;
  created_at: string;
  updated_at: string;
}

export interface ReadinessChecklist {
  status: 'ready' | 'incomplete' | 'missing_items';
  rates_on: string;
  w4_on: string;
  missing_keys: string[];
  items: { key: string; label: string; complete: boolean; applicable: boolean; missing_label: string | null }[];
}

export interface VerificationDetails extends VerificationRow {
  changed_fields: string[];
  before_values: Record<string, unknown>;
  after_values: Record<string, unknown>;
  readiness_checklist: ReadinessChecklist;
  return_note: string | null;
  client_response_note: string | null;
  verification_note: string | null;
  resubmitted_at: string | null;
  audit_references: { id: number; return_note: string | null; staff_edit_audit_id: number | null }[];
  can_review: boolean;
  warnings: {
    committed_pay_period_ids: number[];
    possible_self_created_hire: boolean;
    review_final_pay: boolean;
    post_termination_committed_pay_period_ids: number[];
    direct_deposit_missing_bank_details: boolean;
    tax_filing_impact: { committed_tax_years?: number[]; filed_quarters?: string[] } | null;
    approved_pay_period_ids: number[];
  };
}

type VerificationFilters = { status?: VerificationStatus; event_kind?: VerificationEvent; search?: string; page: number; per_page: number };
export type ReadinessScope = { pay_period_id: number } | { expires_on: string };
export interface ReadinessOptions {
  today: string;
  latest_expiration: string;
  pay_periods: { id: number; start_date: string; end_date: string; pay_date: string }[];
  active_overrides: { id: number; pay_period_id: number | null; expires_on: string | null; reason: string }[];
}
export interface ReadinessPreview {
  checklist: ReadinessChecklist;
  default_w4_acknowledgement_required: boolean;
}
export type ReadinessMutation =
  | { action: 'grant'; scope: ReadinessScope; reason: string; default_w4_acknowledged: boolean }
  | { action: 'clear'; reason: string }
  | { action: 'revoke'; overrideId: number; reason: string };

type PreflightChecks = {
  pending_non_address_change_requests_count: number;
  active_intake_window: boolean;
  qualifying_staff_notification_recipients_count: number;
};
export interface LifecyclePreflight extends PreflightChecks {
  ready: boolean;
  blockers: string[];
  lifecycle_mode_activation_status: 'inactive' | 'scheduled' | 'blocked' | 'active';
  lifecycle_mode_activation_blockers: Partial<PreflightChecks>;
  scheduled_effective_on: string | null;
}

const queuePath = '/admin/employee_verification_items';
const employeeApiPath = (id: number) => `/admin/employees/${id}`;
const profilePath = (companyId: number) => `/admin/companies/${companyId}/operating_profile`;

export const staffEmployeeLifecycleApi = {
  employeeForFix: (companyId: number, employeeId: number) =>
    api.get<{ data: Employee }>(employeeApiPath(employeeId), { mask_tax_ids: true }, { companyId }),
  list: (companyId: number, filters: VerificationFilters, signal: AbortSignal) =>
    api.get<{ data: VerificationRow[]; meta: { current_page: number; total_pages: number; total_count: number } }>(
      queuePath, filters, { companyId, signal },
    ),
  get: (companyId: number, itemId: number, signal?: AbortSignal) =>
    api.get<{ data: VerificationDetails }>(`${queuePath}/${itemId}`, undefined, { companyId, signal }),
  verify: (companyId: number, itemId: number, body: { updated_at: string; verification_note?: string; fixed_by_staff?: boolean }) =>
    api.post<{ data: VerificationDetails }>(`${queuePath}/${itemId}/verify`, body, { companyId }),
  sendBack: (companyId: number, itemId: number, body: { updated_at: string; return_note: string }) =>
    api.post<{ data: VerificationDetails }>(`${queuePath}/${itemId}/return_to_client`, body, { companyId }),
  readinessOptions: (companyId: number, employeeId: number, signal: AbortSignal) =>
    api.get<{ data: ReadinessOptions }>(`${employeeApiPath(employeeId)}/readiness_override`, undefined, { companyId, signal }),
  readinessPreview: (companyId: number, employeeId: number, scope: ReadinessScope, signal: AbortSignal) =>
    api.get<{ data: ReadinessPreview }>(`${employeeApiPath(employeeId)}/readiness_override`, scope, { companyId, signal }),
  changeReadiness: (token: string, companyId: number, employeeId: number, mutation: ReadinessMutation): Promise<Response> => {
    const path = employeeApiPath(employeeId);
    const actionPath = mutation.action === 'revoke' ? `readiness_override/${mutation.overrideId}`
      : mutation.action === 'grant' ? 'readiness_override' : 'clear_readiness_gate';
    const body = mutation.action === 'grant'
      ? { ...mutation.scope, reason: mutation.reason, default_w4_acknowledged: mutation.default_w4_acknowledged }
      : { reason: mutation.reason };
    return fetch(`${getApiBaseUrl()}${path}/${actionPath}`, {
      method: mutation.action === 'revoke' ? 'DELETE' : 'POST',
      cache: 'no-store',
      redirect: 'error',
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        'X-Company-Id': String(companyId),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    });
  },
  retryActivation: (companyId: number) =>
    api.post<OperatingProfileResponse>(`${profilePath(companyId)}/activate_lifecycle_mode`, undefined, { companyId }),
  revertActivation: (companyId: number, body: { effective_on: string; reason: string; lock_version: number }) =>
    api.patch<OperatingProfileResponse & { saved: OperatingProfileVersion }>(
      profilePath(companyId), { ...body, changes: { [LIFECYCLE_MODE_KEY]: 'approval_first' } }, { companyId },
    ),
};
