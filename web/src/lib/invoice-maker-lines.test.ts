import { expect, it } from 'vitest';
import { invoicePreviewLines, newManualInvoiceLine } from './invoice-maker-lines';

it('adds the monthly fee once in the manual editor and starts later lines at zero', () => {
  const first = newManualInvoiceLine([], 3000);
  const second = newManualInvoiceLine([first], 3000);
  expect([first.rate, second.rate]).toEqual([3000, 0]);
  expect(newManualInvoiceLine([{ ...first, line_kind: 'reimbursement', rate: 125 }], 3000).rate).toBe(3000);
  expect(newManualInvoiceLine([{ ...first, _destroy: true }], 3000).rate).toBe(3000);
  expect(newManualInvoiceLine([{ ...first, rate: 0 }], 3000).rate).toBe(0);
});
it('resolves omitted AI rates for the first service fee before converting to numeric form', () => {
  const lines = invoicePreviewLines([
    { description: 'Tax payment', item_name: 'Reimbursement', line_kind: 'reimbursement', quantity: 1 },
    { description: 'Monthly accounting', item_name: 'Accounting Consulting', quantity: 1, rate: null },
    { description: 'Extra service', quantity: 1 },
    { description: 'Travel payment', line_kind: 'reimbursement', quantity: 1, rate: 125 },
  ], 3000);
  expect(lines.map((line) => line.rate)).toEqual([0, 3000, 0, 125]);
  expect(lines.map((line) => line.amount)).toEqual([0, 3000, 0, 125]);
  expect(lines[0]).toMatchObject({ item_name: 'Reimbursement', line_kind: 'reimbursement' });
});
it('preserves explicit zero and positive AI fees and does not shift the default to later fees', () => {
  for (const rate of [0, 700]) {
    expect(invoicePreviewLines([
      { description: 'Explicit fee', quantity: 1, rate },
      { description: 'Extra fee', quantity: 1 },
    ], 3000).map((line) => line.rate)).toEqual([rate, 0]);
  }
});
