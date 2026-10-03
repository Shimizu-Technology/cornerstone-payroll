import { useState } from 'react';
import { checksApi } from '@/services/api';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { guamBusinessDate } from '@/lib/payrollBusinessDate';

interface DepositItem {
  id: number;
  employee_name: string;
  net_pay: number;
}

export function RecordDirectDepositPaymentDialog({ item, onClose, onComplete }: {
  item: DepositItem;
  onClose: () => void;
  onComplete: () => Promise<void>;
}) {
  const [settledOn, setSettledOn] = useState(guamBusinessDate());
  const [bankReference, setBankReference] = useState('');
  const [note, setNote] = useState('');
  const [attested, setAttested] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    setSaving(true);
    setError(null);
    try {
      await checksApi.confirmDirectDepositPayment(item.id, {
        settled_on: settledOn,
        bank_reference: bankReference.trim(),
        note: note.trim() || undefined,
        attestation: attested,
      });
      await onComplete();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Could not record bank payment.');
    } finally {
      setSaving(false);
    }
  };

  return <Dialog open onOpenChange={(open) => { if (!open && !saving) onClose(); }}>
    <DialogContent>
      <DialogHeader>
        <DialogTitle>Confirm bank payment</DialogTitle>
        <DialogDescription>
          {item.employee_name} · ${item.net_pay.toFixed(2)} net. Record this only after verifying the transfer completed at the bank. Cornerstone does not send the transfer.
        </DialogDescription>
      </DialogHeader>
      <div className="grid gap-4">
        <Input label="Bank settlement date" type="date" value={settledOn} onChange={(event) => setSettledOn(event.target.value)} />
        <Input label="Bank confirmation or transaction reference" value={bankReference} onChange={(event) => setBankReference(event.target.value)} helperText="Required evidence from your bank or payment provider." />
        <Input label="Note (optional)" value={note} onChange={(event) => setNote(event.target.value)} />
      </div>
      <label className="flex items-start gap-2 rounded-xl border border-primary-200 bg-primary-50 p-4 text-sm leading-5 text-primary-900">
        <input className="mt-1 h-4 w-4" type="checkbox" checked={attested} onChange={(event) => setAttested(event.target.checked)} />
        <span>I verified this transfer completed at the bank. Recording it will mark any linked AIRE hours paid.</span>
      </label>
      {error && <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 p-4 text-sm text-danger-700">{error}</div>}
      <DialogFooter>
        <Button variant="outline" onClick={onClose} disabled={saving}>Cancel</Button>
        <Button onClick={() => void submit()} disabled={saving || !settledOn || !bankReference.trim() || !attested}>{saving ? 'Recording…' : 'Confirm payment'}</Button>
      </DialogFooter>
    </DialogContent>
  </Dialog>;
}
