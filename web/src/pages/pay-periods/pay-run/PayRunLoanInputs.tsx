

import { NamedLoanInputs } from '@/components/payroll/NamedLoanInputs';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunLoanInputs({
  additionalEmployeeIds,
  canEditPayPeriod,
  employees,
  isCalculated,
  isDraft,
  namedLoanDrafts,
  namedLoanOptions,
  payPeriod,
  payrollItems,
  setNamedLoanDrafts,
  standaloneLoanConflicts
}: PayRunSectionProps<'loans'>) {
  return (<>
{standaloneLoanConflicts.length > 0 && canEditPayPeriod && (
          <div role="alert" className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm text-warning-900">
            Use Linked loan repayments to credit the saved loan balance. Clear the standalone one-time deduction
            for {Array.from(new Set(standaloneLoanConflicts.map(option => {
              const employee = employees.find(candidate => candidate.id === option.employee_id);
              return employee ? `${employee.first_name} ${employee.last_name}` : `employee #${option.employee_id}`;
            }))).join(', ')} before calculating and approving.
          </div>
        )}
{(isDraft || isCalculated) && namedLoanOptions.length > 0 && (
          <section className="hidden space-y-3 md:block" aria-label="Linked loan repayments">
            <h3 className="font-semibold text-neutral-900">Linked loan repayments</h3>
            <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
              {employees.filter(employee => namedLoanOptions.some(option => option.employee_id === employee.id)
                && (isDraft || payrollItems.some(item => item.employee_id === employee.id) || additionalEmployeeIds.has(employee.id)))
                .map(employee => (
                  <div key={employee.id}>
                    <p className="mb-1 text-sm font-semibold">{employee.first_name} {employee.last_name}</p>
                    <NamedLoanInputs
                      options={namedLoanOptions.filter(option => option.employee_id === employee.id)}
                      drafts={namedLoanDrafts[String(employee.id)] || {}}
                      includesRecurring={payPeriod.includes_recurring_items}
                      onChange={(loanId, draft) => setNamedLoanDrafts(previous => ({
                        ...previous,
                        [String(employee.id)]: { ...previous[String(employee.id)], [String(loanId)]: draft },
                      }))}
                    />
                  </div>
                ))}
            </div>
          </section>
        )}
  </>);
}
