/* eslint-disable react-refresh/only-export-components */
import { createContext, useContext, useState, useEffect, useCallback, useRef, type ReactNode } from 'react';
import { companiesApi, type CompanyListItem } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';

interface CompanyContextValue {
  companies: CompanyListItem[];
  organizations: Array<{ id: number; name: string }>;
  activeCompany: CompanyListItem | null;
  activeCompanyId: number | null;
  activeOrganizationId: number | null;
  activeOrganizationName: string | null;
  canManageClients: boolean;
  canViewClientManagement: boolean;
  canSwitchCompany: boolean;
  loading: boolean;
  switchCompany: (companyId: number) => void;
  switchOrganization: (organizationId: number) => void;
  refreshCompanies: () => Promise<void>;
}

const CompanyContext = createContext<CompanyContextValue>({
  companies: [],
  organizations: [],
  activeCompany: null,
  activeCompanyId: null,
  activeOrganizationId: null,
  activeOrganizationName: null,
  canManageClients: false,
  canViewClientManagement: false,
  canSwitchCompany: false,
  loading: true,
  switchCompany: () => {},
  switchOrganization: () => {},
  refreshCompanies: async () => {},
});

export function useCompany() {
  return useContext(CompanyContext);
}

function applyCompanyResponse(
  res: { companies: CompanyListItem[]; can_manage_clients: boolean; can_view_client_management?: boolean; can_switch_company: boolean; current_company_id: number },
  setCompanies: (c: CompanyListItem[]) => void,
  setCanManageClients: (v: boolean) => void,
  setCanViewClientManagement: (v: boolean) => void,
  setCanSwitchCompany: (v: boolean) => void,
  setActiveCompanyId: (id: number | null) => void,
  setFetched: (v: boolean) => void,
) {
  setCompanies(res.companies);
  setCanManageClients(res.can_manage_clients);
  setCanViewClientManagement(res.can_view_client_management ?? res.can_manage_clients);
  setCanSwitchCompany(res.can_switch_company ?? res.can_manage_clients);

  const storedId = companiesApi.getActiveCompanyId();
  if (storedId && res.companies.some(c => c.id === storedId)) {
    setActiveCompanyId(storedId);
    companiesApi.switchCompany(storedId, res.companies.find(c => c.id === storedId)?.organization_id);
  } else if (res.current_company_id) {
    setActiveCompanyId(res.current_company_id);
    companiesApi.switchCompany(res.current_company_id, res.companies.find(c => c.id === res.current_company_id)?.organization_id);
  }
  setFetched(true);
}

export function CompanyProvider({ children }: { children: ReactNode }) {
  const { isAuthenticated, isLoading: authLoading, user } = useAuth();
  const userId = user?.id ?? null;
  const [companies, setCompanies] = useState<CompanyListItem[]>([]);
  const [activeCompanyId, setActiveCompanyId] = useState<number | null>(
    companiesApi.getActiveCompanyId()
  );
  const [canManageClients, setCanManageClients] = useState(false);
  const [canViewClientManagement, setCanViewClientManagement] = useState(false);
  const [canSwitchCompany, setCanSwitchCompany] = useState(false);
  const [loading, setLoading] = useState(true);
  const [fetched, setFetched] = useState(false);
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    return () => { mountedRef.current = false; };
  }, []);

  const resetCompanyState = useCallback(() => {
    companiesApi.clearActiveCompanyId();
    setCompanies([]);
    setActiveCompanyId(null);
    setCanManageClients(false);
    setCanViewClientManagement(false);
    setCanSwitchCompany(false);
    setFetched(false);
    setLoading(false);
  }, []);

  const refreshCompanies = useCallback(async () => {
    try {
      const res = await companiesApi.list();
      if (!mountedRef.current) return;
      applyCompanyResponse(res, setCompanies, setCanManageClients, setCanViewClientManagement, setCanSwitchCompany, setActiveCompanyId, setFetched);
    } catch {
      // Retry once after a short delay (handles race with auth/server startup)
      setTimeout(async () => {
        try {
          const res = await companiesApi.list();
          if (!mountedRef.current) return;
          applyCompanyResponse(res, setCompanies, setCanManageClients, setCanViewClientManagement, setCanSwitchCompany, setActiveCompanyId, setFetched);
        } catch { /* give up */ }
        if (mountedRef.current) setLoading(false);
      }, 1500);
      return;
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    if (authLoading) {
      return;
    }

    if (!isAuthenticated || userId === null) {
      const resetTimer = window.setTimeout(() => {
        if (!mountedRef.current) return;
        resetCompanyState();
      }, 0);
      return () => window.clearTimeout(resetTimer);
    }

    const initTimer = window.setTimeout(() => {
      if (!mountedRef.current) return;
      setLoading(true);
      setFetched(false);
    }, 0);

    return () => window.clearTimeout(initTimer);
  }, [authLoading, isAuthenticated, userId, resetCompanyState]);

  useEffect(() => {
    if (authLoading || !isAuthenticated || userId === null || fetched) return;

    const fetchTimer = window.setTimeout(() => {
      void refreshCompanies();
    }, 0);

    return () => window.clearTimeout(fetchTimer);
  }, [authLoading, isAuthenticated, userId, fetched, refreshCompanies]);

  const switchCompany = useCallback((companyId: number) => {
    const company = companies.find((candidate) => candidate.id === companyId);
    if (!company) return;
    if (companyId === activeCompanyId) {
      return;
    }

    setActiveCompanyId(companyId);
    companiesApi.switchCompany(companyId, company.organization_id);
  }, [activeCompanyId, companies]);

  const activeCompany = companies.find(c => c.id === activeCompanyId) || null;
  const activeOrganizationId = activeCompany?.organization_id ?? user?.organization_id ?? null;
  const activeOrganizationName = activeCompany?.organization_name || user?.organization_name || null;
  const organizations = Array.from(new Map(companies.map((company) => [
    company.organization_id,
    { id: company.organization_id, name: company.organization_name || `Organization #${company.organization_id}` },
  ])).values()).sort((left, right) => left.name.localeCompare(right.name));
  const switchOrganization = (organizationId: number) => {
    if (organizationId === activeOrganizationId) return;
    const destination = companies.find((company) => company.organization_id === organizationId && !company.test_workspace)
      || companies.find((company) => company.organization_id === organizationId);
    if (destination) switchCompany(destination.id);
  };

  return (
    <CompanyContext.Provider
      value={{
        companies,
        organizations,
        activeCompany,
        activeCompanyId,
        activeOrganizationId,
        activeOrganizationName,
        canManageClients,
        canViewClientManagement,
        canSwitchCompany,
        loading,
        switchCompany,
        switchOrganization,
        refreshCompanies,
      }}
    >
      {children}
    </CompanyContext.Provider>
  );
}
