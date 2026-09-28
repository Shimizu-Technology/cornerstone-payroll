import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { ArrowDownToLine, CircleDollarSign, FileText, Plus, Receipt, Search, Upload, X } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { FinanceBookSelector } from '@/contexts/FinanceBookContext';
import { expenseVendorsApi, expensesApi, organizationsApi, type BlobDownload, type Expense, type ExpenseSummary, type ExpenseVendor } from '@/services/api';

type ExpenseForm = {
  expense_vendor_id: string;
  category: string;
  description: string;
  expense_on: string;
  due_on: string;
  total_amount: string;
  currency: string;
  reference_number: string;
};

const today = () => {
  const date = new Date();
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
};
const emptyExpense = (): ExpenseForm => ({
  expense_vendor_id: '', category: '', description: '', expense_on: today(), due_on: '',
  total_amount: '', currency: 'USD', reference_number: '',
});
const inputClass = 'mt-1 w-full rounded-md border border-neutral-300 bg-white px-3 py-2.5 text-sm text-neutral-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300';

function money(value: string | number, currency = 'USD') {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency }).format(Number(value));
}

function downloadBlob(data: BlobDownload, fallback: string) {
  const url = URL.createObjectURL(data.blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = data.filename || fallback;
  document.body.append(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function StatusLabel({ status }: { status: Expense['payment_status'] }) {
  const colors: Record<Expense['payment_status'], string> = {
    open: 'border-neutral-200 bg-neutral-50 text-neutral-700',
    partial: 'border-amber-200 bg-amber-50 text-amber-800',
    paid: 'border-emerald-200 bg-emerald-50 text-emerald-800',
    overdue: 'border-rose-200 bg-rose-50 text-rose-800',
    voided: 'border-neutral-200 bg-neutral-100 text-neutral-500',
  };
  return <span className={`rounded-full border px-2.5 py-1 text-xs font-semibold capitalize ${colors[status]}`}>{status}</span>;
}

export function ExpenseLedger() {
  const { user } = useAuth();
  const { activeOrganizationId, activeOrganizationName } = useCompany();
  const organizationId = activeOrganizationId || user?.organization_id;
  const [selectedOrganization, setSelectedOrganization] = useState<{ id: number; name: string } | null>(null);
  useEffect(() => {
    if (!organizationId || organizationId === user?.organization_id || user?.role !== 'super_admin') return;
    let active = true;
    void organizationsApi.get(organizationId).then((response) => {
      if (active) setSelectedOrganization({ id: organizationId, name: response.data.name });
    }).catch(() => {
      if (active) setSelectedOrganization(null);
    });
    return () => { active = false; };
  }, [organizationId, user?.organization_id, user?.role]);
  const organizationName = activeOrganizationName || (organizationId === user?.organization_id
    ? user?.organization_name
    : selectedOrganization && selectedOrganization.id === organizationId ? selectedOrganization.name : undefined);
  const [expenses, setExpenses] = useState<Expense[]>([]);
  const [summary, setSummary] = useState<ExpenseSummary | null>(null);
  const [vendors, setVendors] = useState<ExpenseVendor[]>([]);
  const [selected, setSelected] = useState<Expense | null>(null);
  const [page, setPage] = useState(1);
  const [totalCount, setTotalCount] = useState(0);
  const [vendorFilter, setVendorFilter] = useState('all');
  const [statusFilter, setStatusFilter] = useState('all');
  const [search, setSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [showExpenseForm, setShowExpenseForm] = useState(false);
  const [showVendorForm, setShowVendorForm] = useState(false);
  const [form, setForm] = useState<ExpenseForm>(emptyExpense);
  const [vendorName, setVendorName] = useState('');
  const [vendorEmail, setVendorEmail] = useState('');
  const [paymentAmount, setPaymentAmount] = useState('');
  const [paymentDate, setPaymentDate] = useState(today);
  const [paymentMethod, setPaymentMethod] = useState('ach');
  const [paymentReference, setPaymentReference] = useState('');
  const [reversePaymentId, setReversePaymentId] = useState<number | null>(null);
  const [reversalReason, setReversalReason] = useState('');
  const [voidReason, setVoidReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const requestSequence = useRef(0);
  const detailRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const timer = window.setTimeout(() => setDebouncedSearch(search.trim()), 250);
    return () => window.clearTimeout(timer);
  }, [search]);

  const load = useCallback(async (nextPage = 1) => {
    if (!organizationId) return;
    const sequence = ++requestSequence.current;
    try {
      const [expenseData, vendorData] = await Promise.all([
        expensesApi.list({ page: nextPage, per_page: 50, vendor_id: vendorFilter === 'all' ? undefined : Number(vendorFilter),
          q: debouncedSearch || undefined, status: statusFilter === 'all' ? undefined : statusFilter }),
        expenseVendorsApi.list(),
      ]);
      if (sequence !== requestSequence.current) return;
      setExpenses(expenseData.expenses);
      setSummary(expenseData.summary);
      setTotalCount(expenseData.meta.total_count);
      setVendors(vendorData.expense_vendors);
      setPage(nextPage);
      setError(null);
    } catch (loadError) {
      if (sequence === requestSequence.current) setError(loadError instanceof Error ? loadError.message : 'Unable to load expenses');
    } finally {
      if (sequence === requestSequence.current) setLoading(false);
    }
  }, [organizationId, vendorFilter, debouncedSearch, statusFilter]);

  useEffect(() => {
    setExpenses([]);
    setSummary(null);
    setVendors([]);
    setSelected(null);
    setPage(1);
    setLoading(true);
    void load(1);
    return () => { requestSequence.current += 1; };
  }, [organizationId, vendorFilter, debouncedSearch, statusFilter, load]);
  const summaryMoney = (field: 'balance_due' | 'amount_paid') => summary?.currencies.length
    ? summary.currencies.map((entry) => `${entry.currency} ${money(entry[field], entry.currency)}`).join(' · ')
    : money(0);

  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    setError(null);
    setNotice(null);
    try { await action(); }
    catch (actionError) { setError(actionError instanceof Error ? actionError.message : 'The action could not be completed'); }
    finally { setBusy(false); }
  };

  const refreshSelected = async (id: number) => {
    const result = await expensesApi.show(id);
    setSelected(result.expense);
    await load(page);
  };

  const saveVendor = () => run(async () => {
    if (!vendorName.trim()) throw new Error('Enter a vendor name');
    const response = await expenseVendorsApi.create({ name: vendorName.trim(), email: vendorEmail.trim() || undefined });
    await load();
    setForm((current) => ({ ...current, expense_vendor_id: String(response.expense_vendor.id) }));
    setVendorName('');
    setVendorEmail('');
    setShowVendorForm(false);
    setShowExpenseForm(true);
    setNotice('Vendor saved. Add the expense details below.');
  });

  const saveExpense = () => run(async () => {
    if (!form.expense_vendor_id || !form.category.trim() || !form.description.trim() || !form.expense_on) {
      throw new Error('Choose a vendor and enter a category, description, and expense date');
    }
    if (!(Number(form.total_amount) > 0)) throw new Error('Enter an amount greater than zero');
    const response = await expensesApi.create({
      expense_vendor_id: Number(form.expense_vendor_id), category: form.category.trim(),
      description: form.description.trim(), expense_on: form.expense_on, due_on: form.due_on || undefined,
      total_amount: form.total_amount, currency: form.currency, reference_number: form.reference_number.trim() || undefined,
    });
    await load(1);
    setSelected((await expensesApi.show(response.expense.id)).expense);
    setForm(emptyExpense());
    setShowExpenseForm(false);
    setNotice('Expense recorded. Add its receipt and payment evidence in the detail panel.');
  });

  const openExpense = (id: number) => run(async () => {
    await refreshSelected(id);
    if (window.innerWidth < 1280) {
      window.requestAnimationFrame(() => detailRef.current?.scrollIntoView({ block: 'start',
        behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' }));
    }
  });

  const savePayment = () => run(async () => {
    if (!selected) return;
    await expensesApi.recordPayment(selected.id, {
      amount: paymentAmount, paid_on: paymentDate, payment_method: paymentMethod,
      reference_number: paymentReference.trim() || undefined,
    });
    await refreshSelected(selected.id);
    setPaymentAmount('');
    setPaymentReference('');
    setNotice('Payment recorded with its date and method.');
  });

  const reversePayment = () => run(async () => {
    if (!selected || !reversePaymentId || !reversalReason.trim()) throw new Error('Enter a reversal reason');
    await expensesApi.reversePayment(selected.id, reversePaymentId, reversalReason.trim());
    await refreshSelected(selected.id);
    setReversePaymentId(null);
    setReversalReason('');
    setNotice('Payment reversed; its original record remains in the ledger.');
  });

  const uploadReceipt = (file: File | undefined) => run(async () => {
    if (!selected || !file) return;
    await expensesApi.uploadArtifact(selected.id, file);
    await refreshSelected(selected.id);
    setNotice('Original receipt attached.');
  });

  const voidExpense = () => run(async () => {
    if (!selected || !voidReason.trim()) throw new Error('Enter a void reason');
    await expensesApi.void(selected.id, voidReason.trim());
    await refreshSelected(selected.id);
    setVoidReason('');
    setNotice('Expense voided with its reason retained.');
  });

  return (
    <div className="min-h-screen bg-[#f8f7f4]">
      <Header title="Expense Ledger" description="Track vendor bills, receipts, and what has actually been paid for this book."
        contextLabel="Organization" contextValue={organizationName}
        actions={<>
          <Button variant="outline" onClick={() => void run(async () => downloadBlob(await expensesApi.export({
            vendor_id: vendorFilter === 'all' ? undefined : Number(vendorFilter),
            q: debouncedSearch || undefined,
            status: statusFilter === 'all' ? undefined : statusFilter,
          }), 'expenses.csv'))} disabled={busy}>
            <ArrowDownToLine className="mr-2 h-4 w-4" />Export CSV
          </Button>
          <Button variant="secondary" onClick={() => setShowVendorForm((value) => !value)}><Plus className="mr-2 h-4 w-4" />Vendor</Button>
          <Button onClick={() => setShowExpenseForm((value) => !value)}><Plus className="mr-2 h-4 w-4" />Expense</Button>
        </>} />

      <main className="mx-auto max-w-[1500px] space-y-6 px-4 py-6 sm:px-6 lg:px-8">
        <FinanceBookSelector disabled={busy || loading} />
        <div className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm leading-6 text-amber-900">
          Record payments from bank, card, or processor evidence. An invoice or receipt alone does not prove that a bill was paid.
        </div>
        {error && <div role="alert" className="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-800">{error}</div>}
        {notice && <div role="status" className="rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-800">{notice}</div>}

        <section className="grid gap-3 sm:grid-cols-3" aria-label="Expense summary for current filters">
          <SummaryCard label="Open balance" value={summaryMoney('balance_due')} note="Matching expenses" icon={<CircleDollarSign className="h-5 w-5" />} />
          <SummaryCard label="Payments recorded" value={summaryMoney('amount_paid')} note="Matching expenses" icon={<Receipt className="h-5 w-5" />} />
          <SummaryCard label="Overdue bills" value={String(summary?.overdue_count || 0)} note="Matching expenses" icon={<FileText className="h-5 w-5" />} />
        </section>

        {showVendorForm && <section className="rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm" aria-label="Add vendor">
          <div className="mb-4 flex items-center justify-between"><h2 className="text-lg font-semibold text-neutral-950">New vendor</h2><button aria-label="Close vendor form" onClick={() => setShowVendorForm(false)}><X className="h-4 w-4" /></button></div>
          <div className="grid gap-3 sm:grid-cols-2">
            <label className="text-sm font-medium">Vendor name<Input className="mt-1" value={vendorName} onChange={(event) => setVendorName(event.target.value)} /></label>
            <label className="text-sm font-medium">Email (optional)<Input className="mt-1" type="email" value={vendorEmail} onChange={(event) => setVendorEmail(event.target.value)} /></label>
          </div>
          <Button className="mt-4" onClick={saveVendor} disabled={busy}>Save vendor</Button>
        </section>}

        {showExpenseForm && <section className="rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm" aria-label="Add expense">
          <div className="mb-4 flex items-center justify-between"><div><h2 className="text-lg font-semibold text-neutral-950">Record an expense</h2><p className="text-sm text-neutral-500">Add the bill first, then attach the original and record verified payments.</p></div><button aria-label="Close expense form" onClick={() => setShowExpenseForm(false)}><X className="h-4 w-4" /></button></div>
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <label className="text-sm font-medium">Vendor<select className={inputClass} value={form.expense_vendor_id} onChange={(event) => setForm({ ...form, expense_vendor_id: event.target.value })}><option value="">Choose vendor</option>{vendors.filter((vendor) => vendor.active).map((vendor) => <option key={vendor.id} value={vendor.id}>{vendor.name}</option>)}</select></label>
            <label className="text-sm font-medium">Category<Input className="mt-1" value={form.category} onChange={(event) => setForm({ ...form, category: event.target.value })} placeholder="Software, travel, supplies…" /></label>
            <label className="text-sm font-medium">Expense date<Input className="mt-1" type="date" value={form.expense_on} onChange={(event) => setForm({ ...form, expense_on: event.target.value })} /></label>
            <label className="text-sm font-medium">Due date (optional)<Input className="mt-1" type="date" value={form.due_on} onChange={(event) => setForm({ ...form, due_on: event.target.value })} /></label>
            <label className="text-sm font-medium">Amount<Input className="mt-1" type="number" min="0.01" step="0.01" value={form.total_amount} onChange={(event) => setForm({ ...form, total_amount: event.target.value })} /></label>
            <label className="text-sm font-medium">Currency<Input className="mt-1" value={form.currency} maxLength={3} onChange={(event) => setForm({ ...form, currency: event.target.value.toUpperCase() })} /></label>
            <label className="text-sm font-medium sm:col-span-2">Vendor bill or reference<Input className="mt-1" value={form.reference_number} onChange={(event) => setForm({ ...form, reference_number: event.target.value })} /></label>
            <label className="text-sm font-medium sm:col-span-2 lg:col-span-4">Description<Textarea className="mt-1" rows={2} value={form.description} onChange={(event) => setForm({ ...form, description: event.target.value })} /></label>
          </div>
          <Button className="mt-4" onClick={saveExpense} disabled={busy}>Save expense</Button>
        </section>}

        <div className="grid items-start gap-5 xl:grid-cols-[minmax(0,1fr)_390px]">
          <section className="min-w-0 overflow-hidden rounded-2xl border border-neutral-200 bg-white shadow-sm" aria-label="Expenses">
            <div className="flex flex-col gap-3 border-b border-neutral-200 p-4 sm:flex-row sm:items-center">
              <div className="relative flex-1"><Search className="pointer-events-none absolute left-3 top-3 h-4 w-4 text-neutral-400" /><Input className="pl-9" placeholder="Search all expenses" value={search} onChange={(event) => setSearch(event.target.value)} aria-label="Search all expenses" /></div>
              <select className={inputClass + ' mt-0 sm:w-48'} value={vendorFilter} onChange={(event) => setVendorFilter(event.target.value)} aria-label="Filter by vendor"><option value="all">All vendors</option>{vendors.map((vendor) => <option key={vendor.id} value={vendor.id}>{vendor.name}</option>)}</select>
              <select className={inputClass + ' mt-0 sm:w-36'} value={statusFilter} onChange={(event) => setStatusFilter(event.target.value)} aria-label="Filter expenses by status"><option value="all">All statuses</option><option value="open">Open</option><option value="partial">Partial</option><option value="overdue">Overdue</option><option value="paid">Paid</option></select>
            </div>
            {loading ? <p className="p-8 text-sm text-neutral-500">Loading expenses…</p> : expenses.length === 0 ? <p className="p-8 text-sm text-neutral-500">No matching expenses. Clear the filters or add the first expense.</p> : <>
              <div className="divide-y divide-neutral-100 sm:hidden">{expenses.map((expense) => <button key={expense.id} type="button" onClick={() => void openExpense(expense.id)} className="w-full space-y-2 px-4 py-4 text-left hover:bg-neutral-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary-500" aria-label={`Open expense from ${expense.vendor_name} on ${expense.expense_on}, ${expense.reference_number || `record ${expense.id}`}`}><div className="flex items-start justify-between gap-3"><div className="min-w-0"><p className="font-semibold text-neutral-950">{expense.vendor_name}</p><p className="mt-1 truncate text-xs text-neutral-500">{expense.expense_on} · {expense.category}</p></div><StatusLabel status={expense.payment_status} /></div><div className="flex justify-between gap-3 text-sm"><span className="text-neutral-500">Total {money(expense.total_amount, expense.currency)}</span><span className="font-semibold text-neutral-900">Due {money(expense.balance_due, expense.currency)}</span></div></button>)}</div>
              <div className="hidden overflow-x-auto sm:block"><table className="w-full min-w-[720px] text-left text-sm"><thead className="bg-neutral-50 text-xs uppercase tracking-wide text-neutral-500"><tr><th className="px-4 py-3">Date / vendor</th><th className="px-4 py-3">Category</th><th className="px-4 py-3 text-right">Total</th><th className="px-4 py-3 text-right">Balance</th><th className="px-4 py-3">Status</th></tr></thead><tbody className="divide-y divide-neutral-100">{expenses.map((expense) => <tr key={expense.id} className={selected?.id === expense.id ? 'bg-primary-50' : 'hover:bg-neutral-50'}><td className="px-4 py-3"><button className="text-left font-semibold text-neutral-950 hover:text-primary-700 focus-visible:outline-none focus-visible:underline" onClick={() => void openExpense(expense.id)}>{expense.vendor_name}</button><div className="text-xs text-neutral-500">{expense.expense_on}{expense.reference_number ? ` · ${expense.reference_number}` : ''}</div></td><td className="px-4 py-3 text-neutral-700">{expense.category}</td><td className="px-4 py-3 text-right tabular-nums">{money(expense.total_amount, expense.currency)}</td><td className="px-4 py-3 text-right font-semibold tabular-nums">{money(expense.balance_due, expense.currency)}</td><td className="px-4 py-3"><StatusLabel status={expense.payment_status} /></td></tr>)}</tbody></table></div>
            </>}
            <div className="flex items-center justify-between border-t border-neutral-200 px-4 py-3 text-xs text-neutral-500"><span>{totalCount} expenses · page {page} of {Math.max(1, Math.ceil(totalCount / 50))}</span><div className="flex gap-2"><Button size="sm" variant="outline" disabled={busy || page <= 1} onClick={() => { setLoading(true); void load(page - 1); }}>Previous</Button><Button size="sm" variant="outline" disabled={busy || page * 50 >= totalCount} onClick={() => { setLoading(true); void load(page + 1); }}>Next</Button></div></div>
          </section>

          <aside ref={detailRef} className="scroll-mt-4 rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm xl:sticky xl:top-28" aria-label="Expense details">
            {!selected ? <div className="py-10 text-center"><Receipt className="mx-auto h-8 w-8 text-neutral-300" /><h2 className="mt-3 font-semibold text-neutral-900">Select an expense</h2><p className="mt-1 text-sm text-neutral-500">Payment history and original receipts appear here.</p></div> : <>
              <div className="flex items-start justify-between gap-3"><div><p className="text-xs font-semibold uppercase tracking-widest text-primary-700">Vendor bill</p><h2 className="mt-1 text-xl font-bold text-neutral-950">{selected.vendor_name}</h2><p className="mt-1 text-sm text-neutral-500">{selected.description}</p></div><StatusLabel status={selected.payment_status} /></div>
              <dl className="mt-5 grid grid-cols-2 gap-3 border-y border-neutral-200 py-4 text-sm"><div><dt className="text-neutral-500">Total</dt><dd className="font-semibold tabular-nums">{money(selected.total_amount, selected.currency)}</dd></div><div><dt className="text-neutral-500">Still due</dt><dd className="font-semibold tabular-nums">{money(selected.balance_due, selected.currency)}</dd></div><div><dt className="text-neutral-500">Expense date</dt><dd>{selected.expense_on}</dd></div><div><dt className="text-neutral-500">Due date</dt><dd>{selected.due_on || '—'}</dd></div></dl>

              <div className="mt-5"><h3 className="text-sm font-semibold text-neutral-950">Original receipts</h3><ul className="mt-2 space-y-2">{selected.artifacts?.map((artifact) => <li key={artifact.id}><button className="inline-flex items-center gap-2 text-sm text-primary-700 hover:underline" onClick={() => void run(async () => downloadBlob(await expensesApi.downloadArtifact(selected.id, artifact.id), artifact.filename))}><FileText className="h-4 w-4" />{artifact.filename}</button></li>)}</ul>{!selected.artifacts?.length && <p className="mt-2 text-xs text-neutral-500">No receipt attached yet.</p>}{!selected.voided_at && <label className="mt-3 inline-flex cursor-pointer items-center gap-2 text-sm font-semibold text-primary-700"><Upload className="h-4 w-4" />Attach PDF or image<input className="sr-only" type="file" accept="application/pdf,image/jpeg,image/png,image/webp" onChange={(event) => { const file = event.target.files?.[0]; if (file) void uploadReceipt(file); event.target.value = ''; }} /></label>}</div>

              <div className="mt-6 border-t border-neutral-200 pt-5"><h3 className="text-sm font-semibold text-neutral-950">Payments</h3><ul className="mt-3 space-y-3">{selected.payments?.map((payment) => <li key={payment.id} className="rounded-lg bg-neutral-50 p-3 text-sm"><div className="flex items-start justify-between gap-2"><div><p className={payment.reversed_at ? 'text-neutral-400 line-through' : 'font-semibold text-neutral-900'}>{money(payment.amount, selected.currency)}</p><p className="text-xs text-neutral-500">{payment.paid_on} · {payment.payment_method}{payment.reference_number ? ` · ${payment.reference_number}` : ''}</p></div>{!payment.reversed_at && !selected.voided_at && <button className="text-xs font-medium text-rose-700 hover:underline" onClick={() => { setReversePaymentId(payment.id); setReversalReason(''); }}>Reverse</button>}</div>{payment.reversed_at && <p className="mt-1 text-xs text-rose-700">Reversed: {payment.reversal_reason}</p>}</li>)}</ul>{!selected.payments?.length && <p className="mt-2 text-xs text-neutral-500">No payment has been recorded.</p>}
                {reversePaymentId && <div className="mt-3 rounded-lg border border-rose-200 p-3"><label className="text-xs font-medium">Reason for reversal<Input className="mt-1" value={reversalReason} onChange={(event) => setReversalReason(event.target.value)} /></label><div className="mt-2 flex gap-2"><Button size="sm" variant="danger" disabled={busy} onClick={reversePayment}>Reverse payment</Button><Button size="sm" variant="ghost" onClick={() => setReversePaymentId(null)}>Cancel</Button></div></div>}
                {!selected.voided_at && Number(selected.balance_due) > 0 && <div className="mt-4 grid grid-cols-2 gap-2"><label className="text-xs font-medium">Amount<Input className="mt-1" type="number" min="0.01" step="0.01" max={selected.balance_due} value={paymentAmount} onChange={(event) => setPaymentAmount(event.target.value)} /></label><label className="text-xs font-medium">Paid on<Input className="mt-1" type="date" value={paymentDate} onChange={(event) => setPaymentDate(event.target.value)} /></label><label className="text-xs font-medium">Method<select className={inputClass} value={paymentMethod} onChange={(event) => setPaymentMethod(event.target.value)}>{['ach', 'card', 'check', 'wire', 'cash', 'other'].map((method) => <option key={method} value={method}>{method.toUpperCase()}</option>)}</select></label><label className="text-xs font-medium">Reference<Input className="mt-1" value={paymentReference} onChange={(event) => setPaymentReference(event.target.value)} /></label><Button className="col-span-2 mt-1" disabled={busy || !paymentAmount} onClick={savePayment}>Record verified payment</Button></div>}
              </div>

              {!selected.voided_at && Number(selected.amount_paid) === 0 && <div className="mt-6 border-t border-neutral-200 pt-5"><label className="text-xs font-medium">Void reason<Input className="mt-1" value={voidReason} onChange={(event) => setVoidReason(event.target.value)} /></label><Button className="mt-2" variant="outline" size="sm" disabled={busy || !voidReason.trim()} onClick={voidExpense}>Void expense</Button></div>}
            </>}
          </aside>
        </div>
      </main>
    </div>
  );
}

function SummaryCard({ label, value, note, icon }: { label: string; value: string; note: string; icon: ReactNode }) {
  return <div className="rounded-2xl border border-neutral-200 bg-white px-5 py-4 shadow-sm"><div className="flex items-center justify-between text-neutral-500"><span className="text-xs font-semibold uppercase tracking-widest">{label}</span>{icon}</div><p className="mt-3 font-display text-3xl font-bold tracking-tight text-neutral-950">{value}</p><p className="mt-1 text-xs text-neutral-500">{note}</p></div>;
}
