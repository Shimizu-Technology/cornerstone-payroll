import { Link } from 'react-router';
import { employeePath, retirementSetupPath } from '@/lib/routes';
import { errorRecovery } from '@/lib/error-recovery';

export interface PayrollCalculationFailure {
  employee_id: number;
  name?: string;
  error: string;
}

export function PayrollCalculationIssues({ failures, names, companyId, year, returnTo }: {
  failures: PayrollCalculationFailure[];
  names: Map<number, string>;
  companyId: number;
  year: number;
  returnTo: string;
}) {
  const groups = new Map<string, PayrollCalculationFailure[]>();
  failures.forEach((failure) => groups.set(failure.error, [...(groups.get(failure.error) || []), failure]));
  return <section id="payroll-calculation-issues" tabIndex={-1} aria-labelledby="payroll-calculation-issues-title" className="scroll-mt-24 rounded-2xl border border-danger-200 bg-danger-50 p-4 sm:p-5">
    <h2 id="payroll-calculation-issues-title" className="text-base font-bold text-danger-900">Resolve these employees before approval</h2>
    <p className="mt-2 text-sm leading-6 text-danger-900">Keep this payroll tab open to retain your entered values. Review links open an employee in a new tab. Resolve the issue, then return to this tab and calculate payroll again.</p>
    <div className="mt-4 space-y-4">{Array.from(groups, ([message, employees]) => {
      const isRetirement = /401\(k\)|retirement|catch.up|Roth/i.test(message);
      const isYearReview = /historical|imported|classification|retained|prior.year|wage evidence|annual|yearly retirement/i.test(message);
      const isSharedAnnualRules = /^Retirement limits are not configured/i.test(message);
      const guidance = errorRecovery(message);
      return <div key={message} className="rounded-xl border border-danger-200 bg-white p-4">
        <p className="break-words text-sm font-semibold leading-6 text-danger-900">{message}</p>
        {guidance && <p className="mt-2 text-sm leading-6 text-neutral-700">{guidance}</p>}
        <ul className="mt-3 divide-y divide-neutral-100">{employees.map((failure, index) => <li key={`${failure.employee_id}:${index}`} className="flex flex-col gap-2 py-3 first:pt-0 last:pb-0 sm:flex-row sm:items-center sm:justify-between">
          <span className="text-sm font-semibold text-neutral-900">{failure.name || names.get(failure.employee_id) || `Employee #${failure.employee_id}`}</span>
          {!isSharedAnnualRules && <Link target="_blank" rel="noopener noreferrer" className="inline-flex min-h-11 items-center justify-center rounded-full border border-primary-200 px-4 py-2 text-sm font-semibold text-primary-800 hover:bg-primary-50 focus-visible:outline-2 focus-visible:outline-primary-600" to={isRetirement
            ? retirementSetupPath(companyId, failure.employee_id, year, isYearReview ? 'retirement-year-evidence' : 'retirement-plan', { returnTo })
            : employeePath(companyId, failure.employee_id, 'pay-setup', { returnTo })}>
            {isRetirement ? (isYearReview ? `Review ${year} retirement checks` : 'Review contribution settings') : 'Open employee pay setup'}
          </Link>}
        </li>)}</ul>
      </div>;
    })}</div>
  </section>;
}
