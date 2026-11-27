

import { useState } from 'react';
import { Link } from 'react-router';
import { Button } from '@/components/ui/button';
import { BusyStatus } from '@/components/ui/busy-status';
import { AddBackNotice } from './AddBackNotice';
import { addBackSummary } from './addBackText';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunRoster({
  additionalEmployeeIds,
  companyId,
  employees,
  financialActionsHeld,
  handleRunPayroll,
  handleRestoreEmployee,
  addBackNotice,
  canEditPayPeriod,
  hasStagedWorksheetChanges,
  isCalculated,
  isDraft,
  payPeriod,
  payrollItems,
  processing,
  processingAction,
  setAdditionalEmployeeIds,
  setBonusEdits,
  setBonusMap,
  setHoursMap,
  setLoansMap,
  setNamedLoanDrafts,
  setPayrollFieldDrafts,
  setSalaryOverrideMap,
  setTipsMap,
  setTipsPaidOutMap
}: PayRunSectionProps<'roster'>) {
  const [restoringId, setRestoringId] = useState<number | null>(null);
  const restoring = restoringId !== null;
  const [restoreError, setRestoreError] = useState('');
  const restore = async (employeeId: number) => {
    setRestoringId(employeeId);
    setRestoreError('');
    try { await handleRestoreEmployee(employeeId, 'roster'); }
    catch (error) { setRestoreError(error instanceof Error ? error.message : 'Could not add employee back'); }
    finally { setRestoringId(null); }
  };
  // Expected entries shows an add-back it lists; this covers the rest.
  const rosterNotice = addBackNotice?.source === 'roster' &&
    !payPeriod.expected_entries?.added_back?.some(entry => entry.employee_id === addBackNotice.result.employee_id) ? addBackNotice : null;
  return (<>
{rosterNotice && (isCalculated || isDraft) && <AddBackNotice result={rosterNotice.result} hoursEntered={rosterNotice.hoursEntered} />}
{/* Stays mounted so the add-back result is announced when it arrives. */}
<p aria-live="polite" aria-atomic="true" className="sr-only" data-testid="add-back-announcement">{addBackNotice?.source === 'roster' ? addBackSummary(addBackNotice.result, addBackNotice.hoursEntered) : ''}</p>
{(isCalculated || isDraft) && !!payPeriod.excluded_employees?.length && (
  <section aria-label="Removed from this run" className="rounded-lg border border-neutral-200 bg-neutral-50 p-4">
    <h3 className="font-medium text-neutral-800">Removed from this run ({payPeriod.excluded_employees.length})</h3>
    {restoreError && <p role="alert" className="mt-2 text-sm text-danger-700">{restoreError}</p>}
    <ul className="mt-3 space-y-3">
      {payPeriod.excluded_employees.map(employee => <li key={employee.employee_id} className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div className="min-w-0 break-words"><p className="text-sm font-medium">{employee.name}</p><p className="text-sm text-neutral-600">{employee.reason || 'Removed from pay period'}</p></div>
        <Button className="min-h-11 shrink-0" size="sm" variant="outline" disabled={restoring || processing || financialActionsHeld || !canEditPayPeriod || hasStagedWorksheetChanges} loading={restoringId === employee.employee_id} loadingLabel="Adding back…" onClick={() => void restore(employee.employee_id)} aria-label={restoringId === employee.employee_id ? `Adding back ${employee.name}…` : `Add back ${employee.name}`}>Add back</Button>
      </li>)}
    </ul>
    <BusyStatus className="mt-2" busy={restoring}>Adding employee back to this run…</BusyStatus>
    {hasStagedWorksheetChanges && <p className="mt-2 text-sm text-neutral-600">Calculate your worksheet edits first, then add someone back.</p>}
  </section>
)}
{(isCalculated || isDraft || payPeriod.status === 'approved') && !!payPeriod.readiness_excluded_employees?.length && (
  <details className="rounded-lg border border-warning-200 bg-warning-50/70 p-4 text-sm text-warning-950">
    <summary className="min-h-11 cursor-pointer font-semibold">
      Not included — incomplete setup ({payPeriod.readiness_excluded_employees.length})
    </summary>
    <p className="mt-2 text-sm leading-6 text-warning-900">
      These client-managed hires are missing required payroll setup for this pay period and cannot be paid until their checklist is complete or an organization admin records an override.
    </p>
    <ul className="mt-3 space-y-2">
      {payPeriod.readiness_excluded_employees.map((employee) => {
        const effectiveCompanyId = companyId ?? payPeriod.company_id;
        return (
          <li key={employee.employee_id} className="flex flex-col gap-1 border-t border-warning-200/80 pt-2 first:border-t-0 first:pt-0 sm:flex-row sm:items-baseline sm:justify-between">
            <div className="min-w-0 break-words">
              {effectiveCompanyId ? (
                <Link className="font-semibold text-primary-800 underline" to={`/companies/${effectiveCompanyId}/employees/${employee.employee_id}`}>
                  {employee.name}
                </Link>
              ) : (
                <span className="font-semibold">{employee.name}</span>
              )}
              <span className="ml-1.5 text-warning-900">— {employee.reason}</span>
            </div>
          </li>
        );
      })}
    </ul>
  </details>
)}
{(isCalculated || (isDraft && payPeriod.run_purpose !== 'regular')) && (() => {
          const payrollEmployeeIds = new Set(payrollItems.map((pi) => pi.employee_id));
          const excludedEmployeeIds = new Set(payPeriod.excluded_employee_ids || []);
          const readinessExcludedIds = new Set((payPeriod.readiness_excluded_employees || []).map((emp) => emp.employee_id));
          const missingEmployees = employees.filter((emp) => !payrollEmployeeIds.has(emp.id) && !excludedEmployeeIds.has(emp.id) && !readinessExcludedIds.has(emp.id));
          if (missingEmployees.length === 0) return null;
          return (
            <div className="rounded-lg border border-neutral-200 bg-neutral-50 p-4">
              <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <p className="font-medium text-neutral-800">
                    {isDraft ? 'Choose employees for this special run' : `No pay in this period for ${missingEmployees.length} eligible employee${missingEmployees.length !== 1 ? 's' : ''}`}
                  </p>
                  <p className="mt-1 text-sm text-neutral-600">{isDraft ? 'Only the employees you choose are included. Select Enter pay, review their amounts below, then calculate payroll.' : 'They have no payroll item or paycheck for this run. Enter pay and recalculate if one should be included.'}</p>
                  <ul className="mt-3 space-y-2 text-sm text-neutral-700">
                    {missingEmployees.map((emp) => (
                      <li key={emp.id} className="flex flex-wrap items-center gap-2">
                        <span>{emp.first_name} {emp.last_name}</span>
                        <span className="text-xs text-neutral-600">({emp.employment_type})</span>
                        {additionalEmployeeIds.has(emp.id) ? (
                          <>
                            <span className="text-xs font-medium text-emerald-700">Ready for pay entry — review the amount below, then calculate</span>
                            <button type="button" className="min-h-11 text-xs font-medium text-primary-700 underline"
                              aria-label={`Remove ${emp.first_name} ${emp.last_name} from this run`}
                              onClick={() => {
                                setAdditionalEmployeeIds(previous => { const next = new Set(previous); next.delete(emp.id); return next; });
                                const withoutEmployee = <T,>(values: Record<string, T>) => Object.fromEntries(Object.entries(values).filter(([key]) => key !== String(emp.id)));
                                setHoursMap(withoutEmployee); setSalaryOverrideMap(withoutEmployee); setBonusMap(withoutEmployee);
                                setBonusEdits(withoutEmployee); setTipsMap(withoutEmployee); setTipsPaidOutMap(withoutEmployee);
                                setLoansMap(withoutEmployee); setNamedLoanDrafts(withoutEmployee);
                                setPayrollFieldDrafts(previous => Object.fromEntries(Object.entries(previous).filter(([key]) => !key.startsWith(`${emp.id}:`))));
                              }}>Remove from this run</button>
                          </>
                        ) : (
                          <button
                            onClick={() => {
                              setAdditionalEmployeeIds(prev => { const next = new Set(prev); next.add(emp.id); return next; });
                              setHoursMap(prev => ({
                                ...prev,
                                [String(emp.id)]: { regular: 0, overtime: 0, wage_rates: prev[String(emp.id)]?.wage_rates },
                              }));
                            }}
                            className="min-h-11 rounded-lg px-3 py-2 text-xs font-medium text-primary-700 underline-offset-2 hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-500"
                          >
                            Enter pay
                          </button>
                        )}
                      </li>
                    ))}
                  </ul>
                </div>
                {additionalEmployeeIds.size > 0 && (
                  <div><Button size="sm" className="min-h-11" variant="outline" loading={processing && processingAction === 'calculate'} loadingLabel={isDraft ? 'Calculating…' : 'Recalculating…'} onClick={() => void handleRunPayroll()} disabled={processing || financialActionsHeld}>
                    {isDraft ? 'Calculate' : 'Recalculate'} with {additionalEmployeeIds.size} added
                  </Button><BusyStatus className="mt-1" busy={processing && processingAction === 'calculate'}>Calculating payroll… This can take a few seconds.</BusyStatus></div>
                )}
              </div>
            </div>
          );
        })()}
  </>);
}
