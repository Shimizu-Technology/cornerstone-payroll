// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { FinancialCorrectionSourcePanel } from './FinancialCorrectionSourcePanel';
import type { PayPeriod } from '@/types';
import type { CorrectedHoursPreview } from '@/services/api';
const mocks = vi.hoisted(() => ({ get: vi.fn(), connect: vi.fn(), company: 2 }));
vi.mock('@/services/api', () => ({ payPeriodsApi: { correctedHours: mocks.get, connectCorrectedHours: mocks.connect } }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: mocks.company }) }));
const period = { id: 3, company_id: 2, status: 'committed' } as PayPeriod;
const preview: CorrectedHoursPreview = { required: true, status: 'needs_connection', expected_digest: 'reviewed-input', items: [{ payroll_item_id: 2, employee_name: 'Synthetic Worker', original_pay_period_id: 2, original_payroll_item_id: 1, corrected_pay_period_id: 3, work_start: '2026-11-01', work_end: '2026-11-15', regular_hours: 4, overtime_hours: 0 }] };
afterEach(cleanup);
beforeEach(() => { vi.resetAllMocks(); mocks.company = 2; mocks.get.mockResolvedValue({ corrected_hours: preview }); });
it('reviews the actual work and sends only the saved review digest, preserving amounts and check context', async () => {
  mocks.connect.mockResolvedValue({ corrected_hours: { ...preview, status: 'pending' } });
  render(<FinancialCorrectionSourcePanel payPeriod={period} />);
  fireEvent.click(await screen.findByRole('button', { name: 'Connect corrected hours' }));
  expect(screen.getByText(/Original run 2 → Corrected run 3/)).toBeTruthy();
  expect(screen.getByText(/REG 4h · OT 0h/)).toBeTruthy();
  expect(screen.getByText(/amounts and check reference will not change/)).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Confirm connection' }));
  await waitFor(() => expect(mocks.connect).toHaveBeenCalledExactlyOnceWith(3, 'reviewed-input'));
  expect(await screen.findByText(/Waiting for the time source/)).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Connect corrected hours' })).toBeNull();
});
it('keeps a failed confirmation reviewable and blocks repeated or escape transitions while pending', async () => {
  let reject!: (error: Error) => void;
  mocks.connect.mockReturnValue(new Promise((_, no) => { reject = no; }));
  render(<FinancialCorrectionSourcePanel payPeriod={period} />);
  fireEvent.click(await screen.findByRole('button', { name: 'Connect corrected hours' }));
  fireEvent.click(screen.getByRole('button', { name: 'Confirm connection' }));
  expect((screen.getByRole('button', { name: 'Keep reviewing' }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.keyDown(document, { key: 'Escape' });
  expect(screen.getByRole('dialog')).toBeTruthy();
  reject(new Error('Source is unavailable; retry the saved intent.'));
  await screen.findAllByText(/Source is unavailable/);
  expect((screen.getByRole('button', { name: 'Confirm connection' }) as HTMLButtonElement).disabled).toBe(false);
  expect(mocks.connect).toHaveBeenCalledTimes(1);
});
it('never shows catch-up as a pre-commit error or sends a request for another company', () => {
  const { rerender } = render(<FinancialCorrectionSourcePanel payPeriod={{ ...period, status: 'draft' }} />);
  expect(mocks.get).not.toHaveBeenCalled();
  mocks.company = 8;
  rerender(<FinancialCorrectionSourcePanel payPeriod={period} />);
  expect(mocks.get).not.toHaveBeenCalled();
  expect(screen.queryByRole('region')).toBeNull();
});
it('ignores a stale successful confirmation after company context changes', async () => {
  let resolve!: (value: { corrected_hours: CorrectedHoursPreview }) => void;
  mocks.connect.mockReturnValue(new Promise(yes => { resolve = yes; }));
  const { rerender } = render(<FinancialCorrectionSourcePanel payPeriod={period} />);
  fireEvent.click(await screen.findByRole('button', { name: 'Connect corrected hours' }));
  fireEvent.click(screen.getByRole('button', { name: 'Confirm connection' }));
  mocks.company = 8;
  rerender(<FinancialCorrectionSourcePanel payPeriod={period} />);
  resolve({ corrected_hours: { ...preview, status: 'confirmed' } });
  await waitFor(() => expect(screen.queryByText(/time source confirmed/)).toBeNull());
  expect(screen.queryByRole('dialog')).toBeNull();
});
it('refreshes confirmation and retries a failed saved intent without offering a new pending connection', async () => {
  mocks.get.mockResolvedValueOnce({ corrected_hours: { ...preview, status: 'failed' } }).mockResolvedValueOnce({ corrected_hours: { ...preview, status: 'confirmed' } });
  const refreshed = vi.fn();
  render(<FinancialCorrectionSourcePanel payPeriod={period} onConnectionConfirmed={refreshed} />);
  expect(await screen.findByRole('button', { name: 'Retry connection' })).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Refresh connection' }));
  expect(await screen.findByText(/time source confirmed/)).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Retry connection' })).toBeNull();
  expect(mocks.connect).not.toHaveBeenCalled();
  expect(refreshed).toHaveBeenCalledTimes(1);
});

it('invalidates a deferred confirmation on unmount without refreshing an unrelated work page', async () => {
  let resolve!: (value: { corrected_hours: CorrectedHoursPreview }) => void;
  const refreshed = vi.fn();
  mocks.connect.mockReturnValue(new Promise(yes => { resolve = yes; }));
  const { unmount } = render(<FinancialCorrectionSourcePanel payPeriod={period} onConnectionConfirmed={refreshed} />);
  fireEvent.click(await screen.findByRole('button', { name: 'Connect corrected hours' }));
  fireEvent.click(screen.getByRole('button', { name: 'Confirm connection' }));
  unmount();
  resolve({ corrected_hours: { ...preview, status: 'confirmed' } });
  await Promise.resolve();
  expect(refreshed).not.toHaveBeenCalled();
});
