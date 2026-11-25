import { apiClient, getApiBaseUrl } from '@/services/api';

export type CheckStatus = 'passed' | 'failed' | 'waived';

export interface ReadinessCheck {
  key: string;
  name: string;
  status: CheckStatus;
  detail: string | null;
}

export interface SwitchRow {
  key: string;
  label: string;
  description: string;
  on: boolean;
  open_today: boolean;
  feature: boolean;
  blocked_by: string[];
}

export interface EarlyAccessWindow {
  id: number;
  status: 'in_effect' | 'expired' | 'ended';
  expires_on: string;
  companies: { id: number; name: string | null }[];
  reason: string;
  set_by: string | null;
  set_at: string;
  ended_at: string | null;
  ended_by: string | null;
  end_reason: string | null;
}

export interface EmployeeAppSwitchState {
  company: { id: number; name: string; demo: boolean; live: boolean; subdomain_slug: string | null };
  switches: SwitchRow[];
  stays_off: { key: string; label: string; description: string }[];
  readiness: {
    checked_at: string;
    checks: ReadinessCheck[];
    counsel_checks: Record<'terms' | 'consent', ReadinessCheck>;
    switch_checks: Record<string, string[]>;
    observed: {
      reported: boolean;
      fresh: boolean;
      observed_at: string | null;
      revision: string | null;
      rls_guard_mode: 'off' | 'log' | 'raise' | null;
      rls_runtime_role_verified: boolean;
      dependencies_healthy: boolean;
      answered_health_check: boolean;
      health_check_configured: boolean;
    };
    database: { phase: 'enforced' | 'shadow' | 'not_installed' | 'unknown'; enforced: boolean; enforced_tables: number; protected_tables: number };
    early_access: { id: number; status: string; expires_on: string; covers_company: boolean; applied: boolean } | null;
  };
  early_access: {
    name: string;
    max_days: number;
    max_companies: number;
    demo_companies: { id: number; name: string }[];
    windows: EarlyAccessWindow[];
  };
}

export interface SwitchFailure {
  error?: string;
  code?: string;
  failing_checks?: ReadinessCheck[];
  data?: EmployeeAppSwitchState;
}

const PATH = '/admin/employee_app_switch';

export const employeeAppSwitchApi = {
  get: (companyId: number) => apiClient.get<{ data: EmployeeAppSwitchState }>(PATH, undefined, { companyId }),
};

/**
 * Builds a mutating request for useStepUpRequest, so Clerk can ask for a
 * fresh second factor when the server needs one (turning on, early access).
 */
export function switchRequest(companyId: number, method: 'PATCH' | 'PUT' | 'DELETE' | 'POST', suffix: string, body: unknown) {
  return (token: string) => fetch(`${getApiBaseUrl()}${PATH}${suffix}`, {
    method,
    cache: 'no-store',
    redirect: 'error',
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'X-Company-Id': String(companyId), 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}
