import { useCallback, useEffect, useMemo, useRef, useState, type ReactElement } from 'react';
import {
  AlertTriangle,
  ArchiveRestore,
  Check,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  Eye,
  FileArchive,
  FileCheck2,
  FileSpreadsheet,
  LockKeyhole,
  RefreshCw,
  Search,
  ShieldCheck,
  UploadCloud,
} from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { formatCurrency, formatDateRange } from '@/lib/utils';
import {
  ApiError,
  historicalImportsApi,
  type HistoricalArchiveSummary,
  type HistoricalBreakdownLine,
  type HistoricalImportBatch,
  type HistoricalImportDetail,
  type HistoricalPaycheck,
} from '@/services/api';
import type { PaginationMeta } from '@/types';

const EMPTY_META: PaginationMeta = { current_page: 1, total_pages: 0, total_count: 0, per_page: 50 };

function dollars(value?: string | number | null): string {
  return formatCurrency(Number(value || 0));
}

function shortDate(value?: string | null): string {
  if (!value) return '—';
  return new Date(`${value}T00:00:00`).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function fieldLabel(field: string): string {
  return field.replaceAll('_', ' ').replace(/^./, (letter) => letter.toUpperCase());
}

function statusBadge(status: HistoricalImportBatch['status']): ReactElement {
  if (status === 'locked') return <Badge variant="success"><LockKeyhole className="mr-1 h-3 w-3" />Locked</Badge>;
  if (status === 'applied') return <Badge variant="info"><FileCheck2 className="mr-1 h-3 w-3" />Applied</Badge>;
  if (status === 'failed') return <Badge variant="danger">Failed</Badge>;
  return <Badge variant="warning">Preview</Badge>;
}

interface MetricProps {
  label: string;
  value: string;
  note?: string;
}

function Metric({ label, value, note }: MetricProps): ReactElement {
  return (
    <div className="border-l-2 border-primary-200 pl-4">
      <p className="text-[11px] font-bold uppercase tracking-[0.13em] text-neutral-500">{label}</p>
      <p className="mt-1 font-display text-2xl font-extrabold tracking-tight text-neutral-950">{value}</p>
      {note && <p className="mt-1 text-xs text-neutral-500">{note}</p>}
    </div>
  );
}

interface BreakdownProps {
  title: string;
  lines: HistoricalBreakdownLine[];
  unit?: 'currency' | 'hours';
}

function Breakdown({ title, lines, unit = 'currency' }: BreakdownProps): ReactElement | null {
  if (lines.length === 0) return null;
  return (
    <section>
      <h3 className="text-xs font-bold uppercase tracking-[0.12em] text-neutral-500">{title}</h3>
      <div className="mt-2 divide-y divide-neutral-100 rounded-xl border border-neutral-200 bg-neutral-50/70 px-3">
        {lines.map((line, index) => (
          <div key={`${line.label}-${index}`} className="flex items-center justify-between gap-4 py-2 text-sm">
            <span className="text-neutral-700">{line.label}</span>
            <span className="font-mono font-semibold tabular-nums text-neutral-950">
              {unit === 'hours' ? `${Number(line.amount).toLocaleString('en-US', { maximumFractionDigits: 4 })} hr` : dollars(line.amount)}
            </span>
          </div>
        ))}
      </div>
    </section>
  );
}

export function HistoricalPayroll(): ReactElement {
  const { user } = useAuth();
  const { activeCompanyId } = useCompany();
  const canMutate = ['super_admin', 'org_admin', 'admin', 'manager'].includes(user?.role || '');
  const fileInputRef = useRef<HTMLInputElement>(null);
  const listRequestIdRef = useRef(0);
  const detailRequestIdRef = useRef(0);
  const [batches, setBatches] = useState<HistoricalImportBatch[]>([]);
  const [archive, setArchive] = useState<HistoricalArchiveSummary | null>(null);
  const [selectedBatchId, setSelectedBatchId] = useState<number | null>(null);
  const [detail, setDetail] = useState<HistoricalImportDetail | null>(null);
  const [meta, setMeta] = useState<PaginationMeta>(EMPTY_META);
  const [files, setFiles] = useState<File[]>([]);
  const [search, setSearch] = useState('');
  const [periodId, setPeriodId] = useState<number | undefined>();
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(true);
  const [action, setAction] = useState<'preview' | 'apply' | 'lock' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [validationErrors, setValidationErrors] = useState<Record<string, string[]>>({});
  const [notice, setNotice] = useState<string | null>(null);
  const [paycheck, setPaycheck] = useState<HistoricalPaycheck | null>(null);
  const [confirmAction, setConfirmAction] = useState<'apply' | 'lock' | null>(null);

  const handleError = useCallback((err: unknown, fallback: string): void => {
    if (err instanceof ApiError) {
      setValidationErrors(err.details || {});
      setError(err.message);
      return;
    }

    setValidationErrors({});
    setError(errorMessage(err, fallback));
  }, []);

  const loadList = useCallback(async (): Promise<void> => {
    const requestId = ++listRequestIdRef.current;
    const response = await historicalImportsApi.list();
    if (requestId !== listRequestIdRef.current) return;

    setBatches(response.data);
    setArchive(response.archive);
    setSelectedBatchId((current) => (
      current && response.data.some((batch) => batch.id === current)
        ? current
        : response.data[0]?.id ?? null
    ));
  }, []);

  const loadDetail = useCallback(async (): Promise<void> => {
    const requestId = ++detailRequestIdRef.current;
    if (!selectedBatchId) {
      setDetail(null);
      setMeta(EMPTY_META);
      return;
    }
    try {
      const response = await historicalImportsApi.show(selectedBatchId, {
        page,
        per_page: 50,
        period_id: periodId,
        search: search.trim() || undefined,
      });
      if (requestId !== detailRequestIdRef.current) return;

      setDetail(response.data);
      setMeta(response.meta);
    } catch (err) {
      if (requestId === detailRequestIdRef.current) {
        handleError(err, 'Historical paychecks could not be loaded.');
      }
    }
  }, [handleError, page, periodId, search, selectedBatchId]);

  const refresh = useCallback(async (): Promise<void> => {
    setError(null);
    setValidationErrors({});
    try {
      await loadList();
    } catch (err) {
      handleError(err, 'Historical payroll could not be loaded.');
    }
  }, [handleError, loadList]);

  useEffect(() => {
    listRequestIdRef.current += 1;
    detailRequestIdRef.current += 1;
    setSelectedBatchId(null);
    setDetail(null);
    setMeta(EMPTY_META);
    setValidationErrors({});
    setLoading(true);
    let current = true;
    void refresh().finally(() => {
      if (current) setLoading(false);
    });
    return () => {
      current = false;
      listRequestIdRef.current += 1;
      detailRequestIdRef.current += 1;
    };
  }, [activeCompanyId, refresh]);

  useEffect(() => {
    void loadDetail();
  }, [loadDetail]);

  useEffect(() => {
    setPage(1);
    setPeriodId(undefined);
    setSearch('');
  }, [selectedBatchId]);

  const selectedBatch = useMemo(
    () => batches.find((batch) => batch.id === selectedBatchId) || detail,
    [batches, detail, selectedBatchId],
  );

  const handlePreview = async (): Promise<void> => {
    if (files.length === 0) {
      setValidationErrors({});
      setError('Select the exported QuickBooks files first.');
      return;
    }
    setAction('preview');
    setError(null);
    setValidationErrors({});
    setNotice(null);
    try {
      const response = await historicalImportsApi.preview(files);
      setSelectedBatchId(response.data.id);
      setFiles([]);
      if (fileInputRef.current) fileInputRef.current.value = '';
      setNotice(response.idempotent ? 'This exact bundle was already staged. The existing preview was opened.' : 'QuickBooks history was staged. Review reconciliation before applying it.');
      await loadList();
    } catch (err) {
      handleError(err, 'QuickBooks history could not be previewed.');
    } finally {
      setAction(null);
    }
  };

  const runLifecycleAction = async (): Promise<void> => {
    if (!selectedBatchId || !confirmAction) return;
    setAction(confirmAction);
    setError(null);
    setValidationErrors({});
    setNotice(null);
    try {
      const response = confirmAction === 'apply'
        ? await historicalImportsApi.apply(selectedBatchId)
        : await historicalImportsApi.lock(selectedBatchId);
      setNotice(confirmAction === 'apply'
        ? 'Historical payroll is now available in the archive. No payroll was recalculated.'
        : 'The reconciled QuickBooks batch is locked against ordinary changes.');
      setConfirmAction(null);
      await loadList();
      setDetail((current) => current ? { ...current, ...response.data } : current);
    } catch (err) {
      handleError(err, 'The historical import action failed.');
    } finally {
      setAction(null);
    }
  };

  const reconciliationPassed = selectedBatch?.reconciliation_summary.passed && selectedBatch.errors.length === 0;
  const summary = selectedBatch?.preview_summary;
  const linkedWorkers = detail?.workers.filter((worker) => worker.employee_id).length || 0;

  return (
    <div className="min-h-full bg-neutral-50/70">
      <Header
        title="Historical payroll"
        description="Import QuickBooks as locked source-of-record snapshots, reconcile every paycheck, and keep live payroll untouched."
        actions={<Button variant="outline" onClick={() => void refresh()} disabled={loading}><RefreshCw className="mr-2 h-4 w-4" />Refresh</Button>}
      />

      <main className="space-y-6 p-4 sm:p-6 lg:p-8">
        {error && (
          <div role="alert" className="flex items-start gap-3 rounded-2xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-800">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
            <div>
              <p>{error}</p>
              {Object.keys(validationErrors).length > 0 && (
                <ul className="mt-2 space-y-1">
                  {Object.entries(validationErrors).flatMap(([field, messages]) => (
                    messages.map((message) => <li key={`${field}-${message}`}>{fieldLabel(field)}: {message}</li>)
                  ))}
                </ul>
              )}
            </div>
          </div>
        )}
        {notice && <div role="status" className="flex items-start gap-3 rounded-2xl border border-success-200 bg-success-50 px-4 py-3 text-sm text-success-700"><CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" /><span>{notice}</span></div>}

        <section className="grid gap-6 xl:grid-cols-[minmax(0,1.7fr)_minmax(320px,0.75fr)]">
          <Card className="overflow-hidden">
            <CardHeader className="bg-[linear-gradient(135deg,rgba(239,246,255,0.94),rgba(255,255,255,0.98)_55%,rgba(240,253,250,0.82))]">
              <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <div className="flex items-center gap-2 text-xs font-bold uppercase tracking-[0.14em] text-primary-700"><ArchiveRestore className="h-4 w-4" />Archive ledger</div>
                  <CardTitle className="mt-3 text-2xl">{selectedBatch?.source_label || 'No QuickBooks history staged yet'}</CardTitle>
                  <CardDescription className="mt-2 max-w-2xl">The archive stores the final values QuickBooks recorded. It does not calculate checks, post taxes, issue payments, or update live YTD tables.</CardDescription>
                </div>
                {selectedBatch && statusBadge(selectedBatch.status)}
              </div>
            </CardHeader>
            <CardContent>
              {loading ? (
                <div className="grid animate-pulse gap-6 sm:grid-cols-2 xl:grid-cols-4"><div className="h-20 rounded-xl bg-neutral-100" /><div className="h-20 rounded-xl bg-neutral-100" /><div className="h-20 rounded-xl bg-neutral-100" /><div className="h-20 rounded-xl bg-neutral-100" /></div>
              ) : summary ? (
                <div className="grid gap-6 sm:grid-cols-2 xl:grid-cols-4">
                  <Metric label="Paychecks" value={summary.paycheck_count.toLocaleString()} note={`${summary.period_count} period records`} />
                  <Metric label="Workers" value={summary.worker_count.toLocaleString()} note={`${linkedWorkers} linked to live profiles`} />
                  <Metric label="Gross payroll" value={dollars(summary.totals.gross_pay)} note={`${shortDate(summary.first_pay_date)} – ${shortDate(summary.last_pay_date)}`} />
                  <Metric label="Net payroll" value={dollars(summary.totals.net_pay)} note={`${summary.check_number_count || 0} recorded check numbers`} />
                </div>
              ) : (
                <div className="py-8 text-center text-sm text-neutral-500">Select a QuickBooks export bundle to create the first preview.</div>
              )}
            </CardContent>
          </Card>

          <Card className="border-primary-200 bg-primary-950 text-white ring-primary-900/20">
            <CardContent className="flex h-full flex-col justify-between gap-6 p-6">
              <div>
                <ShieldCheck className="h-8 w-8 text-primary-200" />
                <h2 className="mt-6 font-display text-xl font-extrabold tracking-tight">Source values stay source values</h2>
                <p className="mt-2 text-sm leading-6 text-primary-100/80">Historical money is written to an isolated ledger. The live payroll calculator and payment workflows cannot touch it.</p>
              </div>
              <div className="space-y-2 text-xs text-primary-100/80">
                <p className="flex items-center gap-2"><Check className="h-3.5 w-3.5 text-success-300" />Encrypted employee setup evidence</p>
                <p className="flex items-center gap-2"><Check className="h-3.5 w-3.5 text-success-300" />Bundle and file SHA-256 fingerprints</p>
                <p className="flex items-center gap-2"><Check className="h-3.5 w-3.5 text-success-300" />Apply-time total verification</p>
              </div>
            </CardContent>
          </Card>
        </section>

        <section className="grid gap-6 lg:grid-cols-[minmax(320px,0.8fr)_minmax(0,1.2fr)]">
          <Card>
            <CardHeader><CardTitle>Stage a QuickBooks bundle</CardTitle><CardDescription>Select every exported report and supporting PDF/image. Files are hashed and parsed into a preview; the source files are not saved in this application.</CardDescription></CardHeader>
            <CardContent className="space-y-4">
              {canMutate ? (
                <>
                  <label className="group flex min-h-32 cursor-pointer flex-col items-center justify-center rounded-2xl border border-dashed border-primary-300 bg-primary-50/50 px-6 py-6 text-center transition hover:border-primary-500 hover:bg-primary-50 focus-within:ring-2 focus-within:ring-primary-300">
                    <UploadCloud className="h-7 w-7 text-primary-700" />
                    <span className="mt-3 text-sm font-semibold text-neutral-900">Select exported files</span>
                    <span className="mt-1 text-xs text-neutral-500">XLS, XLSX, PDF, JPG or PNG · up to 75 files</span>
                    <input ref={fileInputRef} type="file" multiple accept=".xls,.xlsx,.pdf,.jpg,.jpeg,.png" className="sr-only" onChange={(event) => setFiles(Array.from(event.target.files || []))} />
                  </label>
                  <div className="flex items-center justify-between gap-3 text-sm"><span className="min-w-0 truncate text-neutral-600">{files.length ? `${files.length} file${files.length === 1 ? '' : 's'} selected` : 'No files selected'}</span><Button onClick={() => void handlePreview()} disabled={!files.length || action !== null}>{action === 'preview' ? <RefreshCw className="mr-2 h-4 w-4 animate-spin" /> : <FileSpreadsheet className="mr-2 h-4 w-4" />}Build preview</Button></div>
                </>
              ) : (
                <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm leading-6 text-neutral-600">Accountants can review imported history and reconciliation. A manager or administrator must stage, apply, or lock a bundle.</div>
              )}

              {batches.length > 0 && (
                <div>
                  <label htmlFor="historical-batch" className="text-xs font-bold uppercase tracking-[0.12em] text-neutral-500">Review batch</label>
                  <select id="historical-batch" value={selectedBatchId || ''} onChange={(event) => setSelectedBatchId(Number(event.target.value))} className="mt-2 w-full rounded-xl border border-neutral-300 bg-white px-3.5 py-2.5 text-sm text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200">
                    {batches.map((batch) => <option key={batch.id} value={batch.id}>{batch.source_label} · {batch.status}</option>)}
                  </select>
                </div>
              )}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"><div><CardTitle>Reconciliation gate</CardTitle><CardDescription>QuickBooks Payroll Details must agree with Paycheck History before history can be applied.</CardDescription></div>{selectedBatch && (reconciliationPassed ? <Badge variant="success"><CheckCircle2 className="mr-1 h-3 w-3" />Passed</Badge> : <Badge variant="danger">Blocked</Badge>)}</div>
            </CardHeader>
            <CardContent className="space-y-5">
              {selectedBatch ? (
                <>
                  <div className="grid gap-3 sm:grid-cols-3">
                    <div className="rounded-xl bg-neutral-50 p-4"><p className="text-xs text-neutral-500">Native rows</p><p className="mt-1 text-xl font-bold text-neutral-950">{selectedBatch.reconciliation_summary.native_paycheck_rows?.toLocaleString() || 0}</p></div>
                    <div className="rounded-xl bg-neutral-50 p-4"><p className="text-xs text-neutral-500">Matched exactly</p><p className="mt-1 text-xl font-bold text-neutral-950">{selectedBatch.reconciliation_summary.matched_native_rows?.toLocaleString() || 0}</p></div>
                    <div className="rounded-xl bg-neutral-50 p-4"><p className="text-xs text-neutral-500">Opening summaries</p><p className="mt-1 text-xl font-bold text-neutral-950">{selectedBatch.reconciliation_summary.opening_summary_rows?.toLocaleString() || 0}</p></div>
                  </div>
                  {selectedBatch.errors.length > 0 && <div role="alert" className="rounded-xl border border-danger-200 bg-danger-50 p-4"><p className="text-sm font-semibold text-danger-800">Resolve before applying</p><ul className="mt-2 space-y-1 text-sm text-danger-700">{selectedBatch.errors.map((message) => <li key={message}>• {message}</li>)}</ul></div>}
                  {selectedBatch.warnings.length > 0 && <div className="rounded-xl border border-warning-200 bg-warning-50 p-4"><p className="text-sm font-semibold text-warning-800">Known source limitations</p><ul className="mt-2 space-y-1 text-sm leading-6 text-warning-700">{selectedBatch.warnings.map((message) => <li key={message}>• {message}</li>)}</ul></div>}
                  {canMutate && (
                    <div className="flex flex-col gap-3 border-t border-neutral-200 pt-6 sm:flex-row sm:items-center sm:justify-between">
                      <p className="max-w-xl text-xs leading-5 text-neutral-500">Apply makes reconciled rows visible in the archive. Lock makes the batch permanently read-only through ordinary workflows.</p>
                      <div className="flex gap-2">
                        {selectedBatch.status === 'previewed' && <Button onClick={() => setConfirmAction('apply')} disabled={!reconciliationPassed || action !== null}>Apply history</Button>}
                        {selectedBatch.status === 'applied' && <Button onClick={() => setConfirmAction('lock')} disabled={action !== null}><LockKeyhole className="mr-2 h-4 w-4" />Lock batch</Button>}
                        {selectedBatch.status === 'locked' && <Badge variant="success" className="px-4 py-2">Locked and immutable</Badge>}
                      </div>
                    </div>
                  )}
                </>
              ) : <p className="py-10 text-center text-sm text-neutral-500">No preview selected.</p>}
            </CardContent>
          </Card>
        </section>

        {detail && (
          <Card>
            <CardHeader>
              <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
                <div><CardTitle>Paycheck ledger</CardTitle><CardDescription>Final QuickBooks values, searchable by employee or check number. Open a row to inspect its itemized source lines.</CardDescription></div>
                <div className="grid gap-2 sm:grid-cols-[minmax(220px,1fr)_minmax(220px,1fr)]">
                  <div className="relative"><Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-neutral-400" /><Input aria-label="Search historical paychecks" value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Employee or check number" className="pl-9" /></div>
                  <select aria-label="Filter historical period" value={periodId || ''} onChange={(event) => { setPeriodId(event.target.value ? Number(event.target.value) : undefined); setPage(1); }} className="rounded-xl border border-neutral-300 bg-white px-3.5 py-2.5 text-sm text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-200"><option value="">All {detail.periods.length} periods</option>{detail.periods.map((period) => <option key={period.id} value={period.id}>{shortDate(period.pay_date)} · {period.source_label}{period.period_type === 'opening_summary' ? ' · summary' : ''}</option>)}</select>
                </div>
              </div>
            </CardHeader>
            <CardContent className="p-0">
              <div className="overflow-x-auto">
                <Table>
                  <TableHeader><TableRow><TableHead>Pay date</TableHead><TableHead>Employee</TableHead><TableHead className="text-right">Gross</TableHead><TableHead className="text-right">FIT</TableHead><TableHead className="text-right">SS / Medicare</TableHead><TableHead className="text-right">Other deductions</TableHead><TableHead className="text-right">Net</TableHead><TableHead>Check</TableHead><TableHead><span className="sr-only">Details</span></TableHead></TableRow></TableHeader>
                  <TableBody>
                    {detail.paychecks.map((row) => (
                      <TableRow key={row.id}>
                        <TableCell className="whitespace-nowrap text-sm">{shortDate(row.pay_date)}</TableCell>
                        <TableCell><p className="font-semibold text-neutral-950">{row.source_employee_name}</p><p className="mt-0.5 text-xs text-neutral-500">{row.period_type === 'opening_summary' ? 'Opening summary' : formatDateRange(row.period_start, row.period_end)}</p></TableCell>
                        <TableCell className="text-right font-mono tabular-nums">{dollars(row.gross_pay)}</TableCell>
                        <TableCell className="text-right font-mono tabular-nums">{dollars(row.federal_income_tax)}</TableCell>
                        <TableCell className="text-right font-mono tabular-nums">{dollars(Number(row.social_security_tax) + Number(row.medicare_tax))}</TableCell>
                        <TableCell className="text-right font-mono tabular-nums">{dollars(Number(row.pretax_deductions) + Number(row.after_tax_deductions))}</TableCell>
                        <TableCell className="text-right font-mono font-bold tabular-nums">{dollars(row.net_pay)}</TableCell>
                        <TableCell className="whitespace-nowrap text-sm text-neutral-600">{row.check_number || 'Not provided'}</TableCell>
                        <TableCell><Button size="sm" variant="ghost" onClick={() => setPaycheck(row)} aria-label={`View ${row.source_employee_name} paycheck`}><Eye className="h-4 w-4" /></Button></TableCell>
                      </TableRow>
                    ))}
                    {detail.paychecks.length === 0 && <TableRow><TableCell colSpan={9} className="py-12 text-center text-sm text-neutral-500">No historical paychecks match these filters.</TableCell></TableRow>}
                  </TableBody>
                </Table>
              </div>
              <div className="flex flex-col gap-3 border-t border-neutral-200 px-4 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-6">
                <p className="text-xs text-neutral-500">Showing page {meta.current_page} of {Math.max(meta.total_pages, 1)} · {meta.total_count.toLocaleString()} paychecks</p>
                <div className="flex gap-2"><Button size="sm" variant="outline" onClick={() => setPage((value) => Math.max(1, value - 1))} disabled={page <= 1}><ChevronLeft className="mr-1 h-4 w-4" />Previous</Button><Button size="sm" variant="outline" onClick={() => setPage((value) => value + 1)} disabled={page >= meta.total_pages}>Next<ChevronRight className="ml-1 h-4 w-4" /></Button></div>
              </div>
            </CardContent>
          </Card>
        )}

        {selectedBatch && (
          <Card>
            <CardHeader><CardTitle>Source inventory</CardTitle><CardDescription>{selectedBatch.source_file_manifest.length} files fingerprinted. Private source content and employee tax details are never returned by this screen.</CardDescription></CardHeader>
            <CardContent className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
              {selectedBatch.source_file_manifest.map((file) => <div key={`${file.filename}-${file.sha256}`} className="flex min-w-0 items-start gap-3 rounded-xl border border-neutral-200 bg-neutral-50/70 p-3"><FileArchive className="mt-0.5 h-4 w-4 shrink-0 text-primary-700" /><div className="min-w-0"><p className="truncate text-sm font-medium text-neutral-900" title={file.filename}>{file.filename}</p><p className="mt-1 text-xs text-neutral-500">{file.report_type.replaceAll('_', ' ')} · {(file.byte_size / 1024).toFixed(0)} KB</p></div></div>)}
            </CardContent>
          </Card>
        )}

        {archive && archive.applied_batch_count > 0 && <p className="pb-2 text-center text-xs text-neutral-500">Archive coverage: {archive.paycheck_count.toLocaleString()} paychecks · {archive.worker_count.toLocaleString()} workers · {shortDate(archive.first_pay_date)} through {shortDate(archive.last_pay_date)}</p>}
      </main>

      <Dialog open={Boolean(paycheck)} onOpenChange={(open) => !open && setPaycheck(null)}>
        <DialogContent className="max-h-[88vh] max-w-3xl overflow-y-auto">
          <DialogHeader><DialogTitle>{paycheck?.source_employee_name}</DialogTitle><DialogDescription>{paycheck ? `${shortDate(paycheck.pay_date)} payday · ${formatDateRange(paycheck.period_start, paycheck.period_end)}` : ''}</DialogDescription></DialogHeader>
          {paycheck && <div className="space-y-6"><div className="grid gap-4 rounded-2xl bg-neutral-950 p-6 text-white sm:grid-cols-3"><div><p className="text-xs text-neutral-400">Gross</p><p className="mt-1 text-xl font-bold">{dollars(paycheck.gross_pay)}</p></div><div><p className="text-xs text-neutral-400">Taxes + deductions</p><p className="mt-1 text-xl font-bold">{dollars(Number(paycheck.employee_taxes) + Number(paycheck.pretax_deductions) + Number(paycheck.after_tax_deductions))}</p></div><div><p className="text-xs text-neutral-400">Net</p><p className="mt-1 text-xl font-bold">{dollars(paycheck.net_pay)}</p></div></div><div className="grid gap-6 md:grid-cols-2"><Breakdown title="Hours" lines={paycheck.hours_breakdown} unit="hours" /><Breakdown title="Earnings" lines={paycheck.earnings_breakdown} /><Breakdown title="Pre-tax deductions" lines={paycheck.pretax_deduction_breakdown} /><Breakdown title="Employee taxes" lines={paycheck.employee_tax_breakdown} /><Breakdown title="After-tax deductions" lines={paycheck.after_tax_deduction_breakdown} /><Breakdown title="Employer taxes" lines={paycheck.employer_tax_breakdown} /><Breakdown title="Employer contributions" lines={paycheck.employer_contribution_breakdown} /></div></div>}
          <DialogFooter><Button variant="outline" onClick={() => setPaycheck(null)}>Close</Button></DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(confirmAction)} onOpenChange={(open) => !open && setConfirmAction(null)}>
        <DialogContent>
          <DialogHeader><DialogTitle>{confirmAction === 'apply' ? 'Apply historical payroll?' : 'Lock this historical batch?'}</DialogTitle><DialogDescription>{confirmAction === 'apply' ? 'This makes the reconciled QuickBooks snapshots available in the archive. It does not run payroll or update live YTD totals.' : 'Locking prevents ordinary edits and mapping changes. Use this only after the reconciliation evidence is accepted.'}</DialogDescription></DialogHeader>
          <div className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm leading-6 text-warning-800">{confirmAction === 'apply' ? 'You are accepting QuickBooks final values as authoritative historical records.' : 'This is the final integrity gate for this imported bundle.'}</div>
          <DialogFooter><Button variant="outline" onClick={() => setConfirmAction(null)} disabled={action !== null}>Cancel</Button><Button onClick={() => void runLifecycleAction()} disabled={action !== null}>{action ? <RefreshCw className="mr-2 h-4 w-4 animate-spin" /> : confirmAction === 'lock' ? <LockKeyhole className="mr-2 h-4 w-4" /> : <FileCheck2 className="mr-2 h-4 w-4" />}{confirmAction === 'apply' ? 'Apply authoritative history' : 'Lock reconciled batch'}</Button></DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
