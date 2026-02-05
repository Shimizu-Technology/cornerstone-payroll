import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Header } from '@/components/layout/Header';
import { formatCurrency, payPeriodStatusConfig } from '@/lib/utils';
import { reportsApi, type DashboardResponse } from '@/services/api';
import type { PayPeriodStatus } from '@/types';

function StatCard({ title, value, subtitle, loading }: { title: string; value: string | number; subtitle?: string; loading?: boolean }) {
  return (
    <Card>
      <CardContent className="pt-6">
        <p className="text-sm font-medium text-gray-500">{title}</p>
        {loading ? (
          <div className="mt-2 h-9 bg-gray-100 animate-pulse rounded" />
        ) : (
          <p className="mt-2 text-3xl font-semibold text-gray-900">{value}</p>
        )}
        {subtitle && <p className="mt-1 text-sm text-gray-500">{subtitle}</p>}
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
        title="Dashboard"
        description="Overview of your payroll operations"
        actions={
          <Button onClick={() => navigate('/pay-periods')}>Manage Pay Periods</Button>
        }
      />

      <div className="p-8">
        {error && (
          <div className="mb-4 p-4 bg-red-50 border border-red-200 text-red-700 rounded-lg">
            {error}
          </div>
        )}

        {/* Stats Grid */}
        <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-4">
          <StatCard
            title="Active Employees"
            value={stats?.active_employees ?? 0}
            subtitle={`${stats?.total_employees ?? 0} total`}
            loading={loading}
          />
          <StatCard
            title="Last Payroll"
            value={stats?.recent_payrolls?.[0] ? formatCurrency(stats.recent_payrolls[0].total_net) : '$0.00'}
            loading={loading}
          />
          <StatCard
            title="YTD Payroll"
            value={stats?.ytd_totals ? formatCurrency(stats.ytd_totals.net_pay) : '$0.00'}
            subtitle={stats?.ytd_totals ? `${stats.ytd_totals.payroll_count} pay periods` : undefined}
            loading={loading}
          />
          <StatCard
            title="YTD Gross"
            value={stats?.ytd_totals ? formatCurrency(stats.ytd_totals.gross_pay) : '$0.00'}
            loading={loading}
          />
        </div>

        {/* Current Pay Period */}
        <Card className="mt-8">
          <CardHeader>
            <div className="flex items-center justify-between">
              <CardTitle>Current Pay Period</CardTitle>
              {currentPayPeriod && statusConfig && (
                <Badge
                  variant={
                    currentPayPeriod.status === 'committed' ? 'success' :
                    currentPayPeriod.status === 'approved' ? 'info' :
                    currentPayPeriod.status === 'calculated' ? 'warning' :
                    'default'
                  }
                >
                  {statusConfig.label}
                </Badge>
              )}
            </div>
          </CardHeader>
          <CardContent>
            {loading ? (
              <div className="h-16 bg-gray-100 animate-pulse rounded" />
            ) : currentPayPeriod ? (
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-lg font-medium text-gray-900">
                    {currentPayPeriod.period_description}
                  </p>
                  <p className="text-sm text-gray-500">
                    Pay date: {new Date(currentPayPeriod.pay_date).toLocaleDateString('en-US', {
                      weekday: 'long',
                      year: 'numeric',
                      month: 'long',
                      day: 'numeric',
                    })}
                  </p>
                  <p className="text-sm text-gray-500 mt-1">
                    {currentPayPeriod.employee_count} employees • {formatCurrency(currentPayPeriod.total_gross)} gross • {formatCurrency(currentPayPeriod.total_net)} net
                  </p>
                </div>
                <div className="flex gap-3">
                  <Button variant="outline" onClick={() => navigate(`/pay-periods/${currentPayPeriod.id}`)}>
                    View Details
                  </Button>
                  {currentPayPeriod.status === 'draft' && (
                    <Button onClick={() => navigate(`/pay-periods/${currentPayPeriod.id}`)}>
                      Process Payroll
                    </Button>
                  )}
                </div>
              </div>
            ) : (
              <div className="text-center py-4">
                <p className="text-gray-500">No active pay period</p>
                <Button className="mt-4" onClick={() => navigate('/pay-periods')}>
                  Create Pay Period
                </Button>
              </div>
            )}
          </CardContent>
        </Card>

        {/* Recent Payrolls */}
        {stats?.recent_payrolls && stats.recent_payrolls.length > 0 && (
          <Card className="mt-8">
            <CardHeader>
              <CardTitle>Recent Payrolls</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="space-y-4">
                {stats.recent_payrolls.map((payroll) => (
                  <div
                    key={payroll.id}
                    className="flex items-center justify-between py-2 border-b last:border-0 cursor-pointer hover:bg-gray-50 -mx-2 px-2 rounded"
                    onClick={() => navigate(`/pay-periods/${payroll.id}`)}
                  >
                    <div>
                      <p className="font-medium text-gray-900">{payroll.period_description}</p>
                      <p className="text-sm text-gray-500">
                        {new Date(payroll.pay_date).toLocaleDateString()} • {payroll.employee_count} employees
                      </p>
                    </div>
                    <p className="font-semibold text-green-600">{formatCurrency(payroll.total_net)}</p>
                  </div>
                ))}
              </div>
            </CardContent>
          </Card>
        )}

        {/* Quick Actions */}
        <div className="mt-8 grid gap-6 md:grid-cols-3">
          <Card
            className="cursor-pointer hover:border-primary-300 transition-colors"
            onClick={() => navigate('/employees/new')}
          >
            <CardContent className="pt-6">
              <div className="flex items-center gap-4">
                <div className="p-3 bg-primary-100 rounded-lg">
                  <svg className="w-6 h-6 text-primary-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0z" />
                  </svg>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Add Employee</p>
                  <p className="text-sm text-gray-500">Register a new employee</p>
                </div>
              </div>
            </CardContent>
          </Card>

          <Card
            className="cursor-pointer hover:border-primary-300 transition-colors"
            onClick={() => navigate('/pay-periods')}
          >
            <CardContent className="pt-6">
              <div className="flex items-center gap-4">
                <div className="p-3 bg-green-100 rounded-lg">
                  <svg className="w-6 h-6 text-green-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8c-1.657 0-3 .895-3 2s1.343 2 3 2 3 .895 3 2-1.343 2-3 2m0-8c1.11 0 2.08.402 2.599 1M12 8V7m0 1v8m0 0v1m0-1c-1.11 0-2.08-.402-2.599-1M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Run Payroll</p>
                  <p className="text-sm text-gray-500">Process the current period</p>
                </div>
              </div>
            </CardContent>
          </Card>

          <Card
            className="cursor-pointer hover:border-primary-300 transition-colors"
            onClick={() => navigate('/reports')}
          >
            <CardContent className="pt-6">
              <div className="flex items-center gap-4">
                <div className="p-3 bg-purple-100 rounded-lg">
                  <svg className="w-6 h-6 text-purple-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 17v-2m3 2v-4m3 4v-6m2 10H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
                  </svg>
                </div>
                <div>
                  <p className="font-medium text-gray-900">View Reports</p>
                  <p className="text-sm text-gray-500">Payroll & tax reports</p>
                </div>
              </div>
            </CardContent>
          </Card>
        </div>

        {/* YTD Tax Summary */}
        {stats?.ytd_totals && stats.ytd_totals.gross_pay > 0 && (
          <Card className="mt-8">
            <CardHeader>
              <CardTitle>{stats.ytd_totals.year} Year-to-Date Summary</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
                <div>
                  <p className="text-sm text-gray-500">Gross Pay</p>
                  <p className="text-lg font-medium">{formatCurrency(stats.ytd_totals.gross_pay)}</p>
                </div>
                <div>
                  <p className="text-sm text-gray-500">Withholding Tax</p>
                  <p className="text-lg font-medium text-red-600">{formatCurrency(stats.ytd_totals.withholding_tax)}</p>
                </div>
                <div>
                  <p className="text-sm text-gray-500">Social Security</p>
                  <p className="text-lg font-medium text-red-600">{formatCurrency(stats.ytd_totals.social_security_tax)}</p>
                </div>
                <div>
                  <p className="text-sm text-gray-500">Medicare</p>
                  <p className="text-lg font-medium text-red-600">{formatCurrency(stats.ytd_totals.medicare_tax)}</p>
                </div>
              </div>
            </CardContent>
          </Card>
        )}
      </div>
    </div>
  );
}
