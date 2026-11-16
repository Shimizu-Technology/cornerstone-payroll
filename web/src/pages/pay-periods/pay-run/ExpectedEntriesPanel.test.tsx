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
  render(<ExpectedEntriesPanel onUnapprove={vi.fn()} payPeriod={period} disabled={false} onRestore={vi.fn().mockResolvedValue(undefined)} onCalculate={calculate} onSaved={saved} onEnterPay={vi.fn()} />);
  fireEvent.change(screen.getByLabelText('Hours: Manual hours'), { target: { value: '16' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save and calculate' }));
  await waitFor(() => expect(calculate).toHaveBeenCalledWith(period.expected_entries!.fields[0], 16));
  expect(mocks.post).not.toHaveBeenCalled();
  expect(saved).not.toHaveBeenCalled();
});
it('records notes and reuses roster entry for missing regulars', async () => {
  mocks.post.mockResolvedValue({});
  const enter = vi.fn();
  render(<ExpectedEntriesPanel onUnapprove={vi.fn()} payPeriod={period} disabled={false} onRestore={vi.fn().mockResolvedValue(undefined)} onCalculate={vi.fn()} onSaved={vi.fn()} onEnterPay={enter} />);
  fireEvent.click(screen.getByRole('button', { name: 'Enter pay for Regular Worker' }));
  expect(enter).toHaveBeenCalledWith(8);
  fireEvent.change(screen.getByLabelText('Note for Manual hours (optional)'), { target: { value: 'Away' } });
  fireEvent.click(screen.getByRole('button', { name: 'None this period' }));
  await waitFor(() => expect(mocks.post).toHaveBeenCalledWith('/admin/pay_periods/1/entry_resolutions', { employee_id: 7, payroll_standing_change_id: 4, note: 'Away' }));
});
it.each(['availability_error', 'inline_save_error'] as const)('blocks unsafe inline writes and explains %s', key => {
  const data = { ...period, expected_entries: { ...period.expected_entries!, fields: [{ ...period.expected_entries!.fields[0], [key]: 'Fix saved setup' }] } };
  render(<ExpectedEntriesPanel onUnapprove={vi.fn()} payPeriod={data} disabled={false} onRestore={vi.fn().mockResolvedValue(undefined)} onCalculate={vi.fn()} onSaved={vi.fn()} onEnterPay={vi.fn()} />);
  expect(screen.getByRole('alert').textContent).toContain('Fix saved setup');
  expect((screen.getByRole('button', { name: 'Save and calculate' }) as HTMLButtonElement).disabled).toBe(true);
});
it('restores excluded fields and regulars while retaining the original reasons', async () => {
  const data = { ...period, expected_entries: { fields: [{ ...period.expected_entries!.fields[0], status: 'excluded' as const, note: 'No work scheduled' }], missing_regulars: [{ employee_id: 8, label: 'Regular Worker', resolved: true, excluded: true, note: 'Client no pay' }], outstanding: [] } };
  const restore = vi.fn().mockResolvedValue(undefined);
  render(<ExpectedEntriesPanel onUnapprove={vi.fn()} payPeriod={data} disabled={false} onRestore={restore} onCalculate={vi.fn()} onSaved={vi.fn()} onEnterPay={vi.fn()} />);
  expect(screen.getByText(/Excluded this period/)).toBeTruthy();
  expect(screen.getByText('No work scheduled')).toBeTruthy();
  expect(screen.getByText('Client no pay')).toBeTruthy();
  const actions = screen.getAllByRole('button', { name: 'Add back to this run' });
  fireEvent.click(actions[0]);
  await waitFor(() => expect(restore).toHaveBeenCalledWith(7));
  expect(await screen.findByText("Imported hours aren't brought back. Enter hours or import again.")).toBeTruthy();
  await waitFor(() => expect(actions[1]).toHaveProperty('disabled', false));
  fireEvent.click(actions[1]);
  await waitFor(() => expect(restore).toHaveBeenCalledWith(8));
  expect(screen.queryByRole('button', { name: /Undo/ })).toBeNull();
});

it('keeps restore failures visible and permits retry before entering hours', async () => {
  const excluded = { ...period, expected_entries: { ...period.expected_entries!, fields: [{ ...period.expected_entries!.fields[0], status: 'excluded' as const }], missing_regulars: [] } };
  const restore = vi.fn().mockRejectedValueOnce(new Error('Review employment status')).mockResolvedValue(undefined);
  const props = { payPeriod: excluded, disabled: false, onRestore: restore, onCalculate: vi.fn().mockResolvedValue(undefined), onSaved: vi.fn(), onEnterPay: vi.fn() };
  const view = render(<ExpectedEntriesPanel onUnapprove={vi.fn()} {...props} />);
  fireEvent.click(screen.getByRole('button', { name: 'Add back to this run' }));
  await waitFor(() => expect(screen.getByRole('alert').textContent).toBe('Review employment status'));
  fireEvent.click(screen.getByRole('button', { name: 'Add back to this run' }));
  await waitFor(() => expect(restore).toHaveBeenCalledTimes(2));
  view.rerender(<ExpectedEntriesPanel onUnapprove={vi.fn()} {...props} payPeriod={{ ...excluded, expected_entries: { ...excluded.expected_entries, fields: [{ ...excluded.expected_entries.fields[0], status: 'missing' }] } }} />);
  fireEvent.change(screen.getByLabelText('Hours: Manual hours'), { target: { value: '16' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save and calculate' }));
  await waitFor(() => expect(props.onCalculate).toHaveBeenCalledWith(expect.objectContaining({ employee_id: 7 }), 16));
});
it.each(['committed'] as const)('hides expected-entry actions for %s runs', status => {
  render(<ExpectedEntriesPanel onUnapprove={vi.fn()} payPeriod={{ ...period, status }} disabled={false} onRestore={vi.fn()} onCalculate={vi.fn()} onSaved={vi.fn()} onEnterPay={vi.fn()} />);
  expect(screen.queryByRole('region', { name: 'Expected entries' })).toBeNull();
});

it('offers amount-free resolutions and undo on approved runs while pay entry requires unapproval', async () => {
  mocks.post.mockResolvedValue({}); mocks.delete.mockResolvedValue({});
  const saved = vi.fn().mockResolvedValue(undefined), unapprove = vi.fn();
  const props = { disabled: false, onSaved: saved, onUnapprove: unapprove, onEnterPay: vi.fn(), onCalculate: vi.fn(), onRestore: vi.fn() };
  const view = render(<ExpectedEntriesPanel {...props} payPeriod={{ ...period, status: 'approved' }} />);
  expect(screen.getByText('To enter pay, unapprove first.')).toBeTruthy();
  expect(screen.queryByRole('spinbutton')).toBeNull();
  expect(screen.queryByRole('button', { name: 'Save and calculate' })).toBeNull();
  expect(screen.queryByRole('button', { name: 'Enter pay for Regular Worker' })).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: 'None this period' }));
  await waitFor(() => expect(mocks.post).toHaveBeenCalledWith('/admin/pay_periods/1/entry_resolutions', expect.objectContaining({ payroll_standing_change_id: 4 })));
  await waitFor(() => expect(screen.getByRole('button', { name: 'Not paid this period' })).toHaveProperty('disabled', false));
  fireEvent.click(screen.getByRole('button', { name: 'Not paid this period' }));
  await waitFor(() => expect(mocks.post).toHaveBeenCalledWith('/admin/pay_periods/1/entry_resolutions', expect.objectContaining({ employee_id: 8 })));
  await waitFor(() => expect(saved).toHaveBeenCalledTimes(2));
  view.rerender(<ExpectedEntriesPanel {...props} payPeriod={{ ...period, status: 'approved', expected_entries: { fields: [{ ...period.expected_entries!.fields[0], status: 'none' }], missing_regulars: [{ employee_id: 8, label: 'Regular Worker', resolved: true }], outstanding: [] } }} />);
  fireEvent.click(screen.getByRole('button', { name: 'Undo none for Manual hours' }));
  await waitFor(() => expect(mocks.delete).toHaveBeenCalledWith('/admin/pay_periods/1/entry_resolutions', { data: expect.objectContaining({ payroll_standing_change_id: 4 }) }));
  await waitFor(() => expect(screen.getByRole('button', { name: 'Undo not paid for Regular Worker' })).toHaveProperty('disabled', false));
  fireEvent.click(screen.getByRole('button', { name: 'Undo not paid for Regular Worker' }));
  await waitFor(() => expect(mocks.delete).toHaveBeenCalledWith('/admin/pay_periods/1/entry_resolutions', { data: expect.objectContaining({ employee_id: 8 }) }));
  await waitFor(() => expect(saved).toHaveBeenCalledTimes(4));
  expect(screen.queryByRole('button', { name: 'Unapprove to enter pay' })).toBeNull();
  view.rerender(<ExpectedEntriesPanel {...props} payPeriod={{ ...period, status: 'approved' }} />);
  fireEvent.click(screen.getByRole('button', { name: 'Unapprove to enter pay' }));
  expect(unapprove).toHaveBeenCalledOnce();
});

it('does not prompt for unapproval when approved fields are filled and no entries are outstanding', () => {
  render(<ExpectedEntriesPanel onUnapprove={vi.fn()} onRestore={vi.fn()} onCalculate={vi.fn()} onSaved={vi.fn()} onEnterPay={vi.fn()} disabled={false} payPeriod={{ ...period, status: 'approved', expected_entries: { fields: [{ ...period.expected_entries!.fields[0], status: 'filled', value: '16' }], missing_regulars: [], outstanding: [] } }} />);
  expect(screen.getByText('All expected entries are resolved.')).toBeTruthy();
  expect(screen.queryByText('To enter pay, unapprove first.')).toBeNull();
  expect(screen.queryByRole('button', { name: 'Unapprove to enter pay' })).toBeNull();
});
