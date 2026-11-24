import { lazy, Suspense, useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import { ArrowLeft, MailWarning, Users } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { useSelectedCompanyCapability } from '@/hooks/useSelectedCompanyCapability';
import { canWriteCompany } from '@/lib/company-write-access';
import { employeesPath } from '@/lib/routes';
import { cn } from '@/lib/utils';
import { staffContactHygieneApi, type SharedEmailReportResponse } from '@/services/staffContactHygieneApi';
import { EmployeeContactDetails } from './EmployeeContactDetails';

const SharedInboxReportPanel = lazy(() =>
  import('@/components/employees/SharedInboxReportPanel').then((module) => ({ default: module.SharedInboxReportPanel })),
);

const DEV_COMPANY_ID = parseInt(import.meta.env.VITE_COMPANY_ID || '1', 10);

export function StaffEmployeeContactDetails() {
  const [searchParams, setSearchParams] = useSearchParams();
  const { user, isClient } = useAuth();
  const { activeCompanyId, activeCompany } = useCompany();
  const canManageClientConfiguration = useSelectedCompanyCapability('manage_client_configuration');
  const canViewSharedInboxReport = !isClient && canManageClientConfiguration;
  const companyId = activeCompanyId ?? user?.company_id ?? DEV_COMPANY_ID;
  const canEdit = canWriteCompany(activeCompany);

  const requestedTab = searchParams.get('tab');
  const activeTab: 'grid' | 'shared-emails' = (canViewSharedInboxReport && requestedTab === 'shared-emails') ? 'shared-emails' : 'grid';

  const [sharedReportSummary, setSharedReportSummary] = useState<SharedEmailReportResponse['summary'] | null>(null);
  const [needsContactCount, setNeedsContactCount] = useState(0);
  const [gridRefreshKey, setGridRefreshKey] = useState(0);

  useEffect(() => {
    if (!canViewSharedInboxReport) {
      setSharedReportSummary(null);
      return;
    }
    let cancelled = false;
    void staffContactHygieneApi.sharedEmails().then(
      (report) => {
        if (!cancelled) setSharedReportSummary(report.summary);
      },
      () => {
        // Non-blocking badge summary; full panel shows errors if opened.
      },
    );
    return () => { cancelled = true; };
  }, [canViewSharedInboxReport, companyId]);

  const setTab = (tab: 'grid' | 'shared-emails') => {
    const next = new URLSearchParams(searchParams);
    if (tab === 'grid') next.delete('tab');
    else next.set('tab', tab);
    setSearchParams(next);
  };

  return (
    <div>
      <Header
        title="Contact Details"
        description="Set and update every employee's own email, mobile number, and mailing address in one place."
        actions={
          <Link
            to={employeesPath(companyId)}
            className="inline-flex min-h-11 items-center justify-center gap-2 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-700 transition hover:border-primary-300 hover:bg-primary-50/60 hover:text-primary-800 sm:min-h-10"
          >
            <ArrowLeft className="h-4 w-4" aria-hidden="true" />
            All employees
          </Link>
        }
      />

      <div className="space-y-6 p-4 sm:p-6 lg:p-8">
        {canViewSharedInboxReport && (
          <div role="tablist" aria-label="Contact details sections" className="flex flex-wrap gap-2 border-b border-neutral-200 pb-3">
            <button
              type="button"
              role="tab"
              aria-selected={activeTab === 'grid'}
              onClick={() => setTab('grid')}
              className={cn(
                'inline-flex min-h-10 items-center gap-2 rounded-full px-4 text-sm font-semibold transition',
                activeTab === 'grid'
                  ? 'bg-primary-700 text-white shadow-sm'
                  : 'border border-neutral-200 bg-white text-neutral-700 hover:bg-neutral-50',
              )}
            >
              <Users className="h-4 w-4" aria-hidden="true" />
              Contact details
              {needsContactCount > 0 && (
                <span className={cn(
                  'rounded-full px-2 py-0.5 text-xs font-bold tabular-nums',
                  activeTab === 'grid' ? 'bg-white/20 text-white' : 'bg-warning-100 text-warning-900',
                )}>
                  {needsContactCount} need details
                </span>
              )}
            </button>

            <button
              type="button"
              role="tab"
              aria-selected={activeTab === 'shared-emails'}
              onClick={() => setTab('shared-emails')}
              className={cn(
                'inline-flex min-h-10 items-center gap-2 rounded-full px-4 text-sm font-semibold transition',
                activeTab === 'shared-emails'
                  ? 'bg-primary-700 text-white shadow-sm'
                  : 'border border-neutral-200 bg-white text-neutral-700 hover:bg-neutral-50',
              )}
            >
              <MailWarning className="h-4 w-4" aria-hidden="true" />
              Shared & placeholder emails
              {sharedReportSummary && sharedReportSummary.total_employee_records > 0 && (
                <span className={cn(
                  'rounded-full px-2 py-0.5 text-xs font-bold tabular-nums',
                  activeTab === 'shared-emails' ? 'bg-white/20 text-white' : 'bg-danger-100 text-danger-800',
                )}>
                  {sharedReportSummary.total_employee_records}
                </span>
              )}
            </button>
          </div>
        )}

        {activeTab === 'shared-emails' && canViewSharedInboxReport ? (
          <Suspense
            fallback={
              <div className="flex items-center justify-center py-12">
                <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-primary-600" />
              </div>
            }
          >
            <SharedInboxReportPanel
              activeCompanyId={companyId}
              readOnly={!canEdit}
              onReportLoaded={(report) => setSharedReportSummary(report.summary)}
              onCleared={(clearedCompanyId) => {
                if (clearedCompanyId === companyId) {
                  setGridRefreshKey((count) => count + 1);
                }
              }}
            />
          </Suspense>
        ) : (
          <EmployeeContactDetails
            embedded
            refreshKey={gridRefreshKey}
            onNeedsContactCountChange={setNeedsContactCount}
          />
        )}
      </div>
    </div>
  );
}
