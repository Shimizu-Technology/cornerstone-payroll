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

/** The API's limit on an email subject (Invoice::EMAIL_SUBJECT_MAX). */
export const EMAIL_SUBJECT_MAX = 300;
const SEPARATOR = ' - ';

function truncate(text: string, length: number): string {
  return text.length <= length ? text : `${text.slice(0, Math.max(0, length - 1))}…`;
}

/** Always fits EMAIL_SUBJECT_MAX; a long customer name is shortened first, keeping the number and month. */
export function defaultInvoiceSubject(number: string, customerName: string | null | undefined, service: string | null): string {
  const prefix = `Invoice ${number}`;
  const customer = (customerName || '').replace(/\s+/g, ' ').trim() || null;
  let subject = [prefix, customer, service].filter(Boolean).join(SEPARATOR);
  if (subject.length <= EMAIL_SUBJECT_MAX) return subject;
  if (customer) {
    const room = EMAIL_SUBJECT_MAX - prefix.length - SEPARATOR.length - (service ? service.length + SEPARATOR.length : 0);
    subject = [prefix, room >= 2 ? truncate(customer, room) : null, service].filter(Boolean).join(SEPARATOR);
  }
  return truncate(subject, EMAIL_SUBJECT_MAX);
}

export function defaultInvoiceEmail(input: InvoiceEmailInput): { subject: string; body: string } {
  const service = invoiceServiceLabel(input);
  const subject = defaultInvoiceSubject(input.number, input.customer, service);
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
