import { ActionFeedback } from '@/components/ui/action-feedback';
import { useEffect, useState, type ReactNode } from 'react';
import { Link } from 'react-router';
import { ArrowDownLeft, ArrowUpRight, Clock3, KeyRound, RefreshCw } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { FinanceBookSelector, useFinanceBook } from '@/contexts/FinanceBookContext';
import { financeOverviewApi, type FinanceOverview as FinanceOverviewData } from '@/services/api';

function money(value: string, currency: string) {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency }).format(Number(value));
}

function localToday() {
  const date = new Date();
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

function Metric({ label, value, detail, icon }: { label: string; value: string; detail: string; icon: ReactNode }) {
  return <div className="rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm">
    <div className="flex items-center gap-2 text-sm font-medium text-neutral-600">{icon}{label}</div>
    <p className="mt-3 text-2xl font-semibold tabular-nums text-neutral-950">{value}</p>
    <p className="mt-1 text-xs leading-5 text-neutral-600">{detail}</p>
  </div>;
}

export function FinanceOverview() {
  const { activeBook } = useFinanceBook();
  const [overview, setOverview] = useState<FinanceOverviewData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [refresh, setRefresh] = useState(0);
  const switchingBook = overview !== null && overview.finance_book_id !== activeBook.id;

  useEffect(() => {
    let current = true;
    setLoading(true);
    setError(null);
    setOverview(null);
    void financeOverviewApi.show(localToday()).then((data) => {
      if (!current) return;
      if (data.finance_book_id !== activeBook.id) throw new Error('Financial book changed. Refresh this overview.');
      setOverview(data);
    }).catch((loadError) => {
      if (current) setError(loadError instanceof Error ? loadError.message : 'Unable to load finance overview');
    }).finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [activeBook.id, refresh]);

  return <div className="min-h-screen bg-[#f8f7f4]">
    <Header title="Finance Overview" description="Invoices owed to you and expenses you owe, together in one financial book."
      contextLabel="Financial book" contextValue={activeBook.name}
      actions={<Button variant="outline" onClick={() => setRefresh((value) => value + 1)} disabled={loading}><RefreshCw className="mr-2 h-4 w-4" />Refresh</Button>} />
    <main className="mx-auto max-w-[1500px] space-y-6 px-4 py-6 sm:px-6 lg:px-8">
      <FinanceBookSelector disabled={loading} />
      <div className="grid gap-3 sm:grid-cols-3">
        <Link to="/tools/invoices" className="flex min-h-12 items-center justify-between rounded-xl border border-neutral-200 bg-white px-4 text-sm font-semibold text-primary-800 hover:border-primary-300 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-600">Manage invoices <ArrowUpRight className="h-4 w-4" /></Link>
        <Link to="/tools/expenses" className="flex min-h-12 items-center justify-between rounded-xl border border-neutral-200 bg-white px-4 text-sm font-semibold text-primary-800 hover:border-primary-300 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-600">Manage bills & purchases <ArrowUpRight className="h-4 w-4" /></Link>
        <Link to="/tools/finance/agent-access" className="flex min-h-12 items-center justify-between rounded-xl border border-neutral-200 bg-white px-4 text-sm font-semibold text-primary-800 hover:border-primary-300 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-600">Agent access <KeyRound className="h-4 w-4" /></Link>
      </div>
      {error && <ActionFeedback tone="error" message={error} />}
      {loading || switchingBook ? <p role="status" className="text-sm text-neutral-600">Loading this book’s finances…</p>
        : error ? null
        : !overview?.currencies.length ? <div className="rounded-2xl border border-neutral-200 bg-white p-6 text-sm text-neutral-600">No invoices or expenses are recorded in this book yet. Start with an invoice or vendor bill.</div>
          : overview.currencies.map((row) => <section key={row.currency} aria-label={`${row.currency} finance summary`} className="space-y-4">
            <div className="flex flex-wrap items-baseline justify-between gap-2"><h2 className="text-lg font-semibold text-neutral-950">{row.currency}</h2><p className="text-xs text-neutral-500">Current balances · overdue as of {overview.as_of}</p></div>
            <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
              <Metric label="Customers owe" value={money(row.receivables, row.currency)} detail={`${row.open_invoice_count} open invoices · ${money(row.overdue_receivables, row.currency)} overdue`} icon={<ArrowDownLeft className="h-4 w-4 text-primary-700" />} />
              <Metric label="You owe vendors" value={money(row.payables, row.currency)} detail={`${row.open_expense_count} open expenses · ${money(row.overdue_payables, row.currency)} overdue`} icon={<ArrowUpRight className="h-4 w-4 text-amber-700" />} />
              <Metric label="Payments received" value={money(row.payments_received, row.currency)} detail="Recorded invoice payments, all time" icon={<ArrowDownLeft className="h-4 w-4 text-emerald-700" />} />
              <Metric label="Payments made" value={money(row.payments_made, row.currency)} detail="Recorded expense payments, all time" icon={<ArrowUpRight className="h-4 w-4 text-rose-700" />} />
            </div>
            {(row.overdue_invoice_count > 0 || row.overdue_expense_count > 0) && <div className="flex items-center gap-2 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900"><Clock3 className="h-4 w-4 shrink-0" />{row.overdue_invoice_count} overdue invoices and {row.overdue_expense_count} overdue expenses need review.</div>}
          </section>)}
      <p className="text-xs leading-5 text-neutral-600">Payments shown here are entries in this book. Match them to bank, card, or processor statements before treating them as reconciled cash.</p>
    </main>
  </div>;
}
