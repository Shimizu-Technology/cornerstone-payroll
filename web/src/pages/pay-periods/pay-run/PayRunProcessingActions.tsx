
import { needsSourceCoverageAcknowledgement } from '@/lib/payroll-source-coverage';

import { Link } from 'react-router';
import { MoreHorizontal } from 'lucide-react';
import { useEffect, useRef } from 'react';
import { Button } from '@/components/ui/button';


import { payRunPath } from '@/lib/routes';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunProcessingActions({
  calculationFailures,
  canEditPayPeriod,
  canImportMosa,
  canImportSpikeIntake,
  canImportTimeTracking,
  canLinkAireRecord,
  companyId,
  correctionCalculationHeld,
  financialActionsHeld,
  handleApprove,
  handleRunPayroll,
  handleUnapprove,
  hasLinkedAireRecord,
  hasPendingCalculationChanges,
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
  setCommitPeriodId,
  setImportModalOpen,
  setPayrollIntakeImportOpen,
  setRefreshBaseSalary,
  setRefreshRecurring,
  setRefreshSetupOpen,
  setTimeTrackingAutoPreview,
  setTimeTrackingImportOpen,
  standaloneLoanConflicts
}: PayRunSectionProps<'processing'>) {
  const menu = useRef<HTMLDetailsElement>(null);
  useEffect(() => {
    const closeOutside = (event: PointerEvent) => { if (!menu.current?.contains(event.target as Node)) menu.current?.removeAttribute('open'); };
    document.addEventListener('pointerdown', closeOutside);
    return () => document.removeEventListener('pointerdown', closeOutside);
  }, []);
  const needsHours = isDraft && canImportTimeTracking && needsSourceCoverageAcknowledgement(payPeriod);
  const openHours = () => { setTimeTrackingAutoPreview(false); setTimeTrackingImportOpen(true); };
  const approveReason = savedImportReloadRequired ? 'Reload the saved source import before approval' : correctionCalculationHeld ? 'Review retained source evidence and pay setup before approval'
    : calculationFailures.length > 0 ? 'Resolve the employee calculation errors and calculate again before approval'
    : payrollItems.length === 0 ? 'Enter pay for at least one employee before approval'
    : hasPendingCalculationChanges ? 'Recalculate the staged payroll changes before approval'
    : payPeriod.client_payroll_approval_required === true && payPeriod.payroll_review?.status !== 'approved' ? 'Client approval is required for this revision' : undefined;
  const route = (tab: 'work' | 'checks' | 'activity', hash = '') => `${payRunPath(companyId, payRunId, tab, { returnTo })}${hash}`;
  return <section className="flex w-full items-start gap-2 sm:w-auto" aria-label="Payroll processing actions">
    <div className="min-w-0 flex-1 sm:flex-initial">
      {needsHours ? <Button className="w-full" onClick={openHours} disabled={processing || savedImportReloadRequired}>Review &amp; add hours</Button>
        : isDraft ? <Button className="w-full" onClick={() => void handleRunPayroll()} disabled={processing || financialActionsHeld}>{processing ? 'Calculating...' : 'Calculate Payroll'}</Button>
        : isCalculated ? <Button className="w-full" onClick={handleApprove} disabled={processing || financialActionsHeld || standaloneLoanConflicts.length > 0 || Boolean(approveReason)} title={approveReason}>Approve</Button>
        : isApproved ? <Button className="w-full" onClick={() => setCommitPeriodId(payPeriod.id)} disabled={processing || financialActionsHeld || payPeriod.parallel_run} title={payPeriod.parallel_run ? 'Parallel comparison · cannot commit' : undefined}>{processing ? 'Committing...' : 'Commit'}</Button>
        : <Link className="inline-flex min-h-11 w-full items-center justify-center rounded-full bg-primary-700 px-4 text-sm font-semibold text-white hover:bg-primary-800" to={route(isVoided ? 'activity' : 'checks', isVoided ? '#payroll-corrections' : '')}>{isVoided ? 'Review corrections' : 'Checks & payments'}</Link>}
      {isApproved && payPeriod.parallel_run && <p className="mt-1 max-w-52 text-xs text-neutral-600">Parallel comparison · cannot commit</p>}
      {isCalculated && approveReason && <p className="mt-1 max-w-64 text-xs text-neutral-600">{approveReason}</p>}
    </div>
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
        {needsHours && <>
          <p className="text-sm text-neutral-700">Time tracking hours have not been added. Review &amp; add hours first. Calculating now requires a reason and acknowledgement of missing hourly pay.</p>
          <Button variant="outline" onClick={() => void handleRunPayroll()} disabled={processing || financialActionsHeld}>{processing ? 'Calculating...' : 'Calculate Payroll'}</Button>
        </>}
        {isCalculated && <Button variant="outline" onClick={() => void handleRunPayroll()} disabled={processing || financialActionsHeld}>Recalculate</Button>}
        {isApproved && <Button variant="outline" onClick={handleUnapprove} disabled={processing}>Roll Back Approval</Button>}
        {(isCommitted || isVoided || payPeriod.run_purpose === 'correction') && <Link className="inline-flex min-h-11 items-center justify-center rounded-full border border-neutral-300 px-4 text-sm font-semibold text-neutral-700" to={route('activity', '#payroll-corrections')}>Payroll corrections</Link>}
      </div>
    </details>
  </section>;
}
