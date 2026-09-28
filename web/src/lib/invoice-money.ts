import Decimal from 'decimal.js';

export function roundInvoiceCurrency(value: number): number {
  return new Decimal(value).toDecimalPlaces(2, Decimal.ROUND_HALF_UP).toNumber();
}

export function invoicePercentDiscount(subtotal: number, percentage: number): number {
  return new Decimal(subtotal).times(percentage).div(100).toDecimalPlaces(2, Decimal.ROUND_HALF_UP).toNumber();
}
