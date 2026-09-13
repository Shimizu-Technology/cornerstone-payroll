import { useEffect, useId, useRef, useState, type FormEvent } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { adminClientDocumentsApi, reportsApi, type PayrollFilingEventType, type PayrollFilingRecord, type PayrollFilingEvidenceType } from '@/services/api';

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
  if (filing.status === 'accepted') return isPayment ? 'Payment confirmed with retained proof.' : 'Agency acceptance confirmed with retained proof.';
  if (filing.status === 'accepted_with_errors') return isPayment
    ? 'Payment was received with an issue; resolve it and retain the retry confirmation.'
    : 'Accepted with errors; correct the filing and record the resubmission.';
  if (filing.status === 'needs_correction') return isPayment
    ? 'The payment record needs a correction; resolve it and retain the new confirmation.'
    : 'A correction is required; prepare it and retain the new submission receipt.';
  return isPayment ? 'Payment was rejected; resolve it and retain the retry confirmation.' : 'Rejected; correct the filing and record the resubmission.';
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

function formatGuamDateTime(value: string) {
  return `${new Date(value).toLocaleString('en-US', {
    timeZone: 'Pacific/Guam',
    dateStyle: 'medium',
    timeStyle: 'short',
  })} ChST`;
}

export function FilingEvidencePanel({
  filingType,
  taxYear,
  quarter,
  preparationReady,
  readinessMessage,
}: {
  filingType: PayrollFilingEvidenceType;
  taxYear: number;
  quarter?: number;
  preparationReady: boolean;
  readinessMessage: string;
}) {
  const formId = useId();
  const [filing, setFiling] = useState<PayrollFilingRecord | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [eventType, setEventType] = useState<PayrollFilingEventType | null>(null);
  const [saving, setSaving] = useState(false);
  const idempotencyKeyRef = useRef<string | null>(null);
  const isPayment = filingType === 'form_500_payment';

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError(null);
    void reportsApi.payrollFilingRecord(filingType, taxYear, quarter)
      .then((response) => { if (active) setFiling(response.filing); })
      .catch((err) => { if (active) setError(err instanceof Error ? err.message : 'Unable to load filing evidence'); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [filingType, quarter, taxYear]);

  async function submitEvent(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!eventType) return;

    const form = event.currentTarget;
    const data = new FormData(form);
    const occurredAt = guamDateTimeWithOffset(data.get('occurred_at'));
    if (occurredAt) data.set('occurred_at', occurredAt);
    data.append('filing_type', filingType);
    data.append('tax_year', String(taxYear));
    if (quarter) data.append('quarter', String(quarter));
    data.append('event_type', eventType);
    const idempotencyKey = idempotencyKeyRef.current || crypto.randomUUID();
    idempotencyKeyRef.current = idempotencyKey;
    data.append('idempotency_key', idempotencyKey);
    setSaving(true);
    setError(null);
    try {
      const response = await reportsApi.recordPayrollFilingEvent(data);
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
      const response = await adminClientDocumentsApi.download(documentId);
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
  const needsSigner = !isPayment && eventType && ['submitted', 'resubmitted'].includes(eventType);
  const needsNotes = eventType === 'accepted_with_errors' || eventType === 'rejected' || eventType === 'correction_needed';

  return (
    <div className="mt-4 rounded-xl border border-neutral-200 bg-neutral-50 p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-sm font-semibold text-neutral-950">{LABELS[filingType]} evidence</p>
          <p aria-live="polite" className="mt-1 text-xs leading-5 text-neutral-600">{loading ? 'Loading evidence…' : messageForStatus(filing, isPayment)}</p>
        </div>
        <Badge variant={tone}>{filing ? filing.status.replaceAll('_', ' ') : 'not submitted'}</Badge>
      </div>

      {filing?.source_changed && (
        <div className="mt-3 rounded-lg border border-warning-300 bg-warning-50 px-3 py-2 text-xs text-warning-900">
          Payroll source records changed after the last submission. Review the changes before relying on this evidence or resubmitting.
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
            <p className="mt-1 text-xs text-neutral-500">Attach the actual portal receipt, acknowledgement, or agency response. A generated draft is not evidence.</p>
          </div>
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
              Receipt or agency response
              <input name="file" type="file" required accept=".pdf,.png,.jpg,.jpeg,.webp,.txt,.csv,.doc,.docx,.xls,.xlsx" className="mt-1 block min-h-11 w-full rounded-md border border-neutral-300 bg-white px-3 py-2 text-sm text-neutral-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300 focus-visible:ring-offset-1 file:mr-3 file:rounded-md file:border-0 file:bg-neutral-100 file:px-3 file:py-1 file:text-xs file:font-semibold" />
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

      {error && <p role="alert" className="mt-3 text-xs font-medium text-red-700">{error}</p>}

      {filing && filing.events.length > 0 && (
        <ol className="mt-4 space-y-2 border-t border-neutral-200 pt-3">
          {[...filing.events].reverse().map((entry) => (
            <li key={entry.id} className="flex flex-wrap items-start justify-between gap-2 text-xs">
              <div>
                <p className="font-semibold text-neutral-800">{entry.event_type.replaceAll('_', ' ')} · {entry.reference_number}</p>
                <p className="mt-0.5 text-neutral-500">{formatGuamDateTime(entry.occurred_at)} by {entry.recorded_by}</p>
                {entry.notes && <p className="mt-1 max-w-2xl text-neutral-600">{entry.notes}</p>}
              </div>
              <Button type="button" size="sm" variant="ghost" onClick={() => void downloadEvidence(entry.evidence_document.id, entry.evidence_document.file_name)}>
                Download proof
              </Button>
            </li>
          ))}
        </ol>
      )}
    </div>
  );
}
