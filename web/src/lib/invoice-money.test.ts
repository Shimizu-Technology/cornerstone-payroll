import { describe, expect, it } from 'vitest';
import { invoiceSubtotal, invoicePercentDiscount, roundInvoiceCurrency } from './invoice-money';

describe('invoice currency calculations', () => {
  it('rounds percentage discounts to cents like the invoice API', () => {
    const discount = invoicePercentDiscount(0.29, 50);
    expect(discount).toBe(0.15);
    expect(roundInvoiceCurrency(0.29 - discount)).toBe(0.14);
  });

  it('rounds negative ties away from zero without moving nearby values across the boundary', () => {
    expect(roundInvoiceCurrency(-0.145)).toBe(-0.15);
    expect(roundInvoiceCurrency(0.145)).toBe(0.15);
    expect(roundInvoiceCurrency(0.14499999999999996)).toBe(0.14);
    expect(roundInvoiceCurrency(-0.14499999999999996)).toBe(-0.14);
  });
});

it('sums rounded cents exactly before discount calculation and validation', () => {
  const subtotal = invoiceSubtotal([{ quantity: 0.5, rate: 0.69 }, { quantity: 0.5, rate: 0.19 }]);
  expect(subtotal).toBe(0.45);
  expect(invoicePercentDiscount(subtotal, 10)).toBe(0.05);
  expect(roundInvoiceCurrency(subtotal - invoicePercentDiscount(subtotal, 10))).toBe(0.4);
  expect(0.45 > subtotal).toBe(false);
});
