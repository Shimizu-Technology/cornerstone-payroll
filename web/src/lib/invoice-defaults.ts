export const invoiceBusinessDate = (now = new Date()) => new Intl.DateTimeFormat('en-CA', { timeZone: 'Pacific/Guam', year: 'numeric', month: '2-digit', day: '2-digit' }).format(now);

export const invoiceIsOverdue = (invoice: { base_status?: string; balance_due: number; due_date?: string | null }, today = invoiceBusinessDate()) => invoice.base_status === 'open' && invoice.balance_due > 0 && !!invoice.due_date && invoice.due_date < today;

export function customerDefaults<T extends { payment_terms: string; line_items: { rate: number }[] }>(draft: T, customer?: { payment_terms?: string | null; default_rate?: number | null }): T {
  return { ...draft, payment_terms: draft.payment_terms || customer?.payment_terms || '', line_items: draft.line_items.map((line) => ({ ...line, rate: line.rate || customer?.default_rate || 0 })) };
}
