// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { CorrectionPanel } from './CorrectionPanel';
import type { PayPeriod } from '@/types';
const mocks = vi.hoisted(() => ({ preflight: vi.fn(), reopen: vi.fn(), void: vi.fn() }));
vi.mock('@/services/api', () => ({ payPeriodsApi: { correctionPreflight: mocks.preflight, reopenUnpaid: mocks.reopen, void: mocks.void } }));
afterEach(cleanup);
const period = { id: 83, company_id: 2, status: 'committed', can_void: true, pay_date: '2026-10-10' } as PayPeriod;
const preflight = { eligible: true, blockers: [], employee_checks: [{ id: 10, check_number: '3108', payee: 'Example Employee', amount: 1393.15, status: 'assigned', already_voided: false }], other_payments: [{ id: 11, check_number: '3109', payee: 'Treasurer of Guam', amount: 103.66, status: 'assigned', already_voided: false }], requires_unpaid_acknowledgement: true };
function mount() {
  vi.clearAllMocks();
  mocks.preflight.mockResolvedValue({ correction_preflight: preflight, void_preflight: preflight });
  render(<MemoryRouter initialEntries={['/companies/2/pay-runs/83/work']}><Routes><Route path="/companies/2/pay-runs/83/work" element={<CorrectionPanel payPeriod={period} returnTo="/companies/2/pay-runs" onPayPeriodChange={vi.fn()} />} /><Route path="/companies/2/pay-runs/86/work" element={<p>Replacement draft 86</p>} /></Routes></MemoryRouter>);
}
it('discloses employee and tax checks and creates a connected draft after unpaid acknowledgement', async () => {
  mount();
  mocks.reopen.mockResolvedValue({ source_pay_period: { ...period, correction_status: 'voided' }, correction_run: { id: 86 } });
  fireEvent.click(screen.getByRole('button', { name: 'Reopen unpaid payroll' }));
  expect(await screen.findByText(/Check #3109 · Treasurer of Guam/)).toBeTruthy();
  const confirm = screen.getByRole('button', { name: 'Reopen and create draft' });
  expect((confirm as HTMLButtonElement).disabled).toBe(true);
  fireEvent.change(screen.getByLabelText('Reason for reopening'), { target: { value: 'Include the existing saved loan repayment' } });
  fireEvent.click(screen.getByRole('checkbox'));
  fireEvent.click(confirm);
  await waitFor(() => expect(mocks.reopen).toHaveBeenCalledWith(83, { reason: 'Include the existing saved loan repayment', unpaid_acknowledgement: true }));
  expect(await screen.findByText('Replacement draft 86')).toBeTruthy();
});
it('blocks reopening when an associated payment is already delivered', async () => {
  mount();
  mocks.preflight.mockResolvedValue({ correction_preflight: { ...preflight, eligible: false, blockers: ['Check #3108 was delivered to the employee.'] } });
  fireEvent.click(screen.getByRole('button', { name: 'Reopen unpaid payroll' }));
  expect(await screen.findByText('Check #3108 was delivered to the employee.')).toBeTruthy();
  expect((screen.getByRole('button', { name: 'Reopen and create draft' }) as HTMLButtonElement).disabled).toBe(true);
  expect(mocks.reopen).not.toHaveBeenCalled();
});
it('voids the entire payroll with payment acknowledgement and preserves a failed server action in the dialog', async () => {
  mount();
  mocks.void.mockRejectedValue(new Error('Another operator recorded payment delivery.'));
  fireEvent.click(screen.getByRole('button', { name: 'Void This Pay Period' }));
  expect(await screen.findByText(/Check #3108 · Example Employee/)).toBeTruthy();
  fireEvent.click(screen.getByRole('checkbox'));
  fireEvent.change(screen.getByLabelText(/Reason for voiding/), { target: { value: 'Correct an unpaid payroll with a missing deduction' } });
  fireEvent.change(screen.getByPlaceholderText('VOID'), { target: { value: 'VOID' } });
  fireEvent.click(screen.getByRole('button', { name: 'Void Pay Period' }));
  await waitFor(() => expect(mocks.void).toHaveBeenCalledWith(83, { reason: 'Correct an unpaid payroll with a missing deduction', unpaid_acknowledgement: true }));
  expect(await screen.findByText(/Another operator recorded payment delivery/)).toBeTruthy();
});


it('uses ordinary void eligibility independently from stricter automatic reopening requirements', async () => {
  mount();
  mocks.preflight.mockResolvedValue({ correction_preflight: { ...preflight, eligible: false, blockers: ['The finalized AIRE source cannot be automatically reopened.'] }, void_preflight: preflight });
  fireEvent.click(screen.getByRole('button', { name: 'Reopen unpaid payroll' }));
  expect(await screen.findByText('The finalized AIRE source cannot be automatically reopened.')).toBeTruthy();
  expect((screen.getByRole('button', { name: 'Reopen and create draft' }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  fireEvent.click(screen.getByRole('button', { name: 'Void This Pay Period' }));
  expect(await screen.findByRole('checkbox')).toBeTruthy();
  expect(screen.queryByText('The finalized AIRE source cannot be automatically reopened.')).toBeNull();
  fireEvent.click(screen.getByRole('checkbox'));
  fireEvent.change(screen.getByPlaceholderText('VOID'), { target: { value: 'VOID' } });
  expect((screen.getByRole('button', { name: 'Void Pay Period' }) as HTMLButtonElement).disabled).toBe(false);
});
