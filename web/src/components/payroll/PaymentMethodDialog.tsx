import { useEffect, useRef, useState, type ReactElement } from 'react';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { ActionFeedback, useFeedback, useFeedbackState } from '@/components/ui/action-feedback';
import { payrollItemsApi } from '@/services/api';
import { paymentMethodLabel } from '@/lib/employee-payment-delivery';
import { formatDate } from '@/lib/utils';
import type { PayPeriod, PayrollItem, PaymentDeliveryMethod } from '@/types';



interface Props {
  payPeriod: PayPeriod;
  item: PayrollItem | null;
  onClose: () => void;
  onSaved: () => Promise<void>;
}

export function PaymentMethodDialog({ payPeriod, item, onClose, onSaved }: Props): ReactElement {
  const { notify } = useFeedback();
  const [record, setRecord] = useState<PayrollItem | null>(null);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [method, setMethod] = useState<PaymentDeliveryMethod>('paper_check');
  const [futureDefault, setFutureDefault] = useState(false);
  const [reason, setReason] = useState('');
  const [unpaid, setUnpaid] = useState(false);
  const [cancelled, setCancelled] = useState(false);
  const [evidence, setEvidence] = useState('');
  const [error, setError, errorAttempt] = useFeedbackState<string | null>(null);
  const [reload, setReload] = useState(0);
  const itemId = item?.id;
  const scope = `${payPeriod.company_id}:${payPeriod.id}:${itemId || ''}`;
  const activeRef = useRef(false);
  useEffect(() => { activeRef.current = true; return () => { activeRef.current = false; }; }, []);
  const scopeRef = useRef(scope);
  scopeRef.current = scope;

  useEffect(() => {
    let active = true;
    setRecord(null);
    setError(null);
    setSaving(false);
    setFutureDefault(false);
    setReason('');
    setUnpaid(false);
    setCancelled(false);
    setEvidence('');
    if (!itemId) return;
    setLoading(true);
    void payrollItemsApi.get(payPeriod.id, itemId, payPeriod.company_id).then(({ payroll_item }) => {
      if (!active) return;
      setRecord(payroll_item);
      setMethod(payroll_item.effective_payment_delivery_method === 'direct_deposit' ? 'paper_check' : 'direct_deposit');
    }).catch((caught: unknown) => {
      if (active) setError(caught instanceof Error ? caught.message : 'Could not check this payment. Try again.');
    }).finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [scope, itemId, payPeriod.id, payPeriod.company_id, reload, setError]);

  const currentMethod = record?.effective_payment_delivery_method || record?.payment_delivery_method || 'paper_check';
  const eligibility = record?.payment_method_change;
  const methodChanges = method !== currentMethod;
  const committed = eligibility?.requires_unpaid_confirmation ?? payPeriod.status === 'committed';
  const retiresCheck = committed && methodChanges && eligibility?.mode === 'retire_check';
  const blocked = !eligibility || !eligibility.eligible;
  const ready = Boolean(record && !loading && !saving && !blocked && (methodChanges || futureDefault) &&
    (!committed || (reason.trim().length >= 10 && unpaid)) && (!retiresCheck || (cancelled && evidence.trim())));

  const save = async (): Promise<void> => {
    if (!record || !ready) return;
    const savingScope = scope;
    setSaving(true);
    setError(null);
    let saved: Awaited<ReturnType<typeof payrollItemsApi.updatePaymentMethod>>;
    try {
      saved = await payrollItemsApi.updatePaymentMethod(payPeriod.id, record.id, method, {
        update_employee_default: futureDefault,
        expected_check_number: record.check_number || null,
        ...(committed ? { reason: reason.trim(), confirm_not_paid: unpaid } : {}),
        ...(retiresCheck ? { retire_existing_check: true, confirm_check_cancelled: cancelled, cancellation_evidence_reference: evidence.trim() } : {}),
      }, payPeriod.company_id);
    } catch (caught) {
      if (activeRef.current && scopeRef.current === savingScope) {
        setError(caught instanceof Error ? caught.message : 'Could not change the payment method.');
        setSaving(false);
      }
      return;
    }
    if (!activeRef.current || scopeRef.current !== savingScope) return;
    notify({ tone: 'success', message: `${record.employee_name}: ${paymentMethodLabel(method)} for ${formatDate(payPeriod.pay_date)}. ${futureDefault ? 'Future payroll default also updated.' : 'Future payroll default unchanged.'} No bank transfer was sent.${payPeriod.status === 'approved' && saved.pay_period_status === 'calculated' ? ' Review and approve this payroll again.' : ''}` });
    const reapprovals = saved.payment_method_review?.reapproval_pay_period_ids || [];
    if (reapprovals.length) notify({ tone: 'warning', message: `Review and approve pay runs ${reapprovals.map(id => `#${id}`).join(', ')} again before processing. Their recorded delivery choices were preserved.` });
    setSaving(false);
    onClose();
    try { await onSaved(); }
    catch { notify({ tone: 'warning', message: 'The payment method was saved, but the screen could not refresh. Reload to see the saved method; do not submit the change again.' }); }
  };

  return <Dialog open={item !== null} onOpenChange={(open) => { if (!open && !saving) onClose(); }} dismissOnEscape={!saving}>
    <DialogContent>
      <DialogHeader><DialogTitle>Change payment method</DialogTitle><DialogDescription>{item?.employee_name} · Pay date {formatDate(payPeriod.pay_date)}. Wages, taxes, deductions, and YTD stay the same.</DialogDescription></DialogHeader>
      {loading && <p role="status" className="text-sm text-neutral-600">Checking the payment and its check history…</p>}
      {error && <ActionFeedback tone="error" message={error} retryKey={errorAttempt} />}
      {!loading && !record && <Button className="max-sm:min-h-[44px]" variant="outline" onClick={() => setReload(value => value + 1)}>Try again</Button>}
      {record && <fieldset disabled={saving} className="space-y-4">
        <p className="text-sm text-neutral-600">Current method: <strong>{paymentMethodLabel(currentMethod)}</strong></p>
        {blocked ? <p role="note" className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-950">{eligibility?.reason || 'This payment cannot be changed until its eligibility has been verified. Refresh and try again.'}</p> : <>
          <Select label="Payment method for this payroll" value={method} onChange={event => setMethod(event.target.value as PaymentDeliveryMethod)}><option value="paper_check">Paper check</option><option value="direct_deposit">Direct deposit</option></Select>
          <p className="text-sm text-neutral-600">This payroll only, unless you also update the future default below.</p>
          <label className="flex items-start gap-3 text-sm"><input type="checkbox" className="mt-1 h-4 w-4 shrink-0" checked={futureDefault} onChange={event => setFutureDefault(event.target.checked)} />Also use this method as the employee’s future payroll default</label>
          {payPeriod.status === 'approved' && !committed && <p role="note" className="rounded-xl bg-amber-50 p-3 text-sm text-amber-900">This change returns the run to Calculated. Review and approve it again before processing.</p>}
          {committed && <>
            <Input label="Reason for changing this payment (at least 10 characters)" value={reason} onChange={event => setReason(event.target.value)} />
            <label className="flex items-start gap-3 text-sm"><input type="checkbox" className="mt-1 h-4 w-4 shrink-0" checked={unpaid} onChange={event => setUnpaid(event.target.checked)} />I verified that this payment has not been paid by check or bank transfer.</label>
            {retiresCheck ? <>
              <p className="rounded-xl bg-amber-50 p-3 text-sm leading-6 text-amber-950">Check #{record.check_number} was prepared or printed. Cancel that check before changing delivery. This records cancellation of the check only; the employee’s earned wages remain payable.</p>
              <Input label="Check cancellation evidence reference" helperText="Reference the returned/destroyed check or the bank’s stop-payment confirmation. Do not enter bank account numbers." value={evidence} onChange={event => setEvidence(event.target.value)} />
              <label className="flex items-start gap-3 text-sm"><input type="checkbox" className="mt-1 h-4 w-4 shrink-0" checked={cancelled} onChange={event => setCancelled(event.target.checked)} />I verified that the original check is cancelled and cannot be used for payment.</label>
            </> : methodChanges && <p className="text-sm text-neutral-600">{method === 'direct_deposit' ? 'The unissued check number will be retired.' : 'A new paper-check number will be assigned.'}</p>}
          </>}
          <p className="text-xs leading-5 text-neutral-600">Confirm direct-deposit enrollment with the employer or bank. Selecting Direct deposit or printing an earnings statement does not send money.</p>
        </>}
      </fieldset>}
      <DialogFooter className="gap-2 sm:gap-0"><Button className="max-sm:min-h-[44px]" variant="outline" disabled={saving} onClick={onClose}>Cancel</Button><Button className="max-sm:min-h-[44px]" disabled={!ready} onClick={() => void save()}>{saving ? 'Saving…' : retiresCheck ? 'Record cancellation and save' : 'Save payment method'}</Button></DialogFooter>
    </DialogContent>
  </Dialog>;
}
