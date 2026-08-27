import { useEffect, useState, type ReactElement } from 'react';
import { useNavigate } from 'react-router';
import { CalendarDays, FileBarChart2, FolderOpen, Users } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { clientDocumentsApi, clientReportsApi } from '@/services/api';
import { formatCurrency } from '@/lib/utils';
import { useCompany } from '@/contexts/CompanyContext';
import { employeesPath, newEmployeePath, payRunPath, payRunsPath } from '@/lib/routes';

export function ClientDashboard(): ReactElement {
  const navigate = useNavigate();
  const { activeCompanyId } = useCompany();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [stats, setStats] = useState<Awaited<ReturnType<typeof clientReportsApi.dashboard>>['stats'] | null>(null);
  const [documentCount, setDocumentCount] = useState(0);
  const employeeListHref = activeCompanyId ? employeesPath(activeCompanyId) : '/employees';
  const newEmployeeHref = activeCompanyId ? newEmployeePath(activeCompanyId) : '/employees/new';
  const payRunListHref = activeCompanyId ? payRunsPath(activeCompanyId) : '/pay-periods';
  const payRunHref = (payRunId: number): string => activeCompanyId
    ? payRunPath(activeCompanyId, payRunId, 'overview')
    : `/pay-periods/${payRunId}`;

  useEffect((): (() => void) => {
    let cancelled = false;

    const load = async (): Promise<void> => {
      setLoading(true);
      setError(null);
      try {
        const [dashboard, documents] = await Promise.all([
          clientReportsApi.dashboard(),
          clientDocumentsApi.list(),
        ]);
        if (cancelled) return;
        setStats(dashboard.stats);
        setDocumentCount(documents.data.length);
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
  }, [activeCompanyId]);

  return (
    <div>
      <Header
        title="Client Portal"
        description="Manage employees, review payroll, and securely share documents."
        actions={<Button onClick={() => navigate(newEmployeeHref)}>Add Employee</Button>}
      />

      <div className="p-6 lg:p-8 space-y-8">
        {error && (
          <div className="rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">
            {error}
          </div>
        )}

        <div className="grid gap-6 md:grid-cols-2 xl:grid-cols-4">
          <PortalStat
            label="Active Employees"
            value={loading ? '—' : String(stats?.active_employees ?? 0)}
            sublabel={loading ? undefined : `${stats?.total_employees ?? 0} total records`}
            icon={<Users className="h-5 w-5" />}
          />
          <PortalStat
            label="YTD Payroll"
            value={loading ? '—' : formatCurrency(stats?.ytd_totals?.net_pay ?? 0)}
            sublabel={loading ? undefined : `${stats?.ytd_totals?.payroll_count ?? 0} pay periods`}
            icon={<CalendarDays className="h-5 w-5" />}
          />
          <PortalStat
            label="Uploaded Documents"
            value={loading ? '—' : String(documentCount)}
            sublabel="Stored for payroll review"
            icon={<FileBarChart2 className="h-5 w-5" />}
          />
          <PortalStat
            label="Recent Payrolls"
            value={loading ? '—' : String(stats?.recent_payrolls?.length ?? 0)}
            sublabel="Committed payrolls ready to review"
            icon={<FolderOpen className="h-5 w-5" />}
          />
        </div>

        <Card className="border-primary-200/70 bg-gradient-to-r from-white to-primary-50/60">
          <CardContent className="py-7">
            <div className="flex flex-col gap-5 lg:flex-row lg:items-center lg:justify-between">
              <div>
                <p className="text-xs font-semibold uppercase tracking-[0.14em] text-primary-700">Current payroll</p>
                <h2 className="mt-2 text-2xl font-semibold tracking-tight text-neutral-900">
                  {stats?.current_pay_period ? stats.current_pay_period.period_description : 'No active pay period'}
                </h2>
                <p className="mt-2 text-sm text-neutral-600">
                  {stats?.current_pay_period
                    ? `Pay date ${new Date(stats.current_pay_period.pay_date).toLocaleDateString()} • ${stats.current_pay_period.employee_count} employees • ${formatCurrency(stats.current_pay_period.total_net)} net`
                    : 'When a pay period is available, you can review it here and download payroll reports.'}
                </p>
              </div>
              <div className="flex flex-wrap gap-3">
                <Button variant="secondary" onClick={() => navigate('/documents')}>
                  Upload Documents
                </Button>
                <Button onClick={() => navigate('/reports')}>Open Reports</Button>
              </div>
            </div>
          </CardContent>
        </Card>

        <div className="grid gap-6 md:grid-cols-2 xl:grid-cols-4">
          <QuickLink
            title="Employees"
            description="Add and update employee records"
            icon={<Users className="h-5 w-5" />}
            onClick={() => navigate(employeeListHref)}
          />
          <QuickLink
            title="Pay Periods"
            description="Review payroll runs and employee pay"
            icon={<CalendarDays className="h-5 w-5" />}
            onClick={() => navigate(payRunListHref)}
          />
          <QuickLink
            title="Documents"
            description="Upload requested files securely"
            icon={<FolderOpen className="h-5 w-5" />}
            onClick={() => navigate('/documents')}
          />
        </div>

        {stats?.recent_payrolls?.length ? (
          <Card>
            <CardHeader>
              <CardTitle>Recent Payrolls</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              {stats.recent_payrolls.map((payroll) => (
                <button
                  key={payroll.id}
                  type="button"
                  onClick={() => navigate(payRunHref(payroll.id))}
                  className="flex w-full items-center justify-between rounded-xl border border-transparent px-3 py-3 text-left transition-all hover:border-primary-200 hover:bg-primary-50/60"
                >
                  <div>
                    <p className="font-medium text-neutral-900">{payroll.period_description}</p>
                    <p className="text-sm text-neutral-500">
                      {new Date(payroll.pay_date).toLocaleDateString()} • {payroll.employee_count} employees
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
      <CardContent className="pt-6">
        <div className="flex items-start justify-between">
          <p className="text-sm font-medium text-neutral-500">{label}</p>
          <div className="rounded-xl bg-primary-50 p-2 text-primary-700">{icon}</div>
        </div>
        <p className="mt-3 text-3xl font-semibold tracking-tight text-neutral-900">{value}</p>
        {sublabel && <p className="mt-1.5 text-sm text-neutral-500">{sublabel}</p>}
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
    <Card className="cursor-pointer hover:-translate-y-0.5 hover:border-primary-300" onClick={onClick}>
      <CardContent className="pt-6">
        <div className="flex items-center gap-4">
          <div className="rounded-xl bg-primary-100 p-3 text-primary-700">{icon}</div>
          <div>
            <p className="font-medium text-neutral-900">{title}</p>
            <p className="text-sm text-neutral-500">{description}</p>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}
