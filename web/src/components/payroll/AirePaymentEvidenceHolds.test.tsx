// @vitest-environment jsdom
import { act, cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AirePaymentEvidenceHolds } from './AirePaymentEvidenceHolds';
const mocks = vi.hoisted(() => ({ read: vi.fn(), create: vi.fn(), retract: vi.fn(), allowed: true }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ hasCapability: () => mocks.allowed }) }));
vi.mock('@/services/api', () => ({ payPeriodsApi: {
  airePaymentEvidence: mocks.read, createAirePaymentHold: mocks.create, retractAirePaymentHold: mocks.retract,
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
