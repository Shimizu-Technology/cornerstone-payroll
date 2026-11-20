import Decimal from 'decimal.js';

export function roundInvoiceCurrency(value: number): number {
  return new Decimal(value).toDecimalPlaces(2, Decimal.ROUND_HALF_UP).toNumber();
}

export function invoicePercentDiscount(subtotal: number, percentage: number): number {
  return new Decimal(subtotal).times(percentage).div(100).toDecimalPlaces(2, Decimal.ROUND_HALF_UP).toNumber();
}

export function invoiceLineAmount(quantity: number, rate: number): number {
  return new Decimal(quantity).times(rate).toDecimalPlaces(2, Decimal.ROUND_HALF_UP).toNumber();
}

export function invoiceSubtotal(lines: { quantity: number; rate: number }[]): number {
  return lines.reduce((sum, line) => sum.plus(invoiceLineAmount(line.quantity, line.rate)), new Decimal(0)).toNumber();
}
