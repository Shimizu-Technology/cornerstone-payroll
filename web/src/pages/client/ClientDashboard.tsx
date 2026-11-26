import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
import { useEffect, useState, type ReactElement } from 'react';
import { Link, useNavigate } from 'react-router';
import { CalendarDays, FileBarChart2, FolderOpen, Users } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { PayrollFilesEntry } from '@/components/payroll-submissions/PayrollFilesEntry';
import { clientDocumentsApi, clientPayPeriodsApi, clientReportsApi, type ClientPayrollHistoryResponse } from '@/services/api';
import { formatCurrency } from '@/lib/utils';
import { formatDate, formatDateRange } from '@/lib/display-date';
import { useCompany } from '@/contexts/CompanyContext';
import { clientPayrollStatus, clientPayRunStatus } from '@/lib/clientPayrollStatus';
import { employeesPath, importedPayRunPath, newEmployeePath, payRunPath, payRunsPath } from '@/lib/routes';

import { supportToken } from '@/support/grant';

type ClientDashboardStats = Awaited<ReturnType<typeof clientReportsApi.dashboard>>['stats'];

interface ClientDashboardPayload {
  companyId: number | null;
  stats: ClientDashboardStats;
  documentCount: number;
}

type PayrollResult = {
  companyId: number | null;
  attempt: number;
  payroll: ClientPayrollHistoryResponse | null;
};

function isPayrollDate(value: unknown): boolean {
  return typeof value === 'string' && Number.isFinite(Date.parse(value));
}

function isPayrollId(value: unknown): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
}

function hasRenderablePayroll(payroll: ClientPayrollHistoryResponse): boolean {
  if (!Array.isArray(payroll?.pay_periods)) return false;
  if (!payroll.pay_periods.every(period => period && (
    period.can_decide_payroll_review !== true || (
      isPayrollId(period.id) && isPayrollDate(period.start_date) &&
      isPayrollDate(period.end_date) && isPayrollDate(period.pay_date) &&
      typeof (period.client_review_status ?? period.status) === 'string'
    )
  ))) return false;

  const open = payroll.open_period;
  return open == null || (
    isPayrollDate(open.start_date) && isPayrollDate(open.end_date) &&
    (open.pay_date == null || isPayrollDate(open.pay_date)) &&
    typeof open.client_payroll_status === 'string' &&
    (open.review_pay_period_id == null
      ? typeof open.ref === 'string' && /^(?:\d+|\d{4}-\d{2}-\d{2}_\d{4}-\d{2}-\d{2})$/.test(open.ref)
      : isPayrollId(open.review_pay_period_id))
  );
}

export function ClientDashboard(): ReactElement {
  const navigate = useNavigate();
  const { activeCompanyId } = useCompany();
  const [loading, setLoading] = useState(true);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [dashboardPayload, setDashboardPayload] = useState<ClientDashboardPayload | null>(null);
  const stats = dashboardPayload?.companyId === activeCompanyId ? dashboardPayload.stats : null;
  const documentCount = dashboardPayload?.companyId === activeCompanyId ? dashboardPayload.documentCount : 0;
  const [payrollAttempt, setPayrollAttempt] = useState(0);
  const [payrollResult, setPayrollResult] = useState<PayrollResult | null>(null);
  const currentPayroll = payrollResult?.companyId === activeCompanyId && payrollResult.attempt === payrollAttempt
    ? payrollResult
    : null;
  const payroll = currentPayroll?.payroll;
  const attention = payroll?.pay_periods.filter(period => period.can_decide_payroll_review === true) ?? [];
  const open = payroll?.open_period;
  const openReview = payroll?.pay_periods.find(period => period.id === open?.review_pay_period_id);
  const employeeListHref = activeCompanyId ? employeesPath(activeCompanyId) : '/employees';
  const newEmployeeHref = activeCompanyId ? newEmployeePath(activeCompanyId) : '/employees/new';
  const payRunListHref = activeCompanyId ? payRunsPath(activeCompanyId) : '/pay-periods';
  const payRunHref = (payRunId: number, imported = false): string => activeCompanyId
    ? imported ? importedPayRunPath(activeCompanyId, payRunId) : payRunPath(activeCompanyId, payRunId)
    : `/pay-periods/${payRunId}`;

  useEffect((): (() => void) => {
    let cancelled = false;
    const requestedCompanyId = activeCompanyId;

    const load = async (): Promise<void> => {
      setLoading(true);
      setError(null);
      setDashboardPayload(null);
      try {
        const [dashboard, documents] = await Promise.all([
          clientReportsApi.dashboard(),
          clientDocumentsApi.list({ per_page: 1 }),
        ]);
        if (cancelled) return;
        setDashboardPayload({
          companyId: requestedCompanyId,
          stats: dashboard.stats,
          documentCount: documents.meta.total_count,
        });
      } catch (err) {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : 'Failed to load portal dashboard');
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    };

    void load();
    return (): void => { cancelled = true; };
  }, [activeCompanyId, setError]);

  useEffect((): (() => void) => {
    let cancelled = false;

    const loadPayroll = async (): Promise<void> => {
      let payroll: ClientPayrollHistoryResponse | null = null;
      try {
        const response = await clientPayPeriodsApi.list({ status: 'approved', per_page: 100 }, activeCompanyId ?? undefined);
        if (hasRenderablePayroll(response)) payroll = response;
      } catch {
        // Keep approval failures local to the attention card.
      }

      if (!cancelled) setPayrollResult({ companyId: activeCompanyId, attempt: payrollAttempt, payroll });
    };

    void loadPayroll();
    return (): void => { cancelled = true; };
  }, [activeCompanyId, payrollAttempt]);

  return (
    <div>
      <Header
        title="Dashboard"
        description="Manage employees, review payroll, and securely share documents."
        mobileSticky={false}
        actions={!supportToken && (
          <div className="hidden sm:block">
            <Button onClick={() => navigate(newEmployeeHref)}>Add employee</Button>
          </div>
        )}
      />

      <div className="space-y-6 p-4 sm:space-y-8 sm:p-6 lg:p-8">
        {error && (
          <ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error} />
        )}

        <Card>
          <CardHeader>
            <h2 className="font-display text-lg font-bold tracking-tight text-neutral-950">Needs your attention</h2>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            {!currentPayroll && <p role="status">Checking for payroll approvals…</p>}
            {currentPayroll && !payroll && (
              <div>
                <p role="alert">Couldn't check for payroll approvals.</p>
                <Button variant="outline" size="sm" className="mt-2 min-h-11 sm:min-h-11" onClick={() => setPayrollAttempt(attempt => attempt + 1)}>
                  Try again
                </Button>
              </div>
            )}
            {payroll && (
              attention.length ? (
                <ul className="space-y-3">
                  {attention.map(period => (
                    <li key={period.id}>
                      <p className="font-medium">Payroll for {formatDateRange(period.start_date, period.end_date)} is ready for your approval.</p>
                      <p>Pay date {formatDate(period.pay_date)} · {clientPayRunStatus(period)}</p>
                      <Link className="inline-flex min-h-11 items-center font-semibold text-primary-800 underline" to={payRunHref(period.id)}>
                        Open payroll preview
                      </Link>
                    </li>
                  ))}
                </ul>
              ) : <p>No payroll needs your approval right now.</p>
            )}
            {open && openReview?.can_decide_payroll_review !== true && (
              <div className="border-t border-neutral-200 pt-3">
                <p className="font-medium">Next payroll · {formatDateRange(open.start_date, open.end_date)}</p>
                <p>{open.pay_date ? `Pay date ${formatDate(open.pay_date)}` : 'Pay date to be set'} · {clientPayrollStatus(open.client_payroll_status)}</p>
                <Link className="inline-flex min-h-11 items-center font-semibold text-primary-800 underline" to={open.review_pay_period_id ? payRunHref(open.review_pay_period_id) : `/payroll-files/${encodeURIComponent(open.ref)}`}>
                  {open.review_pay_period_id ? 'Open payroll preview' : 'Open pay period files'}
                </Link>
              </div>
            )}
          </CardContent>
        </Card>

        <PayrollFilesEntry />

        {!supportToken && (
          <div className="sm:hidden">
            <Button className="w-full" onClick={() => navigate(newEmployeeHref)}>Add employee</Button>
          </div>
        )}

        <div className="grid grid-cols-2 gap-3 sm:gap-6 xl:grid-cols-4">
          <PortalStat
            label="Active employees"
            value={loading ? '—' : String(stats?.active_employees ?? 0)}
            sublabel={loading ? undefined : `${stats?.total_employees ?? 0} total records`}
            icon={<Users className="h-5 w-5" />}
          />
          <PortalStat
            label="YTD net pay"
            value={loading ? '—' : formatCurrency(stats?.ytd_totals?.net_pay ?? 0)}
            sublabel={loading ? undefined : `${stats?.ytd_totals?.payroll_count ?? 0} pay periods`}
            icon={<CalendarDays className="h-5 w-5" />}
          />
          <PortalStat
            label="Uploaded documents"
            value={loading ? '—' : String(documentCount)}
            sublabel="Stored for payroll review"
            icon={<FileBarChart2 className="h-5 w-5" />}
          />
          <PortalStat
            label="Recent payrolls"
            value={loading ? '—' : String(stats?.recent_payrolls?.length ?? 0)}
            sublabel="Finalized and imported payrolls"
            icon={<FolderOpen className="h-5 w-5" />}
          />
        </div>

        <div className="grid gap-4 sm:gap-6 md:grid-cols-2 xl:grid-cols-4">
          <QuickLink
            title="Employees"
            description="Add and update employee records"
            icon={<Users className="h-5 w-5" />}
            onClick={() => navigate(employeeListHref)}
          />
          <QuickLink
            title="Pay periods"
            description="Review payroll runs and employee pay"
            icon={<CalendarDays className="h-5 w-5" />}
            onClick={() => navigate(payRunListHref)}
          />
          <QuickLink
            title="Documents"
            description="Store company and employee files"
            icon={<FolderOpen className="h-5 w-5" />}
            onClick={() => navigate('/documents')}
          />
        </div>

        {stats?.recent_payrolls?.length ? (
          <Card>
            <CardHeader>
              <CardTitle>Recent payrolls</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              {stats.recent_payrolls.map((payroll) => (
                <button
                  key={payroll.key ?? payroll.id}
                  type="button"
                  onClick={() => navigate(payRunHref(payroll.id, payroll.record_type === 'imported'))}
                  className="flex w-full flex-wrap items-start justify-between gap-2 rounded-xl border border-transparent px-3 py-3 text-left transition-all hover:border-primary-200 hover:bg-primary-50/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500"
                >
                  <div className="min-w-0">
                    <p className="font-medium text-neutral-900">{formatDateRange(payroll.start_date, payroll.end_date) || payroll.period_description}</p>
                    <p className="text-sm text-neutral-500">
                      {formatDate(payroll.pay_date)} · {payroll.employee_count} employees · {clientPayrollStatus(payroll.record_type === 'imported' ? 'locked' : 'committed')}
                    </p>
                  </div>
                  <p className="font-semibold text-success-600">{formatCurrency(payroll.total_net)}</p>
                </button>
              ))}
            </CardContent>
          </Card>
        ) : null}
      </div>
    </div>
  );
}

interface PortalStatProps {
  label: string;
  value: string;
  sublabel?: string;
  icon: React.ReactNode;
}

function PortalStat({
  label,
  value,
  sublabel,
  icon,
}: PortalStatProps): ReactElement {
  return (
    <Card>
      <CardContent className="p-4 sm:p-6">
        <div className="flex items-start justify-between gap-2">
          <p className="text-xs font-medium text-neutral-500 sm:text-sm">{label}</p>
          <div className="shrink-0 rounded-xl bg-primary-50 p-2 text-primary-700">{icon}</div>
        </div>
        <p className="mt-2 break-words text-xl font-semibold tracking-tight text-neutral-900 tabular-nums sm:mt-3 sm:text-3xl">{value}</p>
        {sublabel && <p className="mt-1 text-xs text-neutral-500 sm:mt-1.5 sm:text-sm">{sublabel}</p>}
      </CardContent>
    </Card>
  );
}

interface QuickLinkProps {
  title: string;
  description: string;
  icon: React.ReactNode;
  onClick: () => void;
}

function QuickLink({
  title,
  description,
  icon,
  onClick,
}: QuickLinkProps): ReactElement {
  return (
    <Card className="hover:-translate-y-0.5 hover:border-primary-300">
      <CardContent className="pt-6">
        <button type="button" onClick={onClick} className="w-full text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500">
        <div className="flex items-center gap-4">
          <div className="rounded-xl bg-primary-100 p-3 text-primary-700">{icon}</div>
          <div>
            <p className="font-medium text-neutral-900">{title}</p>
            <p className="text-sm text-neutral-500">{description}</p>
          </div>
        </div>
        </button>
      </CardContent>
    </Card>
  );
}
