// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { PaymentMethodDialog } from './PaymentMethodDialog';
import { FeedbackProvider } from '@/components/ui/action-feedback';
import type { PayPeriod, PayrollItem } from '@/types';

const mocks = vi.hoisted(() => ({ get: vi.fn(), save: vi.fn() }));
vi.mock('@/services/api', () => ({ payrollItemsApi: { get: mocks.get, updatePaymentMethod: mocks.save } }));
afterEach(cleanup);
const period = { id: 12, company_id: 6, pay_date: '2026-10-08', status: 'committed' } as PayPeriod;
const item = { id: 31, employee_id: 19, employee_name: 'Avery Example', company_id: 6, employment_type: 'hourly', pay_rate: 15, net_pay: 500, check_number: '2000', effective_payment_delivery_method: 'paper_check', payment_method_change: { eligible: true, mode: 'simple', reason: null, target_method: 'direct_deposit', original_check_number: '2000', requires_unpaid_confirmation: true, requires_check_cancellation: false } } as PayrollItem;
function setup(record = item, run = period, refresh = vi.fn().mockResolvedValue(undefined)) {
  mocks.get.mockResolvedValue({ payroll_item: record });
  mocks.save.mockResolvedValue({ payroll_item: record, pay_period_status: run.status });
  const close = vi.fn();
  render(<FeedbackProvider><PaymentMethodDialog payPeriod={run} item={record} onClose={close} onSaved={refresh} /></FeedbackProvider>);
  return { user: userEvent.setup(), close, refresh };
}
async function attest(user: ReturnType<typeof userEvent.setup>) {
  await user.type(await screen.findByLabelText('Reason for changing this payment (at least 10 characters)'), 'Employer confirmed payment remains unpaid');
  await user.click(screen.getByLabelText(/I verified that this payment has not been paid/));
}

describe('scoped payment method changes', () => {
  beforeEach(() => vi.clearAllMocks());
  it('saves the run and future default in one scoped request with original check identity', async () => {
    const { user, refresh } = setup();
    await attest(user);
    await user.click(screen.getByLabelText(/Also use this method/));
    await user.click(screen.getByRole('button', { name: 'Save payment method' }));
    await waitFor(() => expect(mocks.save).toHaveBeenCalledWith(12, 31, 'direct_deposit', expect.objectContaining({ confirm_not_paid: true, update_employee_default: true, expected_check_number: '2000' }), 6));
    expect(refresh).toHaveBeenCalledOnce();
    expect(screen.getByText(/Future payroll default also updated/)).toBeTruthy();
  });
  it('requires explicit cancelled-check evidence for a prepared check replacement', async () => {
    const record = { ...item, payment_method_change: { ...item.payment_method_change!, mode: 'retire_check' as const, requires_check_cancellation: true } };
    const { user } = setup(record);
    await attest(user);
    const button = screen.getByRole('button', { name: 'Record cancellation and save' });
    expect((button as HTMLButtonElement).disabled).toBe(true);
    await user.type(screen.getByLabelText('Check cancellation evidence reference'), 'Synthetic bank stop-payment confirmation');
    await user.click(screen.getByLabelText(/I verified that the original check is cancelled/));
    await user.click(button);
    await waitFor(() => expect(mocks.save).toHaveBeenCalledWith(12, 31, 'direct_deposit', expect.objectContaining({ retire_existing_check: true, confirm_check_cancelled: true, expected_check_number: '2000', cancellation_evidence_reference: 'Synthetic bank stop-payment confirmation' }), 6));
  });
  it('explains a cleared-payment block and never exposes an enabled save', async () => {
    setup({ ...item, payment_method_change: { ...item.payment_method_change!, eligible: false, mode: 'blocked', reason: 'This check has cleared. Its payment cannot be changed here.' } });
    expect(await screen.findByText(/This check has cleared/)).toBeTruthy();
    expect((screen.getByRole('button', { name: 'Save payment method' }) as HTMLButtonElement).disabled).toBe(true);
    expect(mocks.save).not.toHaveBeenCalled();
  });
  it('keeps a successful save distinct from a failed screen refresh', async () => {
    const refresh = vi.fn().mockRejectedValue(new Error('Network unavailable'));
    const { user } = setup(item, period, refresh);
    await attest(user);
    await user.click(screen.getByRole('button', { name: 'Save payment method' }));
    expect(await screen.findByText(/The payment method was saved, but the screen could not refresh/)).toBeTruthy();
    expect(screen.getByText(/Future payroll default unchanged/)).toBeTruthy();
    expect(mocks.save).toHaveBeenCalledOnce();
  });
  it('keeps failed saves open and retains evidence for a retry', async () => {
    const { user, close, refresh } = setup();
    mocks.save.mockRejectedValue(new Error('The check number changed. Refresh before trying again.'));
    await attest(user);
    await user.click(screen.getByRole('button', { name: 'Save payment method' }));
    expect(await screen.findByText(/The check number changed/)).toBeTruthy();
    expect((screen.getByLabelText('Reason for changing this payment (at least 10 characters)') as HTMLInputElement).value).toContain('Employer confirmed');
    expect(close).not.toHaveBeenCalled();
    expect(refresh).not.toHaveBeenCalled();
  });
  it('requires a verified eligibility result instead of falling back to an unrestricted switch', async () => {
    setup({ ...item, payment_method_change: undefined });
    expect(await screen.findByText(/cannot be changed until its eligibility has been verified/)).toBeTruthy();
    expect(mocks.save).not.toHaveBeenCalled();
  });
});
