import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
import { useEffect, useId, useRef, useState, type FormEvent } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { adminClientDocumentsApi, reportsApi, type FilingDownload, type PayrollFilingEventType, type PayrollFilingRecord, type PayrollFilingEvidenceType } from '@/services/api';

const LABELS: Record<PayrollFilingEvidenceType, string> = {
  form_500_payment: 'Form 500 deposit',
  w1: 'Guam W-1',
  swica: 'SWICA / SW-2',
  federal_941: 'Federal Form 941 + Schedule B',
  w2_gu_w3_ss: 'W-2GU / W-3SS wage submission',
  form_1099_nec: '1099-NEC / 1096 information return',
};

const EVENT_LABELS: Record<PayrollFilingEventType, string> = {
  submitted: 'Record submission',
  resubmitted: 'Record resubmission',
  accepted: 'Record acceptance',
  accepted_with_errors: 'Record accepted with errors',
  rejected: 'Record rejection',
  correction_needed: 'Record correction needed',
};

function messageForStatus(filing: PayrollFilingRecord | null, isPayment: boolean) {
  if (!filing) return isPayment ? 'No payment receipt recorded.' : 'No agency submission recorded.';
  if (filing.status === 'submitted') return isPayment ? 'Payment initiated; confirmation is still pending.' : 'Submitted; waiting for the agency result.';
  if (filing.status === 'accepted') return isPayment ? 'Payment confirmed with retained proof.' : 'Agency acceptance recorded.';
  if (filing.status === 'accepted_with_errors') return isPayment
    ? 'Payment was received with an issue; resolve it and retain the retry confirmation.'
    : 'Accepted with errors; correct the filing and record the resubmission.';
  if (filing.status === 'needs_correction') return isPayment
    ? 'The payment record needs a correction; resolve it and retain the new confirmation.'
    : 'A correction is required; prepare it and retain the new submission receipt.';
  return isPayment ? 'Payment was rejected; resolve it and retain the retry confirmation.' : 'Rejected; correct the filing and record the resubmission.';
}

// "accepted_with_errors" -> "Accepted with errors", for statuses and history.
function statusText(value: string) {
  const words = value.replaceAll('_', ' ');
  return words.charAt(0).toUpperCase() + words.slice(1);
}

function nextEvents(filing: PayrollFilingRecord | null): PayrollFilingEventType[] {
  if (!filing) return ['submitted'];
  if (filing.status === 'submitted') return ['accepted', 'accepted_with_errors', 'rejected'];
  if (filing.status === 'accepted_with_errors' || filing.status === 'rejected' || filing.status === 'needs_correction') return ['resubmitted'];
  if (filing.status === 'accepted') return ['correction_needed'];
  return [];
}

function eventLabel(eventType: PayrollFilingEventType, isPayment: boolean) {
  if (!isPayment) return EVENT_LABELS[eventType];
  return {
    submitted: 'Record payment initiation',
    resubmitted: 'Record payment retry',
    accepted: 'Confirm payment',
    accepted_with_errors: 'Record payment issue',
    rejected: 'Record payment rejection',
    correction_needed: 'Record payment correction',
  }[eventType];
}

function guamDateTimeLocalValue(date = new Date()) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Pacific/Guam',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(date);
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${value.year}-${value.month}-${value.day}T${value.hour}:${value.minute}`;
}

function guamDateTimeWithOffset(value: FormDataEntryValue | null) {
  if (typeof value !== 'string' || value === '') return value;
  return `${value}:00+10:00`;
}

function filingDueDate(year: number) {
  const date = new Date(Date.UTC(year + 1, 0, 31));
  while ([0, 6].includes(date.getUTCDay())) date.setUTCDate(date.getUTCDate() + 1);
  return date.toLocaleDateString('en-US', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' });
}

function formatGuamDateTime(value: string) {
  return `${new Date(value).toLocaleString('en-US', {
    timeZone: 'Pacific/Guam',
    dateStyle: 'medium',
    timeStyle: 'short',
  })} ChST`;
}

type FilingEvidencePanelProps = {
  filingType: PayrollFilingEvidenceType;
  taxYear: number;
  quarter?: number;
  preparationReady: boolean;
  readinessMessage: string;
  companyId?: number;
  agency?: string;
};

export function FilingEvidencePanel(props: FilingEvidencePanelProps) {
  const [agency, setAgency] = useState('ssa');
  if (!props.quarter && props.taxYear >= 2026 && !props.agency) return <div>
    {props.filingType === 'w2_gu_w3_ss' && <label className="text-sm">Agency<select className="ml-2 min-h-11 rounded border px-2" value={agency} onChange={(event) => setAgency(event.target.value)}><option value="ssa">Social Security (BSO)</option><option value="drt">Guam DRT (GuamTax)</option></select></label>}
    <FilingEvidencePanelContent key={agency} {...props} agency={props.filingType === 'form_1099_nec' ? 'drt' : agency} />
  </div>;
  return <FilingEvidencePanelContent {...props} />;
}

function FilingEvidencePanelContent({
  filingType,
  taxYear,
  quarter,
  preparationReady,
  readinessMessage,
  companyId,
  agency,
}: {
  filingType: PayrollFilingEvidenceType;
  taxYear: number;
  quarter?: number;
  preparationReady: boolean;
  readinessMessage: string;
  /** Pin every request to this client instead of the app's current one. */
  companyId?: number;
  agency?: string;
}) {
  const [loadAttempt, setLoadAttempt] = useState(0);
  const [downloadId, setDownloadId] = useState('');
  const [downloads, setDownloads] = useState<FilingDownload[]>([]);
  const currentDownload = downloads.find((file) => file.current);
  const [legacy, setLegacy] = useState<PayrollFilingRecord | null>(null);
  const formId = useId();
  const [filing, setFiling] = useState<PayrollFilingRecord | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [eventType, setEventType] = useState<PayrollFilingEventType | null>(null);
  const [saving, setSaving] = useState(false);
  const loadGenerationRef = useRef(0);
  const idempotencyKeyRef = useRef<string | null>(null);
  const isPayment = filingType === 'form_500_payment';

  useEffect(() => {
    let active = true;
    const generation = ++loadGenerationRef.current;
    const isCurrent = () => active && generation === loadGenerationRef.current;
    setLoading(true);
    setError(null);
    void reportsApi.payrollFilingRecord(filingType, taxYear, quarter, companyId, agency)
      .then((response) => { if (isCurrent()) { setFiling(response.filing); setDownloads(response.downloads || []); setDownloadId(String(response.downloads?.find((file) => file.current)?.id || '')); setLegacy(response.legacy_filing || null); } })
      .catch((err) => { if (isCurrent()) setError(err instanceof Error ? err.message : 'Unable to load filing evidence'); })
      .finally(() => { if (isCurrent()) setLoading(false); });
    return () => { active = false; };
  }, [loadAttempt, agency, companyId, filingType, quarter, setError, taxYear]);

  async function submitEvent(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!eventType || saving) return;

    const form = event.currentTarget;
    const data = new FormData(form);
    const receipt = data.get('file');
    if (!quarter && receipt instanceof File && receipt.size === 0) data.delete('file');
    const occurredAt = guamDateTimeWithOffset(data.get('occurred_at'));
    if (occurredAt) data.set('occurred_at', occurredAt);
    data.append('filing_type', filingType);
    if (agency) data.append('agency', agency);
    data.append('tax_year', String(taxYear));
    if (quarter) data.append('quarter', String(quarter));
    data.append('event_type', eventType);
    const idempotencyKey = idempotencyKeyRef.current || crypto.randomUUID();
    idempotencyKeyRef.current = idempotencyKey;
    data.append('idempotency_key', idempotencyKey);
    setSaving(true);
    setError(null);
    try {
      const response = await reportsApi.recordPayrollFilingEvent(data, companyId);
      // A refresh may have read the old filing before this save completed.
      loadGenerationRef.current += 1;
      setLoading(false);
      setFiling(response.filing);
      setEventType(null);
      idempotencyKeyRef.current = null;
      form.reset();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to save filing evidence');
    } finally {
      setSaving(false);
    }
  }

  async function downloadEvidence(documentId: number, fallbackName: string) {
    try {
      setError(null);
      const response = await adminClientDocumentsApi.download(documentId, companyId);
      const url = URL.createObjectURL(response.blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = response.filename || fallbackName;
      link.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to download evidence');
    }
  }

  const availableEvents = nextEvents(filing);
  const tone = filing?.status === 'accepted'
    ? 'success'
    : filing?.status === 'rejected' || filing?.status === 'accepted_with_errors' || filing?.status === 'needs_correction'
      ? 'warning'
      : 'outline';
  const annual = !quarter && taxYear >= 2026;
  const needsSigner = !annual && !isPayment && eventType && ['submitted', 'resubmitted'].includes(eventType);
  const needsNotes = eventType === 'accepted_with_errors' || eventType === 'rejected' || eventType === 'correction_needed';

  return (
    <div className="mt-4 rounded-xl border border-neutral-200 bg-neutral-50 p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-sm font-semibold text-neutral-950">{LABELS[filingType]} {agency === 'ssa' ? 'Social Security (BSO)' : agency === 'drt' ? 'Guam DRT (GuamTax)' : ''} evidence</p>
          <p aria-live="polite" className="mt-1 text-xs leading-5 text-neutral-600">{loading ? 'Loading evidence…' : messageForStatus(filing, isPayment)}</p>
        </div>
        <Badge variant={tone}>{filing ? filing.status.replaceAll('_', ' ') : 'not submitted'}</Badge>
      </div>

      {annual && <p className="mt-2 text-xs">{filing ? `${statusText(filing.status)} ${formatGuamDateTime(filing.resolved_at || filing.submitted_at)} · confirmation ${filing.confirmation_number}` : currentDownload ? `Final file downloaded ${formatGuamDateTime(currentDownload.created_at)} — record the submission` : downloads.length ? `The downloaded file is out of date — download the final file again in Print and file` : `Not filed yet — due ${filingDueDate(taxYear)}`}</p>}
      {legacy && agency === 'ssa' && <details className="mt-3 text-xs"><summary>Earlier W-2 history — agency not recorded</summary><p>This history does not confirm either portal submission.</p>{legacy.events.map((entry) => <div key={entry.id} className="mt-2 flex flex-wrap items-center justify-between gap-2"><p>{statusText(entry.event_type)} · {entry.reference_number} · {formatGuamDateTime(entry.occurred_at)} by {entry.recorded_by}{entry.notes && ` · ${entry.notes}`}</p>{entry.evidence_document && <Button type="button" size="md" variant="outline" onClick={() => void downloadEvidence(entry.evidence_document!.id, entry.evidence_document!.file_name)}>Download proof</Button>}</div>)}</details>}
      {filing?.source_changed && (
        <div className="mt-3 rounded-lg border border-warning-300 bg-warning-50 px-3 py-2 text-xs text-warning-900">
          Filing data changed after this was filed; a correction may be needed.
        </div>
      )}

      {!preparationReady && !filing && (
        <p className="mt-3 rounded-lg border border-warning-200 bg-warning-50 px-3 py-2 text-xs text-warning-900">{readinessMessage}</p>
      )}

      {!loading && availableEvents.length > 0 && (
        <div className="mt-3 flex flex-wrap gap-2">
          {availableEvents.map((type) => (
            <Button
              key={type}
              type="button"
              size="sm"
              variant={type === 'accepted' ? 'default' : 'outline'}
              className="min-h-10"
              disabled={(!filing && !preparationReady) || saving}
              onClick={() => {
                idempotencyKeyRef.current = null;
                setEventType(type);
              }}
            >
              {eventLabel(type, isPayment)}
            </Button>
          ))}
        </div>
      )}

      {eventType && (
        <form id={formId} onSubmit={submitEvent} className="mt-4 space-y-3 rounded-xl border border-neutral-300 bg-white p-4">
          <div>
            <p className="text-sm font-semibold text-neutral-950">{eventLabel(eventType, isPayment)}</p>
            <p className="mt-1 text-xs text-neutral-500">{annual ? 'Add a portal receipt or agency response if available (optional).' : 'Attach the portal receipt or agency response.'}</p>
          </div>
          {annual && ['submitted', 'resubmitted'].includes(eventType) && <div>
            <label className="block text-xs font-semibold">Final file uploaded
              <select name="download_audit_id" required value={downloadId} onChange={(event) => setDownloadId(event.target.value)} className="mt-1 min-h-11 w-full rounded-md border px-2 text-sm">
                <option value="">Choose a final file</option>
                {downloads.map((file) => <option key={file.id} value={file.id}>{formatGuamDateTime(file.created_at)} · {file.actor_name} · {file.file_digest.slice(0, 12)}{file.current ? '' : ' · out of date'}</option>)}
              </select>
            </label>
            {downloads.length === 0 && <p className="mt-2 text-xs">Download the final {filingType === 'w2_gu_w3_ss' ? 'W-2' : '1099'} e-file in Print and file first.</p>}
            <Button type="button" size="sm" variant="outline" disabled={saving || loading} onClick={() => setLoadAttempt((value) => value + 1)}>Refresh files</Button>
          </div>}
          <div className="grid gap-3 sm:grid-cols-2">
            <label className="text-xs font-semibold text-neutral-600">
              {isPayment ? 'Payment confirmation number' : 'Agency reference number'}
              <input name="reference_number" required className="mt-1 h-11 w-full rounded-md border border-neutral-300 px-3 text-sm text-neutral-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-1" />
            </label>
            <label className="text-xs font-semibold text-neutral-600">
              Event date and time (Guam)
              <input name="occurred_at" type="datetime-local" required defaultValue={guamDateTimeLocalValue()} className="mt-1 h-11 w-full rounded-md border border-neutral-300 px-3 text-sm text-neutral-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-1" />
            </label>
            <label className="text-xs font-semibold text-neutral-600">
              Prepared / recorded by
              <input name="preparer_name" required className="mt-1 h-11 w-full rounded-md border border-neutral-300 px-3 text-sm text-neutral-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-1" />
            </label>
            {needsSigner && (
              <label className="text-xs font-semibold text-neutral-600">
                Authorized signer
                <input name="signer_name" required className="mt-1 h-11 w-full rounded-md border border-neutral-300 px-3 text-sm text-neutral-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-1" />
              </label>
            )}
            {needsSigner && (
              <label className="text-xs font-semibold text-neutral-600">
                Signer title (optional)
                <input name="signer_title" className="mt-1 h-11 w-full rounded-md border border-neutral-300 px-3 text-sm text-neutral-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-1" />
              </label>
            )}
            <label className="text-xs font-semibold text-neutral-600 sm:col-span-2">
              Receipt or agency response {annual ? '(optional)' : ''}
              <input name="file" type="file" required={!annual} accept=".pdf,.png,.jpg,.jpeg,.webp,.txt,.csv,.doc,.docx,.xls,.xlsx" className="mt-1 block min-h-11 w-full rounded-md border border-neutral-300 bg-white px-3 py-2 text-sm text-neutral-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-1 file:mr-3 file:rounded-md file:border-0 file:bg-neutral-100 file:px-3 file:py-1 file:text-xs file:font-semibold" />
            </label>
            <label className="text-xs font-semibold text-neutral-600 sm:col-span-2">
              Notes {needsNotes ? '(required)' : '(optional)'}
              <textarea name="notes" required={needsNotes} className="mt-1 min-h-24 w-full rounded-md border border-neutral-300 px-3 py-2 text-sm text-neutral-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-1" placeholder={needsNotes ? 'Describe the errors, rejection, and next action.' : 'Add context that will help the next reviewer.'} />
            </label>
          </div>
          <div className="flex flex-wrap gap-2">
            <Button type="submit" size="sm" disabled={saving}>{saving ? 'Saving evidence…' : 'Save evidence'}</Button>
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={saving}
              onClick={() => {
                idempotencyKeyRef.current = null;
                setEventType(null);
              }}
            >
              Cancel
            </Button>
          </div>
        </form>
      )}

      {error && <><ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error} />{!eventType && <Button type="button" variant="outline" onClick={() => setLoadAttempt((value) => value + 1)}>Try again</Button>}</>}

      {filing && filing.events.length > 0 && (
        <ol className="mt-4 space-y-2 border-t border-neutral-200 pt-3">
          {[...filing.events].reverse().map((entry) => (
            <li key={entry.id} className="flex flex-wrap items-start justify-between gap-2 text-xs">
              <div>
                <p className="font-semibold text-neutral-800">{statusText(entry.event_type)} · {entry.reference_number}</p>
                <p className="mt-0.5 text-neutral-500">{formatGuamDateTime(entry.occurred_at)} by {entry.recorded_by}</p>
                {entry.notes && <p className="mt-1 max-w-2xl text-neutral-600">{entry.notes}</p>}
              </div>
              {entry.file_digest && <p>Uploaded file reference: {entry.file_digest.slice(0, 12)}</p>}
              {entry.evidence_document && <Button type="button" size="sm" variant="ghost" onClick={() => void downloadEvidence(entry.evidence_document!.id, entry.evidence_document!.file_name)}>
                Download proof
              </Button>}
            </li>
          ))}
        </ol>
      )}
    </div>
  );
}
