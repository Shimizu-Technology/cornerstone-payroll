import { describe, expect, it } from 'vitest';
import type { PayrollItem } from '@/types';
import { needsBankPaymentConfirmation, paymentEvidenceLabel, payRunPaymentDisplay, payrollPaymentLabel } from './payroll-payment-label';

describe('payrollPaymentLabel', () => {
  it("shows the server's wording for each saved payment", () => {
    expect(payrollPaymentLabel({ payment_method_label: 'Direct deposit' })).toBe('Direct deposit');
    expect(payrollPaymentLabel({ payment_method_label: 'Adjustment — no payment issued' })).toBe('Adjustment — no payment issued');
  });

  it('leaves a record without a recorded method unknown', () => {
    expect(payrollPaymentLabel({})).toBe('Not recorded');
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

describe('paymentEvidenceLabel', () => {
  it('keeps an unconfirmed direct deposit open for staff to confirm', () => {
    const unconfirmed = { payment_delivery_method: 'direct_deposit', payment_evidence: { status: 'unissued', label: 'Transfer not confirmed' } };
    expect(paymentEvidenceLabel(unconfirmed)).toBe('Bank payment not confirmed yet');
    expect(needsBankPaymentConfirmation(unconfirmed)).toBe(true);
    const confirmed = { payment_delivery_method: 'direct_deposit', payment_evidence: { status: 'issued', label: 'Transfer confirmed' } };
    expect(paymentEvidenceLabel(confirmed)).toBe('Transfer confirmed');
    expect(needsBankPaymentConfirmation(confirmed)).toBe(false);
    expect(needsBankPaymentConfirmation({ payment_delivery_method: 'paper_check', payment_evidence: { status: 'unissued', label: 'Issue not recorded' } })).toBe(false);
  });

  it('keeps the server wording for confirmed transfers, checks and missing evidence', () => {
    expect(paymentEvidenceLabel({ payment_delivery_method: 'direct_deposit', payment_evidence: { status: 'issued', label: 'Transfer confirmed' } })).toBe('Transfer confirmed');
    expect(paymentEvidenceLabel({ payment_delivery_method: 'paper_check', payment_evidence: { status: 'unissued', label: 'Issue not recorded' } })).toBe('Issue not recorded');
    expect(paymentEvidenceLabel({ payment_delivery_method: 'direct_deposit' })).toBe('Payment evidence not available');
  });
});
