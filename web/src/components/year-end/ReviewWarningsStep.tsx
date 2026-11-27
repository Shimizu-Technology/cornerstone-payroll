import { useCompany } from '@/contexts/CompanyContext';
import { canWriteCompany } from '@/lib/company-write-access';
import { useOptionalSelectedCompanyCapability } from '@/hooks/useSelectedCompanyCapability';
import { BulkTippedOccupations } from './BulkTippedOccupations';
import { useState, type ReactElement } from 'react';
import { Link, useLocation } from 'react-router';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { yearEndApi } from '@/services/api';
import { formatGuamDateTimeShort } from '@/lib/utils';
import type { YearEndChecklist, ActiveYearEndStep, YearEndWarning } from '@/lib/year-end';
import { useStillMounted } from './useStillMounted';
import { StaleReviewNotice } from './StaleReview';
import { isStaleReview, useStaleReview } from './useStaleReview';

type WarningsStepData = ActiveYearEndStep<'review_warnings'>;
const SHOWN_EMPLOYEES = 6;

function WarningStatus({ warning }: { warning: YearEndWarning }): ReactElement {
  if (warning.status === 'reviewed') return <Badge variant="success">Reviewed</Badge>;
  if (warning.status === 'blocked') return <Badge variant="danger">Fix before filing</Badge>;
  return <Badge variant="warning">{warning.acknowledgement_stale ? 'Review again' : 'Needs review'}</Badge>;
}

function AcknowledgeForm({ checklist, warning, onSaved, onRefresh }: {
  checklist: YearEndChecklist;
  warning: YearEndWarning;
  onSaved: (message: string) => Promise<void>;
  onRefresh: () => Promise<void>;
}): ReactElement {
  const [note, setNote] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const noteId = `ack-${warning.code}`;
  const stillMounted = useStillMounted();
  const stale = useStaleReview(warning.digest, onRefresh);

  return (
    <form
      className="mt-3 space-y-2"
      onSubmit={async (event) => {
        event.preventDefault();
        if (!note.trim() || !stale.canSubmit) return;
        setSaving(true);
        setError(null);
        try {
          await yearEndApi.acknowledge({ tax_year: checklist.tax_year, warning_code: warning.code, warning_digest: warning.digest, note: note.trim() }, checklist.company.id);
          if (!stillMounted()) return;
          stale.clear();
          await onSaved(`Recorded your review of "${warning.title}".`);
        } catch (err) {
          if (!stillMounted()) return;
          if (isStaleReview(err)) stale.markRefused();
          else setError(err instanceof Error ? err.message : 'Could not record the review.');
        } finally {
          if (stillMounted()) setSaving(false);
        }
      }}
    >
      <label htmlFor={noteId} className="block text-xs font-medium text-neutral-700">What did you check and confirm?</label>
      <Textarea id={noteId} value={note} onChange={(event) => setNote(event.target.value)} rows={2} maxLength={2000} required disabled={saving} />
      <StaleReviewNotice stale={stale} idPrefix={noteId} what="numbers" />
      {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
      <Button type="submit" size="sm" disabled={!note.trim() || !stale.canSubmit} loading={saving} loadingLabel="Saving…">Mark reviewed</Button>
    </form>
  );
}

function WarningCard({ checklist, warning, onSaved, onRefresh }: {
  checklist: YearEndChecklist;
  warning: YearEndWarning;
  onSaved: (message: string) => Promise<void>;
  onRefresh: () => Promise<void>;
}): ReactElement {
  const location = useLocation();
  const { activeCompany } = useCompany();
  const hasConfigurationAccess = useOptionalSelectedCompanyCapability('manage_client_configuration', checklist.company.id);
  const canSetCodes = hasConfigurationAccess && canWriteCompany(activeCompany, 'manage_client_configuration');
  const [showAll, setShowAll] = useState(false);
  const employees = showAll ? warning.employees : warning.employees.slice(0, SHOWN_EMPLOYEES);
  const returnTo = encodeURIComponent(`${location.pathname}${location.search}#step-review_warnings`);

  return (
    <li className="rounded-xl border border-neutral-200 p-3 sm:p-4">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <h3 className="min-w-0 text-sm font-semibold text-neutral-950">{warning.title}</h3>
        <WarningStatus warning={warning} />
      </div>
      <p className="mt-1 text-sm leading-6 text-neutral-700">{warning.explanation}</p>
      {(warning.details ?? []).length > 0 && (
        <ul className="mt-2 list-disc space-y-1 pl-5 text-sm text-neutral-800">
          {(warning.details ?? []).map((detail) => <li key={detail}>{detail}</li>)}
        </ul>
      )}
      {warning.employees.length > 0 && (
        <div className="mt-2">
          <p className="text-xs font-semibold text-neutral-600">{warning.employees.length} employee{warning.employees.length === 1 ? '' : 's'}</p>
          <ul className="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-sm">
            {employees.map((employee) => (
              <li key={employee.employee_id}>
                <Link to={`${employee.edit_path}?return_to=${returnTo}`} className="inline-flex min-h-9 items-center font-medium text-primary-700 underline [overflow-wrap:anywhere]">
                  {employee.name ?? `Employee ${employee.employee_id}`}
                </Link>
                {employee.history_review && (
                  <p className="text-xs text-neutral-600">Reviewed by {employee.history_review.by} on {formatGuamDateTimeShort(employee.history_review.at)}</p>
                )}
              </li>
            ))}
          </ul>
          {warning.employees.length > SHOWN_EMPLOYEES && !showAll && (
            <button type="button" className="mt-1 min-h-9 text-sm font-semibold text-primary-700 underline" onClick={() => setShowAll(true)}>
              Show all {warning.employees.length}
            </button>
          )}
        </div>
      )}
      {canSetCodes && warning.code === 'tipped_occupation_code_missing' && warning.employees.length > 0 && (
        <BulkTippedOccupations key={`${checklist.company.id}:${checklist.tax_year}`} companyId={checklist.company.id}
          year={checklist.tax_year} employees={warning.employees} onSaved={onSaved} />
      )}
      {warning.acknowledgement && (
        <p className="mt-3 rounded-lg bg-neutral-50 p-2.5 text-sm text-neutral-700">
          {warning.acknowledgement_stale ? 'Earlier review' : 'Reviewed'} by {warning.acknowledgement.acknowledged_by.name}
          {warning.acknowledgement.acknowledged_at ? ` on ${formatGuamDateTimeShort(warning.acknowledgement.acknowledged_at)}` : ''}: “{warning.acknowledgement.note}”
        </p>
      )}
      {warning.kind === 'history_review' && warning.status !== 'reviewed' && (
        <a href="#payroll-history-review" className="mt-2 inline-flex min-h-11 items-center text-sm font-semibold text-primary-700 underline">
          Go to Payroll history review
        </a>
      )}
      {warning.kind === 'acknowledge' && warning.status !== 'reviewed' && (
        checklist.permissions.can_acknowledge
          ? <AcknowledgeForm checklist={checklist} warning={warning} onSaved={onSaved} onRefresh={onRefresh} />
          : <p className="mt-3 text-sm text-neutral-600">A filing reviewer records this review.</p>
      )}
    </li>
  );
}

export function ReviewWarningsStep({ checklist, step, onSaved, onRefresh }: {
  checklist: YearEndChecklist;
  step: WarningsStepData;
  onSaved: (message: string) => Promise<void>;
  onRefresh: () => Promise<void>;
}): ReactElement {
  const warnings = step.data.warnings ?? [];
  if (warnings.length === 0) return <p className="text-sm text-neutral-700">{step.summary}</p>;
  const ordered = [...warnings].sort((a, b) => rank(a) - rank(b));
  return (
    <ul className="space-y-3">
      {ordered.map((warning) => <WarningCard key={warning.code} checklist={checklist} warning={warning} onSaved={onSaved} onRefresh={onRefresh} />)}
    </ul>
  );
}

function rank(warning: YearEndWarning): number {
  return { blocked: 0, needs_review: 1, reviewed: 2 }[warning.status];
}
