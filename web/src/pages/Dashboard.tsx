import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Banknote, CalendarCheck2, FileBarChart2, UserPlus2, Users, Wallet } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Header } from '@/components/layout/Header';
import { formatCurrency, payPeriodStatusConfig } from '@/lib/utils';
import { reportsApi, type DashboardResponse } from '@/services/api';
import type { PayPeriodStatus } from '@/types';

function StatCard({
  title,
  value,
  subtitle,
  loading,
  icon,
}: {
  title: string;
  value: string | number;
  subtitle?: string;
  loading?: boolean;
  icon: React.ReactNode;
}) {
  return (
    <Card className="overflow-hidden">
      <CardContent className="pt-6">
        <div className="flex items-start justify-between">
          <p className="text-sm font-medium text-neutral-500">{title}</p>
          <div className="rounded-xl bg-primary-50 p-2 text-primary-700">{icon}</div>
        </div>
        {loading ? (
          <div className="mt-3 h-9 animate-pulse rounded bg-neutral-100" />
        ) : (
          <p className="mt-3 text-3xl font-semibold tracking-tight text-neutral-900">{value}</p>
        )}
        {subtitle && <p className="mt-1.5 text-sm text-neutral-500">{subtitle}</p>}
      </CardContent>
    </Card>
  );
}

export function Dashboard() {
  const navigate = useNavigate();
  const [loading, setLoading] = useState(true);
  const [stats, setStats] = useState<DashboardResponse['stats'] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    loadDashboard();
  }, []);

  const loadDashboard = async () => {
    try {
      setLoading(true);
      const response = await reportsApi.dashboard();
      setStats(response.stats);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load dashboard');
    } finally {
      setLoading(false);
    }
  };

  const currentPayPeriod = stats?.current_pay_period;
  const statusConfig = currentPayPeriod ? payPeriodStatusConfig[currentPayPeriod.status as PayPeriodStatus] : null;

  return (
    <div>
      <Header
        title="Home"
        description="Your payroll command center"
        actions={<Button onClick={() => navigate('/pay-periods')}>Manage Pay Periods</Button>}
      />

      <div className="p-6 lg:p-8">
        {error && (
          <div className="mb-6 rounded-2xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">
            {error}
          </div>
        )}

        <Card className="mb-8 overflow-hidden border-primary-200/70 bg-gradient-to-r from-white to-primary-50/70">
          <CardContent className="py-7">
            <div className="flex flex-col gap-5 lg:flex-row lg:items-center lg:justify-between">
              <div>
                <p className="text-xs font-semibold uppercase tracking-[0.14em] text-primary-700">Payroll overview</p>
                <h2 className="mt-2 text-2xl font-semibold tracking-tight text-neutral-900">Everything ready for this pay cycle</h2>
                <p className="mt-2 text-sm text-neutral-600">
                  Review your current period, run payroll operations, and export required tax reports from one place.
                </p>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <Button variant="secondary" onClick={() => navigate('/employees/new')}>
                  Add employee
                </Button>
                <Button onClick={() => navigate('/reports')}>Open reports</Button>
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

        <Card className="mt-8">
          <CardHeader>
            <div className="flex items-center justify-between gap-3">
              <CardTitle>Current Pay Period</CardTitle>
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
              <div className="h-16 animate-pulse rounded-xl bg-neutral-100" />
            ) : currentPayPeriod ? (
              <div className="flex flex-col gap-5 lg:flex-row lg:items-center lg:justify-between">
                <div>
                  <p className="text-lg font-semibold tracking-tight text-neutral-900">{currentPayPeriod.period_description}</p>
                  <p className="text-sm text-neutral-500">
                    Pay date:{' '}
                    {new Date(currentPayPeriod.pay_date).toLocaleDateString('en-US', {
                      weekday: 'long',
                      year: 'numeric',
                      month: 'long',
                      day: 'numeric',
                    })}
                  </p>
                  <p className="mt-1 text-sm text-neutral-500">
                    {currentPayPeriod.employee_count} employees • {formatCurrency(currentPayPeriod.total_gross)} gross •{' '}
                    {formatCurrency(currentPayPeriod.total_net)} net
                  </p>
                </div>
                <div className="flex flex-wrap gap-3">
                  <Button variant="outline" onClick={() => navigate(`/pay-periods/${currentPayPeriod.id}`)}>
                    View details
                  </Button>
                  {currentPayPeriod.status === 'draft' && (
                    <Button onClick={() => navigate(`/pay-periods/${currentPayPeriod.id}`)}>Process payroll</Button>
                  )}
                </div>
              </div>
            ) : (
              <div className="flex flex-col items-center justify-center rounded-2xl border border-dashed border-neutral-300 bg-neutral-50/70 px-4 py-8 text-center">
                <CalendarCheck2 className="mb-2 h-6 w-6 text-neutral-400" />
                <p className="text-sm text-neutral-600">No active pay period</p>
                <Button className="mt-4" onClick={() => navigate('/pay-periods')}>
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
                    className="-mx-2 flex cursor-pointer items-center justify-between rounded-xl border border-transparent px-3 py-3 transition-all hover:border-primary-200 hover:bg-primary-50/60"
                    onClick={() => navigate(`/pay-periods/${payroll.id}`)}
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

        <div className="mt-8 grid gap-6 md:grid-cols-3">
          <Card className="cursor-pointer hover:-translate-y-0.5 hover:border-primary-300" onClick={() => navigate('/employees/new')}>
            <CardContent className="pt-6">
              <div className="flex items-center gap-4">
                <div className="rounded-xl bg-primary-100 p-3 text-primary-700">
                  <UserPlus2 className="h-5 w-5" />
                </div>
                <div>
                  <p className="font-medium text-neutral-900">Add Employee</p>
                  <p className="text-sm text-neutral-500">Register a new employee</p>
                </div>
              </div>
            </CardContent>
          </Card>

          <Card className="cursor-pointer hover:-translate-y-0.5 hover:border-primary-300" onClick={() => navigate('/pay-periods')}>
            <CardContent className="pt-6">
              <div className="flex items-center gap-4">
                <div className="rounded-xl bg-success-100 p-3 text-success-600">
                  <Wallet className="h-5 w-5" />
                </div>
                <div>
                  <p className="font-medium text-neutral-900">Run Payroll</p>
                  <p className="text-sm text-neutral-500">Process the current period</p>
                </div>
              </div>
            </CardContent>
          </Card>

          <Card className="cursor-pointer hover:-translate-y-0.5 hover:border-primary-300" onClick={() => navigate('/reports')}>
            <CardContent className="pt-6">
              <div className="flex items-center gap-4">
                <div className="rounded-xl bg-primary-100 p-3 text-primary-700">
                  <FileBarChart2 className="h-5 w-5" />
                </div>
                <div>
                  <p className="font-medium text-neutral-900">View Reports</p>
                  <p className="text-sm text-neutral-500">Payroll and tax exports</p>
                </div>
              </div>
            </CardContent>
          </Card>
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
