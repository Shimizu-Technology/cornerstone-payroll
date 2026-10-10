import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { formatCurrency, formatDateRange, formatDate } from '@/lib/utils';
import type { PayPeriod } from '@/types';

type Props = {
  open: boolean;
  payPeriod: Pick<PayPeriod, 'id' | 'status' | 'start_date' | 'end_date' | 'pay_date' | 'compliance_warnings' | 'correction_status'>;
  companyName: string;
  itemCount: number;
  totalNet: number;
  processing: boolean;
  onCancel: () => void;
  onConfirm: (payPeriodId: number) => void;
};

export function PayrollCommitDialog({ open, payPeriod, companyName, itemCount, totalNet, processing, onCancel, onConfirm }: Props) {
  const canConfirm = !processing && payPeriod.status === 'approved' && payPeriod.correction_status !== 'voided';
  return <Dialog open={open} onOpenChange={value => { if (!value && !processing) onCancel(); }} dismissOnEscape={!processing}>
    <DialogContent>
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
