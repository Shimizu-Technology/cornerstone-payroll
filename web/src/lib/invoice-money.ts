export function roundInvoiceCurrency(value: number): number {
  const cents = value * 100;
  return Math.round(cents + Number.EPSILON * Math.max(1, Math.abs(cents))) / 100;
}

export function invoicePercentDiscount(subtotal: number, percentage: number): number {
  return roundInvoiceCurrency((subtotal * percentage) / 100);
}
