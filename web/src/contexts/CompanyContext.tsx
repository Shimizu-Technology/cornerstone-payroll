import { createContext, useContext, useState, useEffect, useCallback, type ReactNode } from 'react';
import { companiesApi, type CompanyListItem } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';

interface CompanyContextValue {
  companies: CompanyListItem[];
  activeCompany: CompanyListItem | null;
  activeCompanyId: number | null;
  isSuperAdmin: boolean;
  canSwitchCompany: boolean;
  loading: boolean;
  switchCompany: (companyId: number) => void;
  refreshCompanies: () => Promise<void>;
}

const CompanyContext = createContext<CompanyContextValue>({
  companies: [],
  activeCompany: null,
  activeCompanyId: null,
  isSuperAdmin: false,
  canSwitchCompany: false,
  loading: true,
  switchCompany: () => {},
  refreshCompanies: async () => {},
});

export function useCompany() {
  return useContext(CompanyContext);
}

export function CompanyProvider({ children }: { children: ReactNode }) {
  const { isAuthenticated, user } = useAuth();
  const [companies, setCompanies] = useState<CompanyListItem[]>([]);
  const [activeCompanyId, setActiveCompanyId] = useState<number | null>(
    companiesApi.getActiveCompanyId()
  );
  const [isSuperAdmin, setIsSuperAdmin] = useState(false);
  const [canSwitchCompany, setCanSwitchCompany] = useState(false);
  const [loading, setLoading] = useState(true);
  const [fetched, setFetched] = useState(false);

  const refreshCompanies = useCallback(async () => {
    try {
      const res = await companiesApi.list({ active: true });
      setCompanies(res.companies);
      setIsSuperAdmin(res.is_super_admin);
      setCanSwitchCompany(res.can_switch_company ?? res.is_super_admin);

      const storedId = companiesApi.getActiveCompanyId();
      if (storedId && res.companies.some(c => c.id === storedId)) {
        setActiveCompanyId(storedId);
        companiesApi.switchCompany(storedId);
      } else if (res.current_company_id) {
        setActiveCompanyId(res.current_company_id);
        companiesApi.switchCompany(res.current_company_id);
      }
      setFetched(true);
    } catch {
      // Will retry when auth becomes available
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (isAuthenticated && user && !fetched) {
      refreshCompanies();
    }
    if (!isAuthenticated) {
      setLoading(false);
    }
  }, [isAuthenticated, user, fetched, refreshCompanies]);

  const switchCompany = useCallback((companyId: number) => {
    setActiveCompanyId(companyId);
    companiesApi.switchCompany(companyId);
    window.location.href = '/';
  }, []);

  const activeCompany = companies.find(c => c.id === activeCompanyId) || null;

  return (
    <CompanyContext.Provider
      value={{
        companies,
        activeCompany,
        activeCompanyId,
        isSuperAdmin,
        canSwitchCompany,
        loading,
        switchCompany,
        refreshCompanies,
      }}
    >
      {children}
    </CompanyContext.Provider>
  );
}
