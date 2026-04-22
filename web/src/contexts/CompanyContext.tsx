/* eslint-disable react-refresh/only-export-components */
import { createContext, useContext, useState, useEffect, useCallback, useRef, type ReactNode } from 'react';
import { companiesApi, type CompanyListItem } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';

interface CompanyContextValue {
  companies: CompanyListItem[];
  activeCompany: CompanyListItem | null;
  activeCompanyId: number | null;
  canManageClients: boolean;
  canSwitchCompany: boolean;
  loading: boolean;
  switchCompany: (companyId: number) => void;
  refreshCompanies: () => Promise<void>;
}

const CompanyContext = createContext<CompanyContextValue>({
  companies: [],
  activeCompany: null,
  activeCompanyId: null,
  canManageClients: false,
  canSwitchCompany: false,
  loading: true,
  switchCompany: () => {},
  refreshCompanies: async () => {},
});

export function useCompany() {
  return useContext(CompanyContext);
}

function applyCompanyResponse(
  res: { companies: CompanyListItem[]; can_manage_clients: boolean; can_switch_company: boolean; current_company_id: number },
  setCompanies: (c: CompanyListItem[]) => void,
  setCanManageClients: (v: boolean) => void,
  setCanSwitchCompany: (v: boolean) => void,
  setActiveCompanyId: (id: number | null) => void,
  setFetched: (v: boolean) => void,
) {
  setCompanies(res.companies);
  setCanManageClients(res.can_manage_clients);
  setCanSwitchCompany(res.can_switch_company ?? res.can_manage_clients);

  const storedId = companiesApi.getActiveCompanyId();
  if (storedId && res.companies.some(c => c.id === storedId)) {
    setActiveCompanyId(storedId);
    companiesApi.switchCompany(storedId);
  } else if (res.current_company_id) {
    setActiveCompanyId(res.current_company_id);
    companiesApi.switchCompany(res.current_company_id);
  }
  setFetched(true);
}

export function CompanyProvider({ children }: { children: ReactNode }) {
  const { isAuthenticated, user } = useAuth();
  const userId = user?.id ?? null;
  const [companies, setCompanies] = useState<CompanyListItem[]>([]);
  const [activeCompanyId, setActiveCompanyId] = useState<number | null>(
    companiesApi.getActiveCompanyId()
  );
  const [canManageClients, setCanManageClients] = useState(false);
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
    setCanSwitchCompany(false);
    setFetched(false);
    setLoading(false);
  }, []);

  const refreshCompanies = useCallback(async () => {
    try {
      const res = await companiesApi.list();
      if (!mountedRef.current) return;
      applyCompanyResponse(res, setCompanies, setCanManageClients, setCanSwitchCompany, setActiveCompanyId, setFetched);
    } catch {
      // Retry once after a short delay (handles race with auth/server startup)
      setTimeout(async () => {
        try {
          const res = await companiesApi.list();
          if (!mountedRef.current) return;
          applyCompanyResponse(res, setCompanies, setCanManageClients, setCanSwitchCompany, setActiveCompanyId, setFetched);
        } catch { /* give up */ }
        if (mountedRef.current) setLoading(false);
      }, 1500);
      return;
    }
    setLoading(false);
  }, []);

  useEffect(() => {
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
  }, [isAuthenticated, userId, resetCompanyState]);

  useEffect(() => {
    if (!isAuthenticated || userId === null || fetched) return;

    const fetchTimer = window.setTimeout(() => {
      void refreshCompanies();
    }, 0);

    return () => window.clearTimeout(fetchTimer);
  }, [isAuthenticated, userId, fetched, refreshCompanies]);

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
        canManageClients,
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
