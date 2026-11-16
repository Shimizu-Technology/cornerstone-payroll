// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { ExpectedEntriesPanel } from './ExpectedEntriesPanel';
import type { PayPeriod } from '@/types';
const mocks = vi.hoisted(() => ({ post: vi.fn(), delete: vi.fn() }));
vi.mock('@/services/api', () => ({ default: mocks }));
afterEach(() => { cleanup(); vi.clearAllMocks(); });
const period = { id: 1, status: 'calculated', expected_entries: { fields: [
  { id: 4, label: 'Manual hours', employee_id: 7, employee_wage_rate_id: 2, wage_rate: '20', wage_rate_label: 'Job', kind: 'extra_hours', required: true, allow_none: true, status: 'missing', value: '0' },
], missing_regulars: [{ employee_id: 8, label: 'Regular Worker', resolved: false }], outstanding: ['Manual hours', 'Regular Worker'] } } as PayPeriod;
it('fills hours through the existing calculation endpoint and reloads saved results', async () => {
  mocks.post.mockResolvedValue({ results: { errors: [] } });
  const onSaved = vi.fn();
  render(<ExpectedEntriesPanel payPeriod={period} disabled={false} onSaved={onSaved} onEnterPay={vi.fn()} />);
  fireEvent.change(screen.getByLabelText('Hours: Manual hours'), { target: { value: '16' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save and calculate' }));
  await waitFor(() => expect(onSaved).toHaveBeenCalled());
  expect(mocks.post).toHaveBeenCalledWith('/admin/pay_periods/1/run_payroll', expect.objectContaining({ employee_ids: [7], hours: { 7: { wage_rates: [expect.objectContaining({ employee_wage_rate_id: 2, regular_hours: 16, rate: 20 })] } } }));
});
it('preserves other saved jobs when filling the configured hourly job', async () => {
  mocks.post.mockResolvedValue({ results: { errors: [] } });
  const other = { employee_wage_rate_id: 3, label: 'Other job', rate: 30, regular_hours: 10, overtime_hours: 2, holiday_hours: 0, pto_hours: 0 };
  const withJobs = { ...period, expected_entries: { ...period.expected_entries!, fields: [{ ...period.expected_entries!.fields[0], saved_wage_rate_hours: [other] }] } };
  render(<ExpectedEntriesPanel payPeriod={withJobs} disabled={false} onSaved={vi.fn()} onEnterPay={vi.fn()} />);
  fireEvent.change(screen.getByLabelText('Hours: Manual hours'), { target: { value: '16' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save and calculate' }));
  await waitFor(() => expect(mocks.post).toHaveBeenCalledWith('/admin/pay_periods/1/run_payroll', expect.objectContaining({ hours: { 7: { wage_rates: [other, expect.objectContaining({ employee_wage_rate_id: 2, regular_hours: 16 })] } } })));
});
it('records optional notes and reuses roster entry for missing regulars', async () => {
  mocks.post.mockResolvedValue({});
  const enter = vi.fn();
  render(<ExpectedEntriesPanel payPeriod={period} disabled={false} onSaved={vi.fn()} onEnterPay={enter} />);
  fireEvent.click(screen.getByRole('button', { name: 'Enter pay for Regular Worker' }));
  expect(enter).toHaveBeenCalledWith(8);
  fireEvent.change(screen.getByLabelText('Note for Manual hours (optional)'), { target: { value: 'Away' } });
  fireEvent.click(screen.getByRole('button', { name: 'None this period' }));
  await waitFor(() => expect(mocks.post).toHaveBeenCalledWith('/admin/pay_periods/1/entry_resolutions', { employee_id: 7, payroll_standing_change_id: 4, note: 'Away' }));
});
it('keeps partial calculation errors visible and does not report a successful save', async () => {
  mocks.post.mockResolvedValue({ results: { errors: [{ error: 'Saved rate changed' }] } });
  const onSaved = vi.fn();
  render(<ExpectedEntriesPanel payPeriod={period} disabled={false} onSaved={onSaved} onEnterPay={vi.fn()} />);
  fireEvent.change(screen.getByLabelText('Hours: Manual hours'), { target: { value: '8' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save and calculate' }));
  await screen.findByRole("alert");
  expect(screen.getByRole('alert').textContent).toBe('Saved rate changed');
  expect(onSaved).not.toHaveBeenCalled();
});
