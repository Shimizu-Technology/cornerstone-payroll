

import { NamedLoanInputs } from '@/components/payroll/NamedLoanInputs';

import { Fragment } from 'react';

import { Link } from 'react-router';

import { Card } from '@/components/ui/card';

import { NumericInput } from '@/components/ui/numeric-input';
import { Select } from '@/components/ui/select';

import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { formatCurrency } from '@/lib/utils';

import { capturedSourceContext, capturedSourceHoursLocked, worksheetPayBasisHold } from '@/lib/captured-source-worksheet';

import { employeePath } from '@/lib/routes';

import { payrollHoursInputLabel, TABLE_STICKY_TOP_CLASS, MAX_HOURS_PER_PERIOD, toNumber } from './payRunSupport';
import { PayrollFieldAppliedNotice } from './PayrollFieldAppliedNotice';
import type { PayRunSectionProps } from './usePayRunController';

export function PayRunHoursWorksheet({
  additionalEmployeeIds,
  bonusEdits,
  bonusMap,
  companyId,
  currentPath,
  departmentFilter,
  departmentOptions,
  displayEmployeesForHours,
  employeeTypeFilter,
  employees,
  employmentGroupKey,
  employmentGroupLabel,
  employmentGroupTone,
  estimateWorksheetGross,
  hoursMap,
  hoursSortBy,
  hoursSortDirection,
  hoursTableOpen,
  isCalculated,
  isDraft,
  loansMap,
  namedLoanDrafts,
  namedLoanOptions,
  payPeriod,
  payrollFieldAssignmentLookup,
  payrollFieldDrafts,
  payrollItemByEmployeeId,
  payrollItems,
  resetPayrollFieldDraft,
  retainedRetirementEntries,
  salaryOverrideMap,
  searchTerm,
  setBonusEdits,
  setBonusMap,
  setDepartmentFilter,
  setEmployeeTypeFilter,
  setHoursSortBy,
  setHoursSortDirection,
  setHoursTableOpen,
  setNamedLoanDrafts,
  setSearchTerm,
  setShowPayrollFields,
  setShowTipsLoans,
  showPayrollFields,
  showTipsLoans,
  tipsLoansVisibilityModeRef,
  tipsMap,
  tipsPaidOutMap,
  updateHours,
  updateLoan,
  updatePayrollFieldDraft,
  updateSalaryOverride,
  updateTip,
  updateTipsPaidOut,
  updateWageRateHours,
  worksheetPayrollFields
}: PayRunSectionProps<'hours'>) {
  return (<>
{(isDraft || isCalculated) && retainedRetirementEntries.length > 0 && <section className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm leading-6 text-warning-900" aria-label="Retained manual retirement entries">
          <p className="font-semibold">Saved retirement entries still apply to this paycheck</p>
          <p className="mt-1">Pausing or replacing a recurring assignment leaves saved manual amounts in place. Review these entries before adding another contribution; clear an obsolete request explicitly in the paycheck editor.</p>
          <ul className="mt-3 space-y-2">{retainedRetirementEntries.map((entry, index) => {
            const employee = employees.find((candidate) => candidate.id === entry.employee_id);
            const item = payrollItems.find((candidate) => candidate.employee_id === entry.employee_id);
            return <li key={`${entry.employee_id}:${entry.field_id}:${index}`} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-white/70 px-3 py-2"><span>{employee ? `${employee.first_name} ${employee.last_name}` : `Employee #${entry.employee_id}`} · {entry.label}: requested {formatCurrency(Number(entry.requested_amount))}, applied {formatCurrency(Number(entry.applied_amount))}</span>{item && <Link className="font-semibold underline underline-offset-2" to={`/companies/${payPeriod.company_id}/pay-runs/${payPeriod.id}/payroll-items/${item.id}`}>Review paycheck</Link>}</li>;
          })}</ul>
        </section>}
{(isDraft || isCalculated) && (
          <Card>
            <div
              role="button"
              tabIndex={0}
              className="w-full border-b p-4 text-left transition-colors hover:bg-neutral-50/50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-300 focus-visible:ring-inset"
              onClick={() => setHoursTableOpen(prev => !prev)}
              onKeyDown={(event) => {
                if (event.key === 'Enter' || event.key === ' ') {
                  event.preventDefault();
                  setHoursTableOpen(prev => !prev);
                }
              }}
            >
              <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
                <div className="flex items-center gap-2">
                  <svg
                    className={`w-4 h-4 text-neutral-600 transition-transform ${hoursTableOpen ? 'rotate-90' : ''}`}
                    fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}
                  >
                    <path strokeLinecap="round" strokeLinejoin="round" d="M9 5l7 7-7 7" />
                  </svg>
                  <div>
                    <h3 className="font-semibold text-neutral-900">
                      {isCalculated ? 'Adjust Hours' : 'Enter Hours'}
                    </h3>
                    {!hoursTableOpen && (
                      <p className="text-xs text-neutral-600 mt-0.5">Click to expand</p>
                    )}
                  </div>
                </div>
                {hoursTableOpen && (
                  <div className="grid w-full shrink-0 grid-cols-1 gap-3 sm:w-auto sm:grid-cols-none sm:flex sm:items-center" onClick={(e) => e.stopPropagation()}>
                    <Select
                      aria-label="Employee type"
                      value={employeeTypeFilter}
                      onChange={(event) => setEmployeeTypeFilter(event.target.value as typeof employeeTypeFilter)}
                      className="w-full sm:w-36"
                    >
                      <option value="all">All Types</option>
                      <option value="salary">Salary</option>
                      <option value="hourly">Hourly</option>
                      <option value="contractor">1099</option>
                    </Select>
                    <Select
                      aria-label="Department"
                      value={departmentFilter}
                      onChange={(event) => setDepartmentFilter(event.target.value)}
                      className="w-full sm:w-44"
                    >
                      <option value="all">All Departments</option>
                      {departmentOptions.map(([deptId, deptName]) => (
                        <option key={deptId} value={deptId}>{deptName}</option>
                      ))}
                    </Select>
                    <Select
                      aria-label="Sort"
                      value={`${hoursSortBy}:${hoursSortDirection}`}
                      onChange={(event) => {
                        const [sortBy, direction] = event.target.value.split(':') as [typeof hoursSortBy, typeof hoursSortDirection];
                        setHoursSortBy(sortBy);
                        setHoursSortDirection(direction);
                      }}
                      className="w-full sm:w-44"
                    >
                      <option value="name:asc">Name A-Z</option>
                      <option value="name:desc">Name Z-A</option>
                      <option value="rate:desc">Rate High-Low</option>
                      <option value="rate:asc">Rate Low-High</option>
                      <option value="hours:desc">Hours High-Low</option>
                      <option value="hours:asc">Hours Low-High</option>
                      <option value="gross:desc">Est. Gross High-Low</option>
                      <option value="gross:asc">Est. Gross Low-High</option>
                    </Select>
                    <button
                      type="button"
                      onClick={(event) => {
                        event.preventDefault();
                        event.stopPropagation();
                        tipsLoansVisibilityModeRef.current = 'manual';
                        setShowTipsLoans(prev => !prev);
                      }}
                      className={`max-sm:min-h-[44px] text-xs font-medium px-2.5 py-1 rounded-full border transition-colors ${
                        showTipsLoans
                          ? 'bg-blue-100 text-blue-700 border-blue-300'
                          : 'bg-neutral-100 text-neutral-600 border-neutral-200 hover:bg-neutral-200'
                      }`}
                    >
                      {showTipsLoans ? 'Tips & Deductions ✓' : '+ Tips & Deductions'}
                    </button>
                    {worksheetPayrollFields.length > 0 && (
                      <button
                        type="button"
                        onClick={(event) => {
                          event.preventDefault();
                          event.stopPropagation();
                          setShowPayrollFields((previous) => !previous);
                        }}
                        className={`max-sm:min-h-[44px] rounded-full border px-2.5 py-1 text-xs font-medium transition-colors ${
                          showPayrollFields
                            ? 'border-emerald-300 bg-emerald-100 text-emerald-800'
                            : 'border-neutral-200 bg-neutral-100 text-neutral-600 hover:bg-neutral-200'
                        }`}
                      >
                        {showPayrollFields ? `Payroll Fields (${worksheetPayrollFields.length}) ✓` : `+ Payroll Fields (${worksheetPayrollFields.length})`}
                      </button>
                    )}
                        <div className="relative">
                          <input
                            type="text"
                            aria-label="Search employees"
                            placeholder="Search employees..."
                            value={searchTerm}
                            onChange={(e) => setSearchTerm(e.target.value)}
                        className="w-full rounded-lg border border-neutral-300 py-2 pl-8 pr-3 text-sm focus:border-blue-500 focus:ring-2 focus:ring-blue-500 sm:w-48"
                      />
                      <svg className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-neutral-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
                      </svg>
                    </div>
                  </div>
                )}
              </div>
            </div>
            {hoursTableOpen && (
            <div className="space-y-3 px-3 py-3 sm:hidden" aria-label="Employee payroll entry">
              {displayEmployeesForHours.map((emp) => {
                const hours = hoursMap[String(emp.id)] || { regular: 0, overtime: 0 };
                const isHourlyContractor = emp.employment_type === 'contractor' && emp.contractor_pay_type === 'hourly';
                const isFlatContractor = emp.employment_type === 'contractor' && emp.contractor_pay_type !== 'hourly';
                const activeRates = (hours.wage_rates || []).map((rate, index) => ({ rate, index })).filter(({ rate }) => rate.active !== false);
                const hasMultiRate = (emp.employment_type === 'hourly' || isHourlyContractor) && activeRates.length > 1;
                const isVariableSalary = emp.employment_type === 'salary' && emp.salary_type === 'variable';
                const hasHours = emp.employment_type !== 'salary' && !isFlatContractor;
                const name = `${emp.first_name} ${emp.last_name}`;
                const savedItem = payrollItemByEmployeeId.get(emp.id);
                const sourceHoursLocked = capturedSourceHoursLocked(savedItem);
                const correctionHold = worksheetPayBasisHold(savedItem, emp);
                const payRate = toNumber(savedItem && (isCalculated || sourceHoursLocked || savedItem.timekeeping_source === 'correction_reference') ? savedItem.pay_rate : emp.pay_rate);
                const periodsPerYear = ({ weekly: 52, biweekly: 26, semimonthly: 24, monthly: 12 } as Record<string, number>)[emp.pay_frequency] || 26;
                const rateLabel = correctionHold ? 'Retained pay basis · review required' : sourceHoursLocked && activeRates.length ? 'Retained Source rates' : isVariableSalary ? 'Variable pay' : emp.employment_type === 'salary' && emp.salary_type !== 'per_period'
                  ? `${formatCurrency(payRate / periodsPerYear)}/period`
                  : `${formatCurrency(payRate)}${hasHours ? '/hr' : '/period'}`;
                return <section key={emp.id} className="space-y-4 rounded-2xl border border-neutral-200 bg-white p-4" aria-label={`Payroll entry for ${name}`}>
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0"><Link className="font-semibold text-primary-800" to={employeePath(companyId, emp.id, 'overview', { returnTo: currentPath })}>{name}</Link><p className="mt-1 text-xs capitalize text-neutral-600">{isHourlyContractor ? '1099 hourly' : isFlatContractor ? '1099 flat fee' : emp.employment_type}{emp.department?.name ? ` · ${emp.department.name}` : ''}</p></div>
                    <span className="shrink-0 text-sm font-semibold tabular-nums text-neutral-700">{rateLabel}</span>
                  </div>
                  <p className="text-sm font-semibold tabular-nums text-neutral-950">{isCalculated || correctionHold ? 'Saved gross' : 'Estimated gross'}: {estimateWorksheetGross(emp) == null ? 'Unavailable — review pay setup' : formatCurrency(estimateWorksheetGross(emp)!)}</p>
                  {correctionHold && <div role="note" className="rounded-xl border border-warning-200 bg-warning-50 p-3 text-sm text-warning-950"><p className="font-semibold">Retained saved gross {formatCurrency(toNumber(savedItem?.gross_pay))}</p><p className="mt-1">{correctionHold.reason}</p></div>}
                  {!hasMultiRate && activeRates.map(({ rate, index }) => capturedSourceContext(rate) && <p key={rate.source_bucket_key || index} className="text-xs text-neutral-600">{capturedSourceContext(rate)}</p>)}
                  {sourceHoursLocked && <p className="text-xs text-neutral-600">Imported work is read-only. Use Source review and the correction workflow to change work.</p>}
                  {additionalEmployeeIds.has(emp.id) && <p className="text-xs font-medium text-blue-700">New to this payroll</p>}
                  {isFlatContractor && payPeriod.run_purpose === 'off_cycle_tips' && <p className="text-xs font-medium text-primary-700">Flat fee excluded from this tips-only run</p>}
                  {correctionHold ? <p className="text-xs text-warning-800">Review retained source evidence and pay setup before entering new pay.</p> : isVariableSalary ? <label className="block text-xs font-medium text-neutral-600">Pay this period
                    <NumericInput className="mt-1 min-h-11 w-full" value={salaryOverrideMap[String(emp.id)] || null} onValueChange={(value) => updateSalaryOverride(emp.id, value ?? 0)} min={0} fixedDecimalsOnBlur={2} aria-label={`Pay this period for ${name}`} />
                  </label> : hasMultiRate ? <div className="space-y-3">{activeRates.map(({ rate, index }) => <div key={`${rate.label}-${index}`} className="rounded-xl border border-neutral-200 bg-neutral-50 p-3"><p className="text-sm font-semibold text-neutral-800">{rate.label} · {formatCurrency(toNumber(rate.rate))}/hr</p>{capturedSourceContext(rate) && <p className="mt-1 text-xs text-neutral-600">{capturedSourceContext(rate)}</p>}<div className="mt-3 grid grid-cols-2 gap-3"><label className="text-xs font-medium text-neutral-600">Regular hours<NumericInput className="mt-1 min-h-11 w-full" aria-label={payrollHoursInputLabel(emp, 'Regular', rate)} disabled={sourceHoursLocked || Boolean(correctionHold)} value={toNumber(rate.regular_hours)} onValueChange={(value) => updateWageRateHours(emp.id, index, 'regular_hours', value ?? 0)} min={0} max={MAX_HOURS_PER_PERIOD} /></label><label className="text-xs font-medium text-neutral-600">Overtime hours<NumericInput className="mt-1 min-h-11 w-full" aria-label={payrollHoursInputLabel(emp, 'Overtime', rate)} disabled={sourceHoursLocked || Boolean(correctionHold)} value={toNumber(rate.overtime_hours)} onValueChange={(value) => updateWageRateHours(emp.id, index, 'overtime_hours', value ?? 0)} min={0} max={MAX_HOURS_PER_PERIOD} /></label></div></div>)}</div> : hasHours ? <div className="grid grid-cols-2 gap-3"><label className="text-xs font-medium text-neutral-600">Regular hours<NumericInput className="mt-1 min-h-11 w-full" aria-label={payrollHoursInputLabel(emp, 'Regular')} disabled={sourceHoursLocked || Boolean(correctionHold)} value={hours.regular} onValueChange={(value) => updateHours(emp.id, 'regular', value ?? 0)} min={0} max={MAX_HOURS_PER_PERIOD} /></label><label className="text-xs font-medium text-neutral-600">Overtime hours<NumericInput className="mt-1 min-h-11 w-full" aria-label={payrollHoursInputLabel(emp, 'Overtime')} disabled={sourceHoursLocked || Boolean(correctionHold)} value={hours.overtime} onValueChange={(value) => updateHours(emp.id, 'overtime', value ?? 0)} min={0} max={MAX_HOURS_PER_PERIOD} /></label></div> : <p className="text-xs text-neutral-600">Base pay is calculated from this employee’s pay setup.</p>}
                  <label className="block text-xs font-medium text-neutral-600">Bonus this payroll
                    <NumericInput className="mt-1 min-h-11 w-full" aria-label={`Bonus this payroll for ${name}`} value={bonusMap[String(emp.id)] ?? 0} onValueChange={(value) => { const amount = value ?? 0; if (amount === (bonusMap[String(emp.id)] ?? 0)) return; setBonusMap((previous) => ({ ...previous, [String(emp.id)]: amount })); setBonusEdits((previous) => ({ ...previous, [String(emp.id)]: amount })); }} min={0} max={99999999.99} fixedDecimalsOnBlur={2} />
                  </label>
                  {payrollItemByEmployeeId.get(emp.id)?.imported_bonus != null && <p className="text-xs text-neutral-600">Workbook bonus: {formatCurrency(toNumber(payrollItemByEmployeeId.get(emp.id)?.imported_bonus))}{bonusEdits[String(emp.id)] != null && ' · Manual amount retained'}</p>}
                  {(emp.default_payroll_adjustments || []).some((adjustment) => adjustment.active !== false && adjustment.treatment === 'taxable_addition' && /bonus/i.test(adjustment.label)) && <p className="text-xs text-warning-700">A recurring bonus is also configured. Review it before adding another bonus.</p>}
                  <NamedLoanInputs options={namedLoanOptions.filter(option => option.employee_id === emp.id)} drafts={namedLoanDrafts[String(emp.id)] || {}} includesRecurring={payPeriod.includes_recurring_items} onChange={(loanId, draft) => setNamedLoanDrafts(previous => ({ ...previous, [String(emp.id)]: { ...previous[String(emp.id)], [String(loanId)]: draft } }))} />
                  {showTipsLoans && <div className="grid grid-cols-2 gap-3 border-t border-neutral-100 pt-3"><label className="text-xs font-medium text-neutral-600">Reported tips<NumericInput className="mt-1 min-h-11 w-full" value={tipsMap[String(emp.id)]?.amount ?? null} onValueChange={(value) => updateTip(emp.id, value ?? 0)} min={0} fixedDecimalsOnBlur={2} /></label><label className="text-xs font-medium text-neutral-600">Tip pool<select className="mt-1 min-h-11 w-full rounded-xl border border-neutral-300 bg-white px-3" value={tipsMap[String(emp.id)]?.pool || ''} onChange={(event) => updateTip(emp.id, tipsMap[String(emp.id)]?.amount || 0, event.target.value)}><option value="">—</option><option value="foh">FOH</option><option value="boh">BOH</option><option value="mixed">Mixed</option></select></label><label className="text-xs font-medium text-neutral-600">Tips paid out<NumericInput className="mt-1 min-h-11 w-full" value={tipsPaidOutMap[String(emp.id)] ?? null} onValueChange={(value) => updateTipsPaidOut(emp.id, value ?? 0)} min={0} fixedDecimalsOnBlur={2} /></label><label className="text-xs font-medium text-neutral-600">Standalone one-time deduction<NumericInput className="mt-1 min-h-11 w-full" value={loansMap[String(emp.id)] ?? null} onValueChange={(value) => updateLoan(emp.id, value ?? 0)} min={0} fixedDecimalsOnBlur={2} /></label></div>}
                  {showPayrollFields && worksheetPayrollFields.length > 0 && <div className="space-y-3 border-t border-neutral-100 pt-3"><p className="text-xs font-semibold text-neutral-600">Payroll fields</p>{worksheetPayrollFields.map((field) => { const key = `${emp.id}:${field.id}`; const assignment = payrollFieldAssignmentLookup.get(key); if (!assignment) return null; const draft = payrollFieldDrafts[key]; return <div key={key}><label className="block text-xs font-medium text-neutral-600">{field.name}<NumericInput className="mt-1 min-h-11 w-full" value={draft?.mode !== 'override' && payPeriod.includes_recurring_items === false ? null : draft?.amount ?? null} onValueChange={(value) => updatePayrollFieldDraft(emp.id, field.id, value)} emptyValue={null} notifyEmptyOnChange placeholder={field.amount_type === 'percentage' ? 'Auto' : '0.00'} min={0} fixedDecimalsOnBlur={2} disabled={!assignment.editable} aria-invalid={draft?.mode === 'override' && draft.amount == null} /></label><PayrollFieldAppliedNotice assignment={assignment} />{assignment.editable && draft?.mode === 'override' && <button type="button" className="mt-1 text-xs font-medium text-primary-700 underline" onClick={() => resetPayrollFieldDraft(emp.id, field.id)}>{payPeriod.includes_recurring_items === false ? 'Clear this payroll amount' : 'Use employee default'}</button>}{assignment.editable && draft?.mode !== 'override' && payPeriod.includes_recurring_items === false && <p className="mt-1 text-xs text-neutral-600">Recurring setup excluded</p>}{!assignment.editable && <p className="mt-1 text-xs text-warning-700">{assignment.skipped_reason}</p>}</div>; })}</div>}
                </section>;
              })}
              {displayEmployeesForHours.length === 0 && <p className="py-8 text-center text-sm text-neutral-600">No employees match these filters.</p>}
            </div>
            )}
            {hoursTableOpen && (
            <div className="hidden overflow-x-auto sm:block">
              <Table
                stickyHeader
                containerClassName="max-h-[32rem]"
                style={{ minWidth: 1560 + (showTipsLoans ? 420 : 0) + (showPayrollFields ? worksheetPayrollFields.length * 180 : 0) }}
              >
                <TableHeader>
                  <TableRow>
                    <TableHead stickyLeft className={`w-[260px] min-w-[260px] bg-neutral-50 ${TABLE_STICKY_TOP_CLASS}`}>Employee</TableHead>
                    <TableHead className={`w-[300px] bg-neutral-50 ${TABLE_STICKY_TOP_CLASS}`}>Rate</TableHead>
                    <TableHead className={`w-[300px] bg-neutral-50 text-center ${TABLE_STICKY_TOP_CLASS}`}>Regular Hours</TableHead>
                    <TableHead className={`w-[300px] bg-neutral-50 text-center ${TABLE_STICKY_TOP_CLASS}`}>Overtime Hours</TableHead>
                    <TableHead className={`w-[180px] min-w-[180px] bg-neutral-50 text-center ${TABLE_STICKY_TOP_CLASS}`}>Bonus this payroll</TableHead>
                    {showTipsLoans && <TableHead className={`w-[190px] min-w-[190px] bg-neutral-50 text-center ${TABLE_STICKY_TOP_CLASS}`}>Reported Tips</TableHead>}
                    {showTipsLoans && <TableHead className={`w-[150px] min-w-[150px] bg-neutral-50 text-center ${TABLE_STICKY_TOP_CLASS}`}>Tips Paid Out</TableHead>}
                    {showTipsLoans && <TableHead className={`w-[150px] min-w-[150px] bg-neutral-50 text-center ${TABLE_STICKY_TOP_CLASS}`}>Standalone deduction</TableHead>}
                    {showPayrollFields && worksheetPayrollFields.map((field) => (
                      <TableHead
                        key={`worksheet-field-${field.id}`}
                        className={`w-[180px] min-w-[180px] text-center ${TABLE_STICKY_TOP_CLASS} ${
                          field.kind === 'addition'
                            ? 'bg-emerald-50 text-emerald-900'
                            : field.kind === 'deduction'
                              ? 'bg-warning-50 text-warning-900'
                              : 'bg-indigo-50 text-indigo-900'
                        }`}
                      >
                        <span className="block text-xs font-semibold leading-tight">{field.name}</span>
                        <span className="mt-1 block text-xs font-normal text-neutral-700">
                          {field.amount_type === 'percentage' ? 'Automatic %' : field.amount_type}
                        </span>
                      </TableHead>
                    ))}
                    <TableHead className={`w-[160px] bg-neutral-50 text-right ${TABLE_STICKY_TOP_CLASS}`}>Pay preview</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(() => {
                    const draftDividerCols = 6 + (showTipsLoans ? 3 : 0) + (showPayrollFields ? worksheetPayrollFields.length : 0);
                    let prevGroup: string | null = null;
                    return displayEmployeesForHours.map((emp, rowIndex) => {
                      const currentGroup = employmentGroupKey(emp.employment_type);
                      const showDivider = currentGroup !== prevGroup;
                      prevGroup = currentGroup;
                      const hours = hoursMap[String(emp.id)] || { regular: 0, overtime: 0 };
                      const savedItem = payrollItemByEmployeeId.get(emp.id);
                      const sourceHoursLocked = capturedSourceHoursLocked(savedItem);
                      const correctionHold = worksheetPayBasisHold(savedItem, emp);
                      const payRate = toNumber(savedItem && (isCalculated || sourceHoursLocked || savedItem.timekeeping_source === 'correction_reference') ? savedItem.pay_rate : emp.pay_rate);
                      const isContractorHourly = emp.employment_type === 'contractor' && emp.contractor_pay_type === 'hourly';
                      const isContractorFlat = emp.employment_type === 'contractor' && emp.contractor_pay_type !== 'hourly';
                      const activeWageRates = (hours.wage_rates || []).map((rate, index) => ({ rate, index })).filter(({ rate }) => rate.active !== false);
                      const hasMultiRate = (emp.employment_type === 'hourly' || isContractorHourly) && activeWageRates.length > 1;
                      const isVariableSalary = emp.employment_type === 'salary' && emp.salary_type === 'variable';
                      const isPerPeriodSalary = emp.employment_type === 'salary' && emp.salary_type === 'per_period';
                      const noHoursType = emp.employment_type === 'salary' || isContractorFlat;
                      const salaryOverride = salaryOverrideMap[String(emp.id)] || 0;
                      const rowTone = rowIndex % 2 === 0 ? 'bg-white' : 'bg-neutral-100';
                      const periodsPerYear = ({ weekly: 52, biweekly: 26, semimonthly: 24, monthly: 12 } as Record<string, number>)[emp.pay_frequency] || 26;
                      const calculatedItem = savedItem;
                      const estGross = estimateWorksheetGross(emp);
                      return (
                      <Fragment key={emp.id}>
                      {showDivider && (() => {
                        const tone = employmentGroupTone(emp.employment_type);
                        return (
                          <TableRow className={tone.row}>
                            <TableCell stickyLeft colSpan={draftDividerCols} className={`py-1.5 text-xs font-semibold ${tone.text} ${tone.row}`}>
                              {employmentGroupLabel(currentGroup, employeeTypeFilter)}
                            </TableCell>
                          </TableRow>
                        );
                      })()}
                      <TableRow className={rowTone}>
                          <TableCell stickyLeft className={`min-w-[260px] ${rowTone}`}>
                          <div>
                            <div className="flex items-center gap-1.5">
                              <Link className="font-medium text-neutral-900 hover:text-primary-700 hover:underline" to={employeePath(companyId, emp.id, 'overview', { returnTo: currentPath })}>{emp.first_name} {emp.last_name}</Link>
                              {additionalEmployeeIds.has(emp.id) && (
                                <span className="text-xs font-medium text-blue-700 bg-blue-100 rounded-full px-1.5 py-0.5">New</span>
                              )}
                            </div>
                            {correctionHold && <p className="mt-2 text-xs text-warning-800">{correctionHold.reason}</p>}
                            {sourceHoursLocked && <p className="mt-2 text-xs text-neutral-600">Imported work retained. Use source review and corrections to change hours.</p>}
                            <p className="text-xs text-neutral-600 capitalize">
                              {isContractorHourly ? '1099 (Hourly)' : isContractorFlat ? '1099 (Flat Fee)' : emp.employment_type}
                              {emp.department?.name ? ` · ${emp.department.name}` : ''}
                            </p>
                          </div>
                        </TableCell>
                        <TableCell className={`text-neutral-700 ${rowTone}`}>
                          {correctionHold ? (
                            <span className="text-xs font-medium text-warning-800">Retained pay basis · review required</span>
                          ) : sourceHoursLocked && activeWageRates.length ? (
                            <div className="space-y-1 text-left">{activeWageRates.map(({ rate, index }) => <div key={rate.source_bucket_key || index} className="text-xs"><span className="font-medium">{rate.label} · {formatCurrency(toNumber(rate.rate))}/hr</span>{capturedSourceContext(rate) && <p className="mt-1 text-neutral-600">{capturedSourceContext(rate)}</p>}</div>)}</div>
                          ) : isVariableSalary ? (
                            <span className="text-indigo-600 font-medium">Variable</span>
                          ) : isPerPeriodSalary ? (
                            `${formatCurrency(payRate)}/period`
                          ) : emp.employment_type === 'salary' ? (
                            `${formatCurrency(payRate / periodsPerYear)}/period`
                          ) : isContractorFlat ? (
                            payPeriod.run_purpose === 'off_cycle_tips'
                              ? <span className="font-medium text-primary-700">Excluded from tips-only run</span>
                              : `${formatCurrency(payRate)}/period`
                          ) : hasMultiRate ? (
                            <div className="space-y-1 text-left">
                              {activeWageRates.map(({ rate }) => (
                                <div key={`${emp.id}-${rate.source_bucket_key || rate.label}`} className="text-xs">
                                  <span className="font-medium text-neutral-900">{rate.label}</span>{' '}
                                  <span className="text-neutral-600">{formatCurrency(toNumber(rate.rate))}/hr</span>
                                  {capturedSourceContext(rate) && <p className="mt-1 text-neutral-600">{capturedSourceContext(rate)}</p>}
                                </div>
                              ))}
                            </div>
                          ) : (
                            `${formatCurrency(payRate)}/hr`
                          )}
                          {!hasMultiRate && activeWageRates.map(({ rate, index }) => capturedSourceContext(rate) && <p key={rate.source_bucket_key || index} className="mt-1 text-xs text-neutral-600">{capturedSourceContext(rate)}</p>)}
                        </TableCell>
                        <TableCell className={`text-center align-top ${rowTone}`} colSpan={isVariableSalary ? 2 : 1}>
                          {isVariableSalary ? (
                            <div className="flex items-center justify-center gap-2">
                              <span className="text-xs text-neutral-600">Pay this period: $</span>
                              <NumericInput
                                value={salaryOverride || null}
                                disabled={Boolean(correctionHold)}
                                aria-label={`Pay this period for ${emp.first_name} ${emp.last_name}`}
                                onValueChange={(value) => updateSalaryOverride(emp.id, value ?? 0)}
                                placeholder="0.00"
                                className="w-28 text-center border border-indigo-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 bg-indigo-50/50"
                                min={0}
                                fixedDecimalsOnBlur={2}
                              />
                            </div>
                          ) : hasMultiRate ? (
                            <div className="space-y-2">
                              {activeWageRates.map(({ rate, index }) => (
                                <div key={`${emp.id}-${rate.source_bucket_key || rate.label}-regular`} className="grid grid-cols-[12rem_5rem] items-center gap-3">
                                  <span
                                    className="text-left text-xs leading-tight text-neutral-600"
                                    title={capturedSourceContext(rate) || rate.label}
                                  >
                                    {rate.label}
                                    {capturedSourceContext(rate) && <span className="mt-1 block text-neutral-600">{capturedSourceContext(rate)}</span>}
                                  </span>
                                  <NumericInput
                                    disabled={sourceHoursLocked || Boolean(correctionHold)}
                                    aria-label={payrollHoursInputLabel(emp, 'Regular', rate)}
                                    value={toNumber(rate.regular_hours)}
                                    onValueChange={(value) => updateWageRateHours(emp.id, index, 'regular_hours', value ?? 0)}
                                    className="w-20 text-center border border-neutral-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                                    min={0}
                                    max={MAX_HOURS_PER_PERIOD}
                                  />
                                </div>
                              ))}
                            </div>
                          ) : (
                            <NumericInput
                              aria-label={payrollHoursInputLabel(emp, 'Regular')}
                              value={hours.regular}
                              onValueChange={(value) => updateHours(emp.id, 'regular', value ?? 0)}
                              className="w-20 text-center border border-neutral-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 disabled:bg-neutral-100 disabled:text-neutral-600"
                              min={0}
                              max={MAX_HOURS_PER_PERIOD}
                              disabled={noHoursType || sourceHoursLocked || Boolean(correctionHold)}
                            />
                          )}
                        </TableCell>
                        {!isVariableSalary && (
                        <TableCell className={`text-center align-top ${rowTone}`}>
                          {hasMultiRate ? (
                            <div className="space-y-2">
                              {activeWageRates.map(({ rate, index }) => (
                                <div key={`${emp.id}-${rate.source_bucket_key || rate.label}-overtime`} className="grid grid-cols-[12rem_5rem] items-center gap-3">
                                  <span
                                    className="text-left text-xs leading-tight text-neutral-600"
                                    title={capturedSourceContext(rate) || rate.label}
                                  >
                                    {rate.label}
                                    {capturedSourceContext(rate) && <span className="mt-1 block text-neutral-600">{capturedSourceContext(rate)}</span>}
                                  </span>
                                  <NumericInput
                                    disabled={sourceHoursLocked || Boolean(correctionHold)}
                                    aria-label={payrollHoursInputLabel(emp, 'Overtime', rate)}
                                    value={toNumber(rate.overtime_hours)}
                                    onValueChange={(value) => updateWageRateHours(emp.id, index, 'overtime_hours', value ?? 0)}
                                    className="w-20 text-center border border-neutral-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                                    min={0}
                                    max={MAX_HOURS_PER_PERIOD}
                                  />
                                </div>
                              ))}
                            </div>
                          ) : (
                            <NumericInput
                              aria-label={payrollHoursInputLabel(emp, 'Overtime')}
                              value={hours.overtime}
                              onValueChange={(value) => updateHours(emp.id, 'overtime', value ?? 0)}
                              className="w-20 text-center border border-neutral-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 disabled:bg-neutral-100 disabled:text-neutral-600"
                              min={0}
                              max={MAX_HOURS_PER_PERIOD}
                              disabled={noHoursType || sourceHoursLocked || Boolean(correctionHold)}
                            />
                          )}
                        </TableCell>
                        )}
                        <TableCell className={`min-w-[180px] text-center align-top ${rowTone}`}>
                          <NumericInput
                            aria-label={`Bonus this payroll for ${emp.first_name} ${emp.last_name}`}
                            value={bonusMap[String(emp.id)] ?? 0}
                            onValueChange={(value) => {
                              const amount = value ?? 0;
                              if (amount === (bonusMap[String(emp.id)] ?? 0)) return;
                              setBonusMap((previous) => ({ ...previous, [String(emp.id)]: amount }));
                              setBonusEdits((previous) => ({ ...previous, [String(emp.id)]: amount }));
                            }}
                            min={0}
                            max={99999999.99}
                            fixedDecimalsOnBlur={2}
                            className="mx-auto w-28 text-center"
                          />
                          <p className="mt-1 text-xs text-neutral-600">Applies to this payroll only</p>
                          {calculatedItem?.imported_bonus != null && (
                            <p className="mt-1 text-xs text-neutral-600">
                              Workbook: {formatCurrency(toNumber(calculatedItem.imported_bonus))}
                              {(calculatedItem.bonus_source === 'manual' || bonusEdits[String(emp.id)] != null) && ' · Manual amount retained'}
                            </p>
                          )}
                          {(emp.default_payroll_adjustments || []).some((adjustment) => adjustment.active !== false && adjustment.treatment === 'taxable_addition' && /bonus/i.test(adjustment.label)) && (
                            <p className="mt-1 max-w-[180px] text-xs text-warning-700">A recurring bonus is also configured. Review it before adding another bonus.</p>
                          )}
                        </TableCell>
                        {showTipsLoans && (
                        <TableCell className={`min-w-[190px] text-center align-top ${rowTone}`}>
                          <div className="flex min-w-[160px] items-center justify-center gap-2">
                            <span className="text-xs text-neutral-600">$</span>
                            <NumericInput
                              value={tipsMap[String(emp.id)]?.amount ?? null}
                              onValueChange={(value) => updateTip(emp.id, value ?? 0)}
                              placeholder="0"
                              className="w-24 text-center border border-neutral-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                              min={0}
                              fixedDecimalsOnBlur={2}
                            />
                            <select
                              aria-label={`Tip pool for ${emp.first_name} ${emp.last_name}`}
                              value={tipsMap[String(emp.id)]?.pool || ''}
                              onChange={(e) => updateTip(emp.id, tipsMap[String(emp.id)]?.amount || 0, e.target.value)}
                              className="w-20 border border-neutral-300 rounded-md px-2 py-1.5 text-xs focus:ring-2 focus:ring-blue-500 focus:border-blue-500 bg-white"
                            >
                              <option value="">—</option>
                              <option value="foh">FOH</option>
                              <option value="boh">BOH</option>
                              <option value="mixed">Mixed</option>
                            </select>
                          </div>
                        </TableCell>
                        )}
                        {showTipsLoans && (
                        <TableCell className={`min-w-[150px] text-center align-top ${rowTone}`}>
                          <div className="flex min-w-[120px] items-center justify-center gap-2">
                            <span className="text-xs text-neutral-600">$</span>
                            <NumericInput
                              value={tipsPaidOutMap[String(emp.id)] ?? null}
                              onValueChange={(value) => updateTipsPaidOut(emp.id, value ?? 0)}
                              placeholder="0"
                              className="w-24 text-center border border-neutral-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                              min={0}
                              fixedDecimalsOnBlur={2}
                            />
                          </div>
                        </TableCell>
                        )}
                        {showTipsLoans && (
                        <TableCell className={`min-w-[150px] text-center align-top ${rowTone}`}>
                          <div className="flex min-w-[120px] items-center justify-center gap-2">
                            <span className="text-xs text-neutral-600">$</span>
                            <NumericInput
                              aria-label={`Loan deduction this payroll for ${emp.first_name} ${emp.last_name}`}
                              value={loansMap[String(emp.id)] ?? null}
                              onValueChange={(value) => updateLoan(emp.id, value ?? 0)}
                              placeholder="0"
                              className="w-24 text-center border border-neutral-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                              min={0}
                              fixedDecimalsOnBlur={2}
                            />
                          </div>
                          <p className="mt-1 max-w-[160px] text-xs text-neutral-600">Standalone deduction. Does not credit a saved loan.</p>
                        </TableCell>
                        )}
                        {showPayrollFields && worksheetPayrollFields.map((field) => {
                          const key = `${emp.id}:${field.id}`;
                          const assignment = payrollFieldAssignmentLookup.get(key);
                          const draft = payrollFieldDrafts[key];
                          if (!assignment) {
                            return (
                              <TableCell key={key} className={`min-w-[180px] text-center text-neutral-600 ${rowTone}`}>
                                —
                              </TableCell>
                            );
                          }

                          const editable = assignment.editable;
                          const skippedReason = assignment.skipped_reason;
                          const percentage = assignment.assigned_percentage ?? assignment.default_percentage ?? 0;
                          const defaultLabel = field.amount_type === 'percentage'
                            ? `${percentage}% automatic`
                            : field.amount_type === 'manual'
                              ? 'enter for this payroll'
                              : `${formatCurrency(assignment.assigned_amount ?? assignment.default_amount ?? 0)} default`;

                          return (
                            <TableCell key={key} className={`min-w-[180px] align-top ${rowTone}`}>
                              <div className="flex flex-col items-center gap-1">
                                <PayrollFieldAppliedNotice assignment={assignment} />
                                <div className="flex items-center justify-center gap-1.5">
                                  <span className="text-xs text-neutral-600">$</span>
                                  <NumericInput
                                    value={draft?.mode !== 'override' && payPeriod.includes_recurring_items === false ? null : draft?.amount ?? null}
                                    onValueChange={(value) => updatePayrollFieldDraft(emp.id, field.id, value)}
                                    emptyValue={null}
                                    notifyEmptyOnChange
                                    placeholder={field.amount_type === 'percentage' ? 'Auto' : '0.00'}
                                    className={`w-24 rounded-md border px-2 py-1.5 text-center text-sm focus:ring-2 disabled:cursor-not-allowed disabled:bg-neutral-100 ${
                                      field.kind === 'addition'
                                        ? 'border-emerald-300 focus:border-emerald-500 focus:ring-emerald-500'
                                        : field.kind === 'deduction'
                                          ? 'border-warning-300 focus:border-warning-500 focus:ring-warning-500'
                                          : 'border-indigo-300 focus:border-indigo-500 focus:ring-indigo-500'
                                    }`}
                                    min={0}
                                    fixedDecimalsOnBlur={2}
                                    disabled={!editable}
                                    aria-label={`${field.name} requested amount for ${emp.first_name} ${emp.last_name}`}
                                    aria-invalid={draft?.mode === 'override' && draft.amount == null}
                                  />
                                </div>
                                {editable ? (
                                  draft?.mode === 'override' && draft.amount == null ? (
                                    <button
                                      type="button"
                                      onClick={() => resetPayrollFieldDraft(emp.id, field.id)}
                                      className="text-center text-xs font-semibold leading-tight text-danger-600 transition-colors hover:text-danger-700 hover:underline"
                                    >
                                      {payPeriod.includes_recurring_items === false ? 'Enter an amount or clear this payroll amount' : 'Enter an amount or use the employee default'}
                                    </button>
                                  ) : draft?.mode === 'override' ? (
                                    <button
                                      type="button"
                                      onClick={() => resetPayrollFieldDraft(emp.id, field.id)}
                                      className="text-xs font-medium text-blue-700 hover:text-blue-900 hover:underline"
                                    >
                                      {payPeriod.includes_recurring_items === false ? 'Override · clear this payroll amount' : `Override · use ${defaultLabel}`}
                                    </button>
                                  ) : (
                                    <span className="text-xs text-neutral-600">
                                      {field.amount_type === 'manual' ? 'Enter for this payroll' : payPeriod.includes_recurring_items === false ? 'Recurring setup excluded' : `Using ${defaultLabel}`}
                                    </span>
                                  )
                                ) : (
                                  <span className="max-w-[160px] text-center text-xs leading-tight text-warning-700" title={skippedReason || undefined}>
                                    {skippedReason}
                                  </span>
                                )}
                              </div>
                            </TableCell>
                          );
                        })}
                        <TableCell className={`text-right font-medium text-neutral-700 ${rowTone}`}>
                          {estGross == null ? 'Estimate unavailable' : formatCurrency(estGross)}
                          <p className="mt-1 text-xs font-normal text-neutral-600">
                            {correctionHold ? 'Retained saved gross · pay setup review required' : isCalculated ? 'Last calculated gross · recalculate after edits' : 'Estimate · confirmed when payroll is calculated'}
                          </p>
                        </TableCell>
                      </TableRow>
                      </Fragment>
                      );
                    });
                  })()}
                </TableBody>
              </Table>
            </div>
            )}
          </Card>
        )}
  </>);
}
