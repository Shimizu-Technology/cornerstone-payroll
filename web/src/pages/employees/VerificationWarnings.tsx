import { Link } from 'react-router';
import { Alert } from '@/components/ui/alert';
import { Badge } from '@/components/ui/badge';
import { payRunsPath } from '@/lib/routes';
import type { VerificationDetails } from '@/services/staff-employee-lifecycle';

function runNumbers(ids: number[]) {
  return ids.map(id => `#${id}`).join(', ');
}

export function ApprovedRunFixWarning({ ids }: { ids: number[] }) {
  if (!ids.length) return null;
  return <Alert>
    <p className="font-semibold">Changing approved payroll may require client re-approval</p>
    <p>This employee is on approved payroll {runNumbers(ids)}. If this fix affects that payroll, unapprove the run, recalculate, republish the review package, and get client re-approval before committing. Use the next period’s effective date if the fix applies going forward.</p>
  </Alert>;
}

export function VerificationWarnings({ item, canStartFinalPay }: { item: VerificationDetails; canStartFinalPay: boolean }) {
  const warnings = item.warnings;
  const impact = warnings.tax_filing_impact;
  const impactPeriods = [...(impact?.committed_tax_years ?? []), ...(impact?.filed_quarters ?? [])];
  return <div className="space-y-3">
    {warnings.committed_pay_period_ids.map(id => (
      <div key={id}><Badge variant="warning" className="whitespace-normal">
        Paid in committed run #{id}{item.status !== 'verified' ? ' · Still needs verification' : ''}
      </Badge></div>
    ))}
    {warnings.possible_self_created_hire && <Alert><strong>Possible self-created hire.</strong> The client manager’s name or sign-in email matches the new employee. Confirm they are different people or have someone else verify the details before committing payroll.</Alert>}
    {warnings.possible_self_lifecycle_action && <Alert>
      <strong>{warnings.own_record_signal === 'name_only' ? 'Possible self-action (name match only).' : 'Possible self-action.'}</strong>{' '}
      The client manager’s name matched this employee on a {item.event_kind === 'rehire' ? 'rehire' : 'termination'}. Confirm they are different people and verify this change before committing payroll.
    </Alert>}
    {warnings.post_termination_committed_pay_period_ids.length > 0 && <Alert tone="error">
      <strong>Backdated termination.</strong> This employee was paid after their termination date in committed payroll {runNumbers(warnings.post_termination_committed_pay_period_ids)}. Check for an overpayment and review whether the pay needs to be voided or corrected.
    </Alert>}
    {warnings.review_final_pay && <Alert>
      <p>Review final hours, accrued PTO payout, and whether you need an off-cycle final pay run.</p>
      {canStartFinalPay && <Link className="inline-flex min-h-11 items-center font-semibold underline" to={payRunsPath(item.company_id, 'new_final=1')}>Create a final pay run</Link>}
    </Alert>}
    {warnings.direct_deposit_missing_bank_details && <Alert><strong>Bank details are missing.</strong> Direct deposit was selected. Confirm the bank details and ACH setup before payday.</Alert>}
    {impact && <Alert><strong>Review W-2c and Form 941-GU amendments.</strong> This tax ID or legal name changed after reported pay{impactPeriods.length ? ` for ${impactPeriods.join(', ')}` : ''}.</Alert>}
  </div>;
}
