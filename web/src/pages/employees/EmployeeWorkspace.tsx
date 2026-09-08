import { useCallback, useEffect, useRef, useState, type ReactElement } from 'react';
import {
  Activity,
  ArrowLeft,
  ArrowRight,
  BadgeDollarSign,
  Banknote,
  CalendarDays,
  Pencil,
  ReceiptText,
  RefreshCw,
  Settings2,
  UserRound,
} from 'lucide-react';
import { Link, Navigate, useLocation, useParams, useSearchParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { WorkspaceTabs } from '@/components/records/WorkspaceTabs';
import { WorkspaceLoader } from '@/components/records/WorkspaceLoader';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useCompany } from '@/contexts/CompanyContext';
import {
  employeeStatusConfig,
  employmentTypeLabels,
  filingStatusLabels,
  formatCurrency,
  formatDate,
  formatGuamDateTime,
  payFrequencyLabels,
} from '@/lib/utils';
import {
  currentAppPath,
  employeeEditPath,
  employeePath,
  employeesPath,
  importedPayRunPath,
  payrollItemPath,
  payRunPath,
  safeInternalReturnPath,
  type EmployeeWorkspaceTab,
} from '@/lib/routes';
import { employeesApi, reportsApi } from '@/services/api';
import type { Employee } from '@/types';
import { parsePositiveRouteId } from '@/lib/route-params';

type PayHistoryReport = Awaited<ReturnType<typeof reportsApi.employeePayHistory>>['report'];

const tabs: Array<{ id: EmployeeWorkspaceTab; label: string; icon: typeof UserRound }> = [
  { id: 'overview', label: 'Overview', icon: UserRound },
  { id: 'pay-setup', label: 'Pay setup', icon: Settings2 },
  { id: 'pay-history', label: 'Pay history', icon: ReceiptText },
  { id: 'activity', label: 'Activity', icon: Activity },
];
const tabIds = new Set(tabs.map((tab) => tab.id));

function numericValue(record: Record<string, number>, key: string): number {
  const value = Number(record[key]);
  return Number.isFinite(value) ? value : 0;
}

export function EmployeeWorkspace(): ReactElement {
  const { companyId: companyIdParam, id: idParam, tab: tabParam } = useParams<{
    companyId: string;
    id: string;
    tab?: string;
  }>();
  const companyId = parsePositiveRouteId(companyIdParam) ?? 0;
  const employeeId = parsePositiveRouteId(idParam) ?? 0;
  const { activeCompanyId } = useCompany();
  const activeTab = (tabParam ?? 'overview') as EmployeeWorkspaceTab;
  const location = useLocation();
  const [searchParams] = useSearchParams();
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [payHistory, setPayHistory] = useState<PayHistoryReport | null>(null);
  const [payHistoryError, setPayHistoryError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [resolvedRouteKey, setResolvedRouteKey] = useState<string | null>(null);
  const loadRequestIdRef = useRef(0);
  const routeKey = `${companyId}:${employeeId}`;
  const hasValidRouteIds = [companyId, employeeId].every((value) => Number.isInteger(value) && value > 0);

  const load = useCallback(async (): Promise<void> => {
    const requestId = ++loadRequestIdRef.current;
    const isCurrentRequest = (): boolean => loadRequestIdRef.current === requestId;

    if (!hasValidRouteIds) {
      if (isCurrentRequest()) {
        setError('This employee workspace link is invalid.');
        setResolvedRouteKey(routeKey);
        setLoading(false);
      }
      return;
    }

    if (activeCompanyId !== companyId) return;

    setLoading(true);
    setResolvedRouteKey(null);
    setError(null);
    setPayHistoryError(null);
    try {
      const [employeeResult, historyResult] = await Promise.allSettled([
        employeesApi.get(employeeId),
        reportsApi.employeePayHistory(employeeId, { limit: 24 }),
      ]);
      if (!isCurrentRequest()) return;
      if (employeeResult.status === 'rejected') throw employeeResult.reason;

      setEmployee(employeeResult.value.data);
      setResolvedRouteKey(routeKey);
      if (historyResult.status === 'fulfilled') {
        setPayHistory(historyResult.value.report);
      } else {
        setPayHistory(null);
        setPayHistoryError('Pay history is temporarily unavailable. Employee details are still available.');
      }
    } catch (loadError) {
      if (isCurrentRequest()) {
        setError(loadError instanceof Error ? loadError.message : 'Could not load this employee workspace.');
        setResolvedRouteKey(routeKey);
      }
    } finally {
      if (isCurrentRequest()) setLoading(false);
    }
  }, [activeCompanyId, companyId, employeeId, hasValidRouteIds, routeKey]);

  useEffect(() => {
    setEmployee(null);
    setPayHistory(null);
    setPayHistoryError(null);
    setError(null);
    setResolvedRouteKey(null);
    setLoading(true);
    void load();
    return (): void => {
      loadRequestIdRef.current += 1;
    };
  }, [load]);

  const employeeListFallback = companyId > 0 ? employeesPath(companyId) : '/employees';
  const returnTo = safeInternalReturnPath(searchParams.get('return_to'), employeeListFallback);

  if (hasValidRouteIds && tabParam && !tabIds.has(tabParam as EmployeeWorkspaceTab)) {
    return <Navigate to={employeePath(companyId, employeeId, 'overview', { returnTo })} replace />;
  }

  const currentPath = currentAppPath(location.pathname, location.search);

  if (loading || activeCompanyId !== companyId || resolvedRouteKey !== routeKey) {
    return <WorkspaceLoader label="Loading employee workspace" />;
  }

  if (!employee || error) {
    return (
      <div className="p-4 sm:p-6 lg:p-8">
        <Card className="mx-auto max-w-2xl border-danger-200 bg-danger-50">
          <CardContent className="p-6">
            <p className="text-xs font-bold uppercase tracking-[0.14em] text-danger-700">Employee unavailable</p>
            <h1 className="mt-2 font-display text-2xl font-extrabold tracking-tight text-neutral-950">
              This employee workspace could not be opened
            </h1>
            <p className="mt-2 text-sm leading-6 text-neutral-700">
              {error || 'The employee may have been removed, or the link may belong to another client.'}
            </p>
            <div className="mt-4 flex flex-wrap gap-4">
              <Button onClick={() => void load()}><RefreshCw className="mr-2 h-4 w-4" />Try again</Button>
              <Link className="inline-flex min-h-11 items-center gap-2 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-700" to={returnTo}>
                <ArrowLeft className="h-4 w-4" />Back to employees
              </Link>
            </div>
          </CardContent>
        </Card>
      </div>
    );
  }

  const employeeName = `${employee.first_name} ${employee.last_name}`;
  const statusConfig = employeeStatusConfig[employee.status];
  const history = payHistory?.history ?? [];
  const latestPay = history[0];
  const summary = payHistory?.summary ?? {};
  const employeeDescription = [
    employmentTypeLabels[employee.employment_type] || employee.employment_type,
    employee.department?.name || 'No department',
    employee.hire_date ? `Hired ${formatDate(employee.hire_date)}` : 'Hire date not recorded',
  ].join(' · ');

  return (
    <div>
      <Header
        title={employeeName}
        description={employeeDescription}
        actions={
          <div className="flex w-full flex-wrap gap-2 sm:w-auto sm:justify-end">
            <Link className="inline-flex min-h-11 items-center gap-2 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-700 transition hover:border-primary-300 hover:text-primary-800" to={returnTo}>
              <ArrowLeft className="h-4 w-4" />Back
            </Link>
            <Link className="inline-flex min-h-11 items-center gap-2 rounded-full bg-primary-700 px-4 text-sm font-semibold text-white transition hover:bg-primary-800" to={employeeEditPath(companyId, employeeId, { returnTo: currentPath })}>
              <Pencil className="h-4 w-4" />Edit employee
            </Link>
          </div>
        }
      />

      <section className="border-b border-neutral-200 bg-neutral-50/70 px-4 py-3 sm:px-6 lg:px-8" aria-label="Employee identity">
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant={employee.status === 'active' ? 'success' : employee.status === 'terminated' ? 'danger' : 'default'}>
            {statusConfig?.label || employee.status}
          </Badge>
          <Badge variant="default">{employee.tax_classification?.toUpperCase() || (employee.employment_type === 'contractor' ? '1099' : 'W-2')}</Badge>
          <span className="text-sm font-medium text-neutral-500">Employee #{employee.id}</span>
        </div>
      </section>

      <WorkspaceTabs
        label="Employee workspace sections"
        tabs={tabs.map((tab) => ({
          ...tab,
          href: employeePath(companyId, employeeId, tab.id, { returnTo }),
          count: tab.id === 'pay-history' ? history.length : undefined,
        }))}
      />

      <main className="space-y-6 p-4 sm:p-6 lg:p-8">
        {payHistoryError && (
          <div className="flex flex-wrap items-center justify-between gap-4 rounded-2xl border border-amber-200 bg-amber-50 px-4 py-4 text-sm text-amber-900" role="status">
            <span>{payHistoryError}</span>
            <Button variant="outline" size="sm" onClick={() => void load()}>
              <RefreshCw className="mr-2 h-4 w-4" />Try again
            </Button>
          </div>
        )}
        {activeTab === 'overview' && (
          <EmployeeOverview
            companyId={companyId}
            employee={employee}
            latestPay={latestPay}
            summary={summary}
            returnTo={currentPath}
          />
        )}
        {activeTab === 'pay-setup' && (
          <PaySetup employee={employee} editHref={employeeEditPath(companyId, employeeId, { returnTo: currentPath })} />
        )}
        {activeTab === 'pay-history' && (
          <PayHistory companyId={companyId} report={payHistory} returnTo={currentPath} />
        )}
        {activeTab === 'activity' && <EmployeeActivity companyId={companyId} employee={employee} returnTo={currentPath} />}
      </main>
    </div>
  );
}

interface EmployeeOverviewProps {
  companyId: number;
  employee: Employee;
  latestPay: PayHistoryReport['history'][number] | undefined;
  summary: Record<string, number>;
  returnTo: string;
}

function EmployeeOverview({
  companyId,
  employee,
  latestPay,
  summary,
  returnTo,
}: EmployeeOverviewProps): ReactElement {
  return (
    <>
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <Metric icon={BadgeDollarSign} label="Current pay rate" value={formatCurrency(Number(employee.pay_rate) || 0)} detail={employee.employment_type === 'hourly' ? 'per hour' : employee.salary_type === 'per_period' ? 'per pay period' : employee.employment_type === 'contractor' ? 'contract rate' : 'annual salary'} />
        <Metric icon={Banknote} label="Recent gross" value={latestPay ? formatCurrency(latestPay.gross_pay) : 'No payroll yet'} detail={latestPay ? `Paid ${formatDate(latestPay.pay_date)}` : 'No committed payroll records'} />
        <Metric icon={ReceiptText} label="Period gross" value={formatCurrency(numericValue(summary, 'gross_pay'))} detail={`${numericValue(summary, 'payroll_count')} payroll record${numericValue(summary, 'payroll_count') === 1 ? '' : 's'}`} />
        <Metric icon={CalendarDays} label="Period net" value={formatCurrency(numericValue(summary, 'net_pay'))} detail={`${employee.pay_frequency.replace('_', '-')} schedule`} />
      </div>

      <div className="grid gap-6 lg:grid-cols-[minmax(0,1.35fr)_minmax(280px,0.75fr)]">
        <Card>
          <CardHeader className="flex-row items-center justify-between gap-4">
            <div><CardTitle>Recent payroll</CardTitle><p className="mt-2 text-sm text-neutral-500">Open the exact result or its source pay run.</p></div>
            <Link className="text-sm font-bold text-primary-700 hover:text-primary-900" to={employeePath(companyId, employee.id, 'pay-history', { returnTo })}>View all</Link>
          </CardHeader>
          <CardContent className="p-0">
            {latestPay ? (
              <div className="grid gap-4 px-4 py-4 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center sm:px-6">
                <div>
                  <div className="flex flex-wrap items-center gap-2"><p className="font-display text-lg font-bold text-neutral-950">{latestPay.period_description}</p><Badge variant={latestPay.record_type === 'native' ? 'default' : 'warning'}>{latestPay.source.label}</Badge></div>
                  <p className="mt-2 text-sm text-neutral-500">Pay date {formatDate(latestPay.pay_date)} · {formatCurrency(latestPay.net_pay)} net</p>
                </div>
                <div className="flex flex-wrap gap-2">
                  <Link className="inline-flex min-h-11 items-center gap-1 rounded-full border border-neutral-300 px-4 text-sm font-semibold text-neutral-700 hover:border-primary-300 hover:text-primary-800" to={payHistoryRunPath(companyId, latestPay, returnTo)}>{latestPay.record_type === 'native' ? 'Pay run' : 'Imported pay run'} <ArrowRight className="h-4 w-4" /></Link>
                  {latestPay.record_type === 'native' && latestPay.pay_period_id && latestPay.payroll_item_id && <Link className="inline-flex min-h-11 items-center gap-1 rounded-full bg-primary-700 px-4 text-sm font-semibold text-white hover:bg-primary-800" to={payrollItemPath(companyId, latestPay.pay_period_id, latestPay.payroll_item_id, { returnTo })}>Payroll item <ArrowRight className="h-4 w-4" /></Link>}
                </div>
              </div>
            ) : <p className="px-6 py-8 text-sm text-neutral-500">No committed payroll records are available for this employee.</p>}
          </CardContent>
        </Card>

        <Card>
          <CardHeader><CardTitle>Employment context</CardTitle></CardHeader>
          <CardContent className="space-y-4">
            <ContextRow label="Department" value={employee.department?.name || 'Not assigned'} />
            <ContextRow label="Job title" value={employee.job_title || 'Not recorded'} />
            <ContextRow label="Pay frequency" value={payFrequencyLabels[employee.pay_frequency] || employee.pay_frequency} />
            <ContextRow label="Tax filing" value={filingStatusLabels[employee.filing_status] || employee.filing_status} />
          </CardContent>
        </Card>
      </div>
    </>
  );
}

interface PaySetupProps {
  employee: Employee;
  editHref: string;
}

function PaySetup({ employee, editHref }: PaySetupProps): ReactElement {
  const adjustmentCount = (employee.default_payroll_adjustments || []).filter((item) => item.active !== false).length;
  const wageRateCount = (employee.wage_rates || []).filter((item) => item.active !== false).length;
  return (
    <div className="grid gap-6 lg:grid-cols-[minmax(0,1.35fr)_minmax(280px,0.65fr)]">
      <Card>
        <CardHeader><CardTitle>Payroll setup</CardTitle><p className="mt-2 text-sm text-neutral-500">A readable summary of the values used when this employee enters a pay run.</p></CardHeader>
        <CardContent className="grid gap-4 sm:grid-cols-2">
          <ContextRow label="Worker type" value={employmentTypeLabels[employee.employment_type] || employee.employment_type} />
          <ContextRow label="Pay rate" value={formatCurrency(Number(employee.pay_rate) || 0)} />
          <ContextRow label="Pay frequency" value={payFrequencyLabels[employee.pay_frequency] || employee.pay_frequency} />
          <ContextRow label="Salary treatment" value={employee.salary_type?.replace('_', ' ') || 'Not applicable'} />
          <ContextRow label="Active wage rates" value={String(wageRateCount || 1)} />
          <ContextRow label="Recurring adjustments" value={String(adjustmentCount)} />
          <ContextRow label="Traditional retirement" value={`${(Number(employee.retirement_rate || 0) * 100).toFixed(2)}%`} />
          <ContextRow label="Roth retirement" value={`${(Number(employee.roth_retirement_rate || 0) * 100).toFixed(2)}%`} />
        </CardContent>
      </Card>
      <Card className="border-primary-100 bg-primary-50/50">
        <CardContent className="p-6">
          <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-white text-primary-700 shadow-sm"><Settings2 className="h-5 w-5" /></span>
          <h2 className="mt-4 font-display text-xl font-extrabold tracking-tight text-neutral-950">Edit source settings</h2>
          <p className="mt-2 text-sm leading-6 text-neutral-600">Changes happen on the existing validated employee form. Saving returns to this workspace.</p>
          <Link className="mt-4 inline-flex min-h-11 items-center gap-2 rounded-full bg-primary-700 px-4 text-sm font-semibold text-white hover:bg-primary-800" to={editHref}><Pencil className="h-4 w-4" />Edit payroll setup</Link>
        </CardContent>
      </Card>
    </div>
  );
}

interface PayHistoryProps {
  companyId: number;
  report: PayHistoryReport | null;
  returnTo: string;
}

function PayHistory({ companyId, report, returnTo }: PayHistoryProps): ReactElement {
  return (
    <Card>
      <CardHeader><CardTitle>Pay history</CardTitle><p className="mt-2 text-sm text-neutral-500">Committed Cornerstone payroll and linked QuickBooks history appear together. Imported records are locked and cannot be edited or recalculated here.</p></CardHeader>
      <CardContent className="p-0">
        {!report ? (
          <p className="px-6 py-10 text-center text-sm text-amber-800">Pay history could not be loaded. Use Try again above without leaving this employee.</p>
        ) : report.history.length === 0 ? (
          <p className="px-6 py-10 text-center text-sm text-neutral-500">No committed payroll records are available for this employee.</p>
        ) : (
          <Table>
            <TableHeader><TableRow><TableHead>Pay date</TableHead><TableHead>Pay run</TableHead><TableHead>Source</TableHead><TableHead>Gross</TableHead><TableHead>Deductions</TableHead><TableHead>Net</TableHead><TableHead>Check</TableHead><TableHead className="text-right">Record</TableHead></TableRow></TableHeader>
            <TableBody striped>
              {report.history.map((item) => (
                <TableRow key={item.key}>
                  <TableCell className="font-semibold text-neutral-950">{formatDate(item.pay_date)}</TableCell>
                  <TableCell><Link className="font-semibold text-primary-700 hover:text-primary-900" to={payHistoryRunPath(companyId, item, returnTo)}>{item.period_description}</Link></TableCell>
                  <TableCell><Badge variant={item.record_type === 'native' ? 'default' : 'warning'}>{item.source.label}</Badge></TableCell>
                  <TableCell>{formatCurrency(item.gross_pay)}</TableCell>
                  <TableCell>{formatCurrency(item.total_deductions)}</TableCell>
                  <TableCell className="font-semibold text-emerald-700">{formatCurrency(item.net_pay)}</TableCell>
                  <TableCell>{item.check_number || 'Not assigned'}</TableCell>
                  <TableCell className="text-right"><Link aria-label={`Open ${item.record_type === 'native' ? 'payroll item' : 'imported pay run'} for ${formatDate(item.pay_date)}`} className="inline-flex min-h-11 items-center gap-1 font-bold text-primary-700 hover:text-primary-900" to={item.record_type === 'native' && item.pay_period_id && item.payroll_item_id ? payrollItemPath(companyId, item.pay_period_id, item.payroll_item_id, { returnTo }) : payHistoryRunPath(companyId, item, returnTo)}>Open <ArrowRight className="h-4 w-4" /></Link></TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </CardContent>
    </Card>
  );
}

function payHistoryRunPath(companyId: number, item: PayHistoryReport['history'][number], returnTo: string): string {
  if (item.record_type !== 'native') {
    return item.historical_pay_period_id
      ? importedPayRunPath(companyId, item.historical_pay_period_id, { returnTo })
      : returnTo;
  }
  return item.pay_period_id ? payRunPath(companyId, item.pay_period_id, 'overview', { returnTo }) : returnTo;
}

interface EmployeeActivityProps {
  companyId: number;
  employee: Employee;
  returnTo: string;
}

function EmployeeActivity({ companyId, employee, returnTo }: EmployeeActivityProps): ReactElement {
  const events = employee.status_history || [];
  return (
    <div className="grid gap-6 lg:grid-cols-[minmax(0,1.35fr)_minmax(280px,0.65fr)]">
      <Card>
        <CardHeader><CardTitle>Employment activity</CardTitle><p className="mt-2 text-sm text-neutral-500">Authoritative lifecycle events recorded for this employee.</p></CardHeader>
        <CardContent>
          {events.length ? <ol className="space-y-4">{events.map((event) => <li key={event.id} className="grid gap-4 border-l-2 border-primary-100 pl-4 sm:grid-cols-[minmax(0,1fr)_auto]"><div><p className="font-semibold capitalize text-neutral-950">{event.event_type.replace('_', ' ')}</p><p className="mt-2 text-sm text-neutral-600">{event.previous_status} to {event.resulting_status}{event.reason_category ? ` · ${event.reason_category.replace('_', ' ')}` : ''}</p>{event.internal_notes && <p className="mt-2 text-sm leading-6 text-neutral-500">{event.internal_notes}</p>}</div><div className="text-sm text-neutral-500 sm:text-right"><p className="font-semibold text-neutral-700">Effective {formatDate(event.effective_date)}</p><p>{formatGuamDateTime(event.created_at)}</p>{event.actor_name && <p>by {event.actor_name}</p>}</div></li>)}</ol> : <p className="text-sm text-neutral-500">No termination or reactivation events have been recorded.</p>}
        </CardContent>
      </Card>
      <Card>
        <CardHeader><CardTitle>Classification history</CardTitle></CardHeader>
        <CardContent className="space-y-3">
          {employee.classification_history?.previous_employee && <ClassificationLink label="Previous worker record" companyId={companyId} employee={employee.classification_history.previous_employee} returnTo={returnTo} />}
          {employee.classification_history?.next_employee && <ClassificationLink label="Next worker record" companyId={companyId} employee={employee.classification_history.next_employee} returnTo={returnTo} />}
          {!employee.classification_history?.previous_employee && !employee.classification_history?.next_employee && <p className="text-sm leading-6 text-neutral-500">No linked worker-classification transition is recorded.</p>}
        </CardContent>
      </Card>
    </div>
  );
}

interface ClassificationLinkProps {
  label: string;
  companyId: number;
  employee: NonNullable<Employee['classification_history']>['previous_employee'];
  returnTo: string;
}

function ClassificationLink({ label, companyId, employee, returnTo }: ClassificationLinkProps): ReactElement | null {
  if (!employee) return null;
  return <Link to={employeePath(companyId, employee.id, 'activity', { returnTo })} className="group block rounded-xl border border-neutral-200 p-4 transition hover:border-primary-300 hover:bg-primary-50/40"><p className="text-xs font-bold uppercase tracking-wide text-neutral-400">{label}</p><p className="mt-2 font-semibold text-neutral-950 group-hover:text-primary-800">{employee.name}</p><p className="mt-2 text-xs capitalize text-neutral-500">{employee.tax_classification} · {employee.status}</p></Link>;
}

interface MetricProps {
  icon: typeof Banknote;
  label: string;
  value: string;
  detail: string;
}

function Metric({ icon: Icon, label, value, detail }: MetricProps): ReactElement {
  return <Card><CardContent className="p-4"><span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-primary-50 text-primary-700"><Icon className="h-5 w-5" /></span><p className="mt-4 text-xs font-bold uppercase tracking-[0.12em] text-neutral-400">{label}</p><p className="mt-2 font-display text-2xl font-extrabold tracking-tight text-neutral-950">{value}</p><p className="mt-2 text-sm text-neutral-500">{detail}</p></CardContent></Card>;
}

interface ContextRowProps {
  label: string;
  value: string;
}

function ContextRow({ label, value }: ContextRowProps): ReactElement {
  return <div><p className="text-xs font-bold uppercase tracking-[0.12em] text-neutral-400">{label}</p><p className="mt-2 text-sm font-semibold capitalize text-neutral-800">{value}</p></div>;
}
