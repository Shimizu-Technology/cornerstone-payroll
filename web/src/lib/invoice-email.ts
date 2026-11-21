/**
 * The default email for an invoice, as the API writes it
 * (InvoiceEmailContent). The API is the source for saved invoices; this
 * copy previews the default while a draft is being edited.
 *
 *   Subject: Invoice 07052 - MoSa's Hot Box, Inc. - November 2026
 *   Body:    Hello, / attached invoice with amount and due date / footer or thanks / sender
 */
export interface InvoiceEmailInput {
  number: string;
  customer?: string | null;
  invoiceDate?: string | null;
  serviceStart?: string | null;
  serviceEnd?: string | null;
  amountDue: number;
  currency?: string | null;
  paymentTerms?: string | null;
  dueDate?: string | null;
  footer?: string | null;
  sender?: string | null;
}

export const DEFAULT_INVOICE_FOOTER = 'Thank you for your business.';

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

function parts(date: string) {
  const [year, month, day] = date.slice(0, 10).split('-').map(Number);
  return { year, month, day };
}

const monthYear = (date: string) => `${MONTHS[parts(date).month - 1]} ${parts(date).year}`;
const fullDate = (date: string) => { const p = parts(date); return `${MONTHS[p.month - 1]} ${p.day}, ${p.year}`; };
const lastDayOfMonth = (date: string) => { const p = parts(date); return new Date(Date.UTC(p.year, p.month, 0)).getUTCDate(); };

/** Whole calendar months read as months; any other span reads as dates. */
export function invoiceServiceLabel(input: Pick<InvoiceEmailInput, 'invoiceDate' | 'serviceStart' | 'serviceEnd'>): string | null {
  const { serviceStart: start, serviceEnd: end } = input;
  if (!start || !end) return input.invoiceDate ? monthYear(input.invoiceDate) : null;
  const s = parts(start);
  const e = parts(end);
  if (s.day === 1 && e.day === lastDayOfMonth(end)) {
    if (s.year === e.year && s.month === e.month) return monthYear(start);
    if (s.year === e.year) return `${MONTHS[s.month - 1]} - ${monthYear(end)}`;
    return `${monthYear(start)} - ${monthYear(end)}`;
  }
  if (start.slice(0, 10) === end.slice(0, 10)) return fullDate(start);
  return `${fullDate(start)} - ${fullDate(end)}`;
}

function amount(value: number, currency?: string | null) {
  const formatted = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(value);
  const code = (currency || 'USD').toUpperCase();
  return code === 'USD' ? `$${formatted}` : `${code} ${formatted}`;
}

export function defaultInvoiceEmail(input: InvoiceEmailInput): { subject: string; body: string } {
  const service = invoiceServiceLabel(input);
  const subject = [`Invoice ${input.number}`, input.customer?.trim() || null, service].filter(Boolean).join(' - ');
  const due = (input.paymentTerms || '').trim().toLowerCase() === 'due on receipt'
    ? 'due on receipt'
    : input.dueDate ? `due by ${fullDate(input.dueDate)}` : null;
  const lines = [
    'Hello,',
    '',
    `Please find attached invoice ${input.number}${service ? ` for ${service}` : ''}. The amount due is ${[amount(input.amountDue, input.currency), due].filter(Boolean).join(', ')}.`,
    '',
    input.footer?.trim() || DEFAULT_INVOICE_FOOTER,
  ];
  if (input.sender?.trim()) lines.push(input.sender.trim());
  return { subject, body: lines.join('\n') };
}
