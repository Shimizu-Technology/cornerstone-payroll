import { describe, expect, it } from 'vitest';
import { EMAIL_SUBJECT_MAX, defaultInvoiceEmail, defaultInvoiceSubject, invoiceServiceLabel } from './invoice-email';

describe('defaultInvoiceEmail', () => {
  it('matches the API default (InvoiceEmailContent) for the office example', () => {
    const email = defaultInvoiceEmail({
      number: '07052', customer: "MoSa's Hot Box, Inc.", invoiceDate: '2026-11-30', serviceStart: '2026-11-01', serviceEnd: '2026-11-30',
      amountDue: 300, currency: 'USD', paymentTerms: 'Net 15', dueDate: '2026-12-15', footer: null, sender: 'Cornerstone Payroll LLC',
    });
    expect(email.subject).toBe("Invoice 07052 - MoSa's Hot Box, Inc. - November 2026");
    expect(email.body).toBe([
      'Hello,',
      '',
      'Please find attached invoice 07052 for November 2026. The amount due is $300.00, due by December 15, 2026.',
      '',
      'Thank you for your business.',
      'Cornerstone Payroll LLC',
    ].join('\n'));
  });

  it('says due on receipt, uses the footer, and groups thousands', () => {
    const email = defaultInvoiceEmail({ number: '07053', customer: 'Acme', invoiceDate: '2026-12-01', amountDue: 1250.5, paymentTerms: 'Due on receipt', footer: 'Mahalo!' });
    expect(email.subject).toBe('Invoice 07053 - Acme - December 2026');
    expect(email.body).toContain('The amount due is $1,250.50, due on receipt.');
    expect(email.body.endsWith('Mahalo!')).toBe(true);
  });
});

describe('defaultInvoiceSubject', () => {
  it('shortens a long customer name so the subject fits, keeping the number and month', () => {
    const subject = defaultInvoiceSubject('07052', 'A'.repeat(400), 'November 2026');
    expect(subject.length).toBe(EMAIL_SUBJECT_MAX);
    expect(subject.startsWith('Invoice 07052 - AAA')).toBe(true);
    expect(subject.endsWith('A… - November 2026')).toBe(true);
    expect(defaultInvoiceSubject('07052', 'Acme  \n Bakery', 'November 2026')).toBe('Invoice 07052 - Acme Bakery - November 2026');
  });
});

describe('invoiceServiceLabel', () => {
  it('reads whole months as months and other spans as dates', () => {
    expect(invoiceServiceLabel({ serviceStart: '2026-10-01', serviceEnd: '2026-11-30' })).toBe('October - November 2026');
    expect(invoiceServiceLabel({ serviceStart: '2026-12-01', serviceEnd: '2027-01-31' })).toBe('December 2026 - January 2027');
    expect(invoiceServiceLabel({ serviceStart: '2026-11-03', serviceEnd: '2026-11-09' })).toBe('November 3, 2026 - November 9, 2026');
    expect(invoiceServiceLabel({ serviceStart: '2026-02-01', serviceEnd: '2026-02-28' })).toBe('February 2026');
    expect(invoiceServiceLabel({ invoiceDate: '2026-11-21' })).toBe('November 2026');
  });
});
