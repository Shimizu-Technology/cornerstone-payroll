import { useState } from 'react';
import { Button } from '@/components/ui/button';
import { ImportModal } from '@/components/import/ImportModal';
import { payPeriodsApi, type ImportPreviewResponse } from '@/services/api';
import type { PeriodDetail } from '@/services/payrollSubmissions';

export function PortalImportAction({ period, companyId, onApplied }: { period: PeriodDetail; companyId: number; onApplied: () => void }) {
  const [selectedId, setSelectedId] = useState(period.submissions.find(row => row.current)?.id);
  const [supersededReason, setSupersededReason] = useState('');
  const [dispositionReason, setDispositionReason] = useState('');
  const [replace, setReplace] = useState(false);
  const [replaceReason, setReplaceReason] = useState('');
  const [replacementId, setReplacementId] = useState<string | null>(null);
  const [preview, setPreview] = useState<ImportPreviewResponse | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [resolve, setResolve] = useState(false);
  const [tipsPaid, setTipsPaid] = useState(false);
  const selected = period.submissions.find(row => row.id === selectedId);
  if (!period.pay_period_id || !selected) return <p className="text-sm text-neutral-700">Create a matching pay run before opening these files in import review.</p>;
  const runId = period.pay_period_id;
  const open = async () => {
    setBusy(true); setError(null);
    try {
      setPreview(await payPeriodsApi.previewPortalSubmission(runId, selected.id, {
        superseded_reason: !selected.current ? supersededReason.trim() : undefined,
        supersedes_package_id: replace && replacementId ? replacementId : undefined,
        supersession_reason: replace ? replaceReason.trim() : undefined,
        tips_paid_out_from_tips: tipsPaid,
      }));
    } catch (err) {
      const details = (err as { details?: { replacement_required?: boolean; current_package?: { package_id: string } } }).details;
      if (details?.replacement_required) setReplacementId(details.current_package?.package_id || null);
      setError(err instanceof Error ? err.message : 'Could not open import review');
    } finally { setBusy(false); }
  };
  const disposition = async () => {
    const current = period.submissions.find(row => row.current);
    if (!current) return;
    setBusy(true); setError(null);
    try { await payPeriodsApi.resolvePortalSource(runId, current.id, dispositionReason.trim()); setResolve(false); setDispositionReason(''); onApplied(); }
    catch (err) { setError(err instanceof Error ? err.message : 'Could not save source disposition'); }
    finally { setBusy(false); }
  };
  return <section aria-label="Portal import" className="space-y-3 rounded-lg border border-neutral-200 p-3">
    <h3 className="font-semibold">Review payroll source</h3>
    <label className="block text-sm">Source revision<select className="mt-1 block min-h-11 w-full rounded-md border border-neutral-300 bg-white px-3" value={selectedId} onChange={e => { setSelectedId(Number(e.target.value)); setSupersededReason(''); setReplacementId(null); setReplace(false); }}>
      {period.submissions.map(row => <option key={row.id} value={row.id}>Revision {row.revision}{row.current ? ' (current)' : ' (superseded)'}</option>)}
    </select></label>
    {!selected.current && <label className="block text-sm">Why use this superseded revision?<textarea className="mt-1 block min-h-20 w-full rounded-md border border-neutral-300 p-2" maxLength={2000} value={supersededReason} onChange={e => setSupersededReason(e.target.value)} /></label>}
    {resolve && <label className="block text-sm">Why will the current revision not be imported?<textarea className="mt-1 block min-h-20 w-full rounded-md border border-neutral-300 p-2" maxLength={2000} value={dispositionReason} onChange={e => setDispositionReason(e.target.value)} /></label>}
    <label className="flex min-h-11 items-center gap-2 text-sm"><input type="checkbox" checked={tipsPaid} onChange={e => setTipsPaid(e.target.checked)} />Imported tips were already paid out</label>
    {replacementId && <div className="space-y-2 rounded-lg border border-warning-200 p-3">
      <label className="flex min-h-11 items-center gap-2 text-sm"><input type="checkbox" checked={replace} onChange={e => setReplace(e.target.checked)} />Replace the current retained import package</label>
      {replace && <label className="block text-sm">What changed?<textarea className="mt-1 block w-full rounded-md border border-neutral-300 p-2" value={replaceReason} onChange={e => setReplaceReason(e.target.value)} /></label>}
    </div>}
    <div className="flex flex-col gap-2 sm:flex-row">
      <Button disabled={busy || (!selected.current && !supersededReason.trim()) || (replace && !replaceReason.trim())} onClick={() => void open()}>{busy ? 'Opening…' : 'Open in import review'}</Button>
      <Button variant="outline" disabled={busy} onClick={() => setResolve(!resolve)}>Record source disposition</Button>
    </div>
    {resolve && <Button variant="outline" disabled={busy || !dispositionReason.trim()} onClick={() => void disposition()}>Save disposition of current revision</Button>}
    {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
    {preview && <ImportModal key={`${preview.import_id}-${preview.portal_source?.selection_id}`} open initialPreview={preview} payPeriodId={runId} companyId={companyId} onOpenChange={open => { if (!open) setPreview(null); }} onImportComplete={onApplied} />}
  </section>;
}
