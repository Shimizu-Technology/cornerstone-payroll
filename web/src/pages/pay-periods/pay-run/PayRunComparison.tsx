

import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent } from '@/components/ui/card';

import { formatCurrency, formatDate, formatDateRange } from '@/lib/utils';

import { comparisonMetricLabels, formatSignedCurrency, formatSignedNumber } from './payRunSupport';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunComparison({
  comparison,
  comparisonError,
  comparisonFlagTone,
  comparisonHiddenRows,
  comparisonHighlights,
  comparisonLoading,
  comparisonRows,
  comparisonTotalRows,
  isApproved,
  isCalculated,
  isCommitted,
  loadComparison,
  payPeriod,
  payrollItems
}: PayRunSectionProps<'comparison'>) {
  return (<>
{payrollItems.length > 0 && payPeriod.cycle !== 'supplemental' && (isCalculated || isApproved || isCommitted) && (
          <Card className="border-blue-100 bg-blue-50/40">
            <CardContent className="space-y-4 py-5">
              <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <h3 className="text-base font-semibold text-neutral-900">
                    {comparison?.comparison_kind === 'training_benchmark' ? 'Training Benchmark Comparison' : comparison?.comparison_kind === 'selected_employees' ? 'Selected Employee Comparison' : 'Previous Pay Period Comparison'}
                  </h3>
                  <p className={`mt-1 text-sm ${comparisonError ? 'text-danger-700' : 'text-neutral-600'}`}>
                    {comparisonError
                      ? 'Comparison failed to load. Retry before approving this payroll.'
                      : comparison?.previous_pay_period
                        ? `${comparison.comparison_kind === 'training_benchmark' ? `${comparison.benchmark?.immutable ? 'Frozen expected result' : 'Expected result'} from` : comparison.comparison_kind === 'selected_employees' ? 'Compared for the selected employees with' : 'Compared with'} ${formatDateRange(comparison.previous_pay_period.start_date, comparison.previous_pay_period.end_date)} · Pay date ${formatDate(comparison.previous_pay_period.pay_date)}${comparison.benchmark?.source_status ? ` · Captured as ${comparison.benchmark.source_status}` : ''}`
                        : comparisonLoading ? 'Loading comparison…' : 'No comparison target found for this payroll.'}
                  </p>
                </div>
                {comparison && (
                  <Badge className={comparisonFlagTone}>
                    {comparison.review_flags.message}
                  </Badge>
                )}
              </div>

              {comparisonError ? (
                <div className="flex flex-col gap-3 rounded-xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-800 sm:flex-row sm:items-center sm:justify-between">
                  <span>Unable to load comparison data: {comparisonError}</span>
                  <Button variant="outline" size="sm" onClick={() => loadComparison(payPeriod.id)} disabled={comparisonLoading}>
                    Retry comparison
                  </Button>
                </div>
              ) : comparisonLoading ? (
                <p className="text-sm text-neutral-600">Loading comparison…</p>
              ) : comparison?.previous_pay_period ? (
                <>
                  <div className="overflow-x-auto pb-1">
                    <div className="grid min-w-[58rem] grid-cols-6 gap-3">
                      {comparisonHighlights.map((metric) => {
                      const isCount = metric.key === 'employee_count';
                      const deltaClass = metric.delta > 0 ? 'text-emerald-700' : metric.delta < 0 ? 'text-danger-700' : 'text-neutral-600';
                      return (
                        <div key={metric.key} className="rounded-xl border border-white/70 bg-white px-3 py-3 shadow-sm">
                          <p className="text-xs font-semibold text-neutral-600">{comparisonMetricLabels[metric.key]}</p>
                          <p className="mt-1 text-lg font-semibold text-neutral-900">
                            {isCount ? metric.current : formatCurrency(metric.current)}
                          </p>
                          <p className={`mt-0.5 text-xs font-medium ${deltaClass}`}>
                            {isCount ? formatSignedNumber(metric.delta) : formatSignedCurrency(metric.delta)}
                            {metric.percent_delta !== null && ` · ${metric.percent_delta > 0 ? '+' : ''}${metric.percent_delta}%`}
                          </p>
                        </div>
                      );
                      })}
                    </div>
                  </div>

                  {comparisonRows.length > 0 ? (
                    <div className="space-y-2">
                      <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-neutral-600">
                        <span>
                          Showing {comparisonRows.length} of {comparisonTotalRows} flagged employee{comparisonTotalRows === 1 ? '' : 's'}.
                        </span>
                        {comparisonHiddenRows > 0 && (
                          <span className="font-medium text-warning-700">
                            {comparisonHiddenRows} more flagged employee{comparisonHiddenRows === 1 ? '' : 's'} not shown in this summary.
                          </span>
                        )}
                      </div>
                      <div className="overflow-x-auto rounded-xl border border-blue-100 bg-white">
                        <table className="min-w-[72rem] w-full text-sm">
                        <thead className="bg-blue-50 text-xs text-blue-900">
                          <tr>
                            <th className="whitespace-nowrap px-3 py-2 text-left font-semibold">Review item</th>
                            <th className="whitespace-nowrap px-3 py-2 text-right font-semibold">Gross Δ</th>
                            <th className="whitespace-nowrap px-3 py-2 text-right font-semibold">Net Δ</th>
                            <th className="whitespace-nowrap px-3 py-2 text-right font-semibold">Tips Δ</th>
                            <th className="whitespace-nowrap px-3 py-2 text-right font-semibold">Deduct. Δ</th>
                            <th className="whitespace-nowrap px-3 py-2 text-right font-semibold">Loan Ded. Δ</th>
                            <th className="whitespace-nowrap px-3 py-2 text-right font-semibold">Loan Pmt. Δ</th>
                          </tr>
                        </thead>
                        <tbody className="divide-y divide-blue-50">
                          {comparisonRows.map((row) => (
                            <tr key={`${row.employee_id}-${row.change_type}`}>
                              <td className="px-3 py-2">
                                <div className="font-medium text-neutral-900">{row.employee_name}</div>
                                <div className="mt-1 flex flex-wrap gap-1">
                                  {row.flags.map((flag) => (
                                    <span key={flag.key} className={`rounded-full px-2 py-0.5 text-xs font-medium ${flag.severity === 'warning' ? 'bg-danger-50 text-danger-700' : 'bg-warning-50 text-warning-700'}`}>
                                      {flag.message}
                                    </span>
                                  ))}
                                </div>
                              </td>
                              <td className="px-3 py-2 text-right font-mono">{formatSignedCurrency(row.deltas.gross_pay?.delta || 0)}</td>
                              <td className="px-3 py-2 text-right font-mono">{formatSignedCurrency(row.deltas.net_pay?.delta || 0)}</td>
                              <td className="px-3 py-2 text-right font-mono">{formatSignedCurrency(row.deltas.reported_tips?.delta || 0)}</td>
                              <td className="px-3 py-2 text-right font-mono">{formatSignedCurrency(row.deltas.total_deductions?.delta || 0)}</td>
                              <td className="px-3 py-2 text-right font-mono">{formatSignedCurrency(row.deltas.loan_deduction?.delta || 0)}</td>
                              <td className="px-3 py-2 text-right font-mono">{formatSignedCurrency(row.deltas.loan_payment?.delta || 0)}</td>
                            </tr>
                          ))}
                        </tbody>
                        </table>
                      </div>
                    </div>
                  ) : (
                    <div className="rounded-xl border border-emerald-100 bg-emerald-50 px-4 py-3 text-sm text-emerald-800">
                      {comparison.comparison_kind === 'training_benchmark'
                        ? 'No material employee-level differences from the training benchmark.'
                        : comparison.comparison_kind === 'selected_employees'
                          ? 'No material differences for the selected employees. Employees outside this special run are excluded from the comparison.'
                          : 'No material employee-level changes detected against the previous committed period.'}
                    </div>
                  )}
                </>
              ) : null}
            </CardContent>
          </Card>
        )}
  </>);
}
