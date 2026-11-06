

import { Link } from 'react-router';

import { Card } from '@/components/ui/card';

import { formatCurrency } from '@/lib/utils';

import { payRunPath } from '@/lib/routes';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunLinkedCorrections({
  companyId,
  currentPath,
  isCommitted,
  payPeriod,
  supplementals,
  supplementalsLoading
}: PayRunSectionProps<'linkedCorrections'>) {
  return (<>
{isCommitted && payPeriod.cycle !== 'supplemental' && (supplementals.length > 0 || supplementalsLoading) && (
          <Card className="border-warning-200">
            <div className="p-4 border-b border-warning-200 bg-warning-50">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <h3 className="font-semibold text-warning-900">
                    Linked Corrections {supplementals.length > 0 && `(${supplementals.length})`}
                  </h3>
                  <p className="text-xs text-warning-800 mt-0.5">
                    Off-cycle supplemental periods that adjust this committed period.
                    YTDs, W-2s, reports, and configured downstream syncs include these corrections.
                  </p>
                </div>
              </div>
            </div>
            <div className="divide-y">
              {supplementals.map(sp => (
                <div key={sp.id} className="p-4 flex items-start justify-between gap-3">
                  <div className="flex-1 min-w-0">
                    <div className="flex items-baseline gap-2">
                      <Link
                        to={payRunPath(companyId, sp.id, 'work', { returnTo: currentPath })}
                        className="text-sm font-semibold text-blue-700 hover:underline"
                      >
                        Supplemental period · pay date {sp.pay_date}
                      </Link>
                      {sp.tax_sync_status && (
                        <span className="text-xs text-neutral-600">
                          {sp.tax_sync_status === 'synced' ? 'tax-synced' : `tax-sync ${sp.tax_sync_status}`}
                        </span>
                      )}
                    </div>
                    {sp.payroll_items.map(it => (
                      <div key={it.id} className="mt-1.5 grid grid-cols-1 gap-x-4 gap-y-0.5 text-xs text-neutral-700 sm:grid-cols-2">
                        <div>
                          <span className="font-medium text-neutral-900">{it.employee_name}</span>
                          {it.check_number && (
                            <span className="text-neutral-600"> · check #{it.check_number}</span>
                          )}
                        </div>
                        <div className="sm:text-right">
                          Δ gross {formatCurrency(it.gross_pay)} ·
                          Δ FIT {formatCurrency(it.withholding_tax)} ·
                          Δ net <strong>{formatCurrency(it.net_pay)}</strong>
                        </div>
                        {it.correction_reason && (
                          <div className="sm:col-span-2 italic text-neutral-600">
                            “{it.correction_reason}”
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                </div>
              ))}
            </div>
          </Card>
        )}
{payPeriod.cycle === 'supplemental' && payPeriod.corrects_pay_period_id && (
          <Card className="border-blue-200">
            <div className="p-4 bg-blue-50">
              <p className="text-sm text-blue-900">
                This is a <strong>supplemental (corrective) pay period</strong>{' '}
                tied to{' '}
                <Link
                  to={payRunPath(companyId, payPeriod.corrects_pay_period_id, 'work', { returnTo: currentPath })}
                  className="font-semibold underline"
                >
                  the original committed period
                </Link>
                . The figures here are <em>deltas</em> against that period;
                they're rolled into YTDs, W-2s, and reports automatically.
              </p>
            </div>
          </Card>
        )}
  </>);
}
