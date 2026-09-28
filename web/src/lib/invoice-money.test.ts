import { describe, expect, it } from 'vitest';
import { invoicePercentDiscount, roundInvoiceCurrency } from './invoice-money';

describe('invoice currency calculations', () => {
  it('rounds percentage discounts to cents like the invoice API', () => {
    const discount = invoicePercentDiscount(0.29, 50);
    expect(discount).toBe(0.15);
    expect(roundInvoiceCurrency(0.29 - discount)).toBe(0.14);
  });
});
