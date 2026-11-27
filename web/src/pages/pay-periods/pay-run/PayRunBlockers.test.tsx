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

it.each([200, 422])('submits the displayed revision and refreshes the banner after response %i', async (status) => {
  const reloadClientReview = vi.fn();
  const stale = { code: 'stale_payroll_review_revision', error: 'This review revision changed.' };
  const request = vi.fn().mockResolvedValue(new Response(status === 422 ? JSON.stringify(stale) : null, { status }));
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
    expect(screen.getByText('5 / 500 characters')).toBeTruthy();
    expect(screen.getByLabelText(/Override reason/).getAttribute('maxlength')).toBe('500');
    fireEvent.change(screen.getByLabelText(/Override reason/), { target: { value: 'Client requested staff approval.' } });
    fireEvent.click(submit);
    await waitFor(() => expect(reloadClientReview).toHaveBeenCalledOnce());
    if (status === 422) expect((await screen.findByRole('alert')).textContent).toContain(stale.error);
    expect(JSON.parse(request.mock.calls[0][1].body)).toMatchObject({
      revision_id: 91,
      acknowledgement: 'I am approving this exact payroll revision for the client under Cornerstone authority.',
      override_reason: 'Client requested staff approval.',
    });
  } finally {
    vi.unstubAllGlobals();
  }
});

it('renders the stale-calculation banner with Recalculate action and the unverified-changes banner', () => {
  const handleRunPayroll = vi.fn().mockResolvedValue(undefined);
  const props = {
    part: 'lifecycle',
    companyId: 7,
    canEditPayPeriod: true,
    handleRunPayroll,
    payPeriod: {
      id: 12,
      company_id: 7,
      status: 'calculated',
      stale_calculation_employees: [
        { payroll_item_id: 99, employee_id: 21, name: 'Jordan Sample', reason: 'Employee pay, withholding, tax ID, deductions, or status changed after calculation.' },
      ],
      unverified_employee_changes: [
        {
          id: 501,
          updated_at: '2026-11-28T01:00:00.000000Z',
          employee_id: 21,
          employee_name: 'Jordan Sample',
          event_kind: 'compensation_change',
          status: 'pending_verification',
          summary: 'Pay rate or compensation changed (pay rate)',
        },
      ],
    },
  } as unknown as ComponentProps<typeof PayRunBlockers>;

  render(<MemoryRouter><PayRunBlockers {...props} /></MemoryRouter>);

  expect(screen.getByText('Recalculate payroll — employee details changed after calculation')).toBeTruthy();
  expect(screen.getAllByText('Jordan Sample').length).toBeGreaterThanOrEqual(1);
  expect(screen.getByText('Changed since last payroll, not verified (1)')).toBeTruthy();
  expect(screen.getByText(/Pending verification/)).toBeTruthy();

  const staleAlert = document.getElementById('payroll-stale-calculation');
  const unverifiedAlert = document.getElementById('payroll-unverified-changes');
  expect(staleAlert?.getAttribute('tabindex')).toBe('-1');
  expect(unverifiedAlert?.getAttribute('tabindex')).toBe('-1');
  staleAlert?.focus();
  expect(document.activeElement).toBe(staleAlert);
  unverifiedAlert?.focus();
  expect(document.activeElement).toBe(unverifiedAlert);

  fireEvent.click(screen.getByRole('button', { name: 'Recalculate' }));
  expect(handleRunPayroll).toHaveBeenCalledOnce();
});

it('shows Mid-period pay change warnings on hours and approval steps without duplicating on lifecycle', () => {
  const payPeriod = {
    id: 12,
    company_id: 7,
    status: 'approved',
    compensation_warnings: ['Jordan Sample changed rate mid-period.'],
  };

  const { rerender } = render(
    <MemoryRouter>
      <PayRunBlockers {...({ part: 'hours', payPeriod } as unknown as ComponentProps<typeof PayRunBlockers>)} />
    </MemoryRouter>,
  );
  expect(screen.getByText(/Mid-period pay change\./)).toBeTruthy();

  rerender(
    <MemoryRouter>
      <PayRunBlockers {...({ part: 'approval', payPeriod } as unknown as ComponentProps<typeof PayRunBlockers>)} />
    </MemoryRouter>,
  );
  expect(screen.getByText(/Mid-period pay change\./)).toBeTruthy();

  rerender(
    <MemoryRouter>
      <PayRunBlockers {...({ part: 'lifecycle', payPeriod } as unknown as ComponentProps<typeof PayRunBlockers>)} />
    </MemoryRouter>,
  );
  expect(screen.queryByText(/Mid-period pay change\./)).toBeNull();
});
