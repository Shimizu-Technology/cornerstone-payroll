import { useEffect, useState } from 'react';
import { clientPayStubsApi, type ClientPayStub } from '@/services/api';
import { ClientPayStubButton } from './ClientPayStubButton';
import { formatCurrency } from '@/lib/utils';

export function ClientPayStubHistory({ employeeId }: { employeeId: number }) {
  const [rows, setRows] = useState<ClientPayStub[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let current = true;
    setLoading(true);
    setRows([]);
    setError(null);
    void clientPayStubsApi.history(employeeId).then(
      result => { if (current) setRows(result.pay_stubs); },
      caught => { if (current) setError(caught instanceof Error ? caught.message : 'Could not load pay history.'); },
    ).finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [employeeId, attempt]);
  return <section aria-label="Pay history" className="space-y-4">
    <h2 className="text-lg font-semibold">Pay history &amp; stubs</h2>
    {loading ? <p role="status">Loading pay history…</p> : error ? <div><p role="alert">{error}</p><button className="min-h-11 underline" onClick={() => setAttempt(value => value + 1)}>Try again</button></div> :
      rows.length === 0 ? <p>No finished payroll is available for this employee yet.</p> :
      rows.map(row => <div key={row.id} className="flex flex-wrap items-center justify-between gap-3 rounded-xl border p-4">
        <div className="min-w-0"><p className="font-medium">{row.period_description}</p><p className="text-sm">Pay date {row.pay_date} · Net {formatCurrency(Number(row.net_pay))}</p></div>
        <ClientPayStubButton itemId={row.id} />
      </div>)}
  </section>;
}
