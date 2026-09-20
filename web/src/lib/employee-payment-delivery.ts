import type { Employee } from '@/types';

export function employeePaymentDelivery(employee: Pick<Employee, 'payment_delivery_method'>) {
  switch (employee.payment_delivery_method) {
    case 'direct_deposit':
      return {
        label: 'Direct deposit',
        detail: 'Future pay runs use direct deposit by default. Cornerstone prepares an earnings stub; the bank transfer is handled and confirmed outside the app.',
      };
    case 'paper_check':
      return {
        label: 'Paper check',
        detail: 'Future pay runs use paper checks by default. A check number is assigned when a payable run is committed.',
      };
    default:
      return {
        label: 'Paper check (default)',
        detail: 'Payment method has not been reviewed. Future pay runs default to paper check until a method is selected.',
      };
  }
}
