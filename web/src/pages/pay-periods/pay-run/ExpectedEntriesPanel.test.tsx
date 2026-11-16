// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { ExpectedEntriesPanel } from './ExpectedEntriesPanel';
import type { PayPeriod } from '@/types';
const mocks = vi.hoisted(() => ({ post: vi.fn(), delete: vi.fn() }));
vi.mock('@/services/api', () => ({ default: mocks }));
afterEach(() => { cleanup(); vi.clearAllMocks(); });
const period = { id: 1, status: 'draft', expected_entries: { fields: [
  { id: 4, label: 'Manual hours', employee_id: 7, employee_wage_rate_id: 2, wage_rate: '20', kind: 'extra_hours', required: true, allow_none: true, status: 'missing', value: '0' },
], missing_regulars: [{ employee_id: 8, label: 'Regular Worker', resolved: false }], outstanding: ['Manual hours', 'Regular Worker'] } } as PayPeriod;
it('passes a draft panel value to the worksheet calculator without a partial payroll API call or reload', async () => {
  const calculate = vi.fn().mockResolvedValue(undefined);
  const saved = vi.fn();
  render(<ExpectedEntriesPanel payPeriod={period} disabled={false} onCalculate={calculate} onSaved={saved} onEnterPay={vi.fn()} />);
  fireEvent.change(screen.getByLabelText('Hours: Manual hours'), { target: { value: '16' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save and calculate' }));
  await waitFor(() => expect(calculate).toHaveBeenCalledWith(period.expected_entries!.fields[0], 16));
  expect(mocks.post).not.toHaveBeenCalled();
  expect(saved).not.toHaveBeenCalled();
});
it('records notes and reuses roster entry for missing regulars', async () => {
  mocks.post.mockResolvedValue({});
  const enter = vi.fn();
  render(<ExpectedEntriesPanel payPeriod={period} disabled={false} onCalculate={vi.fn()} onSaved={vi.fn()} onEnterPay={enter} />);
  fireEvent.click(screen.getByRole('button', { name: 'Enter pay for Regular Worker' }));
  expect(enter).toHaveBeenCalledWith(8);
  fireEvent.change(screen.getByLabelText('Note for Manual hours (optional)'), { target: { value: 'Away' } });
  fireEvent.click(screen.getByRole('button', { name: 'None this period' }));
  await waitFor(() => expect(mocks.post).toHaveBeenCalledWith('/admin/pay_periods/1/entry_resolutions', { employee_id: 7, payroll_standing_change_id: 4, note: 'Away' }));
});
it.each(['availability_error', 'inline_save_error'] as const)('blocks unsafe inline writes and explains %s', key => {
  const data = { ...period, expected_entries: { ...period.expected_entries!, fields: [{ ...period.expected_entries!.fields[0], [key]: 'Fix saved setup' }] } };
  render(<ExpectedEntriesPanel payPeriod={data} disabled={false} onCalculate={vi.fn()} onSaved={vi.fn()} onEnterPay={vi.fn()} />);
  expect(screen.getByRole('alert').textContent).toContain('Fix saved setup');
  expect((screen.getByRole('button', { name: 'Save and calculate' }) as HTMLButtonElement).disabled).toBe(true);
});
it('shows exclusions with their reasons and no misleading undo action', () => {
  const data = { ...period, expected_entries: { fields: [{ ...period.expected_entries!.fields[0], status: 'excluded' as const, note: 'No work scheduled' }], missing_regulars: [{ employee_id: 8, label: 'Regular Worker', resolved: true, excluded: true, note: 'Client no pay' }], outstanding: [] } };
  render(<ExpectedEntriesPanel payPeriod={data} disabled={false} onCalculate={vi.fn()} onSaved={vi.fn()} onEnterPay={vi.fn()} />);
  expect(screen.getByText(/Excluded this period/)).toBeTruthy();
  expect(screen.getByText('No work scheduled')).toBeTruthy();
  expect(screen.getByText('Client no pay')).toBeTruthy();
  expect(screen.queryByRole('button')).toBeNull();
});
