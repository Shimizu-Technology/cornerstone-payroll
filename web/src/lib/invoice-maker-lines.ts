import type { InvoiceAiPreview, InvoiceLineItem } from '@/services/api';
import { isInvoiceServiceFee } from './invoice-defaults';
import { invoiceLineAmount } from './invoice-money';

export function newManualInvoiceLine(lines: (InvoiceLineItem & { _destroy?: boolean })[], defaultRate = 0): InvoiceLineItem {
  const rate = lines.some(isInvoiceServiceFee) ? 0 : defaultRate;
  return { description: '', line_kind: 'service_fee', quantity: 1, rate, amount: rate, service_date: '', position: lines.length };
}

export function invoicePreviewLines(items: NonNullable<InvoiceAiPreview['line_items']>, defaultRate = 0): InvoiceLineItem[] {
  const firstFee = items.findIndex(isInvoiceServiceFee);
  return items.map((item, index) => {
    const rate = Number(item.rate ?? (index === firstFee ? defaultRate : 0));
    const quantity = Number(item.quantity || 0);
    return { ...item, line_kind: item.line_kind || 'service_fee', quantity, rate,
      amount: invoiceLineAmount(quantity, rate), service_date: item.service_date || '', position: index };
  });
}
