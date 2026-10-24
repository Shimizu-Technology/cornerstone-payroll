

import { paymentMethodLabel } from '@/lib/employee-payment-delivery';

import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent } from '@/components/ui/card';

import { formatGuamDateTime } from '@/lib/utils';

import { AirePaymentEvidenceHolds } from '@/components/payroll/AirePaymentEvidenceHolds';
import { AireManualPaymentReconciliation } from '@/components/payroll/AireManualPaymentReconciliation';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunSupportingDetails({
  aireSourceRefreshToken,
  directDepositCount,
  invalidateAireSource,
  isCommitted,
  isVoided,
  lifecycleItems,
  loadPayPeriod,
  paperCheckCount,
  payPeriod,
  payableItems,
  payrollItems,
  setPaymentMethodItem
}: PayRunSectionProps<'supporting'>) {
  return (<>
<section aria-label="Supporting payroll details" className="space-y-4">
      {!isCommitted && payableItems.length > 0 && (
        <section className="mb-6 rounded-2xl border border-neutral-200 bg-white p-4" aria-label="Payment methods for this pay period">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <p className="font-semibold text-neutral-950">Payment methods for this run</p>
              <p className="mt-1 text-sm text-neutral-700">
                {paperCheckCount} paper checks · {directDepositCount} direct deposits. This changes the delivery method only; pay and taxes stay the same.
              </p>
            </div>
          </div>
          <p className="mt-2 text-xs text-neutral-600">A change here affects this run only. Change the employee profile to set the default for future runs. Unreviewed profiles safely default to paper check.</p>
          <div className="mt-4 grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
            {payableItems.map((item) => (
              <div key={item.id} className="flex min-w-0 flex-col items-stretch justify-between gap-3 rounded-xl border border-neutral-200 bg-neutral-50 px-3 py-2 text-sm sm:flex-row sm:items-center">
                <span className="min-w-0 sm:flex-1">
                  <span className="block break-words font-medium text-neutral-950 sm:truncate">{item.employee_name}</span>
                  {!item.employee_payment_delivery_method && <span className="block text-xs text-warning-700">Profile default not reviewed</span>}
                </span>
                <div className="text-right sm:shrink-0">
                  <p className="mb-1 text-xs text-neutral-600">{paymentMethodLabel(item.effective_payment_delivery_method || 'paper_check')}</p>
                  <Button size="sm" variant="outline" className="min-h-11 w-full sm:w-auto" aria-label={`Change payment method for ${item.employee_name}`} onClick={() => setPaymentMethodItem(item)}>Change payment method</Button>
                </div>
              </div>
            ))}
          </div>
        </section>
      )}

          <div id="manual-time-reconciliation" tabIndex={-1} className="scroll-mt-24 space-y-4">
        {(payPeriod.time_tracking?.active_source_capabilities?.includes('payroll_cockpit') || payPeriod.time_tracking?.active_source_types.includes('aire_services')) && (
          <div className="space-y-4">
            <AirePaymentEvidenceHolds key={`payment-evidence-${payPeriod.id}`} payPeriodId={payPeriod.id}
              refreshToken={aireSourceRefreshToken}
              onChanged={() => { invalidateAireSource(); void loadPayPeriod(payPeriod.id, true, true); }} />
            <AireManualPaymentReconciliation key={`manual-reconciliation-${payPeriod.id}`} payPeriodId={payPeriod.id}
              payPeriodStatus={payPeriod.status} payPeriodVoided={isVoided} payrollItems={payrollItems}
              refreshToken={aireSourceRefreshToken}
              onChanged={() => { invalidateAireSource(); void loadPayPeriod(payPeriod.id, true, true); }} />
          </div>
        )}
          </div>
          <details className="rounded-2xl border border-neutral-200 bg-white p-4">
            <summary className="cursor-pointer py-1 font-semibold text-primary-800">Run notes and processing history</summary>
            <div className="mt-4 space-y-4">
        {payPeriod.notes && (
          <Card className="border-blue-100 bg-blue-50/60">
            <CardContent className="py-4">
              <p className="text-xs font-semibold text-blue-700">Pay Period Notes</p>
              <p className="mt-2 whitespace-pre-wrap text-sm leading-relaxed text-blue-950">{payPeriod.notes}</p>
            </CardContent>
          </Card>
        )}

        <Card>
          <div className="border-b px-4 py-3">
            <h3 className="text-base font-semibold text-neutral-900">Processing Timeline</h3>
            <p className="text-sm text-neutral-600">
              Guam timestamps for payroll lifecycle and operator actions.
            </p>
          </div>
          <div className="grid gap-0 divide-y divide-neutral-100 sm:grid-cols-2 sm:divide-x sm:divide-y-0 lg:grid-cols-[repeat(auto-fit,minmax(11rem,1fr))]">
            {lifecycleItems.map((item) => (
              <div key={item.label} className="min-w-0 p-4">
                <div className="mb-2 flex items-center gap-2">
                  <Badge variant={item.timestamp ? item.tone : 'outline'}>
                    {item.label}
                  </Badge>
                </div>
                <p className="text-sm font-medium text-neutral-900">
                  {item.timestamp ? formatGuamDateTime(item.timestamp) : 'Not recorded'}
                </p>
                <p className={`mt-1 text-xs ${item.timestamp ? 'text-neutral-600' : 'text-neutral-600'}`}>
                  {item.timestamp ? item.actor : 'No audit timestamp yet'}
                </p>
              </div>
            ))}
          </div>
        </Card>

            </div>
          </details>
        </section>
  </>);
}
