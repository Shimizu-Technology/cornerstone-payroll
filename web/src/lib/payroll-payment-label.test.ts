import { describe, expect, it } from 'vitest';
import type { PayrollItem } from '@/types';
import { payRunPaymentDisplay, payrollPaymentLabel } from './payroll-payment-label';

describe('payrollPaymentLabel', () => {
  it('uses the saved direct-deposit method and distinguishes zero-net statements', () => {
    expect(payrollPaymentLabel({ record_type: 'native', payment_delivery_method: 'direct_deposit', net_pay: 700 })).toBe('Direct deposit');
    expect(payrollPaymentLabel({ record_type: 'native', payment_delivery_method: 'direct_deposit', net_pay: 0 })).toBe('$0 net · earnings statement only');
    expect(payrollPaymentLabel({ record_type: 'native', net_pay: 700 })).toBe('Paper check · not assigned');
    expect(payrollPaymentLabel({ record_type: 'native', net_pay: 700, check_number: '100' })).toBe('Paper check');
  });

  it('does not describe negative native corrections as deposit or paper-check payments', () => {
    expect(payrollPaymentLabel({ record_type: 'native', payment_delivery_method: 'direct_deposit', net_pay: -50 })).toBe('Adjustment — no payment issued');
    expect(payrollPaymentLabel({ record_type: 'native', payment_delivery_method: 'paper_check', net_pay: -50, check_number: '100' })).toBe('Adjustment — no payment issued');
  });

  it('preserves imported evidence and leaves an absent method unknown', () => {
    expect(payrollPaymentLabel({ record_type: 'imported', payment_method: 'Direct Deposit', net_pay: 700 })).toBe('Direct deposit');
    expect(payrollPaymentLabel({ record_type: 'imported', net_pay: 700 })).toBe('Not recorded');
    expect(payrollPaymentLabel({ record_type: 'imported', payment_method: 'Cash' })).toBe('Cash');
    expect(payrollPaymentLabel({ record_type: 'adjustment', net_pay: 100 })).toBe('Adjustment — no payment issued');
  });
});

describe('payRunPaymentDisplay action eligibility', () => {
  const item = { net_pay: 500, gross_pay: 600, effective_payment_delivery_method: 'direct_deposit' } as PayrollItem;
  it('exposes the guarded change dialog before and after commitment', () => {
    for (const committed of [false, true]) expect(payRunPaymentDisplay(item, { committed, rehearsal: false, canPreview: false }).canChange).toBe(true);
  });
  it('keeps rehearsal, zero-net and voided rows without a payment-change action', () => {
    const options = { committed: false, rehearsal: false, canPreview: false };
    expect(payRunPaymentDisplay(item, { ...options, rehearsal: true }).canChange).toBe(false);
    expect(payRunPaymentDisplay({ ...item, net_pay: 0 }, options).canChange).toBe(false);
    expect(payRunPaymentDisplay({ ...item, voided: true }, options).canChange).toBe(false);
  });
});
