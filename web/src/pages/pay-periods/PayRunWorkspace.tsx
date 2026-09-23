import { lazy, Suspense, useCallback, useEffect, useRef, useState, type ReactElement } from 'react';
import {
  Activity,
  ArrowLeft,
  ArrowRight,
  Banknote,
  CalendarCheck2,
  CheckCircle2,
  ClipboardList,
  FileClock,
  LockKeyhole,
  Printer,
  RefreshCw,
  ReceiptText,
  UsersRound,
} from 'lucide-react';
import { Link, Navigate, useLocation, useParams, useSearchParams } from 'react-router';
import { useCompany } from '@/contexts/CompanyContext';
import { useAuth } from '@/contexts/AuthContext';
import { Header } from '@/components/layout/Header';
import { ChecksPanel } from '@/components/payroll/ChecksPanel';
import { UnifiedCheckPrintDialog } from '@/components/checks/UnifiedCheckPrintDialog';
import { PdfPreview, type PdfArtifact } from '@/components/documents/PdfPreview';
import { WorkspaceTabs } from '@/components/records/WorkspaceTabs';
import { WorkspaceLoader } from '@/components/records/WorkspaceLoader';
import { RecordActivityTimeline } from '@/components/records/RecordActivityTimeline';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { HelpTip } from '@/components/ui/help-tip';
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
import { countActivePayrollChecks, parsePayRunId } from '@/lib/pay-run-filters';
import { parsePositiveRouteId } from '@/lib/route-params';
import { checksApi, payPeriodsApi, payrollItemsApi } from '@/services/api';
import type { PromotedPaymentPreview } from '@/services/api';
import type { PayPeriod, PayrollItem, PaymentDeliveryMethod } from '@/types';

const PayPeriodDetail = lazy(() => import('@/pages/PayPeriodDetail').then((module) => ({ default: module.PayPeriodDetail })));

const tabs: Array<{ id: PayRunWorkspaceTab; label: string; icon: typeof ClipboardList }> = [
  { id: 'overview', label: 'Overview', icon: ClipboardList },
  { id: 'work', label: 'Process payroll', icon: Banknote },
  { id: 'checks', label: 'Checks & direct deposit', icon: Printer },
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
  const companyId = parsePositiveRouteId(companyIdParam) ?? 0;
  const payRunId = parsePayRunId(idParam) ?? 0;
  const activeTab = tabIds.has(tabParam as PayRunWorkspaceTab) ? tabParam as PayRunWorkspaceTab : 'overview';
  const location = useLocation();
  const { activeCompany } = useCompany();
  const [searchParams] = useSearchParams();
  const [payRun, setPayRun] = useState<(PayPeriod & { payroll_items?: PayrollItem[] }) | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [resolvedRouteKey, setResolvedRouteKey] = useState<string | null>(null);
  const loadRequestIdRef = useRef(0);
  const routeKey = `${companyId}:${payRunId}`;
  const hasValidRouteIds = [companyId, payRunId].every((value) => Number.isInteger(value) && value > 0);
  const [mountedProcessingPayRunId, setMountedProcessingPayRunId] = useState<number | null>(
    activeTab === 'work' ? payRunId : null,
  );

  const load = useCallback(async (): Promise<void> => {
    const requestId = ++loadRequestIdRef.current;
    const isCurrentRequest = (): boolean => loadRequestIdRef.current === requestId;

    if (!hasValidRouteIds) {
      setPayRun(null);
      setError('This pay-run workspace link is invalid.');
      setResolvedRouteKey(routeKey);
      setLoading(false);
      return;
    }

    setLoading(true);
    setResolvedRouteKey(null);
    setError(null);
    setPayRun(null);
    try {
      const response = await payPeriodsApi.get(payRunId, companyId);
      if (isCurrentRequest()) {
        setPayRun(response.pay_period);
        setResolvedRouteKey(routeKey);
      }
    } catch (loadError) {
      if (isCurrentRequest()) {
        setError(loadError instanceof Error ? loadError.message : 'Could not load this pay-run workspace.');
        setResolvedRouteKey(routeKey);
      }
    } finally {
      if (isCurrentRequest()) setLoading(false);
    }
  }, [companyId, hasValidRouteIds, payRunId, routeKey]);

  useEffect((): (() => void) => {
    void load();

    return (): void => {
      loadRequestIdRef.current += 1;
    };
  }, [load]);

  useEffect(() => {
    if (activeTab === 'work') setMountedProcessingPayRunId(payRunId);
  }, [activeTab, payRunId]);

  const handlePayRunChange = useCallback((updated: PayPeriod): void => {
    setPayRun((current) => current?.id === updated.id
      ? { ...current, ...updated, payroll_items: updated.payroll_items ?? current.payroll_items }
      : current);
  }, []);

  const payRunListFallback = Number.isInteger(companyId) && companyId > 0 ? payRunsPath(companyId) : '/pay-periods';
  const returnTo = safeInternalReturnPath(searchParams.get('return_to'), payRunListFallback);

  if (hasValidRouteIds && tabParam && !tabIds.has(tabParam as PayRunWorkspaceTab)) {
    return <Navigate to={payRunPath(companyId, payRunId, 'overview', { returnTo })} replace />;
  }

  const currentPath = currentAppPath(location.pathname, location.search);

  if (loading || resolvedRouteKey !== routeKey) {
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
            <div className="mt-4 flex flex-wrap gap-4"><Button onClick={() => void load()}><RefreshCw className="mr-2 h-4 w-4" />Try again</Button><Link className="inline-flex min-h-11 items-center gap-2 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-700" to={returnTo}><ArrowLeft className="h-4 w-4" />Back to pay runs</Link></div>
          </CardContent>
        </Card>
      </div>
    );
  }

  const isTrainingBaseline = payRun.test_workspace_role === 'baseline';
  const readOnlyWorkspace = activeCompany?.id === companyId && (
    activeCompany.test_workspace_purpose === 'backup_snapshot'
      || Boolean(activeCompany.test_workspace_sealed_at)
  );
  const readOnlyMode: 'training_baseline' | 'backup_snapshot' | null = isTrainingBaseline
    ? 'training_baseline'
    : readOnlyWorkspace
      ? 'backup_snapshot'
      : null;
  if (readOnlyMode && (activeTab === 'work' || activeTab === 'checks')) {
    return <Navigate to={payRunPath(companyId, payRunId, 'overview', { returnTo })} replace />;
  }

  const items = payRun.payroll_items || [];
  const reportableItems = items.filter((item) => !item.voided);
  const statusConfig = payPeriodStatusConfig[payRun.status];

  return (
    <div>
      <Header
        title={`Pay Period: ${formatDateRange(payRun.start_date, payRun.end_date)}`}
        description={`Pay date ${formatDate(payRun.pay_date)} · ${runPurposeLabels[payRun.run_purpose] || payRun.run_purpose}`}
        actions={<div className="flex w-full flex-wrap gap-2 sm:w-auto sm:justify-end"><Link className="inline-flex min-h-11 items-center gap-2 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-700 transition hover:border-primary-300 hover:text-primary-800" to={returnTo}><ArrowLeft className="h-4 w-4" />Back</Link>{!readOnlyMode && activeTab !== 'work' && <Link className="inline-flex min-h-11 items-center gap-2 rounded-full bg-primary-700 px-4 text-sm font-semibold text-white transition hover:bg-primary-800" to={payRunPath(companyId, payRunId, 'work', { returnTo })} preventScrollReset><Banknote className="h-4 w-4" />Open processing</Link>}</div>}
      />

      <section className="border-b border-neutral-200 bg-neutral-50/70 px-4 py-3 sm:px-6 lg:px-8" aria-label="Pay run identity">
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant={payRun.correction_status === 'voided' ? 'danger' : payRun.status === 'committed' ? 'success' : payRun.status === 'approved' ? 'info' : payRun.status === 'calculated' ? 'warning' : 'default'}>{payRun.correction_status === 'voided' ? 'Voided' : statusConfig?.label || payRun.status}</Badge>
          <Badge variant={payRun.run_purpose === 'regular' ? 'default' : 'warning'}>{runPurposeLabels[payRun.run_purpose] || payRun.run_purpose}</Badge>
          {!readOnlyWorkspace && payRun.parallel_run && <span className="inline-flex items-center"><Badge variant="info"><LockKeyhole className="mr-2 h-3.5 w-3.5" />Parallel comparison · cannot commit</Badge><HelpTip label="parallel comparison">This run is isolated from live payroll actions. It can be calculated and reviewed, but never committed, paid, printed, or filed.</HelpTip></span>}
          {isTrainingBaseline && <span className="inline-flex items-center"><Badge variant="warning"><LockKeyhole className="mr-2 h-3.5 w-3.5" />Locked reference history</Badge><HelpTip label="locked reference history">This copied payroll is view-only and preserves the year-to-date starting point for safe testing.</HelpTip></span>}
          {readOnlyWorkspace && <span className="inline-flex items-center"><Badge variant="warning"><LockKeyhole className="mr-2 h-3.5 w-3.5" />Read-only snapshot</Badge><HelpTip label="read-only snapshot">This sealed backup is a recovery record. No payroll or employee data can be changed here.</HelpTip></span>}
          <span className="text-sm font-medium text-neutral-500">Pay run #{payRun.id}</span>
        </div>
      </section>

      <WorkspaceTabs label="Pay-run workspace sections" tabs={tabs.filter((tab) => !readOnlyMode || (tab.id !== 'work' && tab.id !== 'checks')).map((tab) => ({
        ...tab,
        href: payRunPath(companyId, payRunId, tab.id, { returnTo }),
        count: tab.id === 'checks'
          ? countActivePayrollChecks(items) + items.filter((item) => !item.voided && item.effective_payment_delivery_method === 'direct_deposit' && Number(item.net_pay || 0) > 0).length
          : undefined,
      }))} />

      <main className="min-h-[24rem] space-y-6 p-4 sm:p-6 lg:p-8">
        {activeTab === 'overview' && <PayRunOverview companyId={companyId} payRun={payRun} items={reportableItems} returnTo={currentPath} workspaceReturnTo={returnTo} readOnlyMode={readOnlyMode} />}
        {activeTab === 'checks' && <PayRunChecks companyId={companyId} payRun={payRun} items={items} returnTo={currentPath} workspaceReturnTo={returnTo} onChanged={handlePayRunChange} isRehearsal={activeCompany?.id === companyId && activeCompany.payroll_environment === 'migration_rehearsal'} />}
        {activeTab === 'activity' && <PayRunActivity companyId={companyId} payRun={payRun} workspaceReturnTo={returnTo} />}
        {(mountedProcessingPayRunId === payRunId || activeTab === 'work') && (
          <section hidden={activeTab !== 'work'} aria-label="Process payroll workspace">
            <Suspense fallback={<WorkspaceLoader label="Loading payroll processing tools" minHeightClassName="min-h-[24rem]" />}>
              <PayPeriodDetail
                key={`${companyId}:${payRunId}`}
                initialPayPeriod={payRun}
                onPayPeriodChange={handlePayRunChange}
              />
            </Suspense>
          </section>
        )}
      </main>
    </div>
  );
}

interface PayRunOverviewProps {
  companyId: number;
  payRun: PayPeriod;
  items: PayrollItem[];
  returnTo: string;
  workspaceReturnTo: string;
  readOnlyMode: 'training_baseline' | 'backup_snapshot' | null;
}

function PayRunOverview({ companyId, payRun, items, returnTo, workspaceReturnTo, readOnlyMode }: PayRunOverviewProps): ReactElement {
  const totalGross = items.reduce((sum, item) => sum + Number(item.gross_pay || 0), 0);
  const totalNet = items.reduce((sum, item) => sum + Number(item.net_pay || 0), 0);
  const sourceCount = new Set(items.map((item) => item.import_source || item.timekeeping_source || 'manual')).size;
  const readOnly = readOnlyMode !== null;
  const recordsTitle = readOnlyMode === 'training_baseline'
    ? 'Locked reference records'
    : readOnlyMode === 'backup_snapshot'
      ? 'Read-only payroll records'
      : 'Payroll records';
  const recordsDescription = readOnlyMode === 'training_baseline'
    ? 'These verified results provide year-to-date context and cannot be edited.'
    : readOnlyMode === 'backup_snapshot'
      ? 'This sealed backup is preserved for review and recovery. It cannot be changed.'
      : 'Open an employee or the exact calculated result.';
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
          <CardHeader className="flex-row items-center justify-between gap-4"><div><CardTitle>{recordsTitle}</CardTitle><p className="mt-2 text-sm text-neutral-500">{recordsDescription}</p></div>{!readOnly && <Link className="text-sm font-bold text-primary-700 hover:text-primary-900" to={payRunPath(companyId, payRun.id, 'work', { returnTo })}>Process payroll</Link>}</CardHeader>
          <CardContent className="p-0">
            {items.length ? <div className="divide-y divide-neutral-100">{items.slice(0, 10).map((item) => <div key={item.id} className="grid gap-4 px-4 py-4 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center sm:px-6"><div><Link className="font-semibold text-neutral-950 hover:text-primary-800" to={employeePath(companyId, item.employee_id, 'overview', { returnTo })}>{item.employee_name}</Link><p className="mt-2 text-xs capitalize text-neutral-500">{item.employment_type} · {item.import_source || item.timekeeping_source || 'manual input'}</p></div><div className="flex items-center gap-4"><div className="text-right"><p className="font-semibold text-neutral-950">{formatCurrency(Number(item.net_pay || 0))}</p><p className="text-xs text-neutral-500">{formatCurrency(Number(item.gross_pay || 0))} gross</p></div>{!readOnly && <Link aria-label={`Open payroll item for ${item.employee_name}`} className="inline-flex min-h-11 items-center gap-1 rounded-full border border-neutral-300 px-4 text-sm font-bold text-primary-700 hover:border-primary-300 hover:bg-primary-50" to={payrollItemPath(companyId, payRun.id, item.id, { returnTo })}>Open <ArrowRight className="h-4 w-4" /></Link>}</div></div>)}</div> : readOnly ? <div className="px-6 py-10 text-center text-sm text-neutral-500">No payroll records were preserved for this period.</div> : <WorkspaceEmptyState icon={UsersRound} message="No payroll records have been added to this run yet." actionLabel="Process payroll" actionHref={payRunPath(companyId, payRun.id, 'work', { returnTo: workspaceReturnTo })} />}
          </CardContent>
        </Card>
        <div className="space-y-6">
          <Card><CardHeader><CardTitle>Run context</CardTitle></CardHeader><CardContent className="space-y-4"><ContextRow label="Pay date" value={formatDate(payRun.pay_date)} /><ContextRow label="Run purpose" value={runPurposeLabels[payRun.run_purpose] || payRun.run_purpose} /><ContextRow label="Base salary" value={payRun.includes_base_salary ? 'Included' : 'Excluded'} /><ContextRow label="Recurring employee setup" value={payRun.includes_recurring_items ? 'Included' : 'Excluded'} /><ContextRow label="Cycle" value={payRun.cycle || 'regular'} /></CardContent></Card>
          {payRun.notes && <Card className="border-blue-100 bg-blue-50/60"><CardContent className="p-4"><p className="text-xs font-bold uppercase tracking-wide text-blue-700">Pay-run notes</p><p className="mt-2 whitespace-pre-wrap text-sm leading-6 text-blue-950">{payRun.notes}</p></CardContent></Card>}
        </div>
      </div>
    </>
  );
}

interface PayRunChecksProps {
  companyId: number;
  payRun: PayPeriod;
  items: PayrollItem[];
  returnTo: string;
  workspaceReturnTo: string;
  onChanged: (payRun: PayPeriod) => void;
  isRehearsal: boolean;
}

function PayRunChecks({ companyId, payRun, items, returnTo, workspaceReturnTo, onChanged, isRehearsal }: PayRunChecksProps): ReactElement {
  const { isAdmin } = useAuth();
  const [checkPrintOpen, setCheckPrintOpen] = useState(false);
  const [mockPreviewBusy, setMockPreviewBusy] = useState(false);
  const [mockPreviewError, setMockPreviewError] = useState<string | null>(null);
  const [mockPreview, setMockPreview] = useState<PdfArtifact | null>(null);
  const [checkPrintRefreshToken, setCheckPrintRefreshToken] = useState(0);
  const [hasNonEmployeeChecks, setHasNonEmployeeChecks] = useState<boolean | null>(null);
  const [printRefreshError, setPrintRefreshError] = useState<string | null>(null);
  const [switchItem, setSwitchItem] = useState<PayrollItem | null>(null);
  const [switchReason, setSwitchReason] = useState('');
  const [confirmNotPaid, setConfirmNotPaid] = useState(false);
  const [switchBusy, setSwitchBusy] = useState(false);
  const [switchError, setSwitchError] = useState<string | null>(null);
  const [paymentPreview, setPaymentPreview] = useState<PromotedPaymentPreview | null>(null);
  const [paymentPreviewBusy, setPaymentPreviewBusy] = useState(false);
  const [paymentPreviewError, setPaymentPreviewError] = useState<string | null>(null);
  const [paymentDialogOpen, setPaymentDialogOpen] = useState(false);
  const [paymentStartingNumber, setPaymentStartingNumber] = useState('');
  const [paymentCheckDate, setPaymentCheckDate] = useState('');
  const [paymentConfirmed, setPaymentConfirmed] = useState(false);
  const [paymentBusy, setPaymentBusy] = useState(false);
  const [paymentError, setPaymentError] = useState<string | null>(null);
  const [paymentNotice, setPaymentNotice] = useState<string | null>(null);
  const nextMethod: PaymentDeliveryMethod = switchItem?.effective_payment_delivery_method === 'direct_deposit' ? 'paper_check' : 'direct_deposit';
  const mockPreviewEligible = items.filter((item) => !item.voided && item.effective_payment_delivery_method !== 'direct_deposit' && Number(item.net_pay || 0) > 0).length;
  const canPreviewMockChecks = isRehearsal && (payRun.status === 'calculated' || payRun.status === 'approved');
  const recordOnlyPromoted = !isRehearsal && payRun.status === 'committed' &&
    Boolean(payRun.promotion_source_pay_period_id) && payRun.promotion_payment_disposition === 'record_only' &&
    countActivePayrollChecks(items) === 0;

  useEffect(() => {
    setPaymentPreview(null);
    setPaymentPreviewError(null);
    if (!recordOnlyPromoted || !isAdmin) return;

    let active = true;
    setPaymentPreviewBusy(true);
    void payPeriodsApi.promotedPaymentPreview(payRun.id).then((response) => {
      if (!active) return;
      setPaymentPreview(response.promoted_payment);
      setPaymentStartingNumber(response.promoted_payment.suggested_first_check_number || String(response.promoted_payment.current_next_check_number));
    }).catch((error) => {
      if (active) setPaymentPreviewError(error instanceof Error ? error.message : 'Could not verify this promoted payroll.');
    }).finally(() => {
      if (active) setPaymentPreviewBusy(false);
    });

    return () => { active = false; };
  }, [isAdmin, payRun.id, recordOnlyPromoted]);

  const previewMockChecks = async () => {
    setMockPreviewBusy(true);
    setMockPreviewError(null);
    try {
      const result = await checksApi.rehearsalPreviewPdf(payRun.id);
      setMockPreview({
        blob: result.blob,
        filename: result.filename || 'void_rehearsal_checks.pdf',
        title: 'Preview rehearsal checks',
        note: 'Every check is marked VOID. This rehearsal copy cannot be used for payment. Review here, then print on plain paper or download a copy.',
      });
    } catch (error) {
      setMockPreviewError(error instanceof Error ? error.message : 'Could not prepare the rehearsal checks.');
    } finally {
      setMockPreviewBusy(false);
    }
  };

  useEffect(() => {
    setHasNonEmployeeChecks(null);
    if (payRun.status !== 'committed') return;
    let active = true;
    void checksApi.printQueue(payRun.id).then((queue) => {
      if (active) setHasNonEmployeeChecks(queue.items.some((item) => item.kind === 'non_employee' && item.status !== 'voided'));
    }).catch(() => {
      if (active) setHasNonEmployeeChecks(null);
    });
    return () => { active = false; };
  }, [payRun.id, payRun.status, checkPrintRefreshToken]);

  const resetSwitchDialog = () => {
    setSwitchItem(null);
    setSwitchReason('');
    setConfirmNotPaid(false);
    setSwitchError(null);
  };

  const handlePrintConfirmed = () => {
    setCheckPrintRefreshToken((value) => value + 1);
    void payPeriodsApi.get(payRun.id, companyId).then((updated) => {
      onChanged(updated.pay_period);
      setPrintRefreshError(null);
    }).catch(() => {
      setPrintRefreshError('Checks were saved, but the pay-run summary could not refresh. Reopen this run to see the latest status.');
    });
  };

  const switchPaymentMethod = async () => {
    if (!switchItem || switchReason.trim().length < 10 || !confirmNotPaid) return;
    setSwitchBusy(true);
    setSwitchError(null);
    try {
      await payrollItemsApi.updatePaymentMethod(payRun.id, switchItem.id, nextMethod, {
        reason: switchReason.trim(),
        confirm_not_paid: true,
      });
      const updated = await payPeriodsApi.get(payRun.id, companyId);
      onChanged(updated.pay_period);
      setCheckPrintRefreshToken((value) => value + 1);
      resetSwitchDialog();
    } catch (error) {
      setSwitchError(error instanceof Error ? error.message : 'Could not switch payment method.');
    } finally {
      setSwitchBusy(false);
    }
  };

  const resetPaymentDialog = () => {
    setPaymentDialogOpen(false);
    setPaymentCheckDate('');
    setPaymentConfirmed(false);
    setPaymentError(null);
  };

  const preparePromotedPayment = async () => {
    if (!paymentPreview?.eligible || !paymentCheckDate || !paymentStartingNumber || !paymentConfirmed) return;
    setPaymentBusy(true);
    setPaymentError(null);
    try {
      const response = await payPeriodsApi.preparePromotedPayment(payRun.id, {
        acknowledgement: 'PREPARE PROMOTED PAYROLL FOR PAYMENT',
        starting_check_number: paymentStartingNumber,
        check_date: paymentCheckDate,
      });
      onChanged(response.pay_period);
      setPaymentPreview(response.promoted_payment);
      setPaymentNotice(response.promoted_payment.paper_check_count === 1
        ? '1 check is numbered and ready to review and print.'
        : `${response.promoted_payment.paper_check_count} checks are numbered and ready to review and print.`);
      setCheckPrintRefreshToken((value) => value + 1);
      resetPaymentDialog();
      setCheckPrintOpen(true);
    } catch (error) {
      setPaymentError(error instanceof Error ? error.message : 'Could not prepare this promoted payroll for payment.');
    } finally {
      setPaymentBusy(false);
    }
  };

  return (
    <>
      <PdfPreview artifact={mockPreview} onClose={() => setMockPreview(null)} />
      {paymentNotice && (
        <div role="status" className="rounded-xl border border-success-200 bg-success-50 px-4 py-3 text-sm text-success-900">
          <strong>Ready to print.</strong> {paymentNotice}
        </div>
      )}
      {recordOnlyPromoted && (
        <Card className="border-amber-200 bg-amber-50/70">
          <CardContent className="flex flex-col gap-4 p-5 sm:flex-row sm:items-center sm:justify-between">
            <div className="max-w-3xl">
              <p className="text-xs font-bold uppercase tracking-[0.12em] text-amber-800">Promoted payroll is recorded but unpaid</p>
              <h2 className="mt-2 text-lg font-semibold text-neutral-950">Prepare the original checks before printing</h2>
              <p className="mt-2 text-sm leading-6 text-neutral-700">
                This payroll was copied as a historical record, so check numbers were intentionally left blank. Preparing it assigns paper-check numbers once without recalculating pay or adding YTD, loan, or liability amounts again.
              </p>
              {!isAdmin && <p className="mt-2 text-sm font-medium text-amber-900">Ask an organization administrator to prepare this payroll. Accountants and managers can use the normal check workflow after that.</p>}
              {paymentPreviewBusy && <p role="status" className="mt-2 text-sm text-neutral-600">Verifying that this payroll has no prior payment activity…</p>}
              {paymentPreviewError && <p role="alert" className="mt-2 text-sm text-danger-700">{paymentPreviewError}</p>}
              {paymentPreview && !paymentPreview.eligible && <ul className="mt-2 list-disc space-y-1 pl-5 text-sm text-danger-700">{paymentPreview.blockers.map(blocker => <li key={blocker}>{blocker}</li>)}</ul>}
            </div>
            {isAdmin && (
              <Button
                className="shrink-0"
                onClick={() => setPaymentDialogOpen(true)}
                disabled={paymentPreviewBusy || !paymentPreview?.eligible}
              >
                Prepare checks for payment
              </Button>
            )}
          </CardContent>
        </Card>
      )}
      <Card>
        <CardHeader className="flex-row items-start justify-between gap-4">
          <div>
            <CardTitle>Checks and direct deposit</CardTitle>
            <p className="mt-2 text-sm text-neutral-500">{isRehearsal ? 'Preview VOID-marked rehearsal checks, then print on plain paper or download the PDF. These documents are not payments.' : 'Paper checks and direct-deposit stubs are separate. Printing a stub does not initiate a bank transfer.'}</p>
            {printRefreshError && <p role="alert" className="mt-2 text-sm text-danger-700">{printRefreshError}</p>}
            {mockPreviewError && <p role="alert" className="mt-2 text-sm text-danger-700">{mockPreviewError}</p>}
          </div>
          {canPreviewMockChecks && (
            <Button onClick={() => void previewMockChecks()} disabled={mockPreviewBusy || mockPreviewEligible === 0}>
              <Printer className="mr-2 h-4 w-4" />{mockPreviewBusy ? 'Preparing…' : 'Preview rehearsal checks'}
            </Button>
          )}
          {!isRehearsal && payRun.status === 'committed' && (
            <Button onClick={() => setCheckPrintOpen(true)} disabled={countActivePayrollChecks(items) === 0 && hasNonEmployeeChecks !== true}>
              <Printer className="mr-2 h-4 w-4" />Print checks
            </Button>
          )}
        </CardHeader>
        {isRehearsal && (
          <div role="note" className="mx-4 mb-4 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-950 sm:mx-6">
            <strong>Rehearsal only.</strong> {canPreviewMockChecks ? `The PDF marks every check VOID. ${mockPreviewEligible} positive-net paper check${mockPreviewEligible === 1 ? '' : 's'} available; direct-deposit records are excluded.` : 'Calculate this pay run before previewing rehearsal checks.'} Previewing, downloading, and printing do not assign check numbers or mark checks printed.
          </div>
        )}
        <CardContent className="p-0">
          {items.length ? (
            <Table>
              <TableHeader><TableRow><TableHead>Employee</TableHead><TableHead>Payment method</TableHead><TableHead>Check / stub</TableHead><TableHead>Status</TableHead><TableHead>Gross</TableHead><TableHead>Net</TableHead><TableHead className="text-right">Actions</TableHead></TableRow></TableHeader>
              <TableBody striped>
                {items.map((item) => {
                  const isDeposit = item.effective_payment_delivery_method === 'direct_deposit';
                  const status = item.voided ? 'Voided' : isDeposit ? 'Stub ready' : isRehearsal ? canPreviewMockChecks ? 'Preview ready' : 'Not ready' : item.check_status === 'delivered' ? 'Issued' : item.check_printed_at ? 'Printed' : item.check_number ? 'Assigned' : 'Pending';
                  return (
                    <TableRow key={item.id}>
                      <TableCell><Link className="font-semibold text-primary-700 hover:text-primary-900" to={employeePath(companyId, item.employee_id, 'overview', { returnTo })}>{item.employee_name}</Link></TableCell>
                      <TableCell>{isDeposit ? 'Direct deposit' : 'Paper check'}</TableCell>
                      <TableCell>{isDeposit ? 'Earnings stub' : isRehearsal ? 'Rehearsal preview - no check number' : item.check_number || 'Not assigned'}</TableCell>
                      <TableCell><Badge variant={item.voided ? 'danger' : isDeposit ? 'info' : isRehearsal ? 'warning' : item.check_printed_at ? 'success' : 'default'}>{status}</Badge></TableCell>
                      <TableCell>{formatCurrency(Number(item.gross_pay || 0))}</TableCell>
                      <TableCell>{formatCurrency(Number(item.net_pay || 0))}</TableCell>
                      <TableCell className="text-right">
                        <div className="flex flex-wrap justify-end gap-2">
                          {payRun.status === 'committed' && !item.voided && Number(item.net_pay || 0) > 0 &&
                            (isDeposit || (!item.check_printed_at && !item.check_print_count && item.check_status !== 'printed' && item.check_status !== 'delivered')) && (
                            <Button size="sm" variant="outline" onClick={() => { setSwitchItem(item); setSwitchError(null); }}>Switch for this run</Button>
                          )}
                          <Link className="inline-flex min-h-11 items-center gap-1 font-bold text-primary-700 hover:text-primary-900" to={payrollItemPath(companyId, payRun.id, item.id, { returnTo })}>Open <ArrowRight className="h-4 w-4" /></Link>
                        </div>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          ) : <WorkspaceEmptyState icon={Printer} message="No checks or payment records are available for this run." actionLabel="Back to overview" actionHref={payRunPath(companyId, payRun.id, 'overview', { returnTo: workspaceReturnTo })} />}
        </CardContent>
      </Card>
      {!isRehearsal && payRun.status === 'committed' && (
        <>
          <ChecksPanel payPeriod={payRun} refreshToken={checkPrintRefreshToken} />
          <UnifiedCheckPrintDialog
            open={checkPrintOpen}
            payPeriodId={payRun.id}
            onOpenChange={setCheckPrintOpen}
            onConfirmed={handlePrintConfirmed}
          />
        </>
      )}
      <Dialog open={switchItem !== null} onOpenChange={(open) => { if (!open && !switchBusy) resetSwitchDialog(); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Switch payment method for this run</DialogTitle>
            <DialogDescription>
              {switchItem?.employee_name} will change to {nextMethod === 'paper_check' ? 'paper check' : 'direct deposit'}.
              Pay, taxes, and the employee’s future default stay unchanged.
            </DialogDescription>
          </DialogHeader>
          <p className="text-sm text-neutral-700">
            {nextMethod === 'paper_check'
              ? 'A new check number will be assigned. Do not continue if a bank transfer was already sent.'
              : 'The assigned check number will be retired. A printed, downloaded, delivered, or cleared check must use the correction workflow instead.'}
          </p>
          <Input label="Reason (at least 10 characters)" value={switchReason} onChange={(event) => setSwitchReason(event.target.value)} />
          <label className="flex items-start gap-2 text-sm text-neutral-700">
            <input type="checkbox" className="mt-1" checked={confirmNotPaid} onChange={(event) => setConfirmNotPaid(event.target.checked)} />
            I confirm this payment has not been issued by check or bank transfer.
          </label>
          {switchError && <p role="alert" className="text-sm text-danger-700">{switchError}</p>}
          <DialogFooter>
            <Button variant="outline" onClick={resetSwitchDialog} disabled={switchBusy}>Cancel</Button>
            <Button onClick={() => void switchPaymentMethod()} disabled={switchBusy || switchReason.trim().length < 10 || !confirmNotPaid}>{switchBusy ? 'Switching…' : 'Confirm switch'}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <Dialog open={paymentDialogOpen} onOpenChange={(open) => { if (!open && !paymentBusy) resetPaymentDialog(); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Prepare promoted payroll for payment</DialogTitle>
            <DialogDescription>
              Assign check numbers to the unpaid paper checks. Payroll amounts and financial totals will not be recalculated or posted again.
            </DialogDescription>
          </DialogHeader>
          {paymentPreview && (
            <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm text-neutral-700">
              <p><strong>{paymentPreview.paper_check_count}</strong> paper check{paymentPreview.paper_check_count === 1 ? '' : 's'} totaling <strong>{formatCurrency(Number(paymentPreview.paper_check_total))}</strong></p>
              <p className="mt-1">Suggested range: {paymentPreview.suggested_first_check_number}–{paymentPreview.suggested_last_check_number}</p>
            </div>
          )}
          <div className="grid gap-4 sm:grid-cols-2">
            <Input
              label="First physical check number"
              inputMode="numeric"
              value={paymentStartingNumber}
              onChange={(event) => setPaymentStartingNumber(event.target.value.replace(/\D/g, '').slice(0, 7))}
            />
            <Input
              label="Date to print on checks"
              type="date"
              min={payRun.end_date}
              value={paymentCheckDate}
              onChange={(event) => setPaymentCheckDate(event.target.value)}
            />
          </div>
          <p className="text-sm leading-6 text-neutral-600">Use the actual date Cornerstone will issue these checks. Do not assume or backdate it to the original pay date.</p>
          <label className="flex items-start gap-2 rounded-xl border border-neutral-200 p-4 text-sm text-neutral-700">
            <input type="checkbox" className="mt-1" checked={paymentConfirmed} onChange={(event) => setPaymentConfirmed(event.target.checked)} />
            I confirm this payroll has not been paid by paper check or bank transfer, and these are the original employee payments—not replacements.
          </label>
          {paymentError && <p role="alert" className="text-sm text-danger-700">{paymentError}</p>}
          <DialogFooter>
            <Button variant="outline" onClick={resetPaymentDialog} disabled={paymentBusy}>Cancel</Button>
            <Button onClick={() => void preparePromotedPayment()} disabled={paymentBusy || !paymentStartingNumber || !paymentCheckDate || !paymentConfirmed}>
              {paymentBusy ? 'Preparing checks…' : 'Assign check numbers'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}

interface PayRunActivityProps {
  companyId: number;
  payRun: PayPeriod;
  workspaceReturnTo: string;
}

function PayRunActivity({ companyId, payRun, workspaceReturnTo }: PayRunActivityProps): ReactElement {
  const lifecycle = payRun.lifecycle || {};
  const events = [
    { label: 'Created', event: lifecycle.created, icon: ClipboardList },
    { label: 'Calculated', event: lifecycle.calculated, icon: Banknote },
    { label: 'Approved', event: lifecycle.approved, icon: CheckCircle2 },
    { label: 'Approval rolled back', event: lifecycle.unapproved, icon: RefreshCw },
    { label: 'Committed', event: lifecycle.committed, icon: CalendarCheck2 },
  ].filter((item) => item.event?.timestamp);
  return (
    <div className="grid gap-6 lg:grid-cols-[minmax(0,1.35fr)_minmax(280px,0.65fr)]">
      <RecordActivityTimeline companyId={companyId} recordId={payRun.id} recordType="pay_periods" />
      <Card>
        <CardHeader><CardTitle>Payroll milestones</CardTitle><p className="mt-2 text-sm leading-6 text-neutral-500">The run's key processing states, preserved alongside the complete change history.</p></CardHeader>
        <CardContent>
          {events.length ? <ol className="space-y-4">{events.map(({ label, event, icon: Icon }) => <li key={`${label}-${event?.timestamp}`} className="border-l-2 border-primary-100 pl-4"><span className="flex h-9 w-9 items-center justify-center rounded-xl bg-primary-50 text-primary-700"><Icon className="h-4 w-4" /></span><p className="mt-3 font-semibold text-neutral-950">{label}</p><p className="mt-2 text-sm text-neutral-500">{event?.actor_name ? `by ${event.actor_name}` : 'Actor not recorded'}</p><p className="mt-2 text-xs font-medium text-neutral-600">{formatGuamDateTime(event?.timestamp)}</p></li>)}</ol> : <WorkspaceEmptyState icon={Activity} message="No lifecycle activity has been recorded for this run yet." actionLabel="Back to overview" actionHref={payRunPath(companyId, payRun.id, 'overview', { returnTo: workspaceReturnTo })} />}
        </CardContent>
      </Card>
    </div>
  );
}

interface WorkspaceEmptyStateProps {
  icon: typeof ClipboardList;
  message: string;
  actionLabel: string;
  actionHref: string;
}

function WorkspaceEmptyState({ icon: Icon, message, actionLabel, actionHref }: WorkspaceEmptyStateProps): ReactElement {
  return (
    <div className="flex flex-col items-center px-6 py-10 text-center">
      <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-primary-50 text-primary-700">
        <Icon className="h-5 w-5" />
      </span>
      <p className="mt-4 max-w-md text-sm leading-6 text-neutral-500">{message}</p>
      <Link className="mt-4 inline-flex min-h-11 items-center rounded-full border border-neutral-300 bg-white px-4 text-sm font-bold text-primary-700 transition hover:border-primary-300 hover:bg-primary-50" to={actionHref} preventScrollReset>
        {actionLabel}
      </Link>
    </div>
  );
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
