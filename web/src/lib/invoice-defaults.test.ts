import { expect, it } from 'vitest';
import { customerDefaults, invoiceBusinessDate, invoiceIsOverdue } from './invoice-defaults';

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
  expect(customerDefaults({ payment_terms: '', line_items: [{ rate: 0 }] }, customer)).toEqual({ payment_terms: 'Net 30', line_items: [{ rate: 500 }] });
  expect(customerDefaults({ payment_terms: 'Net 15', line_items: [{ rate: 700 }] }, customer)).toEqual({ payment_terms: 'Net 15', line_items: [{ rate: 700 }] });
});
