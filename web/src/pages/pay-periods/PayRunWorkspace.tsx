import { useCallback, useEffect, useState, type ReactElement } from 'react';
import {
  Activity,
  ArrowLeft,
  ArrowRight,
  Banknote,
  CalendarCheck2,
  CheckCircle2,
  ClipboardList,
  FileClock,
  Printer,
  RefreshCw,
  ReceiptText,
  UsersRound,
} from 'lucide-react';
import { Link, Navigate, useLocation, useParams, useSearchParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { WorkspaceTabs } from '@/components/records/WorkspaceTabs';
import { WorkspaceLoader } from '@/components/records/WorkspaceLoader';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { formatCurrency, formatDate, formatDateRange, formatGuamDateTime, payPeriodStatusConfig } from '@/lib/utils';
import {
  currentAppPath,
  employeePath,
  payrollItemPath,
  payRunPath,
  payRunsPath,
  safeInternalReturnPath,
  type PayRunWorkspaceTab,
} from '@/lib/routes';
import { payPeriodsApi } from '@/services/api';
import type { PayPeriod, PayrollItem } from '@/types';

const tabs: Array<{ id: PayRunWorkspaceTab; label: string; icon: typeof ClipboardList }> = [
  { id: 'overview', label: 'Overview', icon: ClipboardList },
  { id: 'work', label: 'Process payroll', icon: Banknote },
  { id: 'checks', label: 'Checks', icon: Printer },
  { id: 'activity', label: 'Activity', icon: Activity },
];
const tabIds = new Set(tabs.map((tab) => tab.id));

const runPurposeLabels: Record<string, string> = {
  regular: 'Regular payroll',
  off_cycle_tips: 'Off-cycle tips',
  bonus: 'Bonus',
  commission: 'Commission',
  correction: 'Correction',
  final: 'Final paycheck',
  adjustment: 'Adjustment',
};

export function PayRunWorkspace(): ReactElement {
  const { companyId: companyIdParam, id: idParam, tab: tabParam } = useParams<{
    companyId: string;
    id: string;
    tab?: string;
  }>();
  const companyId = Number(companyIdParam);
  const payRunId = Number(idParam);
  const activeTab = tabIds.has(tabParam as PayRunWorkspaceTab) ? tabParam as PayRunWorkspaceTab : 'overview';
  const location = useLocation();
  const [searchParams] = useSearchParams();
  const [payRun, setPayRun] = useState<(PayPeriod & { payroll_items?: PayrollItem[] }) | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!Number.isInteger(payRunId) || payRunId < 1) {
      setError('This pay-run workspace link is invalid.');
      setLoading(false);
      return;
    }

    setLoading(true);
    setError(null);
    try {
      const response = await payPeriodsApi.get(payRunId);
      setPayRun(response.pay_period);
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : 'Could not load this pay-run workspace.');
    } finally {
      setLoading(false);
    }
  }, [payRunId]);

  useEffect(() => {
    void load();
  }, [load]);

  const payRunListFallback = payRunsPath(companyId);
  const returnTo = safeInternalReturnPath(searchParams.get('return_to'), payRunListFallback);

  if (tabParam && !tabIds.has(tabParam as PayRunWorkspaceTab)) {
    return <Navigate to={payRunPath(companyId, payRunId, 'overview', { returnTo })} replace />;
  }

  const currentPath = currentAppPath(location.pathname, location.search);

  if (loading) {
    return <WorkspaceLoader label="Loading pay-run workspace" />;
  }

  if (!payRun || error) {
    return (
      <div className="p-4 sm:p-6 lg:p-8">
        <Card className="mx-auto max-w-2xl border-danger-200 bg-danger-50">
          <CardContent className="p-6">
            <p className="text-xs font-bold uppercase tracking-[0.14em] text-danger-700">Pay run unavailable</p>
            <h1 className="mt-2 font-display text-2xl font-extrabold tracking-tight text-neutral-950">This pay-run workspace could not be opened</h1>
            <p className="mt-2 text-sm leading-6 text-neutral-700">{error || 'The pay run may have been removed, or the link may belong to another client.'}</p>
            <div className="mt-5 flex flex-wrap gap-3"><Button onClick={() => void load()}><RefreshCw className="mr-2 h-4 w-4" />Try again</Button><Link className="inline-flex min-h-11 items-center gap-2 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-700" to={returnTo}><ArrowLeft className="h-4 w-4" />Back to pay runs</Link></div>
          </CardContent>
        </Card>
      </div>
    );
  }

  const items = payRun.payroll_items || [];
  const reportableItems = items.filter((item) => !item.voided);
  const statusConfig = payPeriodStatusConfig[payRun.status];

  return (
    <div>
      <Header
        title={formatDateRange(payRun.start_date, payRun.end_date)}
        description={`Pay date ${formatDate(payRun.pay_date)} · ${runPurposeLabels[payRun.run_purpose] || payRun.run_purpose}`}
        actions={<div className="flex w-full flex-wrap gap-2 sm:w-auto sm:justify-end"><Link className="inline-flex min-h-11 items-center gap-2 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-700 transition hover:border-primary-300 hover:text-primary-800" to={returnTo}><ArrowLeft className="h-4 w-4" />Back</Link><Link className="inline-flex min-h-11 items-center gap-2 rounded-full bg-primary-700 px-4 text-sm font-semibold text-white transition hover:bg-primary-800" to={payRunPath(companyId, payRunId, 'work', { returnTo })}><Banknote className="h-4 w-4" />Open processing</Link></div>}
      />

      <section className="border-b border-neutral-200 bg-neutral-50/70 px-4 py-3 sm:px-6 lg:px-8" aria-label="Pay run identity">
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant={payRun.correction_status === 'voided' ? 'danger' : payRun.status === 'committed' ? 'success' : payRun.status === 'approved' ? 'info' : payRun.status === 'calculated' ? 'warning' : 'default'}>{payRun.correction_status === 'voided' ? 'Voided' : statusConfig?.label || payRun.status}</Badge>
          <Badge variant={payRun.run_purpose === 'regular' ? 'default' : 'warning'}>{runPurposeLabels[payRun.run_purpose] || payRun.run_purpose}</Badge>
          <span className="text-sm font-medium text-neutral-500">Pay run #{payRun.id}</span>
        </div>
      </section>

      <WorkspaceTabs label="Pay-run workspace sections" tabs={tabs.map((tab) => ({ ...tab, href: payRunPath(companyId, payRunId, tab.id, { returnTo }), count: tab.id === 'checks' ? items.filter((item) => item.check_number).length : undefined }))} />

      <main className="space-y-6 p-4 sm:p-6 lg:p-8">
        {activeTab === 'overview' && <PayRunOverview companyId={companyId} payRun={payRun} items={reportableItems} returnTo={currentPath} />}
        {activeTab === 'checks' && <PayRunChecks companyId={companyId} payRun={payRun} items={items} returnTo={currentPath} />}
        {activeTab === 'activity' && <PayRunActivity payRun={payRun} />}
        {activeTab === 'work' && (
          <Card>
            <CardContent className="p-6">
              <p className="text-sm text-neutral-600">Payroll processing opens in the dedicated processing view.</p>
              <Link className="mt-4 inline-flex min-h-11 items-center gap-2 rounded-full bg-primary-700 px-4 text-sm font-semibold text-white" to={payRunPath(companyId, payRunId, 'work', { returnTo })}>
                <Banknote className="h-4 w-4" />Open processing
              </Link>
            </CardContent>
          </Card>
        )}
      </main>
    </div>
  );
}

function PayRunOverview({ companyId, payRun, items, returnTo }: { companyId: number; payRun: PayPeriod; items: PayrollItem[]; returnTo: string }): ReactElement {
  const totalGross = items.reduce((sum, item) => sum + Number(item.gross_pay || 0), 0);
  const totalNet = items.reduce((sum, item) => sum + Number(item.net_pay || 0), 0);
  const sourceCount = new Set(items.map((item) => item.import_source || item.timekeeping_source || 'manual')).size;
  return (
    <>
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <Metric icon={UsersRound} label="Payroll records" value={String(items.length)} detail="Employees and contractors" />
        <Metric icon={Banknote} label="Gross payroll" value={formatCurrency(totalGross)} detail="Before taxes and deductions" />
        <Metric icon={ReceiptText} label="Net payroll" value={formatCurrency(totalNet)} detail="Employee and contractor payments" />
        <Metric icon={FileClock} label="Input sources" value={String(sourceCount)} detail="Import, timekeeping, or manual" />
      </div>

      <div className="grid gap-6 lg:grid-cols-[minmax(0,1.4fr)_minmax(280px,0.7fr)]">
        <Card>
          <CardHeader className="flex-row items-center justify-between gap-3"><div><CardTitle>Payroll records</CardTitle><p className="mt-1 text-sm text-neutral-500">Open an employee or the exact calculated result.</p></div><Link className="text-sm font-bold text-primary-700 hover:text-primary-900" to={payRunPath(companyId, payRun.id, 'work', { returnTo })}>Process payroll</Link></CardHeader>
          <CardContent className="p-0">
            {items.length ? <div className="divide-y divide-neutral-100">{items.slice(0, 10).map((item) => <div key={item.id} className="grid gap-3 px-4 py-4 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center sm:px-6"><div><Link className="font-semibold text-neutral-950 hover:text-primary-800" to={employeePath(companyId, item.employee_id, 'overview', { returnTo })}>{item.employee_name}</Link><p className="mt-1 text-xs capitalize text-neutral-500">{item.employment_type} · {item.import_source || item.timekeeping_source || 'manual input'}</p></div><div className="flex items-center gap-4"><div className="text-right"><p className="font-semibold text-neutral-950">{formatCurrency(Number(item.net_pay || 0))}</p><p className="text-xs text-neutral-500">{formatCurrency(Number(item.gross_pay || 0))} gross</p></div><Link aria-label={`Open payroll item for ${item.employee_name}`} className="inline-flex min-h-11 items-center gap-1 rounded-full border border-neutral-300 px-3 text-sm font-bold text-primary-700 hover:border-primary-300 hover:bg-primary-50" to={payrollItemPath(companyId, payRun.id, item.id, { returnTo })}>Open <ArrowRight className="h-4 w-4" /></Link></div></div>)}</div> : <p className="px-6 py-10 text-center text-sm text-neutral-500">No payroll items have been created for this run.</p>}
          </CardContent>
        </Card>
        <div className="space-y-6">
          <Card><CardHeader><CardTitle>Run context</CardTitle></CardHeader><CardContent className="space-y-4"><ContextRow label="Pay date" value={formatDate(payRun.pay_date)} /><ContextRow label="Run purpose" value={runPurposeLabels[payRun.run_purpose] || payRun.run_purpose} /><ContextRow label="Base salary" value={payRun.includes_base_salary ? 'Included' : 'Excluded'} /><ContextRow label="Cycle" value={payRun.cycle || 'regular'} /></CardContent></Card>
          {payRun.notes && <Card className="border-blue-100 bg-blue-50/60"><CardContent className="p-5"><p className="text-xs font-bold uppercase tracking-wide text-blue-700">Pay-run notes</p><p className="mt-2 whitespace-pre-wrap text-sm leading-6 text-blue-950">{payRun.notes}</p></CardContent></Card>}
        </div>
      </div>
    </>
  );
}

function PayRunChecks({ companyId, payRun, items, returnTo }: { companyId: number; payRun: PayPeriod; items: PayrollItem[]; returnTo: string }): ReactElement {
  return (
    <Card>
      <CardHeader><CardTitle>Checks and payment records</CardTitle><p className="mt-1 text-sm text-neutral-500">Check identity stays attached to the exact payroll item.</p></CardHeader>
      <CardContent className="p-0">
        {items.length ? <Table><TableHeader><TableRow><TableHead>Employee</TableHead><TableHead>Check</TableHead><TableHead>Status</TableHead><TableHead>Gross</TableHead><TableHead>Net</TableHead><TableHead className="text-right">Record</TableHead></TableRow></TableHeader><TableBody striped>{items.map((item) => <TableRow key={item.id}><TableCell><Link className="font-semibold text-primary-700 hover:text-primary-900" to={employeePath(companyId, item.employee_id, 'overview', { returnTo })}>{item.employee_name}</Link></TableCell><TableCell>{item.check_number || 'Not assigned'}</TableCell><TableCell><Badge variant={item.voided ? 'danger' : item.check_printed_at ? 'success' : 'default'}>{item.voided ? 'Voided' : item.check_printed_at ? 'Printed' : item.check_number ? 'Assigned' : 'Pending'}</Badge></TableCell><TableCell>{formatCurrency(Number(item.gross_pay || 0))}</TableCell><TableCell>{formatCurrency(Number(item.net_pay || 0))}</TableCell><TableCell className="text-right"><Link className="inline-flex min-h-11 items-center gap-1 font-bold text-primary-700 hover:text-primary-900" to={payrollItemPath(companyId, payRun.id, item.id, { returnTo })}>Open <ArrowRight className="h-4 w-4" /></Link></TableCell></TableRow>)}</TableBody></Table> : <p className="px-6 py-10 text-center text-sm text-neutral-500">No payroll checks or payment records are available.</p>}
      </CardContent>
    </Card>
  );
}

function PayRunActivity({ payRun }: { payRun: PayPeriod }): ReactElement {
  const lifecycle = payRun.lifecycle || {};
  const events = [
    { label: 'Created', event: lifecycle.created, icon: ClipboardList },
    { label: 'Calculated', event: lifecycle.calculated, icon: Banknote },
    { label: 'Approved', event: lifecycle.approved, icon: CheckCircle2 },
    { label: 'Approval rolled back', event: lifecycle.unapproved, icon: RefreshCw },
    { label: 'Committed', event: lifecycle.committed, icon: CalendarCheck2 },
  ].filter((item) => item.event?.timestamp);
  return <Card><CardHeader><CardTitle>Pay-run activity</CardTitle><p className="mt-1 text-sm text-neutral-500">Authoritative lifecycle evidence for this run.</p></CardHeader><CardContent>{events.length ? <ol className="space-y-5">{events.map(({ label, event, icon: Icon }) => <li key={`${label}-${event?.timestamp}`} className="grid gap-3 border-l-2 border-primary-100 pl-4 sm:grid-cols-[auto_minmax(0,1fr)_auto] sm:items-start"><span className="flex h-9 w-9 items-center justify-center rounded-xl bg-primary-50 text-primary-700"><Icon className="h-4 w-4" /></span><div><p className="font-semibold text-neutral-950">{label}</p><p className="mt-1 text-sm text-neutral-500">{event?.actor_name ? `by ${event.actor_name}` : 'Actor not recorded'}</p></div><p className="text-sm font-medium text-neutral-600 sm:text-right">{formatGuamDateTime(event?.timestamp)}</p></li>)}</ol> : <p className="text-sm text-neutral-500">No lifecycle events have been recorded.</p>}</CardContent></Card>;
}

function Metric({ icon: Icon, label, value, detail }: { icon: typeof Banknote; label: string; value: string; detail: string }): ReactElement {
  return <Card><CardContent className="p-5"><span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-primary-50 text-primary-700"><Icon className="h-5 w-5" /></span><p className="mt-4 text-xs font-bold uppercase tracking-[0.12em] text-neutral-400">{label}</p><p className="mt-2 font-display text-2xl font-extrabold tracking-tight text-neutral-950">{value}</p><p className="mt-1 text-sm text-neutral-500">{detail}</p></CardContent></Card>;
}

function ContextRow({ label, value }: { label: string; value: string }): ReactElement {
  return <div><p className="text-xs font-bold uppercase tracking-[0.12em] text-neutral-400">{label}</p><p className="mt-1 text-sm font-semibold capitalize text-neutral-800">{value}</p></div>;
}
