import { useEffect, useState, type ReactElement } from 'react';
import { useNavigate } from 'react-router';
import { ArrowRight, Banknote, CalendarCheck2, CheckCircle2, ClipboardCheck, FileBarChart2, Landmark, UserPlus2, Users, Wallet } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Header } from '@/components/layout/Header';
import { formatCurrency, payPeriodStatusConfig } from '@/lib/utils';
import { reportsApi, type DashboardResponse } from '@/services/api';
import type { PayPeriodStatus } from '@/types';
import { useCompany } from '@/contexts/CompanyContext';
import { newEmployeePath, payRunPath, payRunsPath } from '@/lib/routes';

interface StatCardProps {
  title: string;
  value: string | number;
  subtitle?: string;
  loading?: boolean;
  icon: React.ReactNode;
}

interface DashboardPayload {
  companyId: number | null;
  stats: DashboardResponse['stats'];
}

function StatCard({
  title,
  value,
  subtitle,
  loading,
  icon,
}: StatCardProps): ReactElement {
  return (
    <Card className="group overflow-hidden hover:-translate-y-0.5 hover:border-primary-200/80">
      <CardContent className="pt-6">
        <div className="flex items-start justify-between gap-4">
          <p className="text-sm font-semibold text-neutral-500">{title}</p>
          <div className="rounded-2xl bg-primary-50 p-2.5 text-primary-700 ring-1 ring-primary-100 transition-colors group-hover:bg-primary-100">{icon}</div>
        </div>
        {loading ? (
          <div className="mt-4 h-9 animate-pulse rounded-xl bg-neutral-100" />
        ) : (
          <p className="mt-4 font-display text-3xl font-extrabold tracking-tight text-neutral-950">{value}</p>
        )}
        {subtitle && <p className="mt-1.5 text-sm leading-5 text-neutral-500">{subtitle}</p>}
      </CardContent>
    </Card>
  );
}

export function Dashboard(): ReactElement {
  const navigate = useNavigate();
  const { activeCompanyId } = useCompany();
  const [loading, setLoading] = useState(true);
  const [dashboardPayload, setDashboardPayload] = useState<DashboardPayload | null>(null);
  const [error, setError] = useState<string | null>(null);
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
  }, [activeCompanyId]);

  const currentPayPeriod = stats?.current_pay_period;
  const statusConfig = currentPayPeriod ? payPeriodStatusConfig[currentPayPeriod.status as PayPeriodStatus] : null;
  const payDateLabel = currentPayPeriod
    ? new Date(currentPayPeriod.pay_date).toLocaleDateString('en-US', {
        weekday: 'long',
        year: 'numeric',
        month: 'long',
        day: 'numeric',
      })
    : null;
  const payPeriodSteps = ['draft', 'calculated', 'approved', 'committed'];
  const activeStepIndex = currentPayPeriod ? payPeriodSteps.indexOf(currentPayPeriod.status) : -1;
  const payRunsHref = activeCompanyId ? payRunsPath(activeCompanyId) : '/pay-periods';
  const newEmployeeHref = activeCompanyId ? newEmployeePath(activeCompanyId) : '/employees/new';
  const payRunHref = (payRunId: number, tab: 'overview' | 'work' = 'overview'): string => (
    activeCompanyId ? payRunPath(activeCompanyId, payRunId, tab) : `/pay-periods/${payRunId}`
  );

  return (
    <div>
      <Header
        title="Home"
        description="Your payroll command center"
        actions={<Button onClick={() => navigate(payRunsHref)}>Manage Pay Periods</Button>}
      />

      <div className="p-4 sm:p-6 lg:p-8">
        {error && (
          <div className="mb-6 rounded-2xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">
            {error}
          </div>
        )}

        <Card className="mb-8 overflow-hidden border-primary-200/80 bg-[linear-gradient(135deg,#ffffff_0%,#f4f8ff_52%,#fff8eb_100%)]">
          <CardContent className="relative p-0">
            <div className="absolute right-0 top-0 h-52 w-52 translate-x-1/3 -translate-y-1/3 rounded-full bg-primary-200/50 blur-3xl" />
            <div className="absolute bottom-0 right-24 h-40 w-40 translate-y-1/2 rounded-full bg-accent-200/45 blur-3xl" />
            <div className="relative grid gap-6 p-5 sm:p-6 lg:grid-cols-[minmax(0,1fr)_360px] lg:gap-8 lg:p-8">
              <div>
                <p className="inline-flex rounded-full border border-primary-200 bg-white/70 px-3 py-1 text-xs font-bold uppercase tracking-[0.14em] text-primary-800">
                  Payroll command center
                </p>
                <h2 className="mt-4 max-w-3xl font-display text-2xl font-extrabold tracking-tight text-neutral-950 text-balance sm:text-3xl lg:text-4xl">
                  Run the pay cycle with fewer handoffs and a clearer audit trail.
                </h2>
                <p className="mt-3 max-w-2xl text-base leading-7 text-neutral-600">
                  Start with the current period, then move through checks, reports, and Guam compliance from one operational workspace.
                </p>
                <div className="mt-6 flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-center [&>button]:w-full sm:[&>button]:w-auto">
                  <Button onClick={() => navigate(currentPayPeriod ? payRunHref(currentPayPeriod.id, 'work') : payRunsHref)}>
                    {currentPayPeriod ? 'Continue pay cycle' : 'Create pay period'}
                    <ArrowRight className="ml-2 h-4 w-4" />
                  </Button>
                  <Button variant="secondary" onClick={() => navigate('/reports')}>Open reports</Button>
                  <Button variant="ghost" onClick={() => navigate(newEmployeeHref)}>Add employee</Button>
                </div>
              </div>

              <div className="rounded-[1.15rem] border border-white/80 bg-white/78 p-5 shadow-sm shadow-primary-100/60">
                <p className="text-xs font-bold uppercase tracking-[0.14em] text-neutral-500">Next best action</p>
                <div className="mt-4 flex items-start gap-3">
                  <div className="rounded-2xl bg-success-50 p-2.5 text-success-600 ring-1 ring-success-100">
                    <ClipboardCheck className="h-5 w-5" />
                  </div>
                  <div>
                    <p className="font-display text-lg font-bold text-neutral-950">
                      {currentPayPeriod ? statusConfig?.label ?? 'Review pay period' : 'Set up the next pay period'}
                    </p>
                    <p className="mt-1 text-sm leading-6 text-neutral-500">
                      {currentPayPeriod
                        ? `${currentPayPeriod.employee_count} employees, ${formatCurrency(currentPayPeriod.total_net)} net pay currently in view.`
                        : 'Create the period first, then add or import employee payroll items.'}
                    </p>
                  </div>
                </div>
              </div>
            </div>
          </CardContent>
        </Card>

        <div className="grid gap-6 md:grid-cols-2 xl:grid-cols-4">
          <StatCard
            title="Active Employees"
            value={stats?.active_employees ?? 0}
            subtitle={`${stats?.total_employees ?? 0} total records`}
            loading={loading}
            icon={<Users className="h-[18px] w-[18px]" />}
          />
          <StatCard
            title="Last Payroll"
            value={stats?.recent_payrolls?.[0] ? formatCurrency(stats.recent_payrolls[0].total_net) : '$0.00'}
            loading={loading}
            icon={<Wallet className="h-[18px] w-[18px]" />}
          />
          <StatCard
            title="YTD Payroll"
            value={stats?.ytd_totals ? formatCurrency(stats.ytd_totals.net_pay) : '$0.00'}
            subtitle={stats?.ytd_totals ? `${stats.ytd_totals.payroll_count} pay periods` : undefined}
            loading={loading}
            icon={<Banknote className="h-[18px] w-[18px]" />}
          />
          <StatCard
            title="YTD Gross"
            value={stats?.ytd_totals ? formatCurrency(stats.ytd_totals.gross_pay) : '$0.00'}
            loading={loading}
            icon={<FileBarChart2 className="h-[18px] w-[18px]" />}
          />
        </div>

        <Card className="mt-8 overflow-hidden">
          <CardHeader>
            <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <CardTitle>Current Pay Period</CardTitle>
                <p className="mt-1 text-sm text-neutral-500">A guided view of where this payroll stands.</p>
              </div>
              {currentPayPeriod && statusConfig && (
                <Badge
                  variant={
                    currentPayPeriod.status === 'committed'
                      ? 'success'
                      : currentPayPeriod.status === 'approved'
                        ? 'info'
                        : currentPayPeriod.status === 'calculated'
                          ? 'warning'
                          : 'default'
                  }
                >
                  {statusConfig.label}
                </Badge>
              )}
            </div>
          </CardHeader>
          <CardContent>
            {loading ? (
              <div className="h-32 animate-pulse rounded-2xl bg-neutral-100" />
            ) : currentPayPeriod ? (
              <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_300px]">
                <div>
                  <p className="font-display text-xl font-bold tracking-tight text-neutral-950">{currentPayPeriod.period_description}</p>
                  <p className="mt-1 text-sm text-neutral-500">Pay date: {payDateLabel}</p>

                  <div className="mt-6 grid gap-3 sm:grid-cols-4">
                    {payPeriodSteps.map((step, index) => {
                      const isDone = index <= activeStepIndex;
                      return (
                        <div key={step} className="flex items-center gap-2 rounded-2xl border border-neutral-200 bg-neutral-50/70 px-3 py-2">
                          <span className={`flex h-6 w-6 items-center justify-center rounded-full ${isDone ? 'bg-primary-700 text-white' : 'bg-white text-neutral-400 ring-1 ring-neutral-200'}`}>
                            {isDone ? <CheckCircle2 className="h-3.5 w-3.5" /> : <span className="h-1.5 w-1.5 rounded-full bg-current" />}
                          </span>
                          <span className={`text-xs font-bold uppercase tracking-[0.1em] ${isDone ? 'text-neutral-900' : 'text-neutral-400'}`}>{step}</span>
                        </div>
                      );
                    })}
                  </div>
                </div>

                <div className="rounded-2xl border border-neutral-200 bg-neutral-50/80 p-4">
                  <div className="grid grid-cols-2 gap-4 text-sm">
                    <div>
                      <p className="text-neutral-500">Employees</p>
                      <p className="font-display text-xl font-bold text-neutral-950">{currentPayPeriod.employee_count}</p>
                    </div>
                    <div>
                      <p className="text-neutral-500">Gross</p>
                      <p className="font-display text-xl font-bold text-neutral-950">{formatCurrency(currentPayPeriod.total_gross)}</p>
                    </div>
                    <div className="col-span-2">
                      <p className="text-neutral-500">Net payroll</p>
                      <p className="font-display text-2xl font-extrabold text-success-700">{formatCurrency(currentPayPeriod.total_net)}</p>
                    </div>
                  </div>
                  <div className="mt-5 flex flex-col gap-2 sm:flex-row sm:flex-wrap [&>button]:w-full sm:[&>button]:w-auto">
                    <Button size="sm" onClick={() => navigate(payRunHref(currentPayPeriod.id))}>Open period</Button>
                    {currentPayPeriod.status === 'draft' && (
                      <Button size="sm" variant="secondary" onClick={() => navigate(payRunHref(currentPayPeriod.id, 'work'))}>Process payroll</Button>
                    )}
                  </div>
                </div>
              </div>
            ) : (
              <div className="flex flex-col items-center justify-center rounded-2xl border border-dashed border-neutral-300 bg-neutral-50/70 px-4 py-10 text-center">
                <CalendarCheck2 className="mb-3 h-7 w-7 text-neutral-400" />
                <p className="font-display text-lg font-bold text-neutral-900">No active pay period</p>
                <p className="mt-1 max-w-md text-sm text-neutral-500">Create a pay period to start collecting hours, deductions, checks, and reports.</p>
                <Button className="mt-5" onClick={() => navigate(payRunsHref)}>
                  Create pay period
                </Button>
              </div>
            )}
          </CardContent>
        </Card>

        {stats?.recent_payrolls && stats.recent_payrolls.length > 0 && (
          <Card className="mt-8">
            <CardHeader>
              <CardTitle>Recent Payrolls</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="space-y-3">
                {stats.recent_payrolls.map((payroll) => (
                  <div
                    key={payroll.id}
                    className="-mx-2 flex cursor-pointer flex-col gap-2 rounded-xl border border-transparent px-3 py-3 transition-all hover:border-primary-200 hover:bg-primary-50/60 sm:flex-row sm:items-center sm:justify-between"
                    onClick={() => navigate(payRunHref(payroll.id))}
                  >
                    <div>
                      <p className="font-medium text-neutral-900">{payroll.period_description}</p>
                      <p className="text-sm text-neutral-500">
                        {new Date(payroll.pay_date).toLocaleDateString()} • {payroll.employee_count} employees
                      </p>
                    </div>
                    <p className="font-semibold text-success-600">{formatCurrency(payroll.total_net)}</p>
                  </div>
                ))}
              </div>
            </CardContent>
          </Card>
        )}

        <div className="mt-8 grid gap-5 md:grid-cols-3">
          {[
            { title: 'Add Employee', body: 'Register a worker before the next run.', icon: <UserPlus2 className="h-5 w-5" />, href: newEmployeeHref, tone: 'primary' },
            { title: 'Run Payroll', body: 'Open pay periods and continue processing.', icon: <Wallet className="h-5 w-5" />, href: payRunsHref, tone: 'success' },
            { title: 'Guam Reports', body: 'Export registers, tax summaries, and compliance packets.', icon: <Landmark className="h-5 w-5" />, href: '/reports', tone: 'accent' },
          ].map((action) => (
            <Card key={action.title} className="group cursor-pointer overflow-hidden hover:-translate-y-1 hover:border-primary-200" onClick={() => navigate(action.href)}>
              <CardContent className="pt-6">
                <div className="flex items-start justify-between gap-4">
                  <div className="flex items-start gap-4">
                    <div className={`rounded-2xl p-3 ring-1 ${
                      action.tone === 'success'
                        ? 'bg-success-50 text-success-600 ring-success-100'
                        : action.tone === 'accent'
                          ? 'bg-accent-50 text-accent-700 ring-accent-100'
                          : 'bg-primary-50 text-primary-700 ring-primary-100'
                    }`}>
                      {action.icon}
                    </div>
                    <div>
                      <p className="font-display font-bold text-neutral-950">{action.title}</p>
                      <p className="mt-1 text-sm leading-5 text-neutral-500">{action.body}</p>
                    </div>
                  </div>
                  <ArrowRight className="mt-1 h-4 w-4 text-neutral-300 transition-transform group-hover:translate-x-1 group-hover:text-primary-600" />
                </div>
              </CardContent>
            </Card>
          ))}
        </div>

        {stats?.ytd_totals && stats.ytd_totals.gross_pay > 0 && (
          <Card className="mt-8">
            <CardHeader>
              <CardTitle>{stats.ytd_totals.year} Year-to-Date Summary</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
                <div>
                  <p className="text-sm text-neutral-500">Gross Pay</p>
                  <p className="text-lg font-medium text-neutral-900">{formatCurrency(stats.ytd_totals.gross_pay)}</p>
                </div>
                <div>
                  <p className="text-sm text-neutral-500">Withholding Tax</p>
                  <p className="text-lg font-medium text-danger-600">{formatCurrency(stats.ytd_totals.withholding_tax)}</p>
                </div>
                <div>
                  <p className="text-sm text-neutral-500">Social Security</p>
                  <p className="text-lg font-medium text-danger-600">{formatCurrency(stats.ytd_totals.social_security_tax)}</p>
                </div>
                <div>
                  <p className="text-sm text-neutral-500">Medicare</p>
                  <p className="text-lg font-medium text-danger-600">{formatCurrency(stats.ytd_totals.medicare_tax)}</p>
                </div>
              </div>
            </CardContent>
          </Card>
        )}
      </div>
    </div>
  );
}
