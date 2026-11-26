// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import type { ComponentProps } from 'react';
import { PayRunBlockers } from './PayRunBlockers';
afterEach(cleanup);
it('requires resolving a published change request even when client approval is disabled', () => {
  const props = { part: 'approval', payPeriod: { id: 12, status: 'approved', client_payroll_approval_required: false,
    payroll_review: { id: 91, revision: 1, status: 'changes_requested', published_at: '2026-11-17', checksum_short: 'abc',
      change_request_note: 'Correct the hours', changes_requested_by_name: 'Client' } },
  } as unknown as ComponentProps<typeof PayRunBlockers>;
  render(<MemoryRouter><PayRunBlockers {...props} /></MemoryRouter>);
  expect(screen.getByText("Resolve the client's change request before committing (unapprove to make changes).")).toBeTruthy();
  expect(screen.getByText('Correct the hours')).toBeTruthy();
  expect(screen.queryByText(/staff can commit without a client decision/)).toBeNull();
  expect(screen.queryByRole('button', { name: 'Record Email Approval' })).toBeNull();
});
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

it('offers the override to eligible admins and submits the displayed revision after confirmation', async () => {
  const reloadClientReview = vi.fn();
  const request = vi.fn().mockResolvedValue(new Response(null, { status: 200 }));
  vi.stubGlobal('fetch', request);
  try {
    const payPeriod = { id: 12, company_id: 3, status: 'approved', client_payroll_approval_required: true,
      payroll_review: { id: 91, revision: 1, status: 'pending', published_at: '2026-11-17' } };
    const props = { part: 'approval', payPeriod, reloadClientReview } as unknown as ComponentProps<typeof PayRunBlockers>;
    const renderBanner = (allowed: boolean) => <MemoryRouter><PayRunBlockers {...props}
      payPeriod={{ ...props.payPeriod, can_override_client_approval: allowed, can_record_client_approval: allowed }} /></MemoryRouter>;
    const view = render(renderBanner(false));
    expect(screen.queryByRole('button', { name: 'Approve for client' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Record Email Approval' })).toBeNull();
    view.rerender(renderBanner(true));
    fireEvent.click(screen.getByRole('button', { name: 'Approve for client' }));
    const submit = screen.getByRole<HTMLButtonElement>('button', { name: 'Confirm approval' });
    fireEvent.click(screen.getByRole('checkbox'));
    fireEvent.change(screen.getByLabelText(/Override reason/), { target: { value: 'short' } });
    expect(submit.disabled).toBe(true);
    fireEvent.change(screen.getByLabelText(/Override reason/), { target: { value: 'Client requested staff approval.' } });
    fireEvent.click(submit);
    await waitFor(() => expect(reloadClientReview).toHaveBeenCalledOnce());
    expect(JSON.parse(request.mock.calls[0][1].body)).toMatchObject({
      revision_id: 91,
      acknowledgement: 'I am approving this exact payroll revision for the client under Cornerstone authority.',
      override_reason: 'Client requested staff approval.',
    });
  } finally {
    vi.unstubAllGlobals();
  }
});
