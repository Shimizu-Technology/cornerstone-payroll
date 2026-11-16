// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, it } from 'vitest';
import { MemoryRouter } from 'react-router';
import type { ComponentProps } from 'react';
import { PayRunBlockers } from './PayRunBlockers';
afterEach(cleanup);
it('describes a finalized pending review as retained history without asking for staff approval', () => {
  const props = { part: 'approval', payPeriod: { id: 12, status: 'committed', client_payroll_approval_required: false,
    payroll_review: { id: 91, revision: 1, status: 'pending', published_at: '2026-11-17', checksum_short: 'abc' } },
    calculationFailures: [], standaloneLoanConflicts: [],
  } as unknown as ComponentProps<typeof PayRunBlockers>;
  render(<MemoryRouter><PayRunBlockers {...props} /></MemoryRouter>);
  expect(screen.getByText(/Payroll finalized/)).toBeTruthy();
  expect(screen.getByText('Payroll is finalized. This review is retained as history.')).toBeTruthy();
  expect(screen.queryByText(/Approve payroll to publish preview/)).toBeNull();
  expect(screen.queryByRole('button', { name: 'Record Email Approval' })).toBeNull();
});
it('explains disabled review on an open run without offering email approval', () => {
  const props = { part: 'approval', payPeriod: { id: 12, status: 'approved', client_payroll_approval_required: false,
    payroll_review: { id: 91, revision: 1, status: 'pending', published_at: '2026-11-17', checksum_short: 'abc' } },
  } as unknown as ComponentProps<typeof PayRunBlockers>;
  render(<MemoryRouter><PayRunBlockers {...props} /></MemoryRouter>);
  expect(screen.getByText(/Client review revision 1 · Client review disabled/)).toBeTruthy();
  expect(screen.getByText('Client review is disabled. This preview is retained as history; staff can commit without a client decision.')).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Record Email Approval' })).toBeNull();
});
