

import { Card } from '@/components/ui/card';

import { CorrectionPanel } from '@/components/payroll/CorrectionPanel';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunCorrections({
  commitRouteGenerationRef,
  correctionRouteGeneration,
  isCommitted,
  isCorrection,
  isVoided,
  loadPayPeriod,
  payPeriod,
  payRunId,
  returnTo,
  setCheckPrintRefreshToken,
  setPayPeriod,
  setPayrollItems
}: PayRunSectionProps<'corrections'>) {
  return (<>
{(isCommitted || isVoided || isCorrection) && (
          <Card>
            <div className="p-4 border-b">
              <h3 className="font-semibold text-neutral-900">Payroll Corrections</h3>
              <p className="text-sm text-neutral-600 mt-0.5">
                Void this period, create a correction re-run, or review correction history.
              </p>
            </div>
            <div className="p-4">
              <CorrectionPanel
                payPeriod={payPeriod}
                returnTo={returnTo}
                onPayPeriodChange={(updated) => {
                  if (updated.id !== payRunId || updated.company_id !== payPeriod.company_id ||
                      correctionRouteGeneration !== commitRouteGenerationRef.current) return;
                  setPayPeriod(current => current?.id === updated.id ? {
                    ...current, ...updated, payroll_items: updated.payroll_items ?? current.payroll_items,
                  } : current);
                  if (updated.payroll_items) setPayrollItems(updated.payroll_items);
                  setCheckPrintRefreshToken(token => token + 1);
                  void loadPayPeriod(updated.id, true);
                }}
              />
            </div>
          </Card>
        )}
  </>);
}
