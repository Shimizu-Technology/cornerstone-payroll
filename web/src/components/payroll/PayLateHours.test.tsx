// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { payPeriodsApi } from '@/services/api';
import { PayLateHours } from './PayLateHours';

vi.mock('@/services/api', () => ({ payPeriodsApi: { lateHours: vi.fn(), payLateHours: vi.fn(), retryLateHours: vi.fn(), cancelLateHours: vi.fn() } }));
const review = { period_version: 5, can_pay: true, runs: [], cases: [{ id: 'case-1', version: 2, employee: { name: 'Pilot One' }, reason: 'approved_after_cutoff', total_hours: 4,
  adjustments: [{ line_key: '7:1', source_time_entry_id: '101', original_work_date: '2026-10-05', category: { name: 'Flight Hours' }, regular_hours: 4, overtime_hours: 0, payroll_rate: 25 }] }] };
afterEach(cleanup);
beforeEach(() => { vi.resetAllMocks(); vi.mocked(payPeriodsApi.lateHours).mockResolvedValue(review); });
function mount(canPay = true) { render(<MemoryRouter><PayLateHours payPeriodId={17} canPay={canPay} /></MemoryRouter>); }
it('requires selection and sends exactly the reviewed case versions', async () => {
  vi.mocked(payPeriodsApi.payLateHours).mockResolvedValue({ late_hours_run: { id: 1, pay_period_id: 99, applied: true, pay_date: '2026-10-24', last_error: null } });
  mount(); fireEvent.click(screen.getByRole('button', { name: 'Pay late hours' }));
  expect(await screen.findByText('Pilot One')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Create adjustment run' })).toHaveProperty('disabled', true);
  fireEvent.click(screen.getByRole('checkbox', { name: /Pilot One/ }));
  fireEvent.change(screen.getByLabelText('Pay date'), { target: { value: '2026-10-24' } });
  fireEvent.click(screen.getByRole('button', { name: 'Create adjustment run' }));
  await waitFor(() => expect(payPeriodsApi.payLateHours).toHaveBeenCalledWith(17, expect.objectContaining({ expected_version: 5, cases: [{ id: 'case-1', version: 2 }], pay_date: '2026-10-24' })));
});
it('resumes the same saved adjustment after reload', async () => {
  vi.mocked(payPeriodsApi.lateHours).mockResolvedValue({ ...review, cases: [], runs: [{ id: 8, pay_period_id: 99, applied: false, pay_date: '2026-10-24', last_error: 'Source timed out' }] });
  vi.mocked(payPeriodsApi.retryLateHours).mockResolvedValue({ late_hours_run: { id: 8, pay_period_id: 99, applied: true, pay_date: '2026-10-24', last_error: null } });
  mount(); fireEvent.click(screen.getByRole('button', { name: 'Pay late hours' }));
  fireEvent.click(await screen.findByRole('button', { name: 'Resume adjustment' }));
  await waitFor(() => expect(payPeriodsApi.retryLateHours).toHaveBeenCalledWith(17, 8));
});
it('disables the command without Client management', () => { mount(false); expect(screen.getByRole('button', { name: 'Pay late hours' })).toHaveProperty('disabled', true); });
it('allows a fresh selection after a rejected claim and keeps unrelated hours available', async () => {
  vi.mocked(payPeriodsApi.lateHours).mockResolvedValue({ ...review, runs: [
    { id: 8, pay_period_id: 99, applied: false, closed: true, state: 'rejected', pay_date: '2026-10-24', last_error: 'Source changed' },
    { id: 9, pay_period_id: 100, applied: false, closed: false, state: 'ambiguous', pay_date: '2026-10-24', last_error: 'Response lost' },
  ] });
  mount(); fireEvent.click(screen.getByRole('button', { name: 'Pay late hours' }));
  expect(await screen.findByText(/Adjustment #99 closed/)).toBeTruthy();
  expect(screen.getByRole('checkbox', { name: /Pilot One/ })).toHaveProperty('disabled', false);
  fireEvent.click(screen.getByRole('checkbox', { name: /Pilot One/ }));
  expect(screen.getByRole('button', { name: 'Create adjustment run' })).toHaveProperty('disabled', false);
});
it('requires an explicit review reason to cancel an unapplied reserved claim', async () => {
  const run = { id: 8, pay_period_id: 99, applied: false, closed: false, state: 'reconciliation_required', pay_date: '2026-10-24', last_error: 'Source components changed' };
  vi.mocked(payPeriodsApi.lateHours).mockResolvedValue({ ...review, cases: [], runs: [run] });
  vi.mocked(payPeriodsApi.cancelLateHours).mockResolvedValue({ late_hours_run: { ...run, state: 'cancelled', closed: true } });
  mount(); fireEvent.click(screen.getByRole('button', { name: 'Pay late hours' }));
  fireEvent.click(await screen.findByRole('button', { name: 'Review cancellation' }));
  expect(screen.getByRole('button', { name: 'Cancel unpaid claim' })).toHaveProperty('disabled', true);
  fireEvent.change(screen.getByLabelText('Cancellation reason'), { target: { value: 'Reviewed changed source; select current hours' } });
  fireEvent.click(screen.getByRole('button', { name: 'Cancel unpaid claim' }));
  await waitFor(() => expect(payPeriodsApi.cancelLateHours).toHaveBeenCalledWith(17, 8, 'Reviewed changed source; select current hours'));
});
