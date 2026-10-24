// @vitest-environment jsdom
import { act, cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AirePaymentEvidenceHolds } from './AirePaymentEvidenceHolds';
const mocks = vi.hoisted(() => ({ read: vi.fn(), create: vi.fn(), retract: vi.fn(), resolve: vi.fn(), retry: vi.fn(), allowed: true }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ hasCapability: () => mocks.allowed }) }));
vi.mock('@/services/api', () => ({ payPeriodsApi: {
  airePaymentEvidence: mocks.read, createAirePaymentHold: mocks.create, retractAirePaymentHold: mocks.retract,
  resolveAirePaymentHold: mocks.resolve, retryAirePaymentResolution: mocks.retry,
} }));
const uuid = '282bf986-dd27-46fa-bd70-65ebbc9d9cea';
const entry = { source_time_entry_id: '41', source_time_entry_version: 2, source_user_uuid: uuid,
  employee_name: 'Synthetic Worker', original_work_date: '2026-09-03', total_hours: 4 };
const hold = { id: '501', version: 3, source_time_entry_id: '41', source_time_entry_version: 2,
  source_user_uuid: uuid, employee_name: 'Synthetic Worker', work_date: '2026-09-03', hours: 4,
  status: 'pending_evidence', reason: 'Owner reported payment, check evidence pending', source_changed: true };
beforeEach(() => { vi.clearAllMocks(); mocks.allowed = true; mocks.read.mockResolvedValue({ candidates: [entry], payment_attestations: [] }); });
afterEach(cleanup);
describe('reported payment holds', () => {
  it('requires evidence reason and captured source version, and states that a hold is not payment', async () => {
    const user = userEvent.setup(); const onChanged = vi.fn();
    mocks.create.mockResolvedValue({ payment_attestation: hold });
    render(<AirePaymentEvidenceHolds payPeriodId={12} onChanged={onChanged} />);
    await user.selectOptions(await screen.findByLabelText('Source hours to hold'), '41');
    const button = screen.getByRole('button', { name: 'Record reported-payment hold' });
    expect(button.hasAttribute('disabled')).toBe(true);
    await user.type(screen.getByLabelText('Reporter and pending payment evidence'), hold.reason);
    await user.click(button);
    await waitFor(() => expect(mocks.create).toHaveBeenCalledWith(12, expect.objectContaining({
      source_time_entry_id: '41', source_user_uuid: uuid, expected_version: 2, reason: hold.reason, command_id: expect.any(String),
    })));
    expect(await screen.findByText(/no payroll payment was created/)).toBeTruthy();
    expect(onChanged).toHaveBeenCalledOnce();
  });
  it('permits explicit source-changed retraction and requires settlement review', async () => {
    const user = userEvent.setup(); mocks.read.mockResolvedValue({ candidates: [], payment_attestations: [hold] });
    mocks.retract.mockResolvedValue({ payment_attestation: { ...hold, status: 'retracted' } });
    render(<AirePaymentEvidenceHolds payPeriodId={12} onChanged={vi.fn()} />);
    await user.click(await screen.findByRole('button', { name: 'Retract hold' }));
    expect(screen.getByText(/Source changed after this hold/)).toBeTruthy();
    await user.type(screen.getByLabelText('Retraction reason'), 'Owner withdrew the report after checking delivery records');
    await user.click(screen.getByRole('button', { name: 'Confirm retraction' }));
    await waitFor(() => expect(mocks.retract).toHaveBeenCalledWith(12, '501', expect.objectContaining({ expected_version: 3, source_user_uuid: uuid })));
    expect(await screen.findByText(/Review settlement routing in time tracking Time Cards/)).toBeTruthy();
  });
  it('keeps reason and idempotency identity on uncertain retries and surfaces conflicts', async () => {
    const user = userEvent.setup(); mocks.create.mockRejectedValue(new Error('Source version changed'));
    render(<AirePaymentEvidenceHolds payPeriodId={12} onChanged={vi.fn()} />);
    await user.selectOptions(await screen.findByLabelText('Source hours to hold'), '41');
    await user.type(screen.getByLabelText('Reporter and pending payment evidence'), hold.reason);
    await user.click(screen.getByRole('button', { name: 'Record reported-payment hold' }));
    expect((await screen.findByRole('alert')).textContent).toContain('Source version changed');
    await user.click(screen.getByRole('button', { name: 'Record reported-payment hold' }));
    await waitFor(() => expect(mocks.create).toHaveBeenCalledTimes(2));
    expect(mocks.create.mock.calls[0][1].command_id).toEqual(mocks.create.mock.calls[1][1].command_id);
    expect((screen.getByLabelText('Reporter and pending payment evidence') as HTMLTextAreaElement).value).toEqual(hold.reason);
  });
  it('does not read or expose commands without historical reconciliation capability', () => {
    mocks.allowed = false;
    render(<AirePaymentEvidenceHolds payPeriodId={12} onChanged={vi.fn()} />);
    expect(mocks.read).not.toHaveBeenCalled();
    expect(screen.queryByText('Reported-payment holds')).toBeNull();
  });
  it('clears stale evidence when refresh fails', async () => {
    const user = userEvent.setup(); render(<AirePaymentEvidenceHolds payPeriodId={12} onChanged={vi.fn()} />);
    await screen.findByLabelText('Source hours to hold'); mocks.read.mockRejectedValue(new Error('time tracking unavailable'));
    await user.click(screen.getByRole('button', { name: 'Refresh payment evidence' }));
    expect(await screen.findByRole('alert')).toBeTruthy();
    expect(screen.queryByLabelText('Source hours to hold')).toBeNull();
  });
});


it('preserves a hold draft and settles its pending command through sibling refresh', async () => {
  const user = userEvent.setup(); const onChanged = vi.fn();
  let resolveCreate!: () => void;
  mocks.create.mockImplementation(() => new Promise<void>(resolve => { resolveCreate = resolve; }));
  const view = render(<AirePaymentEvidenceHolds payPeriodId={12} onChanged={onChanged} />);
  await user.selectOptions(await screen.findByLabelText('Source hours to hold'), '41');
  const reason = screen.getByLabelText('Reporter and pending payment evidence') as HTMLTextAreaElement;
  await user.type(reason, hold.reason);
  view.rerender(<AirePaymentEvidenceHolds payPeriodId={12} refreshToken={1} onChanged={onChanged} />);
  await waitFor(() => expect(screen.getByRole('button', { name: 'Record reported-payment hold' }).hasAttribute('disabled')).toBe(false));
  expect(reason.value).toBe(hold.reason);
  expect((screen.getByLabelText('Source hours to hold') as HTMLSelectElement).value).toBe('41');
  await user.click(screen.getByRole('button', { name: 'Record reported-payment hold' }));
  view.rerender(<AirePaymentEvidenceHolds payPeriodId={12} refreshToken={2} onChanged={onChanged} />);
  await waitFor(() => expect(mocks.read).toHaveBeenCalledTimes(3));
  mocks.read.mockResolvedValue({ candidates: [], payment_attestations: [hold] });
  await act(async () => resolveCreate());
  expect(await screen.findByText(/no payroll payment was created/)).toBeTruthy();
  await waitFor(() => expect(onChanged).toHaveBeenCalledOnce());
  expect(reason.value).toBe('');
  expect(screen.queryByRole('button', { name: 'Saving…' })).toBeNull();
});

it('preserves retraction reason while invalidating a hold removed by source refresh', async () => {
  const user = userEvent.setup();
  mocks.read.mockResolvedValue({ candidates: [], payment_attestations: [hold] });
  const view = render(<AirePaymentEvidenceHolds payPeriodId={12} onChanged={vi.fn()} />);
  await user.click(await screen.findByRole('button', { name: 'Retract hold' }));
  await user.type(screen.getByLabelText('Retraction reason'), 'Owner withdrew the report after checking delivery records');
  mocks.read.mockResolvedValue({ candidates: [], payment_attestations: [] });
  view.rerender(<AirePaymentEvidenceHolds payPeriodId={12} refreshToken={1} onChanged={vi.fn()} />);
  expect(await screen.findByText(/This hold is no longer available/)).toBeTruthy();
  expect((screen.getByLabelText('Retraction reason') as HTMLTextAreaElement).value).toBe('Owner withdrew the report after checking delivery records');
  expect(screen.getByRole('button', { name: 'Confirm retraction' }).hasAttribute('disabled')).toBe(true);
  expect(mocks.retract).not.toHaveBeenCalled();
  view.rerender(<AirePaymentEvidenceHolds payPeriodId={13} refreshToken={1} onChanged={vi.fn()} />);
  expect(await screen.findByLabelText('Reporter and pending payment evidence')).toHaveProperty('value', '');
});


const paymentOption = { payroll_item_id: 88, pay_period_id: 16, pay_date: '2026-09-18',
  gross_pay: 120, net_pay: 110, regular_hours: 4, overtime_hours: 0, payment_recorded_at: '2026-09-19T10:00:00Z',
  payment_method: 'paper_check', payment_reference: '001045', payment_effective_on: '2026-09-18',
  regular_hours_available: 4, overtime_hours_available: 0 };
const resolvableHold = { ...hold, source_changed: false, resolution_context: { available: true, reason: null,
  regular_hours: '4.00', overtime_hours: '0.00', total_hours: '4.00', weekly_context_fingerprint: 'a'.repeat(64) }, payment_options: [paymentOption] };
const savedMatch = { id: 99, source_payment_attestation_id: hold.id, payroll_item_id: 88, pay_period_id: 16,
  employee_name: hold.employee_name, original_work_date: hold.work_date, regular_hours: 4, overtime_hours: 0,
  status: 'pending', allocation_status: 'pending_commit', payment_method: 'paper_check', payment_reference: '001045',
  payment_effective_on: '2026-09-18', note: 'Verified unchanged hours and the existing delivered check', original_report: { reason: hold.reason, attested_at: '2026-09-10T10:00:00Z', hours: 4 },
  last_sync_error: 'Lost Source receipt', can_retry: true, hours_reserved: true };

it('shows lifecycle instants in Guam across a non-Guam midnight boundary while retaining business dates', async () => {
  const originalTimezone = process.env.TZ;
  process.env.TZ = 'America/Los_Angeles';
  try {
    const instant = '2026-09-18T15:30:00Z'; // Sep19 01:30 Guam, Sep18 08:30 Los Angeles.
    expect(new Date(instant).getDate()).toBe(18);
    mocks.read.mockResolvedValue({ candidates: [], resolution_access: true,
      payment_attestations: [{ ...resolvableHold, id: '503', payment_options: [{ ...paymentOption, payment_recorded_at: instant }] },
        { ...hold, id: '502', status: 'resolved', resolved_manual_allocation_id: 10, resolved_at: instant }],
      payment_resolutions: [{ ...savedMatch, status: 'matched', original_report: { ...savedMatch.original_report, attested_at: instant } }] });
    const user = userEvent.setup();
    render(<AirePaymentEvidenceHolds payPeriodId={12} onChanged={vi.fn()} />);
    await screen.findByText(/Reported Sep 19, 2026, 1:30:00 AM ChST/);
    expect(screen.getByText(/resolved Sep 19, 2026, 1:30:00 AM ChST/)).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Match existing payment' }));
    await user.selectOptions(screen.getByLabelText('Existing issued payroll payment'), '88');
    expect(screen.getByText(/Scheduled pay date Sep 18, 2026 · payment date Sep 18, 2026 · evidence recorded Sep 19, 2026, 1:30:00 AM ChST/)).toBeTruthy();
    expect(screen.getByText(/Synthetic Worker · Sep 3, 2026 · 4.00 hours/)).toBeTruthy();
  } finally {
    if (originalTimezone == null) delete process.env.TZ;
    else process.env.TZ = originalTimezone;
  }
});

it('matches exact existing payment with complete hours, useful evidence preview and no new payment', async () => {
  const user = userEvent.setup();
  mocks.read.mockResolvedValue({ candidates: [], payment_attestations: [resolvableHold], resolution_access: true, payment_resolutions: [] });
  mocks.resolve.mockResolvedValue({ payment_resolution: { ...savedMatch, status: 'matched' } });
  render(<AirePaymentEvidenceHolds payPeriodId={12} onChanged={vi.fn()} />);
  await user.click(await screen.findByRole('button', { name: 'Match existing payment' }));
  const submit = screen.getByRole('button', { name: 'Confirm existing payment match' });
  expect(submit.hasAttribute('disabled')).toBe(true);
  await user.selectOptions(screen.getByLabelText('Existing issued payroll payment'), '88');
  expect(screen.getByText(/Original payroll: 4.00 REG/).textContent).toContain('gross $120.00 · net $110.00');
  await user.type(screen.getByLabelText('Existing payment match reason'), savedMatch.note);
  await user.click(submit);
  expect(mocks.resolve).toHaveBeenCalledWith(12, '501', { source_user_uuid: uuid, payroll_item_id: 88, expected_version: 3, reason: savedMatch.note });
  expect(await screen.findByText(/no new payment was created/)).toBeTruthy();
});

it('keeps a pending server match visible across remount, blocks retraction and retries only its saved reservation', async () => {
  const user = userEvent.setup();
  mocks.read.mockResolvedValue({ candidates: [], payment_attestations: [resolvableHold], resolution_access: true, payment_resolutions: [savedMatch] });
  mocks.retry.mockResolvedValue({ payment_resolution: { ...savedMatch, status: 'matched' } });
  const view = render(<AirePaymentEvidenceHolds payPeriodId={12} onChanged={vi.fn()} />);
  await screen.findByText(/Match receipt pending/);
  expect(screen.getByRole('button', { name: 'Match existing payment' }).hasAttribute('disabled')).toBe(true);
  expect(screen.getByRole('button', { name: 'Retract hold' }).hasAttribute('disabled')).toBe(true);
  view.unmount();
  render(<AirePaymentEvidenceHolds payPeriodId={12} onChanged={vi.fn()} />);
  await user.click(await screen.findByRole('button', { name: 'Retry saved match' }));
  expect(mocks.retry).toHaveBeenCalledWith(12, 99);
  expect(mocks.resolve).not.toHaveBeenCalled();
  expect(await screen.findByText(/Saved match reconciled/)).toBeTruthy();
});

it('rejects split REG/OT capacity and unavailable review context without losing the report', async () => {
  const user = userEvent.setup();
  mocks.read.mockResolvedValue({ candidates: [], payment_attestations: [{ ...resolvableHold, payment_options: [{ ...paymentOption, regular_hours_available: 3, overtime_hours_available: 1 }] }], resolution_access: true });
  render(<AirePaymentEvidenceHolds payPeriodId={12} onChanged={vi.fn()} />);
  await user.click(await screen.findByRole('button', { name: 'Match existing payment' }));
  await user.selectOptions(screen.getByLabelText('Existing issued payroll payment'), '88');
  await user.type(screen.getByLabelText('Existing payment match reason'), savedMatch.note);
  expect(screen.getByRole('button', { name: 'Confirm existing payment match' }).hasAttribute('disabled')).toBe(true);
  expect(screen.getByRole('alert').textContent).toContain('entire separate REG and OT');
  expect(mocks.resolve).not.toHaveBeenCalled();
});

it('retains resolved Source report history after pending list becomes empty', async () => {
  mocks.read.mockResolvedValue({ candidates: [], payment_attestations: [{ ...hold, status: 'resolved', resolved_manual_allocation_id: '601' }], payment_resolutions: [{ ...savedMatch, status: 'matched', allocation_status: 'committed' }] });
  render(<AirePaymentEvidenceHolds payPeriodId={12} onChanged={vi.fn()} />);
  expect(await screen.findByText(/Matched existing payment/)).toBeTruthy();
  expect(screen.getByText(/current source allocation: committed/)).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Retract hold' })).toBeNull();
});


it('refreshes the durable pending error after a rejected saved retry and keeps the new action feedback visible', async () => {
  const user = userEvent.setup();
  mocks.read.mockResolvedValueOnce({ candidates: [], payment_attestations: [resolvableHold], resolution_access: true, payment_resolutions: [savedMatch] })
    .mockResolvedValue({ candidates: [], payment_attestations: [resolvableHold], resolution_access: true,
      payment_resolutions: [{ ...savedMatch, last_sync_error: 'New saved receipt rejection' }] });
  mocks.retry.mockRejectedValue(new Error('New saved receipt rejection'));
  render(<AirePaymentEvidenceHolds payPeriodId={12} onChanged={vi.fn()} />);
  await user.click(await screen.findByRole('button', { name: 'Retry saved match' }));
  await waitFor(() => expect(mocks.read).toHaveBeenCalledTimes(2));
  expect((await screen.findByRole('alert')).textContent).toContain('New saved receipt rejection');
  expect(screen.queryByText('Lost Source receipt')).toBeNull();
  expect(screen.getAllByText('New saved receipt rejection').length).toBe(2);
});
