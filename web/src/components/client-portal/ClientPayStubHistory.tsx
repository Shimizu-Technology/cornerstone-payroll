import { useEffect, useState } from 'react';
import { clientPayStubsApi, type ClientPayStub, type ClientQuickbooksPaycheck } from '@/services/api';
import { Badge } from '@/components/ui/badge';
import { ClientPayStubButton } from './ClientPayStubButton';
import { formatCurrency } from '@/lib/utils';
import { formatDate, formatDateRange } from '@/lib/display-date';

export function ClientPayStubHistory({ employeeId }: { employeeId: number }) {
  const [rows, setRows] = useState<ClientPayStub[]>([]);
  const [quickbooksPaychecks, setQuickbooksPaychecks] = useState<ClientQuickbooksPaycheck[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let current = true;
    setLoading(true);
    setRows([]);
    setQuickbooksPaychecks([]);
    setError(null);
    void clientPayStubsApi.history(employeeId).then(
      result => {
        if (current) {
          setRows(result.pay_stubs);
          setQuickbooksPaychecks(result.quickbooks_paychecks ?? []);
        }
      },
      caught => { if (current) setError(caught instanceof Error ? caught.message : 'Could not load pay history.'); },
    ).finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [employeeId, attempt]);

  const hasAny = rows.length > 0 || quickbooksPaychecks.length > 0;

  return (
    <section aria-label="Pay history" className="space-y-4">
      <h2 className="text-lg font-semibold">Pay history &amp; stubs</h2>
      {loading ? (
        <p role="status">Loading pay history…</p>
      ) : error ? (
        <div>
          <p role="alert">{error}</p>
          <button className="min-h-11 underline" onClick={() => setAttempt(value => value + 1)}>Try again</button>
        </div>
      ) : !hasAny ? (
        <p>No finished payroll is available for this employee yet.</p>
      ) : (
        <div className="space-y-6">
          {rows.length > 0 && (
            <div className="space-y-3">
              {rows.map(row => (
                <div key={row.id} className="flex flex-wrap items-center justify-between gap-3 rounded-xl border p-4">
                  <div className="min-w-0">
                    <p className="font-medium">{formatDateRange(row.start_date, row.end_date) || row.period_description}</p>
                    {row.corrected && <Badge variant="warning">Corrected</Badge>}
                    <p className="text-sm">Pay date {formatDate(row.pay_date)} · Net {formatCurrency(Number(row.net_pay))}</p>
                  </div>
                  <ClientPayStubButton itemId={row.id} />
                </div>
              ))}
            </div>
          )}

          {quickbooksPaychecks.length > 0 && (
            <section aria-labelledby="client-qb-history-heading" className="space-y-3">
              <div>
                <h3 id="client-qb-history-heading" className="text-base font-semibold text-neutral-900">From QuickBooks records</h3>
                <p className="text-sm text-neutral-600">Checks paid before Cornerstone started.</p>
              </div>
              <div className="space-y-3">
                {quickbooksPaychecks.map(check => {
                  const periodLabel = check.period_start && check.period_end
                    ? formatDateRange(check.period_start, check.period_end)
                    : `Pay date ${formatDate(check.pay_date)}`;
                  return (
                    <div key={check.id} className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-neutral-200 bg-neutral-50/60 p-4">
                      <div className="min-w-0">
                        <p className="font-medium text-neutral-900">{periodLabel}</p>
                        <p className="text-sm text-neutral-700">
                          Pay date {formatDate(check.pay_date)}
                          {check.gross_pay != null ? ` · Gross ${formatCurrency(Number(check.gross_pay))}` : ''}
                          {check.net_pay != null ? ` · Net ${formatCurrency(Number(check.net_pay))}` : ''}
                        </p>
                        {check.adjustment_note && <p className="mt-1 text-xs text-neutral-600">{check.adjustment_note}</p>}
                      </div>
                      <span className="rounded-full border border-neutral-200 bg-white px-3 py-1 text-xs font-medium text-neutral-700">
                        {check.source_label || 'From QuickBooks records'}
                      </span>
                    </div>
                  );
                })}
              </div>
            </section>
          )}
        </div>
      )}
    </section>
  );
}
