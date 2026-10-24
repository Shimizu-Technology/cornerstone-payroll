
import { needsSourceCoverageAcknowledgement } from '@/lib/payroll-source-coverage';

import { Link } from 'react-router';
import { MoreHorizontal } from 'lucide-react';
import { useEffect, useRef } from 'react';
import { Button } from '@/components/ui/button';


import { payRunPath } from '@/lib/routes';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunProcessingActions(props: PayRunSectionProps<'processing'>) {
  const {
  canEditPayPeriod,
  canImportMosa,
  canImportSpikeIntake,
  canImportTimeTracking,
  canLinkAireRecord,
  companyId,
  handleUnapprove,
  hasLinkedAireRecord,
  hasStagedWorksheetChanges,
  isApproved,
  isCalculated,
  isCommitted,
  isDraft,
  isVoided,
  openPayDateCorrection,
  payPeriod,
  payRunId,
  payrollItems,
  processing,
  returnTo,
  savedImportReloadRequired,
  setAireRecordsOpen,
  setImportModalOpen,
  setPayrollIntakeImportOpen,
  setRefreshBaseSalary,
  setRefreshRecurring,
  setRefreshSetupOpen,
  setTimeTrackingAutoPreview,
  setTimeTrackingImportOpen,
} = props;
  const menu = useRef<HTMLDetailsElement>(null);
  useEffect(() => {
    const closeOutside = (event: PointerEvent) => { if (!menu.current?.contains(event.target as Node)) menu.current?.removeAttribute('open'); };
    document.addEventListener('pointerdown', closeOutside);
    return () => document.removeEventListener('pointerdown', closeOutside);
  }, []);
  const needsHours = isDraft && canImportTimeTracking && needsSourceCoverageAcknowledgement(payPeriod);
  const openHours = () => { setTimeTrackingAutoPreview(false); setTimeTrackingImportOpen(true); };
  const route = (tab: 'work' | 'checks' | 'activity', hash = '') => `${payRunPath(companyId, payRunId, tab, { returnTo })}${hash}`;
  return <section className="flex w-full items-start gap-2 sm:w-auto" aria-label="Payroll processing actions">
    <div className="min-w-0 flex-1 [&_button]:w-full [&>div]:w-full">{isVoided ? <Link className="inline-flex min-h-11 items-center justify-center rounded-full bg-primary-700 px-4 text-sm font-semibold text-white" to={route('activity', '#payroll-corrections')}>Review corrections</Link> : <PayRunStepAction {...props} step={isDraft ? 'hours' : isCalculated || isCommitted ? 'results' : 'commit'} header />}</div>
    <details ref={menu} className="relative shrink-0" onKeyDown={event => { if (event.key === 'Escape') { event.preventDefault(); menu.current?.removeAttribute('open'); menu.current?.querySelector('summary')?.focus(); } }}>
      <summary aria-label="More payroll actions" className="flex min-h-11 min-w-11 cursor-pointer list-none items-center justify-center rounded-full border border-neutral-300 bg-white text-neutral-700 hover:bg-neutral-50 focus-visible:outline-2 focus-visible:outline-primary-700 [&::-webkit-details-marker]:hidden"><MoreHorizontal className="h-5 w-5" aria-hidden="true" /></summary>
      <div className="absolute right-0 top-full z-30 mt-2 flex max-h-[70vh] w-72 max-w-[calc(100vw-2rem)] flex-col items-stretch gap-2 overflow-y-auto rounded-xl border border-neutral-200 bg-white p-3 shadow-lg" onClick={event => { if ((event.target as HTMLElement).closest('button:not(:disabled), a')) { menu.current?.removeAttribute('open'); menu.current?.querySelector('summary')?.focus(); } }}>
        {hasLinkedAireRecord && <Button variant="outline" onClick={() => setAireRecordsOpen(true)}>View linked time record</Button>}
        {isCommitted && !isVoided && <>
          {canLinkAireRecord && !hasLinkedAireRecord && <Button variant="outline" onClick={openHours}>Link time tracking record</Button>}
          <Button variant="outline" onClick={openPayDateCorrection}>Correct Pay Date</Button>
        </>}
        {!isCommitted && !isVoided && <>
          {canImportMosa && <Button variant="outline" onClick={() => setImportModalOpen(true)}>Import (MoSa)</Button>}
          {canImportSpikeIntake && <Button variant="outline" onClick={() => setPayrollIntakeImportOpen(true)}>Import Spike Email</Button>}
          {canImportTimeTracking && !needsHours && <Button variant="outline" onClick={openHours}>Import time tracking</Button>}
        </>}
        {canEditPayPeriod && payrollItems.length > 0 && <div>
          <Button className="w-full" variant="outline" disabled={processing || savedImportReloadRequired || hasStagedWorksheetChanges} title={hasStagedWorksheetChanges ? 'Calculate your worksheet edits first so they are saved.' : undefined} onClick={() => { setRefreshRecurring(payPeriod.includes_recurring_items); setRefreshBaseSalary(payPeriod.includes_base_salary); setRefreshSetupOpen(true); }}>Refresh current setup</Button>
          {hasStagedWorksheetChanges && <p className="mt-1 text-xs text-neutral-600">Calculate your worksheet edits first, then refresh current setup.</p>}
        </div>}
        {isApproved && <Button variant="outline" onClick={handleUnapprove} disabled={processing}>Roll Back Approval</Button>}
        {(isCommitted || isVoided || payPeriod.run_purpose === 'correction') && <Link className="inline-flex min-h-11 items-center justify-center rounded-full border border-neutral-300 px-4 text-sm font-semibold text-neutral-700" to={route('activity', '#payroll-corrections')}>Payroll corrections</Link>}
      </div>
    </details>
  </section>;
}

export function PayRunStepAction({ step, header = false, ...props }: PayRunSectionProps<'processing'> & { step: 'hours' | 'results' | 'commit'; header?: boolean }) {
  const { payPeriod, isDraft, isCalculated, isApproved, isCommitted, processing, financialActionsHeld, savedImportReloadRequired, correctionCalculationHeld, calculationFailures, payrollItems, hasPendingCalculationChanges, standaloneLoanConflicts, handleRunPayroll, handleApprove, setCommitPeriodId, canImportTimeTracking, setTimeTrackingAutoPreview, setTimeTrackingImportOpen, hasManualHours } = props;
  const needsHours = isDraft && canImportTimeTracking && needsSourceCoverageAcknowledgement(payPeriod);
  const missingInputs = needsSourceCoverageAcknowledgement(payPeriod) && !hasManualHours;
  const reason = savedImportReloadRequired ? 'Reload the saved source import before approval' : correctionCalculationHeld ? 'Review retained source evidence and pay setup before approval'
    : calculationFailures.length ? 'Resolve the employee calculation errors and calculate again before approval' : !payrollItems.length ? 'Enter pay for at least one employee before approval'
    : hasPendingCalculationChanges ? 'Recalculate the staged payroll changes before approval' : payPeriod.client_payroll_approval_required && payPeriod.payroll_review?.status !== 'approved' ? 'Client approval is required for this revision' : undefined;
  if (step === 'hours') return <div className="flex flex-wrap items-start gap-2">
    {needsHours && <Button onClick={() => { setTimeTrackingAutoPreview(false); setTimeTrackingImportOpen(true); }} disabled={processing || savedImportReloadRequired}>Review &amp; add hours</Button>}
    {(!header || !needsHours) && (isDraft || isCalculated) && <div><Button variant={needsHours ? 'outline' : 'primary'} onClick={() => void handleRunPayroll()} disabled={processing || financialActionsHeld || missingInputs} title={missingInputs ? 'Add source hours or enter manual hours before calculating' : undefined} aria-describedby={!header && missingInputs ? 'hours-required-reason' : undefined}>{processing ? 'Calculating...' : isDraft ? 'Calculate Payroll' : 'Recalculate'}</Button>{!header && missingInputs && <p id="hours-required-reason" className="mt-1 max-w-xl text-sm text-neutral-600">Add source hours or enter manual hours before calculating. Missing time tracking coverage still requires acknowledgement.</p>}</div>}
  </div>;
  if (step === 'results') return isCalculated ? <div><Button onClick={handleApprove} disabled={processing || financialActionsHeld || !!standaloneLoanConflicts.length || !!reason} title={reason} aria-describedby={!header && reason ? 'approval-required-reason' : undefined}>Approve</Button>{!header && reason && <p id="approval-required-reason" className="mt-1 text-sm text-neutral-600">{reason}</p>}</div> : isCommitted ? <Link className="inline-flex min-h-11 items-center justify-center rounded-full bg-primary-700 px-4 text-sm font-semibold text-white" to={payRunPath(props.companyId, payPeriod.id, 'checks', { returnTo: props.returnTo })}>Checks &amp; payments</Link> : isDraft ? <Button disabled variant="outline" title="Calculate payroll before reviewing employee results">Review results</Button> : null;
  return <div><Button onClick={() => setCommitPeriodId(payPeriod.id)} disabled={!isApproved || processing || financialActionsHeld || payPeriod.parallel_run || props.isVoided} title={payPeriod.parallel_run ? 'Parallel comparison · cannot commit' : undefined} aria-describedby={!header && (!isApproved || payPeriod.parallel_run) ? 'commit-required-reason' : undefined}>{processing ? 'Committing...' : 'Commit'}</Button>{!header && (!isApproved || payPeriod.parallel_run) && !isCommitted && <p id="commit-required-reason" className="mt-1 text-sm text-neutral-600">{payPeriod.parallel_run ? 'Parallel comparison · cannot commit.' : 'Approve the reviewed payroll before commitment.'}</p>}</div>;
}
