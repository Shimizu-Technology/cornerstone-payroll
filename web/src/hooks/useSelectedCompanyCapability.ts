import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';

export type ClientCapability =
  | 'manage_client_configuration'
  | 'manage_client_check_settings'
  | 'manage_client_administration';

// Client grants never become global role capabilities. An explicit company
// response (including an empty list) takes precedence over the auth snapshot.
export function useSelectedCompanyCapability(capability: ClientCapability, companyId?: number | null): boolean {
  const { user, isLoading } = useAuth();
  const { activeCompany, activeCompanyId, loading } = useCompany();
  if (isLoading || loading || !activeCompany || !activeCompanyId || activeCompany.id !== activeCompanyId) return false;
  if (companyId !== undefined && companyId !== activeCompanyId) return false;
  const capabilities = activeCompany.client_capabilities ?? user?.company_capabilities?.[String(activeCompanyId)];
  return capabilities?.includes(capability) === true;
}
