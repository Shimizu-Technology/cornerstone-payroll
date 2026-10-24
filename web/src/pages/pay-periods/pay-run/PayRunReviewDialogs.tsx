

import { PayrollItemReviewDialog } from '@/components/payroll/PayrollItemReviewDialog';
import { PaymentMethodDialog } from '@/components/payroll/PaymentMethodDialog';

import type { PayRunSectionProps } from './usePayRunController';

export function PayRunReviewDialogs({
  companyId,
  currentPath,
  loadPayPeriod,
  payPeriod,
  payRunId,
  paymentMethodItem,
  reviewingItem,
  setPaymentMethodItem,
  setReviewingItem
}: PayRunSectionProps<'reviewDialogs'>) {
  return (<>
<PaymentMethodDialog payPeriod={payPeriod} item={paymentMethodItem} onClose={() => setPaymentMethodItem(null)} onSaved={async () => {
        const result = await loadPayPeriod(payPeriod.id, true);
        if (result === 'failed') throw new Error('Saved payment method could not refresh.');
      }} />
<PayrollItemReviewDialog companyId={companyId} payRunId={payRunId} item={reviewingItem} returnTo={currentPath} onClose={() => setReviewingItem(null)} />
  </>);
}
