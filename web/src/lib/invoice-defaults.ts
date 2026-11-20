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

export function invoiceDraftDueDate<T extends { invoice_date: string; due_date: string; payment_terms: string; due_date_manual?: boolean }>(draft: T): T {
  if (draft.due_date_manual || !draft.invoice_date) return draft;
  const terms = draft.payment_terms.trim();
  const days = terms.match(/^Net\s+(\d+)$/i)?.[1];
  if (!days && terms.toLowerCase() !== 'due on receipt') return { ...draft, due_date: '' };
  const date = new Date(`${draft.invoice_date}T12:00:00Z`);
  if (!Number.isFinite(date.getTime())) return draft;
  date.setUTCDate(date.getUTCDate() + Number(days || 0));
  return { ...draft, due_date: date.toISOString().slice(0, 10) };
}
