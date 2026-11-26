import { apiClient } from '@/services/api';

export type EmployeeAppStatus = 'not_invited' | 'invited' | 'active' | 'locked' | 'former' | 'revoked';
export type InviteDelivery = 'email' | 'code';
export type EmailStatus = 'sent' | 'captured' | 'skipped' | 'failed';
export type EmployeeAppOperation = 'invite' | 'resend' | 'unlock' | 'revoke' | 'reset_sign_up';

interface EmployeeName {
  id: number;
  name: string;
}

export interface EmployeeAppAccess extends EmployeeName {
  email: string | null;
  status: EmployeeAppStatus;
  enabled: boolean;
  can_manage_invites: boolean;
  staff_actions: boolean;
  /** Printed sign-up codes are for Cornerstone staff only; clients invite by email. */
  can_print_codes?: boolean;
  access_id: number | null;
  activated_at?: string | null;
  invited_by_name?: string | null;
  former_access_until: string | null;
  invite_expires_at: string | null;
  invite_delivery: InviteDelivery | null;
  locked_until: string | null;
  reset_pending: boolean;
  can_invite: boolean;
}

export interface PrintedInvite {
  name: string;
  code: string;
  url: string;
  expires_at: string;
}

export interface InviteOutcome {
  email_status?: EmailStatus;
  print?: PrintedInvite;
}

export interface WaveOutcome extends InviteOutcome {
  id: number;
  error?: string;
}

export type RolloutCount = 'ready_to_invite' | 'invited' | 'active' | 'needs_contact_details' | 'locked' | 'former';
export interface EmployeeAppRollout {
  enabled: boolean;
  can_manage_invites: boolean;
  can_print_codes?: boolean;
  max_wave_size: number;
  counts: Record<RolloutCount, number>;
  candidates: (EmployeeName & { email: string | null; email_ready: boolean; email_review_required: boolean })[];
  todo: {
    locked: (EmployeeName & { locked_until: string })[];
    needs_contact_details: EmployeeName[];
    expiring: (EmployeeName & { invite_expires_at: string; expired: boolean })[];
    reset_pending: EmployeeName[];
    cleanup: EmployeeName[];
  };
  lock_alert: string | null;
}

export function employeeAppRolloutApi(companyId: number, audience: 'admin' | 'client') {
  const path = `/${audience}/employee_app_rollout/${companyId}`;
  const employeePath = (employeeId: number) => `/${audience}/employees/${employeeId}/employee_app`;
  const options = { companyId };
  return {
    get: () => apiClient.get<{ data: EmployeeAppRollout }>(path, undefined, options),
    employee: (employeeId: number) => apiClient.get<{ data: EmployeeAppAccess }>(employeePath(employeeId), undefined, options),
    change: (employeeId: number, operation: EmployeeAppOperation, payload: {
      access_id: number | null;
      delivery?: InviteDelivery;
      reason?: string;
      confirm_same_person_email?: boolean;
    }) => apiClient.post<{ data: EmployeeAppAccess } & InviteOutcome>(`${employeePath(employeeId)}/${operation}`, payload, options),
    inviteWave: (employeeIds: number[], delivery: InviteDelivery) => apiClient.post<{ data: WaveOutcome[] }>(
      `${path}/invite`, { employee_ids: employeeIds, delivery }, options,
    ),
  };
}

export const employeeAppOff = "The employee app isn't turned on for this company yet.";

export const inviteEmailMessages: Record<EmailStatus, string> = {
  sent: 'Invite email sent.',
  captured: 'Invite saved in the test outbox.',
  skipped: 'Invite created. No email was sent. Resend it from the employee record when email is available.',
  failed: 'Invite created, but the email could not be sent. Resend it from the employee record.',
};

export function formatEmployeeAppDate(value: string, includeTime = false): string {
  // Date-only values represent a calendar day. Timestamps use Guam time.
  const dateOnly = /^\d{4}-\d{2}-\d{2}$/.test(value);
  return new Date(value).toLocaleString('en-US', {
    timeZone: dateOnly ? 'UTC' : 'Pacific/Guam',
    dateStyle: 'medium',
    ...(!dateOnly && includeTime ? { timeStyle: 'short' } : {}),
  });
}
