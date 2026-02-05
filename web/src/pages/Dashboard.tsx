import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Header } from '@/components/layout/Header';
import { formatCurrency, formatDateRange, payPeriodStatusConfig } from '@/lib/utils';
import type { PayPeriodStatus } from '@/types';

// Placeholder data - will be replaced with API calls
const stats = {
  totalEmployees: 4,
  activeEmployees: 4,
  currentPayPeriod: {
    id: 1,
    start_date: '2026-01-20',
    end_date: '2026-02-02',
    pay_date: '2026-02-06',
    status: 'draft' as PayPeriodStatus,
  },
  lastPayrollTotal: 12450.00,
  ytdPayrollTotal: 24900.00,
  pendingApprovals: 0,
};

function StatCard({ title, value, subtitle }: { title: string; value: string | number; subtitle?: string }) {
  return (
    <Card>
      <CardContent className="pt-6">
        <p className="text-sm font-medium text-gray-500">{title}</p>
        <p className="mt-2 text-3xl font-semibold text-gray-900">{value}</p>
        {subtitle && <p className="mt-1 text-sm text-gray-500">{subtitle}</p>}
      </CardContent>
    </Card>
  );
}

export function Dashboard() {
  const statusConfig = payPeriodStatusConfig[stats.currentPayPeriod.status];

  return (
    <div>
      <Header
        title="Dashboard"
        description="Overview of your payroll operations"
        actions={
          <Button>Run Payroll</Button>
        }
      />

      <div className="p-8">
        {/* Stats Grid */}
        <div className="grid gap-6 md:grid-cols-2 lg:grid-cols-4">
          <StatCard
            title="Active Employees"
            value={stats.activeEmployees}
            subtitle={`${stats.totalEmployees} total`}
          />
          <StatCard
            title="Last Payroll"
            value={formatCurrency(stats.lastPayrollTotal)}
          />
          <StatCard
            title="YTD Payroll"
            value={formatCurrency(stats.ytdPayrollTotal)}
          />
          <StatCard
            title="Pending Approvals"
            value={stats.pendingApprovals}
          />
        </div>

        {/* Current Pay Period */}
        <Card className="mt-8">
          <CardHeader>
            <div className="flex items-center justify-between">
              <CardTitle>Current Pay Period</CardTitle>
              <Badge
                variant={
                  stats.currentPayPeriod.status === 'committed' ? 'success' :
                  stats.currentPayPeriod.status === 'approved' ? 'info' :
                  stats.currentPayPeriod.status === 'calculated' ? 'warning' :
                  'default'
                }
              >
                {statusConfig.label}
              </Badge>
            </div>
          </CardHeader>
          <CardContent>
            <div className="flex items-center justify-between">
              <div>
                <p className="text-lg font-medium text-gray-900">
                  {formatDateRange(stats.currentPayPeriod.start_date, stats.currentPayPeriod.end_date)}
                </p>
                <p className="text-sm text-gray-500">
                  Pay date: {new Date(stats.currentPayPeriod.pay_date).toLocaleDateString('en-US', {
                    weekday: 'long',
                    year: 'numeric',
                    month: 'long',
                    day: 'numeric',
                  })}
                </p>
              </div>
              <div className="flex gap-3">
                <Button variant="outline">View Details</Button>
                <Button>Process Payroll</Button>
              </div>
            </div>
          </CardContent>
        </Card>

        {/* Quick Actions */}
        <div className="mt-8 grid gap-6 md:grid-cols-3">
          <Card className="cursor-pointer hover:border-primary-300 transition-colors">
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

          <Card className="cursor-pointer hover:border-primary-300 transition-colors">
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

          <Card className="cursor-pointer hover:border-primary-300 transition-colors">
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
      </div>
    </div>
  );
}
