import { useState } from 'react';
import { checksApi } from '@/services/api';
import type { CheckItem } from '@/types';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { guamBusinessDate } from '@/lib/payrollBusinessDate';

interface RecordBulkCheckDeliveryDialogProps {
  payPeriodId: number;
  items: CheckItem[];
  onClose: () => void;
  onComplete: () => Promise<void>;
}

export function RecordBulkCheckDeliveryDialog({ payPeriodId, items, onClose, onComplete }: RecordBulkCheckDeliveryDialogProps) {
  const [selectedIds, setSelectedIds] = useState<number[]>(items.map((item) => item.id));
  const [deliveredOn, setDeliveredOn] = useState(guamBusinessDate());
  const [deliveryMethod, setDeliveryMethod] = useState<'hand_delivery' | 'mail' | 'courier' | 'other'>('hand_delivery');
  const [evidenceReference, setEvidenceReference] = useState('');
  const [note, setNote] = useState('');
  const [attested, setAttested] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const selectedTotal = items.filter((item) => selectedIds.includes(item.id)).reduce((sum, item) => sum + Number(item.net_pay), 0);

  const submit = async (): Promise<void> => {
    if (saving || selectedIds.length === 0 || !deliveredOn || !attested) return;
    setSaving(true);
    setError(null);
    try {
      await checksApi.markSelectedIssued(payPeriodId, {
        payroll_item_ids: selectedIds,
        delivered_on: deliveredOn,
        delivery_method: deliveryMethod,
        attestation: attested,
        evidence_reference: evidenceReference.trim() || undefined,
        note: note.trim() || undefined,
      });
      await onComplete();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not record the selected checks as issued. No checks were changed.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open onOpenChange={(open) => { if (!open && !saving) onClose(); }}>
      <DialogContent className="max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Record checks issued</DialogTitle>
          <DialogDescription>Review the checks released in this handoff. Each selected check gets its own issue record, and its linked AIRE hours will be marked paid.</DialogDescription>
        </DialogHeader>

        <div className="rounded-xl border border-slate-200">
          <div className="flex items-center justify-between gap-3 border-b border-slate-200 bg-slate-50 px-4 py-3">
            <div><p className="text-sm font-semibold text-slate-900">Checks in this handoff</p><p className="text-xs text-slate-600">{selectedIds.length} selected · {new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(selectedTotal)}</p></div>
            <button type="button" className="text-sm font-semibold text-blue-700 disabled:text-slate-400" disabled={saving} onClick={() => setSelectedIds(selectedIds.length === items.length ? [] : items.map((item) => item.id))}>{selectedIds.length === items.length ? 'Clear all' : 'Select all'}</button>
          </div>
          <div className="max-h-52 divide-y divide-slate-100 overflow-y-auto">
            {items.map((item) => (
              <label key={item.id} className="flex cursor-pointer items-center gap-3 px-4 py-3 hover:bg-slate-50">
                <input type="checkbox" checked={selectedIds.includes(item.id)} disabled={saving} onChange={() => setSelectedIds((current) => current.includes(item.id) ? current.filter((id) => id !== item.id) : [...current, item.id])} aria-label={`Issue check ${item.check_number} for ${item.employee_name}`} />
                <span className="min-w-0 flex-1 text-sm font-medium text-slate-900">#{item.check_number} · {item.employee_name}</span>
                <span className="text-sm tabular-nums text-slate-600">{new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(Number(item.net_pay))}</span>
              </label>
            ))}
          </div>
        </div>

        <div className="grid gap-4 sm:grid-cols-2">
          <Input label="Issue date" type="date" value={deliveredOn} onChange={(event) => setDeliveredOn(event.target.value)} disabled={saving} />
          <Select label="How they were issued" value={deliveryMethod} onChange={(event) => setDeliveryMethod(event.target.value as typeof deliveryMethod)} disabled={saving}>
            <option value="hand_delivery">Hand delivered</option>
            <option value="mail">Mailed</option>
            <option value="courier">Courier / delivery service</option>
            <option value="other">Other documented method</option>
          </Select>
          <Input className="sm:col-span-2" label="Recipient or handoff reference (optional)" helperText="For example, the client representative who received the checks." value={evidenceReference} onChange={(event) => setEvidenceReference(event.target.value)} disabled={saving} />
          <Input className="sm:col-span-2" label="Note (optional)" value={note} onChange={(event) => setNote(event.target.value)} disabled={saving} />
        </div>

        <label className="flex items-start gap-2 rounded-xl border border-primary-200 bg-primary-50 p-4 text-sm leading-5 text-primary-900">
          <input className="mt-1 h-4 w-4" type="checkbox" checked={attested} disabled={saving} onChange={(event) => setAttested(event.target.checked)} />
          <span>I confirm the selected checks were released using the method and date above. This will mark their linked AIRE hours as paid.</span>
        </label>
        {error && <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 p-4 text-sm text-danger-700">{error}</div>}
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={saving}>Cancel</Button>
          <Button onClick={() => void submit()} disabled={saving || selectedIds.length === 0 || !deliveredOn || !attested}>{saving ? 'Recording…' : `Record ${selectedIds.length} check${selectedIds.length === 1 ? '' : 's'} issued`}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
