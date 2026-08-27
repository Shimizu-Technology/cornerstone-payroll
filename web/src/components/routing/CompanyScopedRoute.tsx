import { useEffect, type ReactElement } from 'react';
import { AlertTriangle, Building2 } from 'lucide-react';
import { Link, Outlet, useParams } from 'react-router';
import { WorkspaceLoader } from '@/components/records/WorkspaceLoader';
import { useCompany } from '@/contexts/CompanyContext';
import { employeesPath, payRunsPath } from '@/lib/routes';

function ScopeLoader(): ReactElement {
  return <WorkspaceLoader label="Opening client workspace" minHeightClassName="min-h-[360px]" />;
}

export function CompanyScopedRoute(): ReactElement {
  const { companyId: companyIdParam } = useParams<{ companyId: string }>();
  const { companies, activeCompanyId, loading, switchCompany } = useCompany();
  const companyId = Number(companyIdParam);
  const company = companies.find((candidate) => candidate.id === companyId);

  useEffect(() => {
    if (loading || !company || activeCompanyId === companyId) return;
    switchCompany(companyId);
  }, [activeCompanyId, company, companyId, loading, switchCompany]);

  if (loading) return <ScopeLoader />;

  if (!Number.isInteger(companyId) || companyId < 1 || !company) {
    const fallbackCompanyId = activeCompanyId || companies[0]?.id;
    return (
      <div className="p-4 sm:p-6 lg:p-8">
        <section className="mx-auto max-w-2xl rounded-[1.35rem] border border-amber-200 bg-amber-50 p-6 shadow-sm">
          <div className="flex items-start gap-4">
            <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl bg-amber-100 text-amber-800">
              <AlertTriangle className="h-5 w-5" />
            </span>
            <div>
              <p className="text-xs font-bold uppercase tracking-[0.14em] text-amber-800">Client unavailable</p>
              <h1 className="mt-2 font-display text-2xl font-extrabold tracking-tight text-neutral-950">
                This client workspace could not be opened
              </h1>
              <p className="mt-2 text-sm leading-6 text-neutral-700">
                The link may be outdated, or your account may not have access to that client. No payroll record was loaded.
              </p>
              {fallbackCompanyId && (
                <div className="mt-5 flex flex-wrap gap-3">
                  <Link
                    to={payRunsPath(fallbackCompanyId)}
                    className="inline-flex min-h-11 items-center gap-2 rounded-full bg-primary-700 px-4 py-2 text-sm font-semibold text-white transition hover:bg-primary-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2"
                  >
                    <Building2 className="h-4 w-4" />
                    Open active client pay runs
                  </Link>
                  <Link
                    to={employeesPath(fallbackCompanyId)}
                    className="inline-flex min-h-11 items-center rounded-full border border-neutral-300 bg-white px-4 py-2 text-sm font-semibold text-neutral-700 transition hover:border-primary-300 hover:text-primary-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-2"
                  >
                    Open employees
                  </Link>
                </div>
              )}
            </div>
          </div>
        </section>
      </div>
    );
  }

  if (activeCompanyId !== companyId) return <ScopeLoader />;

  return <Outlet />;
}
