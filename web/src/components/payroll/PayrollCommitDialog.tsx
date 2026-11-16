import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { formatCurrency, formatDateRange, formatDate } from '@/lib/utils';
import type { PayPeriod } from '@/types';

type Props = {
  open: boolean;
  payPeriod: Pick<PayPeriod, 'id' | 'status' | 'start_date' | 'end_date' | 'pay_date' | 'compliance_warnings' | 'correction_status' | 'check_number_summary' | 'payroll_items'>;
  companyName: string;
  itemCount: number;
  totalNet: number;
  processing: boolean;
  onCancel: () => void;
  onConfirm: (payPeriodId: number) => void;
};

export function PayrollCommitDialog({ open, payPeriod, companyName, itemCount, totalNet, processing, onCancel, onConfirm }: Props) {
  const canConfirm = !processing && payPeriod.status === 'approved' && payPeriod.correction_status !== 'voided';
  const hasPaperChecks = payPeriod.payroll_items?.some(item => (item.effective_payment_delivery_method ?? item.payment_delivery_method ?? 'paper_check') === 'paper_check');
  const numbering = payPeriod.check_number_summary;
  return <Dialog open={open} onOpenChange={value => { if (!value && !processing) onCancel(); }} dismissOnEscape={!processing}>
    <DialogContent className="max-h-[calc(100dvh-2rem)] overflow-y-auto">
      <DialogHeader>
        <DialogTitle>Commit and finalize payroll?</DialogTitle>
        <DialogDescription>This locks the calculated payroll and updates year-to-date totals. Checks and bank payments require separate issuance or settlement confirmation.</DialogDescription>
      </DialogHeader>
      <dl className="grid gap-3 rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm sm:grid-cols-2">
        <div><dt className="text-neutral-600">Company</dt><dd className="font-semibold text-neutral-950">{companyName}</dd></div>
        <div><dt className="text-neutral-600">Pay run</dt><dd className="font-semibold text-neutral-950">#{payPeriod.id}</dd></div>
        <div><dt className="text-neutral-600">Work dates</dt><dd>{formatDateRange(payPeriod.start_date, payPeriod.end_date)}</dd></div>
        <div><dt className="text-neutral-600">Scheduled pay date</dt><dd>{formatDate(payPeriod.pay_date)}</dd></div>
        <div><dt className="text-neutral-600">Payroll items</dt><dd>{itemCount}</dd></div>
        <div><dt className="text-neutral-600">Total net pay</dt><dd className="font-semibold">{formatCurrency(totalNet)}</dd></div>
      </dl>
      {hasPaperChecks && numbering && <div className="text-sm leading-6 text-neutral-700">
        <p>Paper checks will be numbered from {numbering.next_check_number} (last used: {numbering.last_used_check_number ?? 'none'})</p>
        {numbering.last_used_check_number !== null && numbering.next_check_number <= numbering.last_used_check_number && <p role="alert" className="font-semibold text-warning-900">The next check number ({numbering.next_check_number}) is at or below the last one used ({numbering.last_used_check_number}). Check the stock before committing.</p>}
        {numbering.can_change && <a className="font-medium text-primary-700 underline" href="/check-settings">Review check settings</a>}
      </div>}
      {!!payPeriod.compliance_warnings?.length && <div className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm text-warning-900">
        <p className="font-semibold">Review these warnings before committing</p>
        <ul className="mt-2 list-disc space-y-1 pl-5">{payPeriod.compliance_warnings.map((warning, index) => <li key={index}>{warning}</li>)}</ul>
      </div>}
      <p className="text-sm leading-6 text-neutral-600">Review this run before confirming. Later payroll changes must use the corrections workflow.</p>
      <DialogFooter className="gap-2 sm:gap-0">
        <Button className="max-sm:min-h-[44px]" type="button" variant="outline" disabled={processing} onClick={onCancel}>Keep reviewing</Button>
        <Button className="max-sm:min-h-[44px]" type="button" disabled={!canConfirm} onClick={() => { if (canConfirm) onConfirm(payPeriod.id); }}>{processing ? 'Committing…' : 'Confirm commit'}</Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>;
}
