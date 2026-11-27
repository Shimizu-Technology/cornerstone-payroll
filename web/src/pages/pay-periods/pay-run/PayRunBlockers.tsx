

import { Link } from 'react-router';
import { AlertTriangle, Loader2, MailCheck, ShieldCheck } from 'lucide-react';
import { Button } from '@/components/ui/button';

import { Alert } from '@/components/ui/alert';

import type { PayPeriod } from '@/types';
import { formatGuam } from '@/lib/payrollSubmissionFormat';
import { ClientApprovalOverride } from './ClientApprovalOverride';
import type { PayRunSectionProps } from './usePayRunController';

const CLIENT_FILE_STATUS: Record<string, string> = { waiting: 'Waiting for review', imported: 'Imported', 'set aside': 'Set aside' };

export function PayRunClientFiles({ payPeriod }: { payPeriod: PayPeriod }) {
  const files = payPeriod.client_files;
  if (!files) return null;
  return <section aria-label="Files from the client" className="rounded-lg border border-neutral-200 bg-white p-3 text-sm">
    <h3 className="font-semibold">Files from the client</h3>
    <p>Revision {files.revision} · {CLIENT_FILE_STATUS[files.status] || files.status} · Sent {formatGuam(files.submitted_at)}</p>
    <Link className="inline-flex min-h-11 items-center text-primary-800 underline" to={`/companies/${payPeriod.company_id}/payroll-submissions/${files.period_id}#revision-${files.submission_id}`}>Open Pay Period Files</Link>
  </section>;
}

export function PayRunBlockers({
  part = 'all',
  adoptingConfirmedWorkweek,
  canEditPayPeriod,
  canImportMosa,
  canImportSpikeIntake,
  clientApprovalLoading,
  companyId,
  enabledIntakeAdapters = [],
  financialActionsHeld,
  handleAdoptConfirmedWorkweek,
  handleRunPayroll,
  hasPendingCalculationChanges,
  openClientApproval,
  openIntakeAdapter,
  processing,
  reloadClientReview,
  payPeriod,
  setImportModalOpen,
  setPayrollIntakeImportOpen
}: PayRunSectionProps<'blockers'> & { part?: 'all' | 'hours' | 'approval' | 'lifecycle' }) {
  const ficaNote = payPeriod.annual_fica_review_note;
  const staleEmployees = payPeriod.stale_calculation_employees ?? [];
  const unverifiedChanges = payPeriod.unverified_employee_changes ?? [];
  const effectiveCompanyId = companyId ?? payPeriod.company_id;
  const showLifecycle = part === 'all' || part === 'lifecycle';
  const showHours = part === 'all' || part === 'hours';
  const showApproval = part === 'all' || part === 'approval';
  return (<>
{showLifecycle && staleEmployees.length > 0 && (payPeriod.status === 'calculated' || payPeriod.status === 'approved') && (
  <Alert id="payroll-stale-calculation" tone="error">
    <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
      <div className="flex items-start gap-3">
        <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-danger-700" aria-hidden="true" />
        <div>
          <p className="font-semibold">Recalculate payroll — employee details changed after calculation</p>
          <p className="mt-1 max-w-4xl text-sm leading-6 text-danger-800">
            {payPeriod.status === 'approved'
              ? 'Unapprove and recalculate this payroll before committing so every paycheck reflects current pay, withholding, tax ID, payment delivery, and status.'
              : 'Approve and commit are blocked until you recalculate this run with updated employee details.'}
          </p>
          <ul className="mt-2 list-disc space-y-1 pl-5 text-sm text-danger-900">
            {staleEmployees.map((entry) => (
              <li key={entry.payroll_item_id}>
                <span className="font-medium">{entry.name}</span> — {entry.reason}
              </li>
            ))}
          </ul>
        </div>
      </div>
      {payPeriod.status === 'calculated' && canEditPayPeriod && handleRunPayroll && (
        <Button
          type="button"
          variant="outline"
          className="shrink-0 border-danger-300 bg-white text-danger-900 hover:bg-danger-100"
          disabled={processing || financialActionsHeld}
          onClick={() => void handleRunPayroll()}
        >
          Recalculate
        </Button>
      )}
    </div>
  </Alert>
)}
{showLifecycle && unverifiedChanges.length > 0 && payPeriod.status !== 'committed' && payPeriod.correction_status !== 'voided' && (
  <Alert id="payroll-unverified-changes" tone="warning" className="border-warning-200 bg-warning-50/70">
    <div>
      <p className="font-semibold text-warning-950">
        Changed since last payroll, not verified ({unverifiedChanges.length})
      </p>
      <p className="mt-1 text-sm leading-6 text-warning-900">
        These client-managed employee updates do not block calculating, approving, or client review. Verify them or acknowledge every item in the Commit dialog before finalizing payroll.
      </p>
      <ul className="mt-2 space-y-1.5 text-sm text-warning-950">
        {unverifiedChanges.map((item) => (
          <li key={item.id} className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
            {effectiveCompanyId ? (
              <Link className="font-medium text-primary-800 underline" to={`/companies/${effectiveCompanyId}/employees/${item.employee_id}`}>
                {item.employee_name}
              </Link>
            ) : (
              <span className="font-medium">{item.employee_name}</span>
            )}
            <span>— {item.summary}</span>
            <span className="text-xs font-medium text-warning-800">
              ({item.status === 'returned_to_client' ? 'Sent back to client' : 'Pending verification'})
            </span>
          </li>
        ))}
      </ul>
    </div>
  </Alert>
)}
{showHours && payPeriod.client_files?.blocks_calculation && <Alert>
  <p>Calculate is blocked until you <Link className="text-primary-800 underline" to={`/companies/${payPeriod.company_id}/payroll-submissions/${payPeriod.client_files.period_id}#revision-${payPeriod.client_files.submission_id}`}>review this revision</Link> and import it or record why it is set aside.</p>
</Alert>}
{showHours && hasPendingCalculationChanges && (
          <Alert>
            <p className="font-semibold">Recalculate to include your changes</p>
            <p className="mt-1 text-sm leading-6 text-warning-800">
              The values below have changed, but the calculated payroll and client review still reflect the previous amounts. Recalculate before approval.
            </p>
          </Alert>
        )}
{showApproval && payPeriod.payroll_review && (payPeriod.client_payroll_approval_required || payPeriod.payroll_review.published_at) && (
          <Alert tone={payPeriod.payroll_review.status === 'approved' ? 'success' : 'warning'} className={payPeriod.payroll_review.status === 'approved' ? 'border-success-200 bg-success-50/70' : 'border-warning-200 bg-warning-50/70'}>
            <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
              <div className="flex items-start gap-3">
                <div className={`mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-xl ${payPeriod.payroll_review.status === 'approved' ? 'bg-success-100 text-success-700' : 'bg-warning-100 text-warning-800'}`}>
                  {payPeriod.payroll_review.status === 'approved' ? <ShieldCheck className="h-5 w-5" /> : <MailCheck className="h-5 w-5" />}
                </div>
                <div>
                  <p className="font-semibold text-neutral-950">
                    Client review revision {payPeriod.payroll_review.revision} · {payPeriod.payroll_review.status === 'approved' ? 'Approved' : payPeriod.payroll_review.status === 'changes_requested' ? 'Changes requested' : payPeriod.status === 'committed' ? 'Payroll finalized' : payPeriod.status === 'approved' ? (payPeriod.client_payroll_approval_required === false ? 'Client review disabled' : 'Awaiting client review') : 'Approve payroll to publish preview'}
                  </p>
                  <p className="mt-1 text-sm leading-6 text-neutral-700">
                    Review ID <span className="font-mono font-semibold">{payPeriod.payroll_review.checksum_short}</span>. This ID changes whenever payroll inputs, source evidence, or calculation results change.
                  </p>
                  {payPeriod.payroll_review.change_request_note && <div role="status" className="mt-3 space-y-1 text-warning-950">
                    <p className="font-semibold">{payPeriod.payroll_review.changes_requested_by_name} requested changes</p>
                    <p className="whitespace-pre-wrap break-words">{payPeriod.payroll_review.change_request_note}</p>
                    <p>{payPeriod.payroll_review.changes_requested_at && formatGuam(payPeriod.payroll_review.changes_requested_at)}</p>
                    <p className="font-semibold">Unapprove to make changes, recalculate, then approve to publish a new revision.</p>
                  </div>}
                  {payPeriod.payroll_review.approval_method === 'cornerstone_override' ? (
                    <div className="mt-1 text-sm text-success-800">
                      <p>Approved by Cornerstone for the client: {payPeriod.payroll_review.approved_by_name}, {payPeriod.payroll_review.approved_at && formatGuam(payPeriod.payroll_review.approved_at)}</p>
                      <p className="whitespace-pre-wrap break-words">{payPeriod.payroll_review.override_reason}</p>
                    </div>
                  ) : payPeriod.payroll_review.status === 'approved' ? (
                    <p className="mt-1 text-sm text-success-800">
                      Approved by {payPeriod.payroll_review.approved_by_name} via {payPeriod.payroll_review.approval_method === 'client_portal' ? 'client portal' : 'email attestation'}.
                    </p>
                  ) : (
                    <p className="mt-1 text-sm text-warning-900">{payPeriod.status === 'committed' ? 'Payroll is finalized. This review is retained as history.' : payPeriod.payroll_review.status === 'changes_requested' ? "Resolve the client's change request before committing (unapprove to make changes)." : payPeriod.client_payroll_approval_required === false ? 'Client review is disabled. This preview is retained as history; staff can commit without a client decision.' : payPeriod.status === 'approved' ? 'The preview is available in the client portal. Client approval is required before commit when enabled for this client.' : 'Staff approval publishes the preview for the client to review.'}</p>
                  )}
                </div>
              </div>
              {payPeriod.company_id && payPeriod.can_override_client_approval && payPeriod.client_payroll_approval_required && payPeriod.status === 'approved' && payPeriod.payroll_review.status === 'pending' && payPeriod.payroll_review.published_at && (
                <ClientApprovalOverride key={payPeriod.payroll_review.id} companyId={payPeriod.company_id} periodId={payPeriod.id}
                  revisionId={payPeriod.payroll_review.id} onDone={reloadClientReview} />
              )}
              {payPeriod.can_record_client_approval && payPeriod.client_payroll_approval_required !== false && payPeriod.status === 'approved' && payPeriod.payroll_review.status === 'pending' && (
                <Button type="button" variant="outline" onClick={() => void openClientApproval()} disabled={clientApprovalLoading} className="shrink-0 bg-white">
                  {clientApprovalLoading ? 'Loading…' : 'Record Email Approval'}
                </Button>
              )}
            </div>
          </Alert>
        )}
{showApproval && payPeriod.payroll_review_history?.some(entry => entry.superseded_at && entry.change_request_note) && <details className="rounded-lg border border-neutral-200 bg-white p-4 text-sm">
  <summary className="min-h-11 cursor-pointer font-semibold">Earlier client change requests</summary>
  {payPeriod.payroll_review_history.filter(entry => entry.superseded_at && entry.change_request_note).map(entry => <div key={entry.id} className="mt-3 space-y-1 border-t pt-3">
    <p className="font-semibold">Revision {entry.revision} · {entry.changes_requested_by_name}</p>
    <p className="whitespace-pre-wrap break-words">{entry.change_request_note}</p>
    {entry.changes_requested_at && <p>{formatGuam(entry.changes_requested_at)}</p>}
  </div>)}
</details>}
{showHours && payPeriod.intake_stale_at && (
          <Alert tone="error">
            <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <div className="flex items-start gap-3">
                <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-danger-700" aria-hidden="true" />
                <div>
                  <p className="font-semibold">This payroll is stale because the source changed</p>
                  <p className="mt-1 max-w-4xl text-sm leading-6 text-danger-800">{payPeriod.intake_stale_reason}</p>
                  <p className="mt-1 text-sm text-danger-800">Review and apply the current source package. Payroll cannot be approved or committed until that revision is applied.</p>
                </div>
              </div>
              {(enabledIntakeAdapters.length > 0 || canImportMosa || canImportSpikeIntake) && (
                <Button
                  type="button"
                  variant="outline"
                  className="shrink-0 border-danger-300 bg-white text-danger-900 hover:bg-danger-100"
                  onClick={() => {
                    const preferred = enabledIntakeAdapters.find((adapter) => adapter.tracks_reviewed_hours) || enabledIntakeAdapters[0];
                    if (preferred) openIntakeAdapter(preferred.key);
                    else if (canImportMosa) setImportModalOpen(true);
                    else setPayrollIntakeImportOpen(true);
                  }}
                >
                  Review current source
                </Button>
              )}
            </div>
          </Alert>
        )}
        {showHours && payPeriod.compensation_warnings?.map((warning) => (
          <Alert key={warning}>
            <p className="max-w-4xl leading-6"><span className="font-semibold">Mid-period pay change.</span> {warning}</p>
          </Alert>
        ))}
        {showHours && payPeriod.compliance_warnings?.filter((warning) => warning !== ficaNote).map((warning) => (
          <Alert key={warning}>
            <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
              <p className="max-w-4xl leading-6">
                <span className="font-semibold">
                  {payPeriod.confirmed_workweek_adoption?.available ? 'Confirmed workweek ready for this run:' : 'This run’s workweek needs attention:'}
                </span>{' '}{warning}
              </p>
              <div className="flex shrink-0 flex-wrap items-center gap-2">
                <Link
                  to="/pay-schedule-settings"
                  target="_blank"
                  rel="noreferrer"
                  className="inline-flex min-h-9 items-center justify-center rounded-full border border-warning-300 bg-white px-4 py-2 text-xs font-semibold text-warning-950 transition-colors hover:bg-warning-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-warning-400 focus-visible:ring-offset-2"
                >
                  Review settings
                </Link>
                {payPeriod.confirmed_workweek_adoption?.available && (
                  <Button
                    type="button"
                    size="sm"
                    onClick={() => void handleAdoptConfirmedWorkweek()}
                    disabled={adoptingConfirmedWorkweek}
                  >
                    {adoptingConfirmedWorkweek ? (
                      <><Loader2 className="mr-2 h-4 w-4 animate-spin" />Applying…</>
                    ) : 'Use confirmed workweek'}
                  </Button>
                )}
              </div>
            </div>
            {payPeriod.confirmed_workweek_adoption?.available && (
              <p className="mt-2 max-w-4xl text-xs leading-5 text-warning-800">
                A matching employer-confirmed workweek is available. Applying it keeps entered hours and does not alter completed runs.
                {payPeriod.calculated_at ? ' Because this run was already calculated, you will need to select Calculate Payroll again.' : ''}
              </p>
            )}
          </Alert>
        ))}
  </>);
}
