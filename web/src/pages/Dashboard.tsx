import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
import { useEffect, useState, type ReactElement } from 'react';
import { Link, useNavigate } from 'react-router';
import { Card, CardContent, CardHeader } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Header } from '@/components/layout/Header';
import { formatCurrency, formatDate, payPeriodStatusConfig } from '@/lib/utils';
import { reportsApi, type DashboardResponse } from '@/services/api';
import type { PayPeriodStatus } from '@/types';
import { useCompany } from '@/contexts/CompanyContext';
import { canWriteCompany } from '@/lib/company-write-access';
import { employeesPath, importedPayRunPath, newEmployeePath, payRunPath, payRunsPath } from '@/lib/routes';

interface DashboardPayload { companyId: number | null; stats: DashboardResponse['stats'] }
function StatCard({ title, value, subtitle, loading }: { title: string; value: string | number; subtitle?: string; loading: boolean }): ReactElement {
  return <Card><CardContent className="pt-5">
    <p className="text-xs font-semibold text-neutral-600">{title}</p>
    <p className="mt-2 text-2xl font-bold tabular-nums text-neutral-950">{loading ? '—' : value}</p>
    {subtitle && <p className="mt-1 text-xs text-neutral-600">{subtitle}</p>}
  </CardContent></Card>;
}

export function Dashboard(): ReactElement {
  const navigate = useNavigate();
  const { activeCompanyId, activeCompany } = useCompany();
  const readOnlyWorkspace = !canWriteCompany(activeCompany);
  const [loading, setLoading] = useState(true);
  const [dashboardPayload, setDashboardPayload] = useState<DashboardPayload | null>(null);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const stats = dashboardPayload?.companyId === activeCompanyId ? dashboardPayload.stats : null;

  useEffect((): (() => void) => {
    let cancelled = false;
    const requestedCompanyId = activeCompanyId;

    const loadDashboard = async (): Promise<void> => {
      setLoading(true);
      setError(null);
      setDashboardPayload(null);
      try {
        const response = await reportsApi.dashboard();
        if (!cancelled) {
          setDashboardPayload({ companyId: requestedCompanyId, stats: response.stats });
        }
      } catch (err) {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : 'Failed to load dashboard');
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    };

    void loadDashboard();
    return (): void => { cancelled = true; };
  }, [activeCompanyId, setError]);

  const current = stats?.current_pay_period;
  const status = current ? payPeriodStatusConfig[current.status as PayPeriodStatus] : null;
  const payRunsHref = activeCompanyId ? payRunsPath(activeCompanyId) : '/pay-periods';
  const employeeHref = activeCompanyId ? newEmployeePath(activeCompanyId) : '/employees/new';
  const runHref = (id: number): string => activeCompanyId ? payRunPath(activeCompanyId, id, 'work') : `/pay-periods/${id}`;
  const recentHref = (row: DashboardResponse['stats']['recent_payrolls'][number]): string => row.record_type === 'imported' && activeCompanyId
    ? importedPayRunPath(activeCompanyId, row.id) : activeCompanyId ? payRunPath(activeCompanyId, row.id, 'overview') : runHref(row.id);
  const lastRegular = stats?.last_regular_payroll;
  const lastAdjustment = stats?.last_adjustment_payroll;
  const importedCount = stats?.ytd_totals?.imported_payroll_count ?? 0;

  return <div>
    <Header title="Home" description={activeCompany?.name || 'Payroll'} actions={<Button onClick={() => navigate(payRunsHref)}>{readOnlyWorkspace ? 'Browse Pay Periods' : 'Manage pay periods'}</Button>} />
    <div className="space-y-6 p-4 sm:p-6 lg:p-8">
      {error && <ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error} />}
      <Card>
        <CardHeader><div className="flex flex-wrap items-center justify-between gap-2">
          <h2 className="font-display text-lg font-bold text-neutral-950">Current pay period</h2>
          {current && <Badge variant={current.status === 'approved' ? 'info' : current.status === 'calculated' ? 'warning' : 'default'}>{status?.label || current.status}</Badge>}
        </div></CardHeader>
        <CardContent>
          {loading ? <p role="status" className="text-sm text-neutral-600">Loading current pay period…</p> : current ? <div className="space-y-4">
            <div><h3 className="font-display text-xl font-bold text-neutral-950">{current.period_description}</h3>
              <p className="mt-1 text-sm text-neutral-600">{current.run_purpose === 'regular' ? 'Regular payroll' : current.run_purpose?.replaceAll('_', ' ') || 'Payroll'} · Pay date {formatDate(current.pay_date)}</p>
            </div>
            {current.status !== 'draft' && <dl className="grid grid-cols-2 gap-4">
              <div><dt className="text-xs text-neutral-600">Gross pay</dt><dd className="text-xl font-semibold tabular-nums text-neutral-950">{formatCurrency(current.total_gross)}</dd></div>
              <div><dt className="text-xs text-neutral-600">Net pay</dt><dd className="text-xl font-semibold tabular-nums text-neutral-950">{formatCurrency(current.total_net)}</dd></div>
            </dl>}
            {current.blocker && <p role="status" className="rounded-lg border border-warning-200 bg-warning-50 p-3 text-sm text-warning-900">{current.blocker}</p>}
            {readOnlyWorkspace ? <p className="text-sm text-neutral-600">Review preserved payroll records</p> : current.next_action && <p className="text-sm font-semibold text-neutral-700">Next: {current.next_action}</p>}
            <Button className="w-full sm:w-auto" onClick={() => navigate(runHref(current.id))}>Continue</Button>
          </div> : <div>
            <p className="text-sm text-neutral-600">{readOnlyWorkspace ? 'Review preserved payroll records' : 'No current pay period. Create the next period to add hours and pay.'}</p>
            <Button className="mt-4 w-full sm:w-auto" onClick={() => navigate(payRunsHref)}>{readOnlyWorkspace ? 'Browse pay periods' : 'Create the next pay period'}</Button>
          </div>}
        </CardContent>
      </Card>

      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard title="Active employees" value={stats?.active_employees ?? 0} subtitle={`${stats?.total_employees ?? 0} total records`} loading={loading} />
        <StatCard title="Last regular payroll" value={lastRegular ? formatCurrency(lastRegular.total_net) : '—'} subtitle={lastRegular ? `Regular · Pay date ${formatDate(lastRegular.pay_date)}` : 'No committed regular payroll'} loading={loading} />
        <StatCard title="YTD net pay" value={formatCurrency(stats?.ytd_totals?.net_pay ?? 0)} subtitle={`${stats?.ytd_totals?.payroll_count ?? 0} pay periods${importedCount ? ` · ${importedCount} imported` : ''}`} loading={loading} />
        <StatCard title="YTD gross pay" value={formatCurrency(stats?.ytd_totals?.gross_pay ?? 0)} loading={loading} />
      </div>
      {lastAdjustment && <Card><CardContent className="pt-5">
        <Link className="block rounded-lg text-primary-800 underline focus-visible:outline-2 focus-visible:outline-offset-4" to={recentHref(lastAdjustment)}>
          <span className="font-semibold">Last adjustment payroll</span> · {lastAdjustment.run_purpose?.replaceAll('_', ' ')} · Pay date {formatDate(lastAdjustment.pay_date)}
        </Link>
        <p className="mt-2 text-lg font-semibold tabular-nums text-neutral-950">{formatCurrency(lastAdjustment.total_net)}</p>
      </CardContent></Card>}

      {!!stats?.recent_payrolls?.length && <Card><CardHeader><h2 className="font-display text-lg font-bold text-neutral-950">Recent payrolls</h2></CardHeader><CardContent className="space-y-2">
        {stats.recent_payrolls.map(row => <Link key={row.key ?? row.id} to={recentHref(row)} aria-label={`Open payroll ${row.period_description}`} className="flex flex-col gap-2 rounded-lg p-3 hover:bg-primary-50 focus-visible:outline-2 sm:flex-row sm:items-center sm:justify-between">
          <div><p className="font-semibold text-neutral-950">{row.period_description}</p><p className="text-sm text-neutral-600">{row.run_purpose?.replaceAll('_', ' ') || 'Regular'} · Pay date {formatDate(row.pay_date)} · {row.employee_count} employees</p>
            {row.record_type === 'imported' && <Badge variant="warning">QuickBooks import · locked</Badge>}</div>
          <p className="font-semibold tabular-nums text-neutral-950">{formatCurrency(row.total_net)}</p>
        </Link>)}
      </CardContent></Card>}

      <nav aria-label="Payroll shortcuts" className="flex flex-wrap gap-4 text-sm font-semibold text-primary-800">
        <Link className="rounded px-1 py-2 underline" to={readOnlyWorkspace && activeCompanyId ? employeesPath(activeCompanyId) : employeeHref}>{readOnlyWorkspace ? 'Browse employees' : 'Add employee'}</Link>
        <Link className="rounded px-1 py-2 underline" to={payRunsHref}>{readOnlyWorkspace ? 'Browse pay periods' : 'Run payroll'}</Link>
        <Link className="rounded px-1 py-2 underline" to="/reports">Open reports</Link>
      </nav>
      {stats?.ytd_totals && stats.ytd_totals.gross_pay > 0 && <Card><CardHeader><h2 className="font-display text-lg font-bold text-neutral-950">{stats.ytd_totals.year} year-to-date summary</h2></CardHeader><CardContent>
        {importedCount > 0 && <p className="mb-4 rounded-lg border border-warning-200 bg-warning-50 p-3 text-sm text-warning-900">These totals include {importedCount} locked QuickBooks pay periods alongside payroll run in Cornerstone.</p>}
        <dl className="grid grid-cols-2 gap-4 md:grid-cols-4">{[
          ['Gross pay', stats.ytd_totals.gross_pay], ['Total withholding tax', stats.ytd_totals.withholding_tax], ['Social Security', stats.ytd_totals.social_security_tax], ['Medicare', stats.ytd_totals.medicare_tax],
        ].map(([label,value]) => <div key={label}><dt className="text-xs text-neutral-600">{label}</dt><dd className="text-lg font-semibold tabular-nums text-neutral-950">{formatCurrency(Number(value))}</dd></div>)}</dl>
      </CardContent></Card>}
    </div>
  </div>;
}
