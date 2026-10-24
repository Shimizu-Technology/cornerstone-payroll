
import { needsSourceCoverageAcknowledgement } from '@/lib/payroll-source-coverage';

import { Link } from 'react-router';
import { LockKeyhole } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';

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
  return (<>
<section className="mb-6 flex flex-col gap-4 rounded-2xl border border-neutral-200 bg-neutral-50/80 p-4 xl:flex-row xl:items-center xl:justify-between" aria-label="Payroll processing actions">
        <div>
          <p className="font-display text-base font-bold text-neutral-950">{isCommitted ? 'Payroll committed' : isApproved ? 'Ready to finalize' : isCalculated ? 'Review calculated pay' : 'Prepare this payroll'}</p>
          <p className="mt-1 text-sm text-neutral-600">{isCommitted ? 'Pay is saved. Prepare checks and record delivery separately in Checks & direct deposit.' : isApproved ? 'Confirm the approved amounts, then commit this run.' : isCalculated ? 'Review employees and resolve any warnings before approval.' : 'Review source hours or enter pay, then calculate the selected employees.'}</p>
        </div>
        <div className="flex w-full flex-wrap gap-2 sm:w-auto sm:justify-end">
      {hasLinkedAireRecord && (
        <Button variant="outline" onClick={() => setAireRecordsOpen(true)}>View linked time record</Button>
      )}
      {isCommitted && !isVoided && (
        <>
          <Link className="inline-flex min-h-11 items-center rounded-full bg-primary-700 px-4 text-sm font-semibold text-white hover:bg-primary-800" to={payRunPath(companyId, payRunId, 'checks', { returnTo })}>Review checks and payments</Link>
          {canLinkAireRecord && !hasLinkedAireRecord && (
            <Button variant="outline" onClick={() => {
              setTimeTrackingAutoPreview(false);
              setTimeTrackingImportOpen(true);
            }}>
              Link time tracking record
            </Button>
          )}
          <Button variant="outline" onClick={openPayDateCorrection}>
            Correct Pay Date
          </Button>
        </>
      )}
      {!isCommitted && !isVoided && (
        <>
          {canImportMosa && (
            <Button variant="outline" onClick={() => setImportModalOpen(true)}>
              Import (MoSa)
            </Button>
          )}
          {canImportSpikeIntake && (
            <Button variant="outline" onClick={() => setPayrollIntakeImportOpen(true)}>
              Import Spike Email
            </Button>
          )}
          {canImportTimeTracking && (
            <Button variant="outline" onClick={() => {
              setTimeTrackingAutoPreview(false);
              setTimeTrackingImportOpen(true);
            }}>
              {needsSourceCoverageAcknowledgement(payPeriod) ? 'Review & add hours' : 'Import time tracking'}
            </Button>
          )}
        </>
      )}
      {canEditPayPeriod && payrollItems.length > 0 && (
        <div>
          <Button
            variant="outline"
            disabled={processing || savedImportReloadRequired || hasStagedWorksheetChanges}
            title={hasStagedWorksheetChanges ? 'Calculate your worksheet edits first so they are saved.' : undefined}
            onClick={() => {
              setRefreshRecurring(payPeriod.includes_recurring_items);
              setRefreshBaseSalary(payPeriod.includes_base_salary);
              setRefreshSetupOpen(true);
            }}
          >
            Refresh current setup
          </Button>
          {hasStagedWorksheetChanges && <p className="mt-1 text-xs text-neutral-600">Calculate your worksheet edits first, then refresh current setup.</p>}
        </div>
      )}
      {isDraft && needsSourceCoverageAcknowledgement(payPeriod) && <p role="status" className="max-w-lg rounded-lg border border-warning-200 bg-warning-50 p-3 text-sm text-warning-900">Time tracking hours have not been added. Review &amp; add hours first. Calculating now requires a reason and acknowledgement of missing hourly pay.</p>}
      {isDraft && (
        <>
          <Button variant={needsSourceCoverageAcknowledgement(payPeriod) ? 'outline' : 'primary'} onClick={() => void handleRunPayroll()} disabled={processing || financialActionsHeld}>
            {processing ? 'Calculating...' : 'Calculate Payroll'}
          </Button>
        </>
      )}
      {isCalculated && (
        <>
          <Button variant="outline" onClick={() => void handleRunPayroll()} disabled={processing || financialActionsHeld}>
            Recalculate
          </Button>
          <Button
            onClick={handleApprove}
            disabled={processing || financialActionsHeld || standaloneLoanConflicts.length > 0 || calculationFailures.length > 0 || payrollItems.length === 0 || hasPendingCalculationChanges || (payPeriod.client_payroll_approval_required === true && payPeriod.payroll_review?.status !== 'approved')}
            title={savedImportReloadRequired ? 'Reload the saved source import before approval' : correctionCalculationHeld ? 'Review retained source evidence and pay setup before approval'
              : calculationFailures.length > 0
              ? 'Resolve the employee calculation errors and calculate again before approval'
              : payrollItems.length === 0
              ? 'Enter pay for at least one employee before approval'
              : hasPendingCalculationChanges
              ? 'Recalculate the staged payroll changes before approval'
              : payPeriod.client_payroll_approval_required === true && payPeriod.payroll_review?.status !== 'approved'
                ? 'Client approval is required for this revision'
                : undefined}
          >
            Approve
          </Button>
        </>
      )}
      {isApproved && (
        <>
          <Button variant="outline" onClick={handleUnapprove} disabled={processing}>
            Roll Back Approval
          </Button>
          {payPeriod.parallel_run
            ? <Badge variant="info"><LockKeyhole className="mr-2 h-3.5 w-3.5" />Parallel comparison · cannot commit</Badge>
            : <Button onClick={() => setCommitPeriodId(payPeriod.id)} disabled={processing || financialActionsHeld}>{processing ? 'Committing...' : 'Commit & Finalize'}</Button>}
        </>
      )}
    </div>
      </section>
  </>);
}
