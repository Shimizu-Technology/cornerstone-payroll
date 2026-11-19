import { useState, type ReactElement } from 'react';
import { CheckCircle2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { ApiError, reportsApi } from '@/services/api';
import { formatGuamDateTimeShort } from '@/lib/utils';
import type { YearEndChecklist, YearEndIssue, YearEndStep } from '@/lib/year-end';
import { useStillMounted } from './useStillMounted';

type MarkReadyStepData = Extract<YearEndStep, { key: 'mark_ready' }>;

/** Runs a fresh preflight and then the existing fingerprint-bound "mark ready" on those exact inputs. */
export function MarkReadyStep({ checklist, step, onSaved }: {
  checklist: YearEndChecklist;
  step: MarkReadyStepData;
  onSaved: (message: string) => Promise<void>;
}): ReactElement {
  const year = checklist.tax_year;
  const companyId = checklist.company.id;
  const stillMounted = useStillMounted();
  const [notes, setNotes] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [details, setDetails] = useState<string[]>([]);
  const filing = step.data.filing;
  const remaining = step.data.remaining_before_ready ?? 0;

  if (step.status === 'done') {
    return (
      <p className="flex gap-2 text-sm text-success-800">
        <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
        Marked ready{filing?.marked_ready_at ? ` ${formatGuamDateTimeShort(filing.marked_ready_at)}` : ''}{filing?.notes ? `: “${filing.notes}”` : '.'}
      </p>
    );
  }
  if (!step.data.can_mark_ready) {
    return <p className="text-sm text-neutral-700">Finish the {remaining} item{remaining === 1 ? '' : 's'} above first. This step opens when they are done.</p>;
  }
  if (!checklist.permissions.can_mark_ready) {
    return <p className="text-sm text-neutral-700">Everything is ready for sign-off. A manager or admin marks the W-2s ready.</p>;
  }

  async function markReady() {
    setSaving(true);
    setError(null);
    setDetails([]);
    try {
      const preflight = await reportsApi.w2GuPreflight(year, companyId);
      if (!stillMounted()) return;
      if (preflight.preflight.blocking_count > 0) {
        setError('The W-2 check found problems. Fix them, then try again.');
        setDetails(preflight.preflight.findings.filter((finding) => finding.severity === 'blocking').map((finding) => finding.message));
        return;
      }
      await reportsApi.w2GuMarkReady(year, notes.trim() || undefined, preflight.filing.preflight_fingerprint, companyId);
      if (!stillMounted()) return;
      await onSaved(`Marked the ${year} W-2s ready.`);
    } catch (err) {
      if (!stillMounted()) return;
      setError(err instanceof Error ? err.message : 'Could not mark the W-2s ready.');
      if (err instanceof ApiError && err.data && typeof err.data === 'object') {
        const blockers = (err.data as { year_end_blockers?: YearEndIssue[] }).year_end_blockers;
        if (blockers) setDetails(blockers.map((blocker) => blocker.message));
      }
    } finally {
      if (stillMounted()) setSaving(false);
    }
  }

  return (
    <div className="space-y-3">
      {filing?.stale && <p className="text-sm text-warning-800">Payroll or filing details changed after the last sign-off, so the W-2s need to be marked ready again.</p>}
      <p className="text-sm text-neutral-700">This runs the W-2 check on the current numbers and records your sign-off. If payroll changes later, the sign-off expires.</p>
      <div className="max-w-xl">
        <label htmlFor="year-end-ready-notes" className="mb-1.5 block text-xs font-medium text-neutral-600">Notes (optional)</label>
        <Textarea id="year-end-ready-notes" value={notes} onChange={(event) => setNotes(event.target.value)} rows={2} maxLength={2000} disabled={saving} />
      </div>
      {error && (
        <div role="alert" className="text-sm text-danger-700">
          <p>{error}</p>
          {details.length > 0 && <ul className="mt-1 list-disc pl-5">{details.map((detail) => <li key={detail}>{detail}</li>)}</ul>}
        </div>
      )}
      <Button onClick={() => void markReady()} loading={saving} loadingLabel="Checking and marking ready…">Mark {year} W-2s ready</Button>
    </div>
  );
}
