import { useEffect, useRef, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { payPeriodsApi } from '@/services/api';
import { capturedSourceContext } from '@/lib/captured-source-worksheet';
import { formatCurrency, formatDate, formatDateRange, formatGuamDateTime } from '@/lib/utils';
import type { AirePayrollTimeEntry, PayPeriod, PayrollItem } from '@/types';
import type { PayrollComponentDisclosure } from '@/lib/payroll-tax-summary';

// Saved evidence stays readable even when the source connection is unavailable.
export function CapturedSourceHours({ item, payPeriod }: { item: PayrollItem; payPeriod: PayPeriod }) {
  const rates = (item.wage_rate_hours || []).filter(rate => rate.source_lines?.length);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [entries, setEntries] = useState<AirePayrollTimeEntry[]>([]);
  const [nextPage, setNextPage] = useState<number | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const request = useRef(0);
  useEffect(() => () => { request.current += 1; }, []);
  if (!rates.length) return null;
  const selected = entries.find(entry => entry.id === selectedId);
  const hasAireSource = item.import_source?.startsWith('time_tracking:aire_services:') || item.time_tracking_provenance?.source === 'aire_services';
  const earnings = (item as PayrollItem & { component_disclosure?: PayrollComponentDisclosure }).component_disclosure?.earnings;

  async function loadSource(id: string, page = 1) {
    setSelectedId(id);
    setLoading(true);
    setError(null);
    const current = ++request.current;
    try {
      const response = await payPeriodsApi.airePayrollTimeEntries(payPeriod.late_hours_origin_pay_period_id || payPeriod.id, { page });
      if (current !== request.current) return;
      setEntries(previous => page === 1 ? response.time_entries : [...previous, ...response.time_entries]);
      setNextPage(response.pagination.current_page < response.pagination.total_pages ? response.pagination.current_page + 1 : null);
    } catch (caught) {
      if (current === request.current) setError(caught instanceof Error ? caught.message : 'Could not read the original source entry.');
    } finally {
      if (current === request.current) setLoading(false);
    }
  }

  return <Card>
    <CardHeader><CardTitle>Work dates included in this paycheck</CardTitle>
      <p className="mt-2 text-sm leading-6 text-neutral-600">Paying payroll: {formatDateRange(payPeriod.start_date, payPeriod.end_date)} · Pay date: {formatDate(item.check_date || payPeriod.pay_date)}. Prior-period hours were worked on the dates below. Their inclusion does not confirm payment.</p>
    </CardHeader>
    <CardContent className="space-y-4">
      {rates.map((rate, index) => {
        const savedEarnings = earnings?.filter(entry => entry.label === rate.label || entry.label === `${rate.label} OT`);
        return <section key={rate.source_bucket_key || index} className="min-w-0 rounded-xl border border-neutral-200 p-4">
        <p className="break-words text-sm font-semibold text-neutral-950">{rate.label}</p>
        <p className="mt-1 break-words text-sm font-medium text-primary-800">{capturedSourceContext(rate)}</p>
        <p className="mt-2 text-sm tabular-nums text-neutral-700">{Number(rate.regular_hours).toFixed(2)} regular hrs × {formatCurrency(Number(rate.rate))}{Number(rate.overtime_hours) !== 0 && <> · {Number(rate.overtime_hours).toFixed(2)} OT hrs × {formatCurrency(Number(rate.rate) * 1.5)}</>}</p>
        {Boolean(savedEarnings?.length) && <p className="mt-1 text-sm font-semibold tabular-nums">Saved hourly earnings: {formatCurrency(savedEarnings!.reduce((sum, entry) => sum + Number(entry.amount), 0))}</p>}
        <details className="mt-3 text-sm"><summary className="min-h-11 cursor-pointer py-3 font-semibold text-primary-700">Original source entries</summary>
          <ul className="space-y-2">{rate.source_lines!.map(line => <li key={`${line.source_time_entry_id}:${line.line_key}`} className="break-words rounded-lg bg-neutral-50 p-3">
            <p>Worked {formatDate(line.original_work_date)} · {Number(line.regular_hours).toFixed(2)} regular / {Number(line.overtime_hours).toFixed(2)} OT hrs</p>
            {hasAireSource ? <Button variant="outline" size="sm" className="mt-2 min-h-11 whitespace-normal text-left" disabled={loading} onClick={() => void loadSource(line.source_time_entry_id)}>Review source entry #{line.source_time_entry_id}</Button> : <p className="text-xs text-neutral-600">Source entry #{line.source_time_entry_id} · review history in the original time system.</p>}
          </li>)}</ul>
        </details>
      </section>; })}
      {selectedId && <section aria-label="Original source entry history" aria-live="polite" className="rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm leading-6">
        <h3 className="font-semibold">Source entry #{selectedId} · current source record</h3>
        <p className="text-xs text-neutral-600">The captured hours above remain the paycheck evidence. Source details may have changed since import.</p>
        {loading && <p>Reading source history…</p>}
        {error && <><p className="mt-2 text-danger-700">{error} Saved work dates and hours remain available above.</p><Button variant="outline" className="mt-2" onClick={() => void loadSource(selectedId)}>Try source again</Button></>}
        {selected && <dl className="mt-3 space-y-2 break-words">
          <div><dt className="font-semibold">Worked</dt><dd>{formatDate(selected.work_date)} · {selected.category?.name || 'Category not recorded'}</dd></div>
          <div><dt className="font-semibold">Entered</dt><dd>{selected.created_at ? formatGuamDateTime(selected.created_at) : 'Entry time not available'} · {selected.capture.entry_method || 'Method not recorded'}</dd></div>
          <div><dt className="font-semibold">Time approval</dt><dd>{selected.state.approval_status}{selected.approval?.occurred_at ? ` · ${formatGuamDateTime(selected.approval.occurred_at)}` : ''}{selected.approval?.actor?.name ? ` · ${selected.approval.actor.name}` : ''}{selected.approval?.note && <p>{selected.approval.note}</p>}</dd></div>
          <div><dt className="font-semibold">Overtime approval</dt><dd>{selected.state.overtime_status}{selected.overtime_approval?.occurred_at ? ` · ${formatGuamDateTime(selected.overtime_approval.occurred_at)}` : ''}{selected.overtime_approval?.actor?.name ? ` · ${selected.overtime_approval.actor.name}` : ''}{selected.overtime_approval?.note && <p>{selected.overtime_approval.note}</p>}</dd></div>
        </dl>}
        {!loading && !error && !selected && <p className="mt-2">This entry was not found{nextPage ? ' on the source pages read so far' : ' in the current source response'}. The saved source reference is retained above.</p>}
        {!error && !selected && nextPage && <Button variant="outline" className="mt-2" disabled={loading} onClick={() => void loadSource(selectedId, nextPage)}>Read next source page</Button>}
      </section>}
    </CardContent>
  </Card>;
}
