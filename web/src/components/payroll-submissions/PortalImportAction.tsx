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
  const [replacementVersion, setReplacementVersion] = useState<number | null>(null);
  const [preview, setPreview] = useState<ImportPreviewResponse | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [resolve, setResolve] = useState(false);
  const [tipsPaid, setTipsPaid] = useState(false);
  const [staffWorkbook, setStaffWorkbook] = useState<File | null>(null);
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
        staff_workbook: staffWorkbook || undefined,
      }));
    } catch (err) {
      const details = (err as { details?: { replacement_required?: boolean; current_package?: { package_id: string; package_revision?: number } } }).details;
      if (details?.replacement_required) {
        setReplacementId(details.current_package?.package_id || null);
        setReplacementVersion(details.current_package?.package_revision ?? null);
      }
      setError(err instanceof Error ? err.message : 'Could not open import review');
    } finally { setBusy(false); }
  };
  const disposition = async () => {
    const current = period.submissions.find(row => row.current);
    if (!current) return;
    setBusy(true); setError(null);
    try { await payPeriodsApi.resolvePortalSource(runId, current.id, dispositionReason.trim()); setResolve(false); setDispositionReason(''); onApplied(); }
    catch (err) { setError(err instanceof Error ? err.message : 'Could not record why this submission is not being used'); }
    finally { setBusy(false); }
  };
  return <section aria-label="Portal import" className="space-y-3 rounded-lg border border-neutral-200 p-3">
    <h3 className="font-semibold">Review the client’s payroll files</h3>
    <p className="text-sm text-neutral-700">The client’s revision number counts each time they sent files. The import version is separate: it counts the sets of files loaded into import review.</p>
    <label className="block text-sm">Client’s revision<select className="mt-1 block min-h-11 w-full rounded-md border border-neutral-300 bg-white px-3" value={selectedId} onChange={e => { setSelectedId(Number(e.target.value)); setStaffWorkbook(null); setSupersededReason(''); setReplacementId(null); setReplacementVersion(null); setReplace(false); }}>
      {period.submissions.map(row => <option key={row.id} value={row.id}>Revision {row.revision}{row.current ? ' (latest)' : ' (older, replaced by a newer one)'}</option>)}
    </select></label>
    {!selected.current && <label className="block text-sm">Why use an older revision instead of the latest?<textarea className="mt-1 block min-h-20 w-full rounded-md border border-neutral-300 p-2" maxLength={2000} value={supersededReason} onChange={e => setSupersededReason(e.target.value)} /></label>}
    {selected.changes_link_url && !selected.documents.some(doc => doc.role === 'changes_workbook') && <div className="space-y-2 rounded-lg border border-primary-200 bg-primary-50 p-3">
      <a className="break-all text-sm underline" href={selected.changes_link_url} target="_blank" rel="noopener noreferrer">Client’s tips &amp; loans workbook link</a>
      <p className="text-sm">Open it, download the workbook, and attach it here.</p>
      <label className="block text-sm font-medium">Downloaded workbook (Excel)<input className="mt-2 block w-full text-sm" type="file" accept=".xls,.xlsx" onChange={e => setStaffWorkbook(e.target.files?.[0] || null)} /></label>
      <p className="text-sm text-neutral-600">Saved as staff evidence with your name and the import. The client’s revision stays as sent.</p>
    </div>}
    {resolve && <label className="block text-sm">Why isn’t the latest revision being used?<textarea className="mt-1 block min-h-20 w-full rounded-md border border-neutral-300 p-2" maxLength={2000} value={dispositionReason} onChange={e => setDispositionReason(e.target.value)} /></label>}
    <label className="flex min-h-11 items-center gap-2 text-sm"><input type="checkbox" checked={tipsPaid} onChange={e => setTipsPaid(e.target.checked)} />Imported tips were already paid out</label>
    {replacementId && <div className="space-y-2 rounded-lg border border-warning-200 p-3">
      <p className="text-sm">Files from this period are already in import review{replacementVersion ? ` (import version ${replacementVersion})` : ''}. Choose “Use corrected files” to replace them with this submission’s files.</p>
      <label className="flex min-h-11 items-center gap-2 text-sm"><input type="checkbox" checked={replace} onChange={e => setReplace(e.target.checked)} />Use corrected files</label>
      {replace && <label className="block text-sm">What changed?<textarea className="mt-1 block w-full rounded-md border border-neutral-300 p-2" value={replaceReason} onChange={e => setReplaceReason(e.target.value)} /></label>}
    </div>}
    <div className="flex flex-col gap-2 sm:flex-row">
      <Button disabled={busy || (!selected.current && !supersededReason.trim()) || (replace && !replaceReason.trim())} onClick={() => void open()}>{busy ? 'Opening…' : replace ? 'Use corrected files' : 'Review these submitted files'}</Button>
      <Button variant="outline" disabled={busy} onClick={() => setResolve(!resolve)}>Don’t use this submission — record why</Button>
    </div>
    {resolve && <Button variant="outline" disabled={busy || !dispositionReason.trim()} onClick={() => void disposition()}>Save: don’t use the latest revision</Button>}
    {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
    {preview && <ImportModal key={`${preview.import_id}-${preview.portal_source?.selection_id}`} open initialPreview={preview} payPeriodId={runId} companyId={companyId} onOpenChange={open => { if (!open) setPreview(null); }} onImportComplete={onApplied} />}
  </section>;
}
