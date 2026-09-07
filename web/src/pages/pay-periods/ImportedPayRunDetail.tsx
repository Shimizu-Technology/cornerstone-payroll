import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactElement } from 'react';
import { ArrowLeft, FileLock2, LockKeyhole } from 'lucide-react';
import { useNavigate, useParams, useSearchParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useCompany } from '@/contexts/CompanyContext';
import { formatCurrency, formatDate, formatDateRange } from '@/lib/utils';
import { parsePositiveRouteId } from '@/lib/route-params';
import { payRunsPath, safeInternalReturnPath } from '@/lib/routes';
import { clientPayPeriodsApi, payrollHistoryApi, type ImportedPayPeriodDetail } from '@/services/api';

const PAGE_SIZE = 50;

export function ImportedPayRunDetail({ audience }: { audience: 'staff' | 'client' }): ReactElement {
  const navigate = useNavigate();
  const { activeCompanyId } = useCompany();
  const { id: idParam, companyId: companyIdParam } = useParams<{ id: string; companyId: string }>();
  const [searchParams] = useSearchParams();
  const importedPayPeriodId = parsePositiveRouteId(idParam);
  const routeCompanyId = parsePositiveRouteId(companyIdParam);
  const fallbackCompanyId = routeCompanyId ?? activeCompanyId;
  const fallbackPath = fallbackCompanyId ? payRunsPath(fallbackCompanyId) : '/pay-periods';
  const returnTo = safeInternalReturnPath(searchParams.get('return_to'), fallbackPath);
  const [record, setRecord] = useState<ImportedPayPeriodDetail | null>(null);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(0);
  const [totalCount, setTotalCount] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const requestIdRef = useRef(0);

  useLayoutEffect((): void => {
    requestIdRef.current += 1;
    setRecord(null);
    setPage(1);
    setError(null);
    setLoading(true);
  }, [importedPayPeriodId, routeCompanyId]);

  const load = useCallback(async (): Promise<void> => {
    const requestId = ++requestIdRef.current;
    if (!importedPayPeriodId || !routeCompanyId || routeCompanyId !== activeCompanyId) {
      setError('This imported pay-run link is invalid.');
      setLoading(false);
      return;
    }

    try {
      setLoading(true);
      setError(null);
      const response = await (audience === 'client' ? clientPayPeriodsApi : payrollHistoryApi).importedPayPeriod(
        importedPayPeriodId,
        { page, per_page: PAGE_SIZE },
        routeCompanyId,
      );
      if (requestId !== requestIdRef.current) return;
      setRecord(response.data);
      setTotalPages(response.meta.total_pages);
      setTotalCount(response.meta.total_count);
    } catch (err) {
      if (requestId !== requestIdRef.current) return;
      setRecord(null);
      setError(err instanceof Error ? err.message : 'Failed to load the imported pay run.');
    } finally {
      if (requestId === requestIdRef.current) setLoading(false);
    }
  }, [activeCompanyId, audience, importedPayPeriodId, page, routeCompanyId]);

  useEffect((): (() => void) => {
    void load();
    return (): void => {
      requestIdRef.current += 1;
    };
  }, [load]);

  return (
    <div>
      <Header
        title={record ? formatDateRange(record.start_date, record.end_date) : 'Imported pay run'}
        description={audience === 'client'
          ? 'Review this finalized payroll from your imported history. It is read-only and shown here for continuity.'
          : 'Review the payroll records accepted from QuickBooks. This source-backed pay run is locked and cannot be recalculated or edited here.'}
        actions={<Button variant="outline" onClick={() => navigate(returnTo)}><ArrowLeft className="mr-2 h-4 w-4" />Back to Payroll</Button>}
      />

      <div className="space-y-6 p-4 sm:p-6 lg:p-8">
        {loading && <Card><CardContent className="py-12 text-center text-sm text-neutral-500">Loading imported payroll records…</CardContent></Card>}
        {error && !loading && (
          <Card className="border-danger-200 bg-danger-50">
            <CardContent className="py-8 text-sm text-danger-700">{error}</CardContent>
          </Card>
        )}

        {record && !loading && (
          <>
            <div className="flex flex-col gap-3 rounded-2xl border border-amber-200 bg-amber-50 px-5 py-4 text-amber-950 sm:flex-row sm:items-center sm:justify-between">
              <div className="flex items-start gap-3">
                <LockKeyhole className="mt-0.5 h-5 w-5 shrink-0 text-amber-700" />
                <div>
                  <p className="font-semibold">Locked source record</p>
                  <p className="mt-1 text-sm leading-6 text-amber-800">{audience === 'client'
                    ? 'This finalized payroll came from QuickBooks. You can review it here, but it cannot be changed or recalculated in Cornerstone.'
                    : 'These values were accepted from QuickBooks and are shown alongside Cornerstone payroll for continuity. Corrections use the migration workflow, not native payroll actions.'}</p>
                </div>
              </div>
              <Badge variant="warning" className="shrink-0">QuickBooks import</Badge>
            </div>

            <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
              <SummaryCard label="Pay date" value={formatDate(record.pay_date)} />
              <SummaryCard label="Payroll records" value={String(record.employee_count)} />
              <SummaryCard label="Gross pay" value={formatCurrency(record.total_gross)} />
              <SummaryCard label="Net pay" value={formatCurrency(record.total_net)} />
            </div>

            <Card>
              <CardHeader className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <CardTitle>Payroll records</CardTitle>
                  <p className="mt-1 text-sm text-neutral-500">{totalCount} source-backed {totalCount === 1 ? 'record' : 'records'} · {record.source.detail}</p>
                </div>
                <div className="flex items-center gap-2 text-xs text-neutral-500"><FileLock2 className="h-4 w-4" />Read-only</div>
              </CardHeader>
              <div className="hidden sm:block">
                <Table stickyHeader containerClassName="max-h-[34rem]">
                  <TableHeader>
                    <TableRow>
                      <TableHead>Employee</TableHead>
                      <TableHead>{audience === 'client' ? 'Payment method' : 'Check'}</TableHead>
                      <TableHead className="text-right">Hours</TableHead>
                      <TableHead className="text-right">Gross</TableHead>
                      <TableHead className="text-right">Employee taxes</TableHead>
                      <TableHead className="text-right">Deductions</TableHead>
                      <TableHead className="text-right">Net</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {record.paychecks.map((paycheck) => (
                      <TableRow key={paycheck.id}>
                        <TableCell>
                          <p className="font-medium text-neutral-950">{paycheck.employee_name || paycheck.source_employee_name}</p>
                          {paycheck.employee_name && paycheck.employee_name !== paycheck.source_employee_name && <p className="mt-1 text-xs text-neutral-500">QuickBooks: {paycheck.source_employee_name}</p>}
                        </TableCell>
                        <TableCell>{audience === 'client' ? (paycheck.payment_method || '—') : (paycheck.check_number || paycheck.payment_method || '—')}</TableCell>
                        <TableCell className="text-right tabular-nums">{Number(paycheck.hours_total).toFixed(2)}</TableCell>
                        <TableCell className="text-right font-medium tabular-nums">{formatCurrency(Number(paycheck.gross_pay))}</TableCell>
                        <TableCell className="text-right tabular-nums">{formatCurrency(Number(paycheck.employee_taxes))}</TableCell>
                        <TableCell className="text-right tabular-nums">{formatCurrency(Number(paycheck.pretax_deductions) + Number(paycheck.after_tax_deductions))}</TableCell>
                        <TableCell className="text-right font-semibold tabular-nums">{formatCurrency(Number(paycheck.net_pay))}</TableCell>
                      </TableRow>
                    ))}
                    {record.paychecks.length === 0 && <TableRow><TableCell colSpan={7} className="py-12 text-center text-sm text-neutral-500">No payroll records were stored for this imported pay run.</TableCell></TableRow>}
                  </TableBody>
                </Table>
              </div>
              <div className="divide-y divide-neutral-200 sm:hidden">
                {record.paychecks.map((paycheck) => (
                  <div key={paycheck.id} className="space-y-3 px-4 py-5">
                    <div className="flex items-start justify-between gap-3">
                      <div><p className="font-semibold text-neutral-950">{paycheck.employee_name || paycheck.source_employee_name}</p><p className="mt-1 text-xs text-neutral-500">{audience === 'client' ? (paycheck.payment_method || 'Payment method not recorded') : (paycheck.check_number ? `Check ${paycheck.check_number}` : paycheck.payment_method || 'No check number')}</p></div>
                      <p className="font-semibold tabular-nums text-neutral-950">{formatCurrency(Number(paycheck.net_pay))}</p>
                    </div>
                    <div className="grid grid-cols-3 gap-3 text-sm"><Metric label="Hours" value={Number(paycheck.hours_total).toFixed(2)} /><Metric label="Gross" value={formatCurrency(Number(paycheck.gross_pay))} /><Metric label="Taxes" value={formatCurrency(Number(paycheck.employee_taxes))} /></div>
                  </div>
                ))}
                {record.paychecks.length === 0 && <p className="px-4 py-12 text-center text-sm text-neutral-500">No payroll records were stored for this imported pay run.</p>}
              </div>
              {totalPages > 1 && (
                <div className="flex items-center justify-between border-t border-neutral-200 px-4 py-4 sm:px-6">
                  <p className="text-sm text-neutral-500">Page {page} of {totalPages}</p>
                  <div className="flex gap-2"><Button variant="outline" size="sm" onClick={() => setPage((current) => Math.max(1, current - 1))} disabled={page <= 1}>Previous</Button><Button variant="outline" size="sm" onClick={() => setPage((current) => Math.min(totalPages, current + 1))} disabled={page >= totalPages}>Next</Button></div>
                </div>
              )}
            </Card>

            {audience === 'staff' && <Card>
              <CardHeader><CardTitle>Import provenance</CardTitle></CardHeader>
              <CardContent className="grid gap-4 text-sm sm:grid-cols-2 lg:grid-cols-4">
                <Metric label="Source" value="QuickBooks Online" />
                <Metric label="Source batch" value={`#${record.source.import_batch_id ?? '—'}`} />
                <Metric label="Locked by" value={record.source.locked_by_name || 'Operator not recorded'} />
                <Metric label="Importer version" value={record.source.importer_version || 'Not recorded'} />
              </CardContent>
            </Card>}
          </>
        )}
      </div>
    </div>
  );
}

function SummaryCard({ label, value }: { label: string; value: string }): ReactElement {
  return <Card><CardContent><p className="text-xs font-bold uppercase tracking-[0.12em] text-neutral-500">{label}</p><p className="mt-2 font-display text-2xl font-bold tracking-tight text-neutral-950">{value}</p></CardContent></Card>;
}

function Metric({ label, value }: { label: string; value: string }): ReactElement {
  return <div><p className="text-xs font-semibold uppercase tracking-[0.1em] text-neutral-500">{label}</p><p className="mt-1 font-medium text-neutral-900">{value}</p></div>;
}
