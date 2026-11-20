export const invoiceBusinessDate = (now = new Date()) => new Intl.DateTimeFormat('en-CA', { timeZone: 'Pacific/Guam', year: 'numeric', month: '2-digit', day: '2-digit' }).format(now);

export const invoiceIsOverdue = (invoice: { base_status?: string; balance_due: number; due_date?: string | null }, today = invoiceBusinessDate()) => invoice.base_status === 'open' && invoice.balance_due > 0 && !!invoice.due_date && invoice.due_date < today;

export function customerDefaults<T extends { payment_terms: string; customerDefaultTerms?: boolean; line_items: { rate: number; customerDefaultRate?: boolean }[] }>(draft: T, customer?: { payment_terms?: string | null; default_rate?: number | null }): T {
  const inheritTerms = draft.customerDefaultTerms === true || (draft.customerDefaultTerms === undefined && !draft.payment_terms);
  return { ...draft, payment_terms: inheritTerms ? customer?.payment_terms || '' : draft.payment_terms,
    customerDefaultTerms: inheritTerms,
    line_items: draft.line_items.map((line) => {
      const inheritRate = line.customerDefaultRate === true || (line.customerDefaultRate === undefined && !line.rate);
      return { ...line, rate: inheritRate ? customer?.default_rate || 0 : line.rate, customerDefaultRate: inheritRate };
    }) };
}
