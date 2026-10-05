import { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import { ArrowLeft, ArrowRight, RefreshCw } from 'lucide-react';
import { employeesApi, type EmployeePayHistoryReport } from '@/services/api';
import type { EmployeeHoursEvidence, EvidenceTotals } from '@/lib/employee-hours-evidence';
import { payrollItemPath, payRunPath } from '@/lib/routes';
import { formatCurrency, formatDate } from '@/lib/utils';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { SavedHours } from './SavedHours';

export function EmployeeHoursPayroll({ employeeId, companyId, report, returnTo }: {
  employeeId: number; companyId: number; report: EmployeePayHistoryReport | null; returnTo: string;
}) {
  const [params, setParams] = useSearchParams();
  const [result, setResult] = useState<EmployeeHoursEvidence | null>(null);
  const [sources, setSources] = useState<EmployeeHoursEvidence['sources']>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [retry, setRetry] = useState(0);
  const sourceId = params.get('hours_source') || undefined;
  const periodId = params.get('period') || undefined;
  const startDate = params.get('hours_start') || undefined;
  const endDate = params.get('hours_end') || undefined;
  const cursor = params.get('hours_cursor') || undefined;
  const detailCursor = params.get('detail_cursor') || undefined;
  useEffect(() => { setSources([]); }, [employeeId, companyId]);
  useEffect(() => {
    let current = true;
    setLoading(true); setResult(null); setError(null);
    employeesApi.hoursEvidence(employeeId, { source_id: sourceId, period_id: periodId,
      start_date: startDate, end_date: endDate, cursor, per_page: 20, detail_cursor: detailCursor, detail_per_page: 25 }).then((data) => {
      if (current) { setResult(data); setSources(data.sources); }
    }).catch((caught: unknown) => {
      if (current) setError(caught instanceof Error ? caught.message : 'Source hours could not be loaded. Please retry.');
    }).finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [employeeId, companyId, sourceId, periodId, startDate, endDate, cursor, detailCursor, retry]);

  const update = (key: string, value: string | undefined): void => {
    const next = new URLSearchParams(params);
    if (value) next.set(key, value); else next.delete(key);
    if (key !== 'hours_cursor' && key !== 'period' && key !== 'detail_cursor') next.delete('hours_cursor');
    if (key !== 'period' && key !== 'hours_cursor' && key !== 'detail_cursor') next.delete('period');
    if (key !== 'detail_cursor') next.delete('detail_cursor');
    setParams(next);
  };
  const period = result?.evidence?.period;
  return <div className="space-y-6">
    <Card>
      <CardHeader><CardTitle>Time tracking evidence</CardTitle>
        <p className="mt-2 text-sm leading-6 text-neutral-600">Review original work periods, including periods without a linked paycheck. Source coverage and current REG/OT are separate from the saved payroll hours below. Missing coverage requires review; it does not establish money owed.</p>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="grid gap-3 sm:grid-cols-3">
          <label className="text-sm font-semibold">Connection<select className="mt-1 block min-h-11 w-full rounded-xl border border-neutral-300 bg-white px-3" value={sourceId || result?.source_id || ''} onChange={(event) => update('hours_source', event.target.value)}>
            {!sources.length && <option value="">No linked connection</option>}
            {sources.map((source) => <option key={source.id} value={source.id}>{source.name}{source.active ? '' : ' (disabled)'}</option>)}
          </select></label>
          <label className="text-sm font-semibold">Work from<input type="date" className="mt-1 block min-h-11 w-full rounded-xl border border-neutral-300 px-3" value={startDate || ''} onChange={(event) => update('hours_start', event.target.value)} /></label>
          <label className="text-sm font-semibold">Work through<input type="date" className="mt-1 block min-h-11 w-full rounded-xl border border-neutral-300 px-3" value={endDate || ''} onChange={(event) => update('hours_end', event.target.value)} /></label>
        </div>
        {loading && <p role="status">Loading source hours…</p>}
        {(error || (result && result.status !== 'available')) && <div role="status" className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
          <p>{error || result?.message}</p><Button variant="outline" size="sm" className="mt-3" onClick={() => setRetry((value) => value + 1)}><RefreshCw className="mr-2 h-4 w-4" />Try again</Button>
        </div>}
        {result?.status === 'available' && <>
          <p className="text-xs text-neutral-500">Source evidence as of {result.evidence?.as_of ? new Date(result.evidence.as_of).toLocaleString() : 'unknown'}</p>
          {result.source_workspace_url && <a href={result.source_workspace_url} target="_blank" rel="noopener noreferrer" className="inline-flex min-h-11 items-center gap-2 font-semibold text-primary-700">Open employee in time tracking <ArrowRight className="h-4 w-4" /></a>}
          {period ? <>
            <Button variant="outline" onClick={() => update('period', undefined)}><ArrowLeft className="mr-2 h-4 w-4" />All work periods</Button>
            <h3 className="font-display text-lg font-bold">{formatDate(period.start_date)} – {formatDate(period.end_date)}</h3>
            <SourceTotals totals={period.summary} />
            <h4 className="font-semibold">Current source entries</h4>
            {period.entries?.length ? <div className="divide-y rounded-xl border border-neutral-200">{period.entries.map((entry) => <div key={entry.id} className="space-y-1 p-4 text-sm">
              <p className="font-semibold">{formatDate(entry.work_date)} · Entry #{entry.id}</p><p>{entry.description || 'No description'}</p>
              <p>Current REG {hours(entry.regular_hours)} · OT {hours(entry.overtime_hours)} · {entry.approval_status || 'Unknown approval'} · OT {entry.overtime_status}</p>
              {entry.source_entry_url && <a href={entry.source_entry_url} target="_blank" rel="noopener noreferrer" className="inline-flex min-h-11 items-center font-semibold text-primary-700">Open exact source entry <ArrowRight className="ml-2 h-4 w-4" /></a>}
              <p>Issued source coverage {hours(entry.issued_hours)} · Needs reconciliation {hours(entry.needs_reconciliation_hours)}</p>
            </div>)}</div> : <p className="text-sm text-neutral-600">No current entries. Retained coverage may still exist.</p>}
            <h4 className="font-semibold">Retained source coverage</h4>
            {period.coverage_lines?.length ? <div className="divide-y rounded-xl border border-neutral-200">{period.coverage_lines.map((line) => <div key={line.id} className="space-y-1 p-4 text-sm">
              <p className="font-semibold">Entry #{line.source_time_entry_id} · Receipt {line.coverage_state}</p>
              {line.identity_state && line.identity_state !== 'verified' && <p className="font-semibold text-amber-800">Employee identity needs review: {line.identity_state.replaceAll('_', ' ')}</p>}
              <p>Source REG {hours(line.regular_hours)} · OT {hours(line.overtime_hours)}{line.batch_id ? ` · Frozen batch ${line.batch_id}` : ''}</p>
              <p>{line.provenance}{line.payment_reference ? ` · Payment ${line.payment_reference}` : ''}</p>{line.reason && <p>{line.reason}</p>}
            </div>)}</div> : <p className="text-sm text-neutral-600">No retained coverage recorded for this period.</p>}
            {!!period.settlement_cases?.length && <><h4 className="font-semibold">Settlement review</h4>{period.settlement_cases.map((item) => <p key={item.public_id} className="rounded-xl border p-3 text-sm">Entry #{item.source_time_entry_id} · {item.status} · {item.origin_reason} · {item.held_total_hours} held hours</p>)}</>}
            {period.detail_pagination && <div className="flex flex-wrap items-center gap-3 text-sm"><p>{period.detail_pagination.counts.entries} entries · {period.detail_pagination.counts.coverage_lines} retained coverage lines · {period.detail_pagination.counts.settlement_cases} settlement cases</p>{detailCursor && <Button variant="outline" onClick={() => update('detail_cursor', undefined)}>First detail page</Button>}{period.detail_pagination.next_cursor && <Button variant="outline" onClick={() => update('detail_cursor', period.detail_pagination?.next_cursor || undefined)}>Next detail page</Button>}</div>}
            {!!result.payroll_records?.length && <><h4 className="font-semibold">Exact linked payroll results</h4>{result.payroll_records.map((record) => <div key={record.payroll_item_id} className="space-y-2 rounded-xl border p-4 text-sm">
              <p className="font-semibold">{record.period_description} · Pay date {formatDate(record.pay_date)}</p>
              <p>Saved REG {hours(record.regular_hours)} · OT {hours(record.overtime_hours)} · Holiday {hours(record.holiday_hours)} · PTO {hours(record.pto_hours)}</p>
              <p>{record.payment_evidence.label}{record.check_number ? ` · Check #${record.check_number}` : ''} · {record.net_pay == null ? 'Net unavailable' : `${formatCurrency(record.net_pay)} net`}</p>
              <Link className="inline-flex min-h-11 items-center font-semibold text-primary-700" to={payrollItemPath(companyId, record.pay_period_id, record.payroll_item_id, { returnTo })}>Open exact payroll item <ArrowRight className="ml-2 h-4 w-4" /></Link>
            </div>)}</>}
          </> : <>
            {result.evidence?.totals && <SourceTotals totals={result.evidence.totals} allPeriods />}
            <p className="text-sm text-neutral-500">{result.evidence?.pagination?.total_count || 0} original work periods match these dates.</p>
            <div className="space-y-3">{result.evidence?.periods?.map((item) => <div key={item.id} className="rounded-xl border border-neutral-200 p-4">
              <div className="flex flex-wrap items-center justify-between gap-3"><h3 className="font-semibold">{formatDate(item.start_date)} – {formatDate(item.end_date)}</h3><Button variant="outline" onClick={() => update('period', item.id)}>Review period <ArrowRight className="ml-2 h-4 w-4" /></Button></div>
              <p className="mt-2 text-sm">{hours(item.summary.worked_hours)} worked · {hours(item.summary.issued_hours)} issued coverage · {hours(item.summary.committed_hours)} committed coverage · {hours(item.summary.needs_reconciliation_hours)} needs reconciliation{item.review_required ? ' · Review needed' : ''}</p>
            </div>)}</div>
            <div className="flex flex-wrap gap-3">{cursor && <Button variant="outline" onClick={() => update('hours_cursor', undefined)}>First page</Button>}{result.evidence?.pagination?.next_cursor && <Button variant="outline" onClick={() => update('hours_cursor', result.evidence?.pagination?.next_cursor || undefined)}>Next periods <ArrowRight className="ml-2 h-4 w-4" /></Button>}</div>
          </>}
        </>}
      </CardContent>
    </Card>
    <Card><CardHeader><CardTitle>Saved payroll hours</CardTitle><p className="mt-2 text-sm text-neutral-600">The actual hours recorded on each payroll result. Printed or committed payroll alone does not confirm payment delivery.</p></CardHeader>
      <CardContent className="space-y-3">{!report ? <p>Payroll history unavailable. Retry from this employee workspace.</p> : report.history.length ? report.history.map((item) => <div key={item.key} className="space-y-2 rounded-xl border border-neutral-200 p-4">
        <p className="font-semibold">{item.period_description} · Pay date {formatDate(item.pay_date)} · {item.source.label}</p><SavedHours item={item} />
        <p className="text-sm">{item.payment_evidence?.label || 'Payment evidence not available'} · {formatCurrency(item.net_pay)} net</p>
        {item.record_type === 'native' && item.pay_period_id && item.payroll_item_id && <div className="flex flex-wrap gap-4 text-sm font-semibold text-primary-700"><Link className="inline-flex min-h-11 items-center" to={payrollItemPath(companyId, item.pay_period_id, item.payroll_item_id, { returnTo })}>Payroll item <ArrowRight className="ml-2 h-4 w-4" /></Link><Link className="inline-flex min-h-11 items-center" to={payRunPath(companyId, item.pay_period_id, 'checks', { returnTo })}>Pay run checks <ArrowRight className="ml-2 h-4 w-4" /></Link></div>}
      </div>) : <p>No saved payroll results. Source work periods may still be available above.</p>}</CardContent>
    </Card>
  </div>;
}

function hours(value: number | null | undefined): string { return value == null ? 'Unknown' : Number(value).toFixed(2); }
function SourceTotals({ totals, allPeriods = false }: { totals: EvidenceTotals; allPeriods?: boolean }) {
  return <div className="rounded-xl bg-neutral-50 p-4 text-sm"><p className="mb-2 font-semibold">{allPeriods ? 'All matching work periods' : 'This original work period'}</p>
    <dl className="grid grid-cols-2 gap-3 sm:grid-cols-4">{[
      ['Worked', totals.worked_hours], ['Issued coverage', totals.issued_hours], ['Committed coverage', totals.committed_hours], ['Needs reconciliation', totals.needs_reconciliation_hours],
      ['Pending approval', totals.pending_hours], ['Denied', totals.denied_hours], ['Held', totals.held_hours], ['Exported coverage', totals.exported_hours],
    ].map(([label, value]) => <div key={String(label)}><dt className="text-neutral-500">{label}</dt><dd className="font-semibold tabular-nums">{hours(value as number)}</dd></div>)}</dl>
    {!!totals.identity_review_count && <p className="mt-3 font-semibold text-amber-800">{totals.identity_review_count} retained lines need employee identity review.</p>}
    {!!totals.uncategorized_entry_count && <p className="mt-2 font-semibold text-amber-800">{totals.uncategorized_entry_count} entries have no work category.</p>}
    <p className="mt-3 text-neutral-600">Current classification: REG {hours(totals.current_regular_hours)} · OT {hours(totals.current_overtime_hours)}. Frozen source lines: REG {hours(totals.frozen_regular_hours)} · OT {hours(totals.frozen_overtime_hours)}. Coverage can be partial or signed corrections; it is not the actual check classification.</p>
  </div>;
}
