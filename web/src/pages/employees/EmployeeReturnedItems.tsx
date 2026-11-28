import { useEffect, useState, type FormEvent } from 'react';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { Alert } from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Textarea } from '@/components/ui/textarea';
import { useCompany } from '@/contexts/CompanyContext';
import { clientEmployeeLifecycleApi, lifecycleErrorCode, maskLifecycleNote, type ReturnedVerificationItem } from '@/services/clientEmployeeLifecycle';

const eventLabels: Record<string, string> = {
  new_hire: 'New hire',
  rehire: 'Rehire',
  termination: 'Termination',
  compensation_change: 'Pay setup',
  w4_change: 'W-4 withholding',
  identity_tax_change: 'Identity or tax details',
  payment_method_change: 'Payment method',
  contractor_tax_change: 'Contractor tax details',
  profile_change: 'Employee details',
};

export function EmployeeReturnedItems({ employeeId, canRespond, refreshVersion = 0 }: {
  employeeId: number;
  canRespond: boolean;
  refreshVersion?: number;
}) {
  const [items, setItems] = useState<ReturnedVerificationItem[]>([]);
  const [loadError, setLoadError] = useState(false);
  const [retry, setRetry] = useState(0);
  const [retrying, setRetrying] = useState(false);
  const [responseSentCount, setResponseSentCount] = useState(0);

  useEffect(() => {
    let current = true;
    void clientEmployeeLifecycleApi.returnedForEmployee(employeeId).then(
      (data) => { if (current) { setItems(data); setLoadError(false); } },
      () => { if (current) setLoadError(true); },
    ).finally(() => { if (current) setRetrying(false); });
    return () => { current = false; };
  }, [employeeId, refreshVersion, retry]);

  if (loadError) return <Alert tone="error" className="flex flex-wrap items-center gap-2">
    <p>Could not load items sent back by Cornerstone.</p>
    <Button variant="outline" className="min-h-11" disabled={retrying} onClick={() => {
      setRetrying(true);
      setRetry((current) => current + 1);
    }}>{retrying ? 'Checking…' : 'Try again'}</Button>
  </Alert>;

  if (!items.length && !responseSentCount) return null;

  return (
    <div className="space-y-3">
      {responseSentCount > 0 && <ActionFeedback tone="success" message="Response sent to Cornerstone for review." retryKey={responseSentCount} />}
      {items.length > 0 && <Card className="border-warning-200 bg-warning-50">
        <CardHeader>
          <CardTitle>Needs attention</CardTitle>
          <p className="text-sm text-neutral-700">
            {canRespond ? 'Cornerstone sent these items back. Update the employee record or reply with a note.' : 'Cornerstone sent these items back for your company to review.'}
          </p>
        </CardHeader>
        <CardContent className="space-y-3">
          {items.map((item) => <ReturnedItem
            key={item.id}
            item={item}
            canRespond={canRespond}
            onSent={() => {
              setItems((current) => current.filter((row) => row.id !== item.id));
              setResponseSentCount((count) => count + 1);
            }}
          />)}
        </CardContent>
      </Card>}
    </div>
  );
}

function ReturnedItem({ item, canRespond, onSent }: { item: ReturnedVerificationItem; canRespond: boolean; onSent: () => void }) {
  const { refreshCompanies } = useCompany();
  const [open, setOpen] = useState(false);
  const [note, setNote] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  async function respond(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!note.trim() || saving) return;
    setSaving(true);
    setError('');
    try {
      await clientEmployeeLifecycleApi.respond(item.id, note.trim());
      onSent();
    } catch (caught) {
      const code = lifecycleErrorCode(caught);
      if (code === 'lifecycle_mode_changed' || code === 'client_lifecycle_disabled') void refreshCompanies().catch(() => {});
      setError(code === 'lifecycle_mode_changed'
        ? 'Your company’s employee settings changed. Review the employee record before sending your reply.'
        : caught instanceof Error ? maskLifecycleNote(caught.message) : 'Could not send your reply. Try again.');
      setSaving(false);
    }
  }

  return (
    <div className="space-y-2 rounded-lg border border-warning-200 bg-white p-3">
      <h3 className="text-sm font-semibold text-neutral-950">{eventLabels[item.event_kind] || 'Employee update'}</h3>
      {item.return_note && <p className="whitespace-pre-wrap wrap-anywhere text-sm text-neutral-700">{maskLifecycleNote(item.return_note)}</p>}
      {canRespond && !open && <Button type="button" variant="outline" className="min-h-11" onClick={() => setOpen(true)}>Reply to Cornerstone</Button>}
      {canRespond && open && <form className="space-y-3" onSubmit={respond}>
        <label className="block text-sm font-medium">Reply to Cornerstone
          <Textarea className="mt-1 min-h-20 text-base" autoFocus value={note} onChange={(event) => setNote(event.target.value)} maxLength={1000} required />
        </label>
        {error && <ActionFeedback tone="error" message={error} />}
        <div className="flex flex-wrap gap-2">
          <Button type="submit" className="min-h-11" disabled={saving || !note.trim()}>{saving ? 'Sending…' : 'Send reply'}</Button>
          <Button type="button" variant="outline" className="min-h-11" disabled={saving} onClick={() => setOpen(false)}>Cancel</Button>
        </div>
      </form>}
    </div>
  );
}
