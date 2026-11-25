import { expect, it } from 'vitest';
import { clientPayrollStatus, clientPayRunStatus } from './clientPayrollStatus';

it.each([
  ['draft', undefined, 'Being prepared'],
  ['approved', 'pending', 'Ready for your review'],
  ['approved', 'approved', 'Client approved'],
  ['committed', 'approved', 'Finalized'],
  ['locked', undefined, 'Imported (read-only)'],
])('labels %s payroll consistently', (status, review, label) => {
  expect(clientPayRunStatus({ status, client_review_status: review })).toBe(label);
  expect(clientPayrollStatus(status === 'approved' ? review : status)).toBe(label);
});
