

import { Fragment, type ReactNode } from 'react';

import { Link } from 'react-router';
import { ArrowRight } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { PayRunResultsView } from './PayRunResultsView';

import { Select } from '@/components/ui/select';

import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { formatCurrency } from '@/lib/utils';
import { payrollTaxSummary } from '@/lib/payroll-tax-summary';
import { capturedSourceContext } from '@/lib/captured-source-worksheet';

import { employeePath } from '@/lib/routes';

import { TABLE_STICKY_TOP_CLASS, adjustmentTreatmentLabels, toNumber, effectiveLoanDeduction } from './payRunSupport';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunEmployeeResults({
  action,
  companyId,
  currentPath,
  departmentFilter,
  departmentOptions,
  employeeLookup,
  employeeTypeFilter,
  employmentGroupKey,
  employmentGroupLabel,
  employmentGroupTone,
  isCalculated,
  isCommitted,
  isDraft,
  payPeriod,
  payrollItemDisplayedHours,
  payrollItemNameParts,
  payrollItems,
  registerPayrollFieldTotals,
  registerTotals,
  resultsSortBy,
  resultsSortDirection,
  searchTerm,
  setCorrectingItem,
  setDepartmentFilter,
  setEditingItem,
  setEmployeeTypeFilter,
  setReplacingItem,
  setResultsSortBy,
  setResultsSortDirection,
  setReviewingItem,
  setSearchTerm,
  sortPayrollItems,
  visiblePayrollFields
}: PayRunSectionProps<'results'> & { action?: ReactNode }) {
  return (<>
{!isDraft && payrollItems.length > 0 && (() => {
          const hasTips = payrollItems.some(i => toNumber(i.reported_tips) > 0);
          const hasTipsPaidOut = payrollItems.some(i => toNumber(i.tips_paid_out) > 0);
          const hasLoans = payrollItems.some(i => effectiveLoanDeduction(i) > 0);
          const hasCustomEarnings = payrollItems.some(i => (i.custom_earnings || []).some((earning) => toNumber(earning.amount) > 0));
          const hasCustomDeductions = payrollItems.some(i => (i.custom_deductions || []).some((deduction) => toNumber(deduction.amount) > 0));
          const hasPayrollAdjustments = payrollItems.some(i => (i.payroll_adjustments || []).some((adjustment) => adjustment.active !== false && toNumber(adjustment.amount) > 0));
          const extraColCount = (hasCustomEarnings ? 1 : 0) + (hasCustomDeductions ? 1 : 0) + (hasPayrollAdjustments ? 1 : 0) + visiblePayrollFields.length + (hasTips ? 1 : 0) + (hasTipsPaidOut ? 1 : 0) + (hasLoans ? 1 : 0);
          const totalCols = 12 + extraColCount + (isCalculated || isCommitted ? 1 : 0);
          return (
          <PayRunResultsView primaryAction={action} companyId={companyId} currentPath={currentPath} isCalculated={isCalculated} isCommitted={isCommitted} payPeriod={payPeriod} payrollItems={payrollItems} sortPayrollItems={sortPayrollItems} registerTotals={registerTotals} payrollItemDisplayedHours={payrollItemDisplayedHours} setReviewingItem={setReviewingItem} setEditingItem={setEditingItem} setCorrectingItem={setCorrectingItem} setReplacingItem={setReplacingItem}
            filters={<div className="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-4">                  <Select
                    aria-label="Employee type"
                    value={employeeTypeFilter}
                    onChange={(event) => setEmployeeTypeFilter(event.target.value as typeof employeeTypeFilter)}
                    className="w-full lg:w-36"
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
                    className="w-full lg:w-44"
                  >
                    <option value="all">All Departments</option>
                    {departmentOptions.map(([deptId, deptName]) => (
                      <option key={deptId} value={deptId}>{deptName}</option>
                    ))}
                  </Select>
                  <Select
                    aria-label="Sort"
                    value={`${resultsSortBy}:${resultsSortDirection}`}
                    onChange={(event) => {
                      const [sortBy, direction] = event.target.value.split(':') as [typeof resultsSortBy, typeof resultsSortDirection];
                      setResultsSortBy(sortBy);
                      setResultsSortDirection(direction);
                    }}
                    className="w-full lg:w-44"
                  >
                    <option value="name:asc">Name A-Z</option>
                    <option value="name:desc">Name Z-A</option>
                    <option value="rate:desc">Rate High-Low</option>
                    <option value="rate:asc">Rate Low-High</option>
                    <option value="hours:desc">Hours High-Low</option>
                    <option value="hours:asc">Hours Low-High</option>
                    <option value="gross:desc">Gross High-Low</option>
                    <option value="gross:asc">Gross Low-High</option>
                    <option value="net:desc">Net High-Low</option>
                    <option value="net:asc">Net Low-High</option>
                    <option value="fit:desc">FIT High-Low</option>
                    <option value="fit:asc">FIT Low-High</option>
                  </Select>
                  <div className="relative sm:col-span-2 lg:col-span-1">
                    <input
                      type="text"
                      aria-label="Search employees"
                      placeholder="Search employees and checks..."
                      value={searchTerm}
                      onChange={(e) => setSearchTerm(e.target.value)}
                      className="w-full rounded-lg border border-neutral-300 py-2.5 pl-8 pr-3 text-base sm:text-sm focus:border-blue-500 focus:ring-2 focus:ring-blue-500 lg:w-56"
                    />
                    <svg className="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-neutral-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
                    </svg>
                  </div></div>}
            fullDetail={<>            <div className="space-y-3 p-3 sm:hidden" aria-label="Employee payroll results">
              <div className="grid grid-cols-2 gap-3 rounded-xl border border-neutral-200 bg-neutral-50 p-3 text-sm">
                <div><p className="text-xs text-neutral-600">Gross total</p><p className="font-semibold tabular-nums">{formatCurrency(registerTotals.gross)}</p></div>
                <div><p className="text-xs text-neutral-600">Net total</p><p className="font-bold tabular-nums text-neutral-950">{formatCurrency(registerTotals.net)}</p></div>
              </div>
              {sortPayrollItems.map((item) => {
                const canCorrect = isCommitted && item.employment_type !== 'contractor' && Boolean(payPeriod?.can_issue_corrective_paycheck);
                const canReplace = isCommitted && item.employment_type !== 'contractor' && payPeriod?.cycle !== 'supplemental' && !item.voided && Boolean(item.check_number);
                return <section key={item.id} className="space-y-3 rounded-2xl border border-neutral-200 bg-white p-4" aria-label={`Payroll result for ${item.employee_name}`}>
                  <div className="flex items-start justify-between gap-3"><div className="min-w-0"><Link className="font-semibold text-primary-800" to={employeePath(companyId, item.employee_id, 'overview', { returnTo: currentPath })}>{item.employee_name}</Link><p className="mt-1 text-xs capitalize text-neutral-600">{item.employment_type}{item.department_name ? ` · ${item.department_name}` : ''}{item.import_source ? ` · ${item.import_source.replaceAll('_', ' ')}` : ''}</p></div>{item.voided && <Badge variant="danger">Voided</Badge>}</div>
                  <dl className="grid grid-cols-2 gap-3 text-sm">
                    <div><dt className="text-xs text-neutral-600">Hours</dt><dd className="font-medium tabular-nums">{payrollItemDisplayedHours(item).toFixed(2)}</dd></div>
                    <div><dt className="text-xs text-neutral-600">Gross</dt><dd className="font-medium tabular-nums">{formatCurrency(toNumber(item.gross_pay))}</dd></div>
                    <div><dt className="text-xs text-neutral-600">Employee taxes</dt><dd className="tabular-nums">{formatCurrency(payrollTaxSummary(item).total)}</dd></div>
                    <div><dt className="text-xs text-neutral-600">Total deductions</dt><dd className="tabular-nums">{formatCurrency(toNumber(item.total_deductions))}</dd></div>
                    <div className="col-span-2 border-t border-neutral-100 pt-2"><dt className="text-xs text-neutral-600">Net pay</dt><dd className="text-lg font-bold tabular-nums text-neutral-950">{formatCurrency(toNumber(item.net_pay))}</dd></div>
                  </dl>
                  {item.wage_rate_hours?.filter(rate => rate.source_bucket_key).map(rate => <p key={rate.source_bucket_key} className="text-xs text-neutral-600">{rate.label} · {formatCurrency(toNumber(rate.rate))}/hr · {toNumber(rate.regular_hours)} REG / {toNumber(rate.overtime_hours)} OT{capturedSourceContext(rate) ? ` · ${capturedSourceContext(rate)}` : ""}</p>)}
                  {item.correction_pay_basis_hold && <p className="text-xs text-warning-800">Retained saved amounts · {item.correction_pay_basis_hold.reason}</p>}
                  {item.check_number && <p className="text-xs text-neutral-600">Check #{item.check_number}</p>}
                  <div className="grid grid-cols-2 gap-2">
                    <button type="button" className="inline-flex min-h-11 items-center justify-center rounded-xl border border-primary-200 px-3 text-sm font-semibold text-primary-700" onClick={() => setReviewingItem(item)}>View details</button>
                    {isCalculated && <Button variant="outline" size="sm" className="min-h-11" onClick={() => setEditingItem(item)}>Edit payroll</Button>}
                    {canCorrect && <Button variant="outline" size="sm" className="min-h-11" onClick={() => setCorrectingItem(item)}>Correct</Button>}
                    {canReplace && <Button variant="outline" size="sm" className="min-h-11" onClick={() => setReplacingItem(item)}>Replace check</Button>}
                  </div>
                </section>;
              })}
              {sortPayrollItems.length === 0 && <p className="py-8 text-center text-sm text-neutral-600">No employees match these filters.</p>}
            </div>
            <div className="hidden max-w-full overflow-x-auto overscroll-x-contain sm:block">
              <Table stickyHeader containerClassName="h-[min(28rem,50vh)]" className="min-w-[1900px] text-neutral-950 tabular-nums">
                <TableHeader>
                  <TableRow>
                    <TableHead stickyLeft className={`w-[170px] min-w-[170px] bg-neutral-50 ${TABLE_STICKY_TOP_CLASS}`}>Last name</TableHead>
                    <TableHead className={`w-[190px] min-w-[190px] bg-neutral-50 ${TABLE_STICKY_TOP_CLASS}`}>First name</TableHead>
                    <TableHead className={`bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>Hours</TableHead>
                    <TableHead className={`bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>Rate</TableHead>
                    <TableHead className={`bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>Gross</TableHead>
                    {hasCustomEarnings && <TableHead className={`bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>Custom Earn.</TableHead>}
                    {hasCustomDeductions && <TableHead className={`bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>Custom Ded.</TableHead>}
                    {hasPayrollAdjustments && <TableHead className={`min-w-[180px] bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>Adjustments</TableHead>}
                    {visiblePayrollFields.map((field) => (
                      <TableHead key={field.id} className={`min-w-[140px] bg-blue-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>
                        <div>{field.name}</div>
                        <div className="text-xs font-normal text-neutral-600">{field.kind.replace(/_/g, ' ')}</div>
                      </TableHead>
                    ))}
                    {hasTips && <TableHead className={`min-w-[130px] bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>Reported Tips</TableHead>}
                    {hasTipsPaidOut && <TableHead className={`min-w-[130px] bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>Tips Paid Out</TableHead>}
                    {hasLoans && <TableHead title="Calculated total of linked loan repayments and any standalone loan deduction." className={`min-w-[130px] bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>Loan deductions</TableHead>}
                    <TableHead className={`bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>FIT</TableHead>
                    <TableHead className={`bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>Addtl W/H</TableHead>
                    <TableHead className={`bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>SS (6.2%)</TableHead>
                    <TableHead
                      className={`min-w-[150px] bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}
                      title="Employee Medicare includes Additional Medicare withholding when applicable."
                    >
                      <div>Employee Medicare</div>
                      <div className="text-xs font-normal normal-case tracking-normal text-neutral-600">incl. Add&apos;l</div>
                    </TableHead>
                    <TableHead className={`min-w-[150px] bg-warning-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>
                      <div>Employer Medicare</div>
                      <div className="text-xs font-normal normal-case tracking-normal text-warning-800">employer-paid</div>
                    </TableHead>
                    <TableHead className={`bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>Total Ded.</TableHead>
                    <TableHead className={`bg-neutral-50 text-right tabular-nums ${TABLE_STICKY_TOP_CLASS}`}>Net pay</TableHead>
                    {(isCalculated || isCommitted) && <TableHead className="sticky right-0 z-30 w-20 border-l border-neutral-200 bg-neutral-50 text-center"><span className="sr-only">Details</span></TableHead>}
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(() => {
                    const displayItems = sortPayrollItems;
                    return displayItems.map((item, idx) => {
                    const isManual = !item.import_source;
                    const isSalary = item.employment_type === 'salary';
                    const isWorkbookPay = item.period_pay_evidence?.source_type === 'mosa_change_workbook';
                    const isContractor = item.employment_type === 'contractor';
                    const empRecord = employeeLookup.get(item.employee_id);
                    const contractorPayType = item.contractor_pay_type || empRecord?.contractor_pay_type;
                    const isContractorHourly = isContractor && contractorPayType === 'hourly';
                    const isContractorFlat = isContractor && contractorPayType !== 'hourly';
                    const regularHours = toNumber(item.hours_worked);
                    const overtimeHours = toNumber(item.overtime_hours);
                    const hasSalaryTimekeeping = Boolean(item.timekeeping_source) || regularHours > 0 || overtimeHours > 0;
                    const itemWageRates = (item.wage_rate_hours || []).filter((rate) => rate.active !== false);
                    const hasMultiRateResults = (item.employment_type === 'hourly' || isContractorHourly) && (item.wage_rate_hours || []).length > 1;
                    const prevGroup = idx > 0 ? employmentGroupKey(displayItems[idx - 1]?.employment_type || '') : null;
                    const currentGroup = employmentGroupKey(item.employment_type);
                    const showGroupDivider = currentGroup !== prevGroup;
                    const rowTone = idx % 2 === 0 ? 'bg-white' : 'bg-neutral-100';
                    const { firstName, lastName } = payrollItemNameParts(item);

                    return (
                      <Fragment key={item.id}>
                        {showGroupDivider && (() => {
                          const tone = employmentGroupTone(item.employment_type);
                          return (
                            <TableRow className={tone.row}>
                              <TableCell stickyLeft colSpan={totalCols} className={`${tone.row} py-1.5 text-xs font-semibold ${tone.text}`}>
                                {employmentGroupLabel(currentGroup, employeeTypeFilter)}
                              </TableCell>
                            </TableRow>
                          );
                        })()}
                        <TableRow key={item.id} className={rowTone}>
                          <TableCell stickyLeft className={`min-w-[170px] ${rowTone}`}>
                            <Link
                              className="font-medium text-neutral-900 hover:text-primary-700 hover:underline"
                              to={employeePath(companyId, item.employee_id, 'overview', { returnTo: currentPath })}
                            >
                              {lastName || '—'}
                            </Link>
                            {(item.department_name || empRecord?.department?.name) && (
                              <p className="mt-0.5 text-xs text-neutral-600">
                                {item.department_name || empRecord?.department?.name}
                              </p>
                            )}
                          </TableCell>
                          <TableCell className={`min-w-[190px] ${rowTone}`}>
                            <p className="font-medium text-neutral-900">{firstName || '—'}</p>
                            <div className="mt-0.5 flex flex-wrap items-center gap-1.5">
                                  {isSalary && (
                                    <span className="inline-flex items-center rounded-full bg-indigo-100 px-1.5 py-0.5 text-xs font-medium text-indigo-700">
                                      Salary
                                    </span>
                                  )}
                                  {isContractor && (
                                    <span className="inline-flex items-center rounded-full bg-emerald-100 px-1.5 py-0.5 text-xs font-medium text-emerald-700">
                                      1099
                                    </span>
                                  )}
                                  {hasMultiRateResults && (
                                    <span className="inline-flex items-center rounded-full bg-blue-100 px-1.5 py-0.5 text-xs font-medium text-blue-700">
                                      Multiple earnings
                                    </span>
                                  )}
                                  {item.time_tracking_provenance && (
                                    <span className="inline-flex items-center rounded-full bg-cyan-100 px-1.5 py-0.5 text-xs font-medium text-cyan-800" title={`${item.time_tracking_provenance.entry_count} time tracking entries · ${item.time_tracking_provenance.total_hours.toFixed(2)} hours${item.time_tracking_provenance.carryover_hours ? ` · ${item.time_tracking_provenance.carryover_hours.toFixed(2)} carryover hours` : ''}`}>
                                      time tracking linked
                                    </span>
                                  )}
                                  {isWorkbookPay && !isContractor && (
                                    <span className="inline-flex items-center rounded-full bg-cyan-100 px-1.5 py-0.5 text-xs font-medium text-cyan-800">
                                      Workbook pay
                                    </span>
                                  )}
                                  {!isWorkbookPay && (isManual || (isSalary && item.salary_override)) && !isContractor && (
                                    <span className="inline-flex items-center rounded-full bg-warning-100 px-1.5 py-0.5 text-xs font-medium text-warning-700">
                                      Manual
                                    </span>
                                  )}
                                  {item.withholding_tax_adjustment != null && toNumber(item.withholding_tax_adjustment) !== 0 && (
                                    <span className="inline-flex items-center rounded-full bg-orange-100 px-1.5 py-0.5 text-xs font-medium text-orange-700" title={`FIT adjusted by ${formatCurrency(toNumber(item.withholding_tax_adjustment))} for this pay period`}>
                                      FIT Adj
                                    </span>
                                  )}
                                  {item.withholding_tax_override != null && (
                                    <span className="inline-flex items-center rounded-full bg-warning-100 px-1.5 py-0.5 text-xs font-medium text-warning-700" title="Final FIT manually overridden for this pay period">
                                      FIT Override
                                    </span>
                                  )}
                                  {toNumber(item.additional_withholding) > 0 && (
                                    <span className="inline-flex items-center rounded-full bg-purple-100 px-1.5 py-0.5 text-xs font-medium text-purple-700" title={item.additional_withholding_override != null ? `W-4 Step 4(c) overridden for this pay period: ${formatCurrency(toNumber(item.additional_withholding))}` : `W-4 Step 4(c) extra withholding for this pay period: ${formatCurrency(toNumber(item.additional_withholding))}`}>
                                      +{formatCurrency(toNumber(item.additional_withholding))} W/H
                                    </span>
                                  )}
                                  {empRecord?.w4_step2_multiple_jobs && (
                                    <span className="inline-flex items-center rounded-full bg-sky-100 px-1.5 py-0.5 text-xs font-medium text-sky-700" title="W-4 Step 2: Two jobs or spouse works">
                                      Step 2
                                    </span>
                                  )}
                            </div>
                            <button type="button"
                              className="mt-1 inline-flex min-h-11 items-center gap-1 text-xs font-bold text-primary-700 hover:text-primary-900"
                              onClick={() => setReviewingItem(item)}
                            >
                              Open payroll item <ArrowRight className="h-3.5 w-3.5" />
                            </button>
                          </TableCell>
                          <TableCell className={`text-right tabular-nums ${rowTone}`}>
                            {isSalary ? (
                              payPeriod.includes_base_salary === false && !hasSalaryTimekeeping ? (
                                <span className="text-neutral-600" title="Salary hours do not apply to this run">—</span>
                              ) : hasSalaryTimekeeping ? (
                                <div
                                  className="inline-flex flex-col items-end leading-tight"
                                  title="Informational salary hours from the timekeeping ledger; base salary is not calculated from these hours"
                                >
                                  <span className="font-medium text-neutral-900">
                                    {regularHours} <span className="font-normal text-neutral-600">regular</span>
                                  </span>
                                  {overtimeHours > 0 && (
                                    <span className="mt-1 font-medium text-warning-800">
                                      +{overtimeHours} overtime
                                    </span>
                                  )}
                                  <span className="mt-1 text-xs font-semibold text-neutral-600">
                                    Informational
                                  </span>
                                </div>
                              ) : (
                                <span className="text-xs font-medium text-warning-700" title="No salary timekeeping record was available for this payroll item">
                                  Not recorded
                                </span>
                              )
                            ) : isContractorFlat ? (
                              <span className="text-neutral-600">—</span>
                            ) : hasMultiRateResults ? (
                              <div className="space-y-1 text-left inline-block">
                                {itemWageRates.map((rate) => {
                                  const totalHours = toNumber(rate.regular_hours) + toNumber(rate.overtime_hours);
                                  return (
                                    <div key={`${item.id}-${rate.source_bucket_key || rate.label}-hours`} className="text-xs">
                                      <span className="font-medium text-neutral-900">{rate.label}</span>{' '}
                                      <span className="text-neutral-600">{totalHours}</span>
                                      {toNumber(rate.overtime_hours) > 0 && (
                                        <span className="text-warning-800 ml-1">({toNumber(rate.overtime_hours)} OT)</span>
                                      )}
                                    </div>
                                  );
                                })}
                              </div>
                            ) : (
                              <>
                                {regularHours}
                                {overtimeHours > 0 && (
                                  <span className="text-warning-800 ml-1">+{overtimeHours} OT</span>
                                )}
                              </>
                            )}
                          </TableCell>
                          <TableCell className={`text-right tabular-nums ${rowTone}`}>
                            {(() => {
                              if (item.correction_pay_basis_hold) return <span className="text-xs text-warning-800">Retained pay basis · {item.correction_pay_basis_hold.reason}</span>;
                              if (isSalary) {
                                if (!payPeriod.includes_base_salary) return <span className="font-medium text-primary-700">Excluded from this run</span>;
                                const override = item.salary_override ? toNumber(item.salary_override) : 0;
                                if (override > 0) return <span className="text-indigo-600" title={isWorkbookPay ? "MoSa change workbook pay for this period" : "Salary override"}>{formatCurrency(override)}/period</span>;
                                if (empRecord?.salary_type === 'variable') return <span className="text-indigo-600 font-medium">Variable</span>;
                                const payRate = toNumber(item.pay_rate);
                                const isPerPeriod = empRecord?.salary_type === 'per_period';
                                if (isPerPeriod) return `${formatCurrency(payRate)}/period`;
                                const periodsPerYear = ({ weekly: 52, biweekly: 26, semimonthly: 24, monthly: 12 } as Record<string, number>)[empRecord?.pay_frequency || ''] || 26;
                                return `${formatCurrency(payRate / periodsPerYear)}/period`;
                              }
                              if (isContractorFlat) {
                                if (payPeriod.run_purpose === 'off_cycle_tips') {
                                  return <span className="font-medium text-primary-700">Excluded from tips-only run</span>;
                                }
                                const override = item.salary_override ? toNumber(item.salary_override) : 0;
                                if (override > 0) return <span className="text-neutral-950" title="Flat Fee Override">{formatCurrency(override)}/period</span>;
                                return <span className="text-neutral-950">{formatCurrency(toNumber(item.pay_rate))}/period</span>;
                              }
                              if (hasMultiRateResults) {
                                return (
                                  <div className="space-y-1 text-left inline-block">
                                    {itemWageRates.map((rate) => (
                                      <div key={`${item.id}-${rate.source_bucket_key || rate.label}-rate`} className="text-xs">
                                        <span className="font-medium text-neutral-900">{rate.label}</span>{' '}
                                        <span className="text-neutral-600">{formatCurrency(toNumber(rate.rate))}/hr</span>
                                      </div>
                                    ))}
                                  </div>
                                );
                              }
                              if (isContractorHourly) {
                                return `${formatCurrency(toNumber(item.pay_rate))}/hr`;
                              }
                              return `${formatCurrency(toNumber(item.pay_rate))}/hr`;
                            })()}
                          </TableCell>
                          <TableCell className={`text-right tabular-nums font-medium ${rowTone}`}>{formatCurrency(toNumber(item.gross_pay))}</TableCell>
                          {hasCustomEarnings && (
                          <TableCell className={`text-right tabular-nums ${rowTone}`}>
                            {(item.custom_earnings || []).some((earning) => toNumber(earning.amount) > 0) ? (
                              <div className="space-y-1">
                                {(item.custom_earnings || []).filter((earning) => toNumber(earning.amount) > 0).map((earning, index) => (
                                  <div key={`${item.id}-custom-earning-${index}-${earning.label}-${earning.amount}`} className="text-xs">
                                    <span className="text-neutral-600">{earning.label}</span>{' '}
                                    <span className="font-medium text-neutral-900">{formatCurrency(toNumber(earning.amount))}</span>
                                  </div>
                                ))}
                              </div>
                            ) : (
                              <span className="text-neutral-600">—</span>
                            )}
                          </TableCell>
                          )}
                          {hasCustomDeductions && (
                          <TableCell className={`text-right tabular-nums ${rowTone}`}>
                            {(item.custom_deductions || []).some((deduction) => toNumber(deduction.amount) > 0) ? (
                              <div className="space-y-1">
                                {(item.custom_deductions || []).filter((deduction) => toNumber(deduction.amount) > 0).map((deduction, index) => (
                                  <div key={`${item.id}-custom-deduction-${index}-${deduction.label}-${deduction.amount}`} className="text-xs">
                                    <span className="text-neutral-600">{deduction.label}</span>{' '}
                                    <span className="font-medium text-neutral-950">{formatCurrency(toNumber(deduction.amount))}</span>
                                  </div>
                                ))}
                              </div>
                            ) : (
                              <span className="text-neutral-600">—</span>
                            )}
                          </TableCell>
                          )}
                          {hasPayrollAdjustments && (
                          <TableCell className={`text-right tabular-nums ${rowTone}`}>
                            {(item.payroll_adjustments || []).some((adjustment) => adjustment.active !== false && toNumber(adjustment.amount) > 0) ? (
                              <div className="space-y-1">
                                {(item.payroll_adjustments || []).filter((adjustment) => adjustment.active !== false && toNumber(adjustment.amount) > 0).map((adjustment, index) => {
                                  const isDeduction = adjustment.treatment === 'pre_tax_deduction' || adjustment.treatment === 'post_tax_deduction';
                                  return (
                                    <div key={`${item.id}-payroll-adjustment-${index}-${adjustment.label}-${adjustment.amount}`} className="text-xs">
                                      <span className="text-neutral-600">{adjustment.label}</span>{' '}
                                      <span className="font-medium text-neutral-950">
                                        {isDeduction ? '-' : '+'}{formatCurrency(toNumber(adjustment.amount))}
                                      </span>
                                      <div className="text-xs text-neutral-600">{adjustmentTreatmentLabels[adjustment.treatment]}</div>
                                    </div>
                                  );
                                })}
                              </div>
                            ) : (
                              <span className="text-neutral-600">—</span>
                            )}
                          </TableCell>
                          )}
                          {visiblePayrollFields.map((field) => {
                            const entry = (item.payroll_field_entries || []).find((candidate) => candidate.active !== false && candidate.payroll_field_definition_id === field.id);
                            const amount = toNumber(entry?.amount);
                            const isDeduction = field.kind === 'deduction';
                            return (
                              <TableCell key={`${item.id}-payroll-field-${field.id}`} className={`text-right tabular-nums ${rowTone}`}>
                                {amount > 0 ? (
                                  <span className="font-medium text-neutral-950">
                                    {isDeduction ? '-' : '+'}{formatCurrency(amount)}
                                  </span>
                                ) : (
                                  <span className="text-neutral-600">—</span>
                                )}
                              </TableCell>
                            );
                          })}
                          {hasTips && (
                          <TableCell className={`text-right tabular-nums ${rowTone}`}>
                            {toNumber(item.reported_tips) > 0 ? (
                              <span>
                                {formatCurrency(toNumber(item.reported_tips))}
                                {item.tip_pool && (
                                  <span className={`ml-1 text-xs font-medium ${
                                    item.tip_pool === 'boh'
                                      ? 'text-warning-800'
                                      : item.tip_pool === 'mixed'
                                      ? 'text-violet-600'
                                      : 'text-blue-600'
                                  }`}>
                                    {item.tip_pool}
                                  </span>
                                )}
                              </span>
                            ) : (
                              <span className="text-neutral-600">—</span>
                            )}
                          </TableCell>
                          )}
                          {hasTipsPaidOut && (
                          <TableCell className={`text-right tabular-nums ${rowTone}`}>
                            {toNumber(item.tips_paid_out) > 0 ? (
                              formatCurrency(toNumber(item.tips_paid_out))
                            ) : (
                              <span className="text-neutral-600">—</span>
                            )}
                          </TableCell>
                          )}
                          {hasLoans && (
                          <TableCell className={`text-right tabular-nums ${rowTone}`}>
                            {effectiveLoanDeduction(item) > 0 ? (
                              formatCurrency(effectiveLoanDeduction(item))
                            ) : (
                              <span className="text-neutral-600">—</span>
                            )}
                          </TableCell>
                          )}
                          <TableCell className={`text-right tabular-nums text-neutral-950 ${rowTone}`}>
                            {formatCurrency(toNumber(item.withholding_tax))}
                            {item.withholding_tax_adjustment != null && toNumber(item.withholding_tax_adjustment) !== 0 && (
                              <span className="ml-0.5 text-xs text-warning-800" title={`FIT adjusted by ${formatCurrency(toNumber(item.withholding_tax_adjustment))}`}>†</span>
                            )}
                            {item.withholding_tax_override != null && (
                              <span className="ml-0.5 text-xs text-warning-800" title="Final FIT manually overridden">*</span>
                            )}
                          </TableCell>
                          <TableCell className={`text-right tabular-nums text-neutral-950 ${rowTone}`}>
                            {toNumber(item.additional_withholding) > 0 ? formatCurrency(toNumber(item.additional_withholding)) : '—'}
                          </TableCell>
                          <TableCell className={`text-right tabular-nums text-neutral-950 ${rowTone}`}>{formatCurrency(toNumber(item.social_security_tax))}</TableCell>
                          <TableCell className={`text-right tabular-nums text-neutral-950 ${rowTone}`}>
                            {formatCurrency(payrollTaxSummary(item).totalMedicare)}
                          </TableCell>
                          <TableCell className={`text-right tabular-nums text-neutral-950 ${rowTone}`}>{formatCurrency(toNumber(item.employer_medicare_tax))}</TableCell>
                          <TableCell className={`text-right tabular-nums text-neutral-950 font-medium ${rowTone}`}>{formatCurrency(toNumber(item.total_deductions))}</TableCell>
                          <TableCell className={`text-right tabular-nums font-bold text-neutral-950 ${rowTone}`}>{formatCurrency(toNumber(item.net_pay))}</TableCell>
                          {isCalculated && (
                            <TableCell className={`sticky right-0 z-10 border-l border-neutral-200 text-center ${rowTone}`}>
                              <button
                                onClick={() => setEditingItem(item)}
                                className="text-xs text-blue-600 hover:text-blue-800 hover:underline font-medium"
                              >
                                Edit
                              </button>
                            </TableCell>
                          )}
                          {isCommitted && !isContractor && (() => {
                            const canCorrect = !!payPeriod?.can_issue_corrective_paycheck;
                            // Replace (uncashed) is offered when we can cleanly
                            // void+reissue or in-place edit a single check on
                            // this period: must be a regular (non-supplemental)
                            // committed period and the item must still own a
                            // non-voided check number.
                            const canReplace =
                              payPeriod?.cycle !== 'supplemental' &&
                              !item.voided &&
                              !!item.check_number;
                            if (!canCorrect && !canReplace) return <TableCell className={`sticky right-0 z-10 border-l border-neutral-200 ${rowTone}`} />;
                            return (
                              <TableCell className={`sticky right-0 z-10 border-l border-neutral-200 text-center ${rowTone}`}>
                                <div className="flex flex-col items-center gap-0.5">
                                  {canCorrect && (
                                    <button
                                      onClick={() => setCorrectingItem(item)}
                                      className="text-xs text-warning-700 hover:text-warning-900 hover:underline font-medium"
                                      title="Issue a separate supplemental check for the difference (use when the original was cashed)"
                                    >
                                      Correct
                                    </button>
                                  )}
                                  {canReplace && (
                                    <button
                                      onClick={() => setReplacingItem(item)}
                                      className="text-xs text-orange-700 hover:text-orange-900 hover:underline font-medium"
                                      title="Void & reissue this check (use when the original is uncashed or never distributed)"
                                    >
                                      Replace
                                    </button>
                                  )}
                                </div>
                              </TableCell>
                            );
                          })()}
                          {isCommitted && isContractor && (
                            <TableCell className={`sticky right-0 z-10 border-l border-neutral-200 ${rowTone}`} />
                          )}
                        </TableRow>
                      </Fragment>
                    );
                  });
                  })()}
                </TableBody>
                <TableFooter className="sticky bottom-0 z-30 border-t-2 border-neutral-300 bg-neutral-100 shadow-[0_-8px_16px_-12px_rgba(15,23,42,0.45)]">
                  {(() => {
                    return (
                      <TableRow className="bg-neutral-100 font-bold hover:bg-neutral-100">
                        <TableCell stickyLeft className="!z-40 bg-neutral-100">Totals ({sortPayrollItems.length} {sortPayrollItems.length === 1 ? 'employee' : 'employees'})</TableCell>
                        <TableCell className="bg-neutral-100" aria-label="First name total not applicable">—</TableCell>
                        <TableCell className="bg-neutral-100 text-right">{registerTotals.hours.toFixed(2)}</TableCell>
                        <TableCell className="bg-neutral-100 text-right" aria-label="Pay rate total not applicable">—</TableCell>
                        <TableCell className="bg-neutral-100 text-right">{formatCurrency(registerTotals.gross)}</TableCell>
                        {hasCustomEarnings && <TableCell className="bg-neutral-100 text-right">{registerTotals.customEarnings > 0 ? formatCurrency(registerTotals.customEarnings) : '—'}</TableCell>}
                        {hasCustomDeductions && <TableCell className="bg-neutral-100 text-right tabular-nums text-neutral-950">{registerTotals.customDeductions > 0 ? formatCurrency(registerTotals.customDeductions) : '—'}</TableCell>}
                        {hasPayrollAdjustments && (
                          <TableCell className={registerTotals.payrollAdjustments < 0 ? 'bg-neutral-100 text-right tabular-nums text-neutral-950' : 'bg-neutral-100 text-right'}>
                            {registerTotals.payrollAdjustments !== 0 ? `${registerTotals.payrollAdjustments < 0 ? '-' : ''}${formatCurrency(Math.abs(registerTotals.payrollAdjustments))}` : '—'}
                          </TableCell>
                        )}
                        {visiblePayrollFields.map((field) => {
                          const amount = registerPayrollFieldTotals.get(field.id) || 0;
                          const isDeduction = field.kind === 'deduction';
                          return (
                            <TableCell
                              key={`payroll-field-total-${field.id}`}
                              className={`bg-neutral-100 text-right tabular-nums text-neutral-950`}
                            >
                              {amount > 0 ? `${isDeduction ? '-' : '+'}${formatCurrency(amount)}` : '—'}
                            </TableCell>
                          );
                        })}
                        {hasTips && <TableCell className="bg-neutral-100 text-right">{registerTotals.tips > 0 ? formatCurrency(registerTotals.tips) : '—'}</TableCell>}
                        {hasTipsPaidOut && <TableCell className="bg-neutral-100 text-right">{registerTotals.tipsPaidOut > 0 ? formatCurrency(registerTotals.tipsPaidOut) : '—'}</TableCell>}
                        {hasLoans && <TableCell className="bg-neutral-100 text-right">{registerTotals.loans > 0 ? formatCurrency(registerTotals.loans) : '—'}</TableCell>}
                        <TableCell className="bg-neutral-100 text-right tabular-nums text-neutral-950">{formatCurrency(registerTotals.withholding)}</TableCell>
                        <TableCell className="bg-neutral-100 text-right tabular-nums text-neutral-950">{registerTotals.additionalWithholding > 0 ? formatCurrency(registerTotals.additionalWithholding) : '—'}</TableCell>
                        <TableCell className="bg-neutral-100 text-right tabular-nums text-neutral-950">{formatCurrency(registerTotals.socialSecurity)}</TableCell>
                        <TableCell className="bg-neutral-100 text-right tabular-nums text-neutral-950">{formatCurrency(registerTotals.employeeMedicare)}</TableCell>
                        <TableCell className="bg-neutral-100 text-right tabular-nums text-neutral-950">{formatCurrency(registerTotals.employerMedicare)}</TableCell>
                        <TableCell className="bg-neutral-100 text-right tabular-nums text-neutral-950">{formatCurrency(registerTotals.deductions)}</TableCell>
                        <TableCell className="bg-neutral-100 text-right tabular-nums text-neutral-950">{formatCurrency(registerTotals.net)}</TableCell>
                        {(isCalculated || isCommitted) && <TableCell className="sticky right-0 z-10 border-l border-neutral-200 bg-neutral-100" />}
                      </TableRow>
                    );
                  })()}
                </TableFooter>
              </Table>
            </div></>}
          />
          );
        })()}
  </>);
}
