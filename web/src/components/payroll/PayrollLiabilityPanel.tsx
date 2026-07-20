import { useMemo, useState } from 'react';
import { Download, Paperclip, RotateCcw, WalletCards } from 'lucide-react';
import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { payPeriodsApi } from '@/services/api';
import { formatCurrency, formatDate, formatGuamDateTime } from '@/lib/utils';
import type { PayrollLiabilityObligation, PayrollLiabilityPayment, PayrollLiabilityReconciliation } from '@/types';

interface PayrollLiabilityPanelProps {
  reconciliation: PayrollLiabilityReconciliation | null;
  loading: boolean;
  error: string | null;
  onUpdated?: (reconciliation: PayrollLiabilityReconciliation) => void;
}

const categoryLabels: Record<string, string> = {
  guam_income_tax_withheld: 'Guam income tax withheld',
  social_security_employee: 'Social Security — employee',
  social_security_employer: 'Social Security — employer',
  medicare_employee: 'Medicare — employee',
  medicare_employer: 'Medicare — employer',
  additional_medicare_employee: 'Additional Medicare — employee',
  retirement_employee: 'Retirement — employee',
  roth_retirement_employee: 'Roth retirement — employee',
  retirement_employer: 'Retirement — employer',
  roth_retirement_employer: 'Roth retirement — employer',
  insurance_employee: 'Insurance — employee',
  garnishment: 'Garnishment',
  child_support: 'Child support',
  benefit_employee: 'Benefit — employee',
  benefit_employer: 'Benefit — employer',
  other_payroll_liability: 'Other payroll liability',
};

const postingTypeLabels: Record<string, string> = {
  commit: 'Payroll committed',
  historical_backfill: 'Historical payroll captured',
  replacement: 'Liability date replaced',
  reversal: 'Liabilities reversed',
};

const obligationStatus = {
  unpaid: { label: 'Unpaid', tone: 'bg-gray-100 text-gray-700' },
  due: { label: 'Due today', tone: 'bg-amber-100 text-amber-800' },
  overdue: { label: 'Overdue', tone: 'bg-red-100 text-red-800' },
  partially_paid: { label: 'Partially paid', tone: 'bg-blue-100 text-blue-800' },
  paid: { label: 'Paid', tone: 'bg-emerald-100 text-emerald-800' },
  overpaid: { label: 'Overpaid · review', tone: 'bg-purple-100 text-purple-800' },
} as const;

function uniqueKey(prefix: string) {
  return `${prefix}:${Date.now()}:${Math.random().toString(36).slice(2)}`;
}

function fileSize(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

export function PayrollLiabilityPanel({ reconciliation, loading, error, onUpdated }: PayrollLiabilityPanelProps) {
  const [selectedObligation, setSelectedObligation] = useState<PayrollLiabilityObligation | null>(null);
  const [paymentForm, setPaymentForm] = useState({ amount: '', payment_date: '', payment_method: 'ach', confirmation_number: '', notes: '' });
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [dueDrafts, setDueDrafts] = useState<Record<string, string>>({});
  const [reverseTarget, setReverseTarget] = useState<PayrollLiabilityPayment | null>(null);
  const [reverseReason, setReverseReason] = useState('');

  const paymentGroups = useMemo(() => {
    if (!reconciliation) return [];
    return reconciliation.payments.filter((payment) => payment.payment_type === 'settlement');
  }, [reconciliation]);

  if (loading) {
    return <Card className="p-5"><div className="h-5 w-52 animate-pulse rounded bg-gray-200" /><div className="mt-3 h-4 w-80 max-w-full animate-pulse rounded bg-gray-100" /></Card>;
  }
  if (error) {
    return <Card className="border-red-200 bg-red-50 p-5"><h3 className="font-semibold text-red-900">Payroll liability ledger unavailable</h3><p className="mt-1 text-sm text-red-700">{error}</p></Card>;
  }
  if (!reconciliation || reconciliation.status === 'not_applicable') return null;

  const statusConfig = {
    posted: { label: 'Posted', variant: 'success' as const, tone: 'border-emerald-200 bg-emerald-50', text: 'text-emerald-900' },
    attention_required: { label: 'Review needed', variant: 'warning' as const, tone: 'border-amber-200 bg-amber-50', text: 'text-amber-900' },
    legacy_unposted: { label: 'Historical · not posted', variant: 'warning' as const, tone: 'border-amber-200 bg-amber-50', text: 'text-amber-900' },
    reversed: { label: 'Reversed', variant: 'default' as const, tone: 'border-gray-200 bg-gray-50', text: 'text-gray-900' },
  }[reconciliation.status];

  const applyUpdate = (response: { payroll_liability_reconciliation: PayrollLiabilityReconciliation }) => {
    onUpdated?.(response.payroll_liability_reconciliation);
  };

  const openPayment = (obligation: PayrollLiabilityObligation) => {
    setActionError(null);
    setSelectedObligation(obligation);
    setPaymentForm({
      amount: Math.max(obligation.outstanding_amount, 0).toFixed(2),
      payment_date: new Intl.DateTimeFormat('en-CA', {
        timeZone: 'Pacific/Guam',
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
      }).format(new Date()),
      payment_method: 'ach',
      confirmation_number: '',
      notes: '',
    });
  };

  const recordPayment = async () => {
    if (!selectedObligation) return;
    setBusy(true);
    setActionError(null);
    try {
      const response = await payPeriodsApi.recordLiabilityPayment(reconciliation.pay_period_id, {
        authority: selectedObligation.authority,
        category: selectedObligation.category,
        amount: Number(paymentForm.amount),
        payment_date: paymentForm.payment_date,
        payment_method: paymentForm.payment_method,
        confirmation_number: paymentForm.confirmation_number || undefined,
        notes: paymentForm.notes || undefined,
        idempotency_key: uniqueKey('liability-payment'),
      });
      applyUpdate(response);
      setSelectedObligation(null);
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'Unable to record the payment');
    } finally {
      setBusy(false);
    }
  };

  const saveDueDate = async (obligation: PayrollLiabilityObligation) => {
    const key = `${obligation.authority}:${obligation.category}`;
    const dueDate = dueDrafts[key] || obligation.due_date || '';
    setBusy(true);
    setActionError(null);
    try {
      const response = await payPeriodsApi.updateLiabilityDueDate(reconciliation.pay_period_id, {
        authority: obligation.authority,
        category: obligation.category,
        due_date: dueDate,
      });
      applyUpdate(response);
      setDueDrafts((current) => { const next = { ...current }; delete next[key]; return next; });
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'Unable to update the due date');
    } finally {
      setBusy(false);
    }
  };

  const openReversal = (payment: PayrollLiabilityPayment) => {
    setActionError(null);
    setReverseTarget(payment);
    setReverseReason('');
  };

  const reversePayment = async () => {
    if (!reverseTarget || !reverseReason.trim()) return;
    setBusy(true);
    setActionError(null);
    try {
      const response = await payPeriodsApi.reverseLiabilityPayment(reconciliation.pay_period_id, reverseTarget.id, {
        reason: reverseReason.trim(),
        idempotency_key: uniqueKey(`liability-payment-${reverseTarget.id}-reversal`),
      });
      applyUpdate(response);
      setReverseTarget(null);
      setReverseReason('');
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'Unable to reverse the payment');
    } finally {
      setBusy(false);
    }
  };

  const uploadEvidence = async (payment: PayrollLiabilityPayment, file?: File) => {
    if (!file) return;
    setBusy(true);
    setActionError(null);
    try {
      const response = await payPeriodsApi.uploadLiabilityEvidence(reconciliation.pay_period_id, payment.id, file);
      applyUpdate(response);
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'Unable to attach the payment evidence');
    } finally {
      setBusy(false);
    }
  };

  const downloadEvidence = async (paymentId: number, evidenceId: number, filename: string) => {
    setBusy(true);
    try {
      const blob = await payPeriodsApi.liabilityEvidence(reconciliation.pay_period_id, paymentId, evidenceId, true);
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = filename;
      anchor.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'Unable to download the payment evidence');
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card className={statusConfig.tone}>
      <div className="flex flex-col gap-4 border-b border-current/10 p-4 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-2"><h3 className={`font-semibold ${statusConfig.text}`}>Payroll Liability Ledger</h3><Badge variant={statusConfig.variant}>{statusConfig.label}</Badge></div>
          <p className="mt-1 max-w-3xl text-sm text-gray-700">Committed obligations and evidence-backed settlement activity. Recording a payment here never recalculates wages or taxes.</p>
        </div>
        <div className="grid grid-cols-3 gap-5 text-right">
          <div><p className="text-[11px] font-medium uppercase tracking-wider text-gray-500">Calculated</p><p className="font-bold text-gray-950">{formatCurrency(reconciliation.active_liability)}</p></div>
          <div><p className="text-[11px] font-medium uppercase tracking-wider text-gray-500">Paid</p><p className="font-bold text-emerald-700">{formatCurrency(reconciliation.settled_amount)}</p></div>
          <div><p className="text-[11px] font-medium uppercase tracking-wider text-gray-500">Outstanding</p><p className="font-bold text-amber-800">{formatCurrency(reconciliation.outstanding_amount)}</p></div>
        </div>
      </div>

      {actionError && <div className="mx-4 mt-4 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800" role="alert">{actionError}</div>}

      {reconciliation.status === 'legacy_unposted' ? (
        <div className="p-4 text-sm text-amber-900">This payroll predates the liability ledger. Its saved payroll and calculations are unchanged. An operator must preview and explicitly run the historical backfill before settlement can be recorded.</div>
      ) : (
        <div className="p-4">
          <div className="mb-3 flex items-center gap-2"><WalletCards className="h-4 w-4 text-gray-500" /><h4 className="text-xs font-semibold uppercase tracking-wider text-gray-500">Settlement worksheet</h4></div>
          <div className="overflow-hidden rounded-xl border border-gray-200 bg-white">
            <div className="hidden grid-cols-[minmax(220px,1.5fr)_minmax(150px,1fr)_120px_120px_140px_120px] gap-3 bg-gray-50 px-4 py-2 text-[11px] font-semibold uppercase tracking-wider text-gray-500 lg:grid">
              <span>Recipient / category</span><span>Due date</span><span className="text-right">Calculated</span><span className="text-right">Paid</span><span className="text-right">Outstanding</span><span />
            </div>
            {reconciliation.obligations.map((obligation) => {
              const key = `${obligation.authority}:${obligation.category}`;
              const status = obligationStatus[obligation.status];
              return (
                <div key={key} className="grid gap-3 border-t border-gray-100 px-4 py-3 first:border-t-0 lg:grid-cols-[minmax(220px,1.5fr)_minmax(150px,1fr)_120px_120px_140px_120px] lg:items-center">
                  <div><p className="font-medium text-gray-950">{obligation.authority}</p><div className="mt-1 flex flex-wrap items-center gap-2"><span className="text-xs text-gray-500">{categoryLabels[obligation.category] || obligation.category.replaceAll('_', ' ')}</span><span className={`rounded-full px-2 py-0.5 text-[11px] font-semibold ${status.tone}`}>{status.label}</span></div></div>
                  <div className="flex items-center gap-2"><Input type="date" aria-label={`Due date for ${obligation.authority}`} value={dueDrafts[key] ?? obligation.due_date ?? ''} onChange={(event) => setDueDrafts((current) => ({ ...current, [key]: event.target.value }))} className="py-2" /><Button size="sm" variant="ghost" disabled={busy || !dueDrafts[key] || dueDrafts[key] === obligation.due_date} onClick={() => saveDueDate(obligation)}>Save</Button></div>
                  <p className="text-right text-sm text-gray-700">{formatCurrency(obligation.calculated_amount)}</p>
                  <p className="text-right text-sm font-medium text-emerald-700">{formatCurrency(obligation.settled_amount)}</p>
                  <p className="text-right font-semibold text-gray-950">{formatCurrency(obligation.outstanding_amount)}</p>
                  <Button size="sm" variant="outline" disabled={busy || obligation.outstanding_amount <= 0} onClick={() => openPayment(obligation)}>Record payment</Button>
                </div>
              );
            })}
            {reconciliation.obligations.length === 0 && <p className="px-4 py-6 text-center text-sm text-gray-500">No active liability obligations remain on this pay period.</p>}
          </div>
        </div>
      )}

      {paymentGroups.length > 0 && (
        <div className="border-t border-current/10 bg-white/70 p-4">
          <h4 className="text-xs font-semibold uppercase tracking-wider text-gray-500">Payment and evidence history</h4>
          <div className="mt-3 space-y-3">
            {paymentGroups.map((payment) => (
              <div key={payment.id} className="rounded-xl border border-gray-200 bg-white p-3">
                <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                  <div><div className="flex flex-wrap items-center gap-2"><p className="font-semibold text-gray-950">{formatCurrency(payment.amount)} to {payment.authority}</p>{payment.reversed && <Badge variant="default">Reversed</Badge>}</div><p className="mt-1 text-xs text-gray-500">{formatDate(payment.payment_date)} · {payment.payment_method.toUpperCase()}{payment.confirmation_number ? ` · Confirmation ${payment.confirmation_number}` : ''} · recorded {formatGuamDateTime(payment.recorded_at)}{payment.recorded_by_name ? ` by ${payment.recorded_by_name}` : ''}</p>{payment.notes && <p className="mt-1 text-sm text-gray-700">{payment.notes}</p>}</div>
                  <div className="flex flex-wrap gap-2">
                    {!payment.reversed && <label className="inline-flex cursor-pointer items-center rounded-full border border-gray-300 bg-white px-3 py-1.5 text-xs font-semibold text-gray-700 transition hover:border-primary-300 hover:bg-primary-50"><Paperclip className="mr-1.5 h-3.5 w-3.5" />Attach evidence<input type="file" className="sr-only" accept="application/pdf,image/jpeg,image/png,image/webp" disabled={busy} onChange={(event) => { void uploadEvidence(payment, event.target.files?.[0]); event.currentTarget.value = ''; }} /></label>}
                    {!payment.reversed && <Button size="sm" variant="ghost" disabled={busy} onClick={() => openReversal(payment)}><RotateCcw className="mr-1.5 h-3.5 w-3.5" />Reverse</Button>}
                  </div>
                </div>
                {payment.evidence.length > 0 && <div className="mt-3 flex flex-wrap gap-2">{payment.evidence.map((record) => <button key={record.id} type="button" className="inline-flex items-center rounded-lg bg-gray-50 px-2.5 py-1.5 text-xs text-gray-700 transition hover:bg-gray-100" onClick={() => downloadEvidence(payment.id, record.id, record.filename)} disabled={busy}><Download className="mr-1.5 h-3.5 w-3.5" />{record.filename} · {fileSize(record.byte_size)}</button>)}</div>}
              </div>
            ))}
          </div>
        </div>
      )}

      {reconciliation.unclassified_components.length > 0 && <div className="mx-4 mb-4 rounded-lg border border-amber-300 bg-amber-50 p-3"><p className="text-sm font-semibold text-amber-900">Some deductions need a liability category and payee</p><ul className="mt-2 space-y-1 text-sm text-amber-900">{reconciliation.unclassified_components.map((component, index) => <li key={`${component.payroll_item_id}-${component.source}-${index}`}>{component.label}: {formatCurrency(component.amount)} — {component.reason}</li>)}</ul></div>}

      {reconciliation.postings.length > 0 && <details className="border-t border-current/10 bg-white/60 px-4 py-3"><summary className="cursor-pointer text-sm font-medium text-gray-700">Journal history ({reconciliation.postings.length} {reconciliation.postings.length === 1 ? 'posting' : 'postings'})</summary><div className="mt-3 space-y-2">{reconciliation.postings.map((posting) => <div key={posting.id} className="rounded-lg border border-gray-200 bg-white px-3 py-2 text-sm"><div className="flex flex-wrap items-center justify-between gap-2"><div><span className="font-medium text-gray-900">{postingTypeLabels[posting.posting_type]}</span><span className="ml-2 text-gray-500">Liability date {formatDate(posting.liability_date)}</span></div><span className={posting.net_amount < 0 ? 'font-semibold text-red-700' : 'font-semibold text-gray-900'}>{formatCurrency(posting.net_amount)}</span></div><p className="mt-1 text-xs text-gray-500">Recorded {formatGuamDateTime(posting.posted_at)}{posting.posted_by_name ? ` by ${posting.posted_by_name}` : ''}{posting.reason ? ` · ${posting.reason}` : ''}</p></div>)}</div></details>}

      <div className="border-t border-current/10 px-4 py-3 text-xs text-gray-600">Calculated amounts come only from the immutable payroll journal. Paid amounts come only from recorded payment allocations; a transmittal or generated check does not mark an authority as paid.</div>

      <Dialog open={selectedObligation !== null} onOpenChange={(open) => { if (!open && !busy) setSelectedObligation(null); }}>
        <DialogContent>
          <DialogHeader><DialogTitle>Record liability payment</DialogTitle><DialogDescription>{selectedObligation ? `${selectedObligation.authority} · ${categoryLabels[selectedObligation.category] || selectedObligation.category}` : ''}</DialogDescription></DialogHeader>
          <div className="mt-5 space-y-4">
            <div className="grid gap-4 sm:grid-cols-2"><Input label="Payment amount" type="number" min="0.01" step="0.01" value={paymentForm.amount} onChange={(event) => setPaymentForm((current) => ({ ...current, amount: event.target.value }))} /><Input label="Payment date" type="date" value={paymentForm.payment_date} onChange={(event) => setPaymentForm((current) => ({ ...current, payment_date: event.target.value }))} /></div>
            <Select label="Payment method" value={paymentForm.payment_method} onChange={(event) => setPaymentForm((current) => ({ ...current, payment_method: event.target.value }))} options={[{ value: 'ach', label: 'ACH' }, { value: 'check', label: 'Check' }, { value: 'eftps', label: 'EFTPS' }, { value: 'wire', label: 'Wire' }, { value: 'card', label: 'Card' }, { value: 'cash', label: 'Cash' }, { value: 'other', label: 'Other' }]} />
            <Input label="Confirmation or reference number" value={paymentForm.confirmation_number} onChange={(event) => setPaymentForm((current) => ({ ...current, confirmation_number: event.target.value }))} placeholder="Recommended for reconciliation" />
            <div><label htmlFor="liability-payment-notes" className="mb-1.5 block text-sm font-medium text-neutral-700">Notes</label><Textarea id="liability-payment-notes" value={paymentForm.notes} onChange={(event) => setPaymentForm((current) => ({ ...current, notes: event.target.value }))} placeholder="Optional settlement context" /></div>
            {actionError && <p className="text-sm text-red-700" role="alert">{actionError}</p>}
          </div>
          <DialogFooter><Button variant="outline" onClick={() => setSelectedObligation(null)} disabled={busy}>Cancel</Button><Button onClick={recordPayment} disabled={busy || !paymentForm.amount || !paymentForm.payment_date}>{busy ? 'Recording…' : 'Record payment'}</Button></DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={reverseTarget !== null} onOpenChange={(open) => { if (!open && !busy) { setReverseTarget(null); setReverseReason(''); } }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Reverse liability payment?</DialogTitle>
            <DialogDescription>
              {reverseTarget ? `${formatCurrency(reverseTarget.amount)} to ${reverseTarget.authority}` : ''} will be offset by an immutable reversal entry. The original payment and its evidence will remain in the audit history.
            </DialogDescription>
          </DialogHeader>
          <div className="mt-5">
            <label htmlFor="liability-payment-reversal-reason" className="mb-1.5 block text-sm font-medium text-neutral-700">Reason for reversal</label>
            <Textarea id="liability-payment-reversal-reason" value={reverseReason} onChange={(event) => setReverseReason(event.target.value)} placeholder="For example: bank rejected the transfer" autoFocus />
            <p className="mt-2 text-xs text-gray-500">Required so the settlement history explains why the payment was reversed.</p>
            {actionError && <p className="mt-3 text-sm text-red-700" role="alert">{actionError}</p>}
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => { setReverseTarget(null); setReverseReason(''); }} disabled={busy}>Cancel</Button>
            <Button variant="destructive" onClick={reversePayment} disabled={busy || !reverseReason.trim()}>{busy ? 'Reversing…' : 'Reverse payment'}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </Card>
  );
}
