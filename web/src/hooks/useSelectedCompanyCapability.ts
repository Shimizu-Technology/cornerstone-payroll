import { useAuth, useOptionalAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { canWriteCompany } from '@/lib/company-write-access';

export type ClientCapability =
  | 'manage_client_configuration'
  | 'manage_client_check_settings'
  | 'manage_client_administration'
  | 'manage_employee_status'
  | 'manage_time_tracking_lock';

type AuthSnapshot = Pick<ReturnType<typeof useAuth>, 'user' | 'isLoading'>;

// Client grants never become global role capabilities. An explicit company
// response (including an empty list) takes precedence over the auth snapshot.
function hasCapability(auth: AuthSnapshot | undefined, company: ReturnType<typeof useCompany>, capability: ClientCapability, companyId?: number | null): boolean {
  const { activeCompany, activeCompanyId, loading } = company;
  if (!auth || auth.isLoading || loading || !activeCompany || !activeCompanyId || activeCompany.id !== activeCompanyId) return false;
  if (companyId !== undefined && companyId !== activeCompanyId) return false;
  const capabilities = activeCompany.client_capabilities ?? auth.user?.company_capabilities?.[String(activeCompanyId)];
  return capabilities?.includes(capability) === true;
}

export function useSelectedCompanyCapability(capability: ClientCapability, companyId?: number | null): boolean {
  return hasCapability(useAuth(), useCompany(), capability, companyId);
}

// The same check for components that may render outside the auth provider,
// such as the import review opened from a pay run. No provider, no capability.
export function useOptionalSelectedCompanyCapability(capability: ClientCapability, companyId?: number | null): boolean {
  return hasCapability(useOptionalAuth(), useCompany(), capability, companyId);
}

// Payroll staff can reactivate an inactive worker. Bringing back a terminated
// worker is a rehire, which also needs client configuration. Both respect the
// selected workspace's write permission.
export function useOptionalWorkerStatusAccess(companyId?: number | null): { canReactivate: boolean; canRehire: boolean } {
  const { activeCompany } = useCompany();
  const hasStatus = useOptionalSelectedCompanyCapability('manage_employee_status', companyId);
  const hasConfiguration = useOptionalSelectedCompanyCapability('manage_client_configuration', companyId);
  const canReactivate = hasStatus && canWriteCompany(activeCompany, 'manage_employee_status');
  return { canReactivate, canRehire: canReactivate && hasConfiguration && canWriteCompany(activeCompany, 'manage_client_configuration') };
}
