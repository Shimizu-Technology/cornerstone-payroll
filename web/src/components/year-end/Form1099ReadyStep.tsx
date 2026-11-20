import { useState, type ReactElement } from 'react';
import { Link, useLocation } from 'react-router';
import { CheckCircle2, CircleAlert, RefreshCw } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { ApiError, yearEndApi } from '@/services/api';
import { formatCurrency, formatGuamDateTimeShort } from '@/lib/utils';
import { employeeEditPath } from '@/lib/routes';
import { oneOffPayeeAnchor, personAnchor, type ActiveYearEndStep, type YearEndChecklist, type YearEndIssue } from '@/lib/year-end';
import { useStillMounted } from './useStillMounted';

type StepData = ActiveYearEndStep<'form_1099_ready'>;

/** Where an open 1099 item is fixed: the payee's row, the contractor's record, or the step it belongs to. */
function fixLink(issue: YearEndIssue, companyId: number, returnTo: string): { to: string; label: string; hash: boolean } {
  if (issue.payee_key) return { to: `#${oneOffPayeeAnchor(issue.payee_key)}`, label: 'Go to this payee', hash: true };
  if (issue.code === 'PAYEE_DETAILS_MISSING' && issue.employee_id) return { to: `#${personAnchor('contractor', issue.employee_id)}`, label: 'Go to this contractor', hash: true };
  if (issue.employee_id) return { to: employeeEditPath(companyId, issue.employee_id, { returnTo }), label: 'Open the contractor', hash: false };
  if (issue.code.startsWith('EMPLOYER_')) return { to: '#step-employer', label: 'Go to employer details', hash: true };
  if (issue.code === 'FORM_1099_FILER_NOT_CHOSEN') return { to: '#step-filing_decision', label: 'Go to step 1', hash: true };
  return { to: '#step-people', label: 'Go to employees and payees', hash: true };
}

function PayeeList({ step }: { step: StepData }): ReactElement | null {
  const payees = step.data.payees ?? [];
  if (payees.length === 0) return null;
  return (
    <div>
      <ul className="divide-y divide-neutral-200 rounded-xl border border-neutral-200" aria-label="1099s to be issued">
        {payees.map((payee) => (
          <li key={payee.employee_id} className="flex items-start justify-between gap-3 px-3 py-2.5 text-sm">
            <div className="min-w-0">
              <p className="font-medium text-neutral-950 [overflow-wrap:anywhere]">{payee.name}</p>
              <p className="text-neutral-600">
                {payee.tin_type ? `${payee.tin_type} ending ${payee.tin_last4}` : 'No TIN'}
                {payee.linked_check_count > 0 ? ` · includes ${payee.linked_check_count} one-off check${payee.linked_check_count === 1 ? '' : 's'}` : ''}
              </p>
            </div>
            <p className="shrink-0 font-semibold tabular-nums text-neutral-950">{formatCurrency(payee.total_compensation)}</p>
          </li>
        ))}
      </ul>
      <p className="mt-2 flex justify-between gap-3 px-3 text-sm text-neutral-800">
        <span>{payees.length} 1099{payees.length === 1 ? '' : 's'}, Box 1a total</span>
        <span className="font-semibold tabular-nums">{formatCurrency(step.data.total_compensation)}</span>
      </p>
      {step.data.no_1099_due_count > 0 && (
        <p className="mt-1 px-3 text-sm text-neutral-600">{step.data.no_1099_due_count} one-off payee{step.data.no_1099_due_count === 1 ? ' is' : 's are'} marked no 1099 due.</p>
      )}
    </div>
  );
}

/** "Mark 1099s ready": a sign-off on exactly the payees and amounts shown. */
export function Form1099ReadyStep({ checklist, step, onSaved, onRefresh }: {
  checklist: YearEndChecklist;
  step: StepData;
  onSaved: (message: string) => Promise<void>;
  onRefresh: () => Promise<void>;
}): ReactElement | null {
  const year = checklist.tax_year;
  const location = useLocation();
  const returnTo = `${location.pathname}${location.search}#step-form_1099_ready`;
  const stillMounted = useStillMounted();
  const [notes, setNotes] = useState('');
  const [saving, setSaving] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<{ message: string; details: string[]; changed: boolean } | null>(null);
  const readiness = step.data.readiness;
  const blockers = step.data.blockers ?? [];

  if (step.status === 'done' && readiness?.status === 'filing_ready') {
    return (
      <div className="space-y-3">
        <p className="flex gap-2 text-sm text-success-800">
          <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
          <span>
            Marked ready{readiness.marked_ready_at ? ` ${formatGuamDateTimeShort(readiness.marked_ready_at)}` : ''}{readiness.marked_ready_by ? ` by ${readiness.marked_ready_by}` : ''}{readiness.notes ? `: “${readiness.notes}”` : '.'}
          </span>
        </p>
        <PayeeList step={step} />
      </div>
    );
  }
  if (step.status === 'done') {
    return step.data.no_1099_due_count > 0
      ? <p className="text-sm text-neutral-700">{step.data.no_1099_due_count} one-off payee{step.data.no_1099_due_count === 1 ? ' is' : 's are'} marked no 1099 due.</p>
      : null;
  }

  async function markReady() {
    if (!step.data.inputs_fingerprint) return;
    setSaving(true);
    setError(null);
    try {
      await yearEndApi.markForm1099Ready({ tax_year: year, inputs_fingerprint: step.data.inputs_fingerprint, notes: notes.trim() || undefined }, checklist.company.id);
      if (!stillMounted()) return;
      await onSaved(`Marked the ${year} 1099s ready.`);
    } catch (err) {
      if (!stillMounted()) return;
      const data = err instanceof ApiError && err.data && typeof err.data === 'object'
        ? err.data as { error?: string; problems?: string[]; year_end_blockers?: YearEndIssue[] }
        : {};
      const changed = err instanceof ApiError && err.status === 409;
      setError({
        message: (changed && data.error) || (err instanceof Error && err.message) || 'Could not mark the 1099s ready.',
        details: [...(data.problems ?? []), ...(data.year_end_blockers ?? []).map((blocker) => blocker.message)],
        changed,
      });
    } finally {
      if (stillMounted()) setSaving(false);
    }
  }

  async function refresh() {
    setRefreshing(true);
    try {
      await onRefresh();
    } finally {
      if (stillMounted()) setRefreshing(false);
    }
  }

  return (
    <div className="space-y-4">
      {readiness?.stale && <p className="text-sm text-warning-800">Payees, amounts or payer details changed after the last sign-off, so the 1099s need to be marked ready again.</p>}
      {blockers.length > 0 && (
        <div>
          <p className="text-sm font-medium text-neutral-900">Finish {blockers.length === 1 ? 'this' : `these ${blockers.length} items`} first:</p>
          <ul className="mt-2 space-y-2 text-sm text-neutral-800">
            {blockers.map((issue, index) => {
              const link = fixLink(issue, checklist.company.id, returnTo);
              return (
                <li key={`${issue.code}-${issue.payee_key ?? issue.employee_id ?? index}`} className="flex flex-col gap-1 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
                  <span className="flex min-w-0 gap-2">
                    <CircleAlert className="mt-0.5 h-4 w-4 shrink-0 text-warning-700" aria-hidden="true" />
                    <span className="[overflow-wrap:anywhere]">{issue.message}</span>
                  </span>
                  {link.hash
                    ? <a href={link.to} className="ml-6 inline-flex min-h-11 items-center font-semibold text-primary-700 underline sm:ml-0 sm:min-h-0 sm:shrink-0">{link.label}</a>
                    : <Link to={link.to} className="ml-6 inline-flex min-h-11 items-center font-semibold text-primary-700 underline sm:ml-0 sm:min-h-0 sm:shrink-0">{link.label}</Link>}
                </li>
              );
            })}
          </ul>
        </div>
      )}
      <PayeeList step={step} />
      {(step.data.smaller_could_reach_count ?? 0) > 0 && (
        <p className="text-sm text-warning-800">
          {step.data.smaller_could_reach_count} smaller one-off payee{step.data.smaller_could_reach_count === 1 ? '' : 's'} could reach the 1099 threshold with a contractor&rsquo;s pay.
          {' '}<a href="#step-people" className="font-semibold text-primary-700 underline">Link any that went to a contractor</a> before you mark the 1099s ready.
        </p>
      )}
      {step.data.can_mark_ready && step.data.unavailable_reason && <p className="text-sm text-neutral-700">{step.data.unavailable_reason}</p>}
      {step.data.can_mark_ready && !step.data.unavailable_reason && (
        <>
          <p className="text-sm text-neutral-700">This records your sign-off on the 1099s above. If a payee, an amount or the client&rsquo;s details change later, the sign-off expires.</p>
          <div className="max-w-xl">
            <label htmlFor="year-end-1099-ready-notes" className="mb-1.5 block text-xs font-medium text-neutral-600">Notes (optional)</label>
            <Textarea id="year-end-1099-ready-notes" value={notes} onChange={(event) => setNotes(event.target.value)} rows={2} maxLength={2000} disabled={saving} />
          </div>
          {error && (
            <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 p-3 text-sm text-danger-800">
              <p>{error.message}</p>
              {error.details.length > 0 && <ul className="mt-1 list-disc pl-5">{error.details.map((detail) => <li key={detail}>{detail}</li>)}</ul>}
              {error.changed && (
                <Button size="sm" variant="outline" className="mt-2 w-full sm:w-auto" onClick={() => void refresh()} loading={refreshing} loadingLabel="Refreshing…">
                  <RefreshCw className="mr-1.5 h-4 w-4" aria-hidden="true" />Refresh checklist
                </Button>
              )}
            </div>
          )}
          <Button className="w-full sm:w-auto" onClick={() => void markReady()} loading={saving} loadingLabel="Checking and marking ready…">Mark {year} 1099s ready</Button>
        </>
      )}
    </div>
  );
}
