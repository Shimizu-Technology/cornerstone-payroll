import { expect, it } from 'vitest';
import { customerDefaults, invoiceBusinessDate, invoiceIsOverdue, invoiceDraftDueDate } from './invoice-defaults';

it('uses Guam date across the UTC midnight boundary', () => {
  expect(invoiceBusinessDate(new Date('2026-11-20T15:00:00Z'))).toBe('2026-11-21');
});
it('includes partially paid overdue balances but excludes settled or voided bills', () => {
  expect(invoiceIsOverdue({ base_status: 'open', balance_due: 90, due_date: '2026-10-21' }, '2026-11-20')).toBe(true);
  expect(invoiceIsOverdue({ base_status: 'voided', balance_due: 90, due_date: '2026-10-21' })).toBe(false);
  expect(invoiceIsOverdue({ base_status: 'open', balance_due: 0, due_date: '2026-10-21' })).toBe(false);
});
it('fills saved customer defaults and preserves entered values', () => {
  const customer = { payment_terms: 'Net 30', default_rate: 500 };
  expect(customerDefaults({ payment_terms: '', line_items: [{ rate: 0 }] }, customer)).toMatchObject({ payment_terms: 'Net 30', line_items: [{ rate: 500 }] });
  expect(customerDefaults({ payment_terms: 'Net 15', line_items: [{ rate: 700 }] }, customer)).toMatchObject({ payment_terms: 'Net 15', line_items: [{ rate: 700 }] });
});

it('replaces inherited defaults when switching clients, preserving manually edited zero rates', () => {
  const first = customerDefaults({ payment_terms: '', line_items: [{ rate: 0, customerDefaultRate: true }] }, { payment_terms: 'Net 30', default_rate: 500 });
  const second = customerDefaults(first, { payment_terms: 'Net 15', default_rate: 125 });
  expect(second).toMatchObject({ payment_terms: 'Net 15', line_items: [{ rate: 125 }] });
  const edited = customerDefaults({ ...second, customerDefaultTerms: false, payment_terms: 'Custom', line_items: [{ rate: 0, customerDefaultRate: false }] }, { payment_terms: 'Net 30', default_rate: 700 });
  expect(edited).toMatchObject({ payment_terms: 'Custom', line_items: [{ rate: 0 }] });
});

it('recomputes automatic draft due dates from terms and invoice dates across months', () => {
  const draft = { invoice_date: '2026-12-20', payment_terms: 'Net 15', due_date: '2026-11-17', due_date_manual: false };
  expect(invoiceDraftDueDate(draft).due_date).toBe('2027-01-04');
  expect(invoiceDraftDueDate({ ...draft, payment_terms: ' Net 30 ' }).due_date).toBe('2027-01-19');
  expect(invoiceDraftDueDate({ ...draft, payment_terms: 'Due on receipt' }).due_date).toBe('2026-12-20');
});
it('preserves a manually selected due date when terms or invoice date change', () => {
  expect(invoiceDraftDueDate({ invoice_date: '2026-12-02', payment_terms: 'Net 30', due_date: '2027-02-01', due_date_manual: true }).due_date).toBe('2027-02-01');
});
it('allows recovery from an empty invoice date and does not invent dates for custom terms', () => {
  expect(invoiceDraftDueDate({ invoice_date: '', payment_terms: 'Net 15', due_date: '' }).due_date).toBe('');
  expect(invoiceDraftDueDate({ invoice_date: '2026-12-02', payment_terms: 'See contract', due_date: '' }).due_date).toBe('');
});
