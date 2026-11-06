

import { Link } from 'react-router';
import { AlertTriangle, Loader2, MailCheck, ShieldCheck } from 'lucide-react';
import { Button } from '@/components/ui/button';

import { Alert } from '@/components/ui/alert';

import type { PayRunSectionProps } from './usePayRunController';

export function FicaHistoryReviewNotice({ note }: { note?: string | null }) {
  if (!note) return null;
  return <Alert>
    <p className="font-semibold">Prior-period payroll review remains open</p>
    <p className="mt-1 text-sm leading-6">{note}</p>
  </Alert>;
}

export function PayRunBlockers({
  part = 'all',
  adoptingConfirmedWorkweek,
  canImportMosa,
  canImportSpikeIntake,
  clientApprovalLoading,
  handleAdoptConfirmedWorkweek,
  hasPendingCalculationChanges,
  openClientApproval,
  payPeriod,
  setImportModalOpen,
  setPayrollIntakeImportOpen
}: PayRunSectionProps<'blockers'> & { part?: 'all' | 'hours' | 'approval' }) {
  const ficaNote = payPeriod.annual_fica_review_note;
  return (<>
{part !== 'approval' && hasPendingCalculationChanges && (
          <Alert>
            <p className="font-semibold">Recalculate to include your changes</p>
            <p className="mt-1 text-sm leading-6 text-warning-800">
              The values below have changed, but the calculated payroll and client review still reflect the previous amounts. Recalculate before approval.
            </p>
          </Alert>
        )}
{part !== 'hours' && payPeriod.client_payroll_approval_required && payPeriod.payroll_review && (
          <Alert tone={payPeriod.payroll_review.status === 'approved' ? 'success' : 'warning'} className={payPeriod.payroll_review.status === 'approved' ? 'border-success-200 bg-success-50/70' : 'border-warning-200 bg-warning-50/70'}>
            <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
              <div className="flex items-start gap-3">
                <div className={`mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-xl ${payPeriod.payroll_review.status === 'approved' ? 'bg-success-100 text-success-700' : 'bg-warning-100 text-warning-800'}`}>
                  {payPeriod.payroll_review.status === 'approved' ? <ShieldCheck className="h-5 w-5" /> : <MailCheck className="h-5 w-5" />}
                </div>
                <div>
                  <p className="font-semibold text-neutral-950">
                    Client review revision {payPeriod.payroll_review.revision} · {payPeriod.payroll_review.status === 'approved' ? 'Approved' : 'Awaiting approval'}
                  </p>
                  <p className="mt-1 text-sm leading-6 text-neutral-700">
                    Review ID <span className="font-mono font-semibold">{payPeriod.payroll_review.checksum_short}</span>. This ID changes whenever payroll inputs, source evidence, or calculation results change.
                  </p>
                  {payPeriod.payroll_review.status === 'approved' ? (
                    <p className="mt-1 text-sm text-success-800">
                      Approved by {payPeriod.payroll_review.approved_by_name} via {payPeriod.payroll_review.approval_method === 'client_portal' ? 'client portal' : 'email attestation'}.
                    </p>
                  ) : (
                    <p className="mt-1 text-sm text-warning-900">The client may approve in their portal, or payroll staff may retain and record an explicit approval email. A receipt-only reply does not approve payroll.</p>
                  )}
                </div>
              </div>
              {payPeriod.payroll_review.status === 'pending' && (
                <Button type="button" variant="outline" onClick={() => void openClientApproval()} disabled={clientApprovalLoading} className="shrink-0 bg-white">
                  {clientApprovalLoading ? 'Loading…' : 'Record Email Approval'}
                </Button>
              )}
            </div>
          </Alert>
        )}
{part !== 'approval' && payPeriod.intake_stale_at && (
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
              {(canImportMosa || canImportSpikeIntake) && (
                <Button
                  type="button"
                  variant="outline"
                  className="shrink-0 border-danger-300 bg-white text-danger-900 hover:bg-danger-100"
                  onClick={() => canImportMosa ? setImportModalOpen(true) : setPayrollIntakeImportOpen(true)}
                >
                  Review current source
                </Button>
              )}
            </div>
          </Alert>
        )}
{part !== 'approval' && payPeriod.compliance_warnings?.filter((warning) => warning !== ficaNote).map((warning) => (
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
