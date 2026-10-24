

import { Card } from '@/components/ui/card';

import { formatCurrency } from '@/lib/utils';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunEmployerTaxes({
  fitDivergence,
  isDraft,
  payrollItems,
  totalDRTDeposit,
  totalEmployerMedicare,
  totalEmployerSS,
  totalMedicare,
  totalSS,
  totalWithholding
}: PayRunSectionProps<'employerTaxes'>) {
  return (<>
{!isDraft && payrollItems.length > 0 && (
          <Card className="border-warning-200">
            <div className="p-4 border-b border-warning-200 bg-warning-50">
              <h3 className="font-semibold text-warning-900">Employer Tax Obligations</h3>
              <p className="text-sm text-warning-700 mt-1">
                Guam FIT deposit plus related FICA obligations for this pay period
              </p>
            </div>
            <div className="p-4">
              <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                {/* FIT Column */}
                <div>
                  <h4 className="text-sm font-semibold text-neutral-600 mb-3">Federal / Guam Income Tax</h4>
                  <div className="space-y-2">
                    <div className="flex justify-between">
                      <span className="text-neutral-600">Employee FIT Withheld</span>
                      <span className="font-medium">{formatCurrency(totalWithholding)}</span>
                    </div>
                    <div className="flex justify-between pt-2 border-t font-semibold">
                      <span>FIT Subtotal</span>
                      <span>{formatCurrency(totalDRTDeposit)}</span>
                    </div>
                    {fitDivergence && (
                      <div className="mt-2 rounded-md border border-orange-300 bg-orange-50 px-2.5 py-2 text-xs text-orange-900">
                        <div className="flex items-start gap-1.5">
                          <svg className="mt-0.5 h-3.5 w-3.5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                            <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
                          </svg>
                          <div>
                            <p className="font-semibold">FIT deposit overridden</p>
                            <p className="mt-0.5 leading-snug">
                              Calculated <span className="font-mono">{formatCurrency(fitDivergence.calculated)}</span>,{' '}
                              depositing <span className="font-mono">{formatCurrency(fitDivergence.deposited)}</span>{' '}
                              ({fitDivergence.delta > 0 ? '+' : ''}{formatCurrency(fitDivergence.delta)})
                            </p>
                          </div>
                        </div>
                      </div>
                    )}
                  </div>
                </div>
                {/* SS + Medicare Column */}
                <div>
                  <h4 className="text-sm font-semibold text-neutral-600 mb-3">Social Security & Medicare (FICA)</h4>
                  <div className="space-y-2">
                    <div className="flex justify-between">
                      <span className="text-neutral-600">Employee Social Security (6.2%)</span>
                      <span className="font-medium">{formatCurrency(totalSS)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-neutral-600">Employer Social Security (6.2%)</span>
                      <span className="font-medium">{formatCurrency(totalEmployerSS)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-neutral-600">Employee Medicare (incl. Additional Medicare)</span>
                      <span className="font-medium">{formatCurrency(totalMedicare)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-neutral-600">Employer Medicare (1.45%)</span>
                      <span className="font-medium">{formatCurrency(totalEmployerMedicare)}</span>
                    </div>
                    <div className="flex justify-between pt-2 border-t font-semibold">
                      <span>FICA Subtotal</span>
                      <span>{formatCurrency(totalSS + totalEmployerSS + totalMedicare + totalEmployerMedicare)}</span>
                    </div>
                  </div>
                </div>
              </div>
              {/* Grand total */}
              <div className="mt-6 flex flex-col gap-3 border-t-2 border-warning-300 pt-4 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <p className="text-lg font-bold text-warning-900">Total DRT deposit</p>
                  <p className="text-sm text-warning-700">Base plus W-4 Step 4(c) additional withholding</p>
                </div>
                <p className="wrap-break-word text-2xl font-bold text-warning-900">{formatCurrency(totalDRTDeposit)}</p>
              </div>
              {fitDivergence && (
                <p className="mt-3 text-xs text-orange-800">
                  ⚠ This total reflects the calculated FIT obligation. The FIT deposit check has been
                  overridden to <span className="font-mono font-semibold">{formatCurrency(fitDivergence.deposited)}</span>{' '}
                  — actual amount going to Treasurer of Guam differs from the total above by{' '}
                  <span className="font-mono font-semibold">{fitDivergence.delta > 0 ? '+' : ''}{formatCurrency(fitDivergence.delta)}</span>.
                  See the Non-Employee Checks section for edit history.
                </p>
              )}
            </div>
          </Card>
        )}
  </>);
}
