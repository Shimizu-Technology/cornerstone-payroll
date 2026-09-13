import { useState } from 'react';
import { checksApi } from '@/services/api';
import type { CheckItem } from '@/types';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { guamBusinessDate } from '@/lib/payrollBusinessDate';

interface RecordCheckDeliveryDialogProps {
  item: CheckItem;
  onClose: () => void;
  onComplete: () => Promise<void>;
}

export function RecordCheckDeliveryDialog({ item, onClose, onComplete }: RecordCheckDeliveryDialogProps) {
  const [deliveredOn, setDeliveredOn] = useState(guamBusinessDate());
  const [deliveryMethod, setDeliveryMethod] = useState<'hand_delivery' | 'mail' | 'courier' | 'other'>('hand_delivery');
  const [evidenceReference, setEvidenceReference] = useState('');
  const [note, setNote] = useState('');
  const [attested, setAttested] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (): Promise<void> => {
    setSaving(true);
    setError(null);
    try {
      await checksApi.markDelivered(item.id, {
        delivered_on: deliveredOn,
        delivery_method: deliveryMethod,
        attestation: attested,
        evidence_reference: evidenceReference.trim() || undefined,
        note: note.trim() || undefined,
      });
      await onComplete();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not record check delivery.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open onOpenChange={(open) => { if (!open && !saving) onClose(); }}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Record check issued</DialogTitle>
          <DialogDescription>
            Check #{item.check_number} for {item.employee_name}. Printing prepared the check; this step records when it left Cornerstone&apos;s control.
          </DialogDescription>
        </DialogHeader>
        <div className="grid gap-4 sm:grid-cols-2">
          <Input label="Issue date" type="date" value={deliveredOn} onChange={(event) => setDeliveredOn(event.target.value)} />
          <Select label="How it was issued" value={deliveryMethod} onChange={(event) => setDeliveryMethod(event.target.value as typeof deliveryMethod)}>
            <option value="hand_delivery">Handed to employee</option>
            <option value="mail">Mailed</option>
            <option value="courier">Courier / delivery service</option>
            <option value="other">Other documented method</option>
          </Select>
          <Input className="sm:col-span-2" label="Reference (optional)" helperText="Mail receipt, courier reference, or internal handoff reference." value={evidenceReference} onChange={(event) => setEvidenceReference(event.target.value)} />
          <Input className="sm:col-span-2" label="Note (optional)" value={note} onChange={(event) => setNote(event.target.value)} />
        </div>
        <label className="flex items-start gap-2 rounded-xl border border-primary-200 bg-primary-50 p-4 text-sm leading-5 text-primary-900">
          <input className="mt-1 h-4 w-4" type="checkbox" checked={attested} onChange={(event) => setAttested(event.target.checked)} />
          <span>I confirm this check was released using the method and date above. This will mark linked AIRE hours as paid.</span>
        </label>
        {error && <div className="rounded-lg border border-danger-200 bg-danger-50 p-4 text-sm text-danger-700">{error}</div>}
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={saving}>Cancel</Button>
          <Button onClick={() => void submit()} disabled={saving || !deliveredOn || !attested}>{saving ? 'Recording…' : 'Record Issued'}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
