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
  const restore = vi.fn().mockResolvedValue({ employee_id: 7, employee_name: 'Manual Worker', restored: [], not_restored: [] });
  const view = render(<ExpectedEntriesPanel onUnapprove={vi.fn()} payPeriod={data} disabled={false} onRestore={restore} onCalculate={vi.fn()} onSaved={vi.fn()} onEnterPay={vi.fn()} />);
  expect(screen.getByText(/Excluded this period/)).toBeTruthy();
  expect(screen.getByText('No work scheduled')).toBeTruthy();
  expect(screen.getByText('Client no pay')).toBeTruthy();
  const actions = screen.getAllByRole('button', { name: 'Add back to this run' });
  fireEvent.click(actions[0]);
  await waitFor(() => expect(restore).toHaveBeenCalledWith(7));
  // The controller hands back the result; the panel shows and announces it.
  view.rerender(<ExpectedEntriesPanel onUnapprove={vi.fn()} payPeriod={data} disabled={false} onRestore={restore} onCalculate={vi.fn()} onSaved={vi.fn()} onEnterPay={vi.fn()}
    addBackNotice={{ source: 'expected_entries', result: { employee_id: 7, employee_name: 'Manual Worker', restored: [], not_restored: [] }, hoursEntered: false }} />);
  expect(screen.getAllByText("Manual Worker is back. Hours aren't brought back. Enter hours or import again.")).toHaveLength(2);
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

it('shows busy calculation feedback, preserves the entered value after failure, and permits retry', async () => {
  let fail!: (error: Error) => void;
  const calculate = vi.fn().mockImplementationOnce(() => new Promise((_, reject) => { fail = reject; })).mockResolvedValue(undefined);
  render(<ExpectedEntriesPanel onUnapprove={vi.fn()} payPeriod={period} disabled={false} onRestore={vi.fn()} onCalculate={calculate} onSaved={vi.fn()} onEnterPay={vi.fn()} />);
  fireEvent.change(screen.getByLabelText('Hours: Manual hours'), { target: { value: '16' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save and calculate' }));
  const busy = screen.getByRole('button', { name: 'Saving and calculating…' });
  expect(busy).toHaveProperty('disabled', true);
  expect(busy.getAttribute('aria-busy')).toBe('true');
  expect(screen.getByRole('status').getAttribute('aria-live')).toBe('polite');
  expect(screen.getByRole('status').lastElementChild?.textContent).toContain('Saving and calculating payroll…');
  fireEvent.click(busy);
  expect(calculate).toHaveBeenCalledOnce();
  fail(new Error('Synthetic calculation failed'));
  await waitFor(() => expect(screen.getByRole('alert').textContent).toBe('Synthetic calculation failed'));
  expect(screen.getByLabelText('Hours: Manual hours')).toHaveProperty('value', '16');
  fireEvent.click(screen.getByRole('button', { name: 'Save and calculate' }));
  await waitFor(() => expect(calculate).toHaveBeenCalledTimes(2));
});

it('shows add-back feedback only on the selected employee while all other writes wait', async () => {
  const excluded = { ...period, expected_entries: { ...period.expected_entries!, fields: [{ ...period.expected_entries!.fields[0], status: 'excluded' as const }] } };
  const restore = vi.fn().mockReturnValue(new Promise(() => {}));
  render(<ExpectedEntriesPanel onUnapprove={vi.fn()} payPeriod={excluded} disabled={false} onRestore={restore} onCalculate={vi.fn()} onSaved={vi.fn()} onEnterPay={vi.fn()} />);
  fireEvent.click(screen.getByRole('button', { name: 'Add back to this run' }));
  expect(screen.getByRole('button', { name: 'Adding back…' }).getAttribute('aria-busy')).toBe('true');
  expect(screen.getByRole('button', { name: 'Not paid this period' })).toHaveProperty('disabled', true);
  expect(screen.getByRole('status').lastElementChild?.textContent).toBe('Adding employee back to this run…');
});

it('shows a saved add-back in the worker row, announces a fresh one, and keeps the live region mounted', async () => {
  const excluded = { ...period, expected_entries: { ...period.expected_entries!, fields: [{ ...period.expected_entries!.fields[0], status: 'excluded' as const }], missing_regulars: [] } };
  const result = { employee_id: 7, employee_name: 'Avery Monroe', import_id: 3,
    restored: [{ key: 'loan', kind: 'loan' as const, label: 'Loan', amount: '159.1' }],
    not_restored: [{ key: 'tips', kind: 'tips' as const, label: 'Tips', amount: '20.0', enter_by_hand: true, reason: 'The import was replaced by newer files. Enter them under Hours → Tips & Deductions.' }] };
  const props = { onUnapprove: vi.fn(), disabled: false, onRestore: vi.fn().mockResolvedValue(result), onCalculate: vi.fn(), onSaved: vi.fn(), onEnterPay: vi.fn() };
  const view = render(<ExpectedEntriesPanel {...props} payPeriod={excluded} />);
  const live = screen.getByTestId('add-back-announcement');
  expect(live.getAttribute('aria-live')).toBe('polite');
  expect(live.textContent).toBe('');
  fireEvent.click(screen.getByRole('button', { name: 'Add back to this run' }));
  await waitFor(() => expect(props.onRestore).toHaveBeenCalledWith(7));
  // After the reload: the server lists the add-back, which survives a page refresh.
  const reloaded = { ...excluded, expected_entries: { ...excluded.expected_entries, fields: [{ ...excluded.expected_entries.fields[0], status: 'missing' as const }],
    added_back: [{ ...result, hours_entered: false }] } };
  view.rerender(<ExpectedEntriesPanel {...props} payPeriod={reloaded} addBackNotice={{ source: 'expected_entries', result, hoursEntered: false }} />);
  expect(screen.getByTestId('add-back-announcement')).toBe(live);
  expect(live.textContent).toBe("Avery Monroe is back. Restored from the import: Loan $159.10. Hours aren't brought back. Enter hours, then calculate.");
  const row = screen.getByLabelText('Hours: Manual hours').closest('div.border-t');
  expect(row?.textContent).toContain('Restored from the import: Loan $159.10.');
  expect(row?.textContent).toContain('Tips $20.00: The import was replaced by newer files. Enter them under Hours → Tips & Deductions.');
  // Hours saved; the tips still need entering, so the notice stays with the new next step.
  view.rerender(<ExpectedEntriesPanel {...props} payPeriod={{ ...reloaded, expected_entries: { ...reloaded.expected_entries, fields: [{ ...reloaded.expected_entries.fields[0], status: 'filled' as const, value: '40' }],
    added_back: [{ ...result, hours_entered: true }] } }} />);
  expect(screen.getByText('Avery Monroe is back. Restored from the import: Loan $159.10. Hours are entered.')).toBeTruthy();
});

it('shows the add-back result when the reload after it failed', () => {
  const excluded = { ...period, expected_entries: { ...period.expected_entries!, fields: [{ ...period.expected_entries!.fields[0], status: 'excluded' as const }], missing_regulars: [] } };
  const result = { employee_id: 7, employee_name: 'Avery Monroe', restored: [],
    not_restored: [{ key: 'loan', kind: 'loan' as const, label: 'Loan', amount: '159.1', enter_by_hand: true, reason: 'The import was replaced by newer files. Apply the current import review, or enter it by hand. Enter it under Hours → Tips & Deductions.' }] };
  render(<ExpectedEntriesPanel onUnapprove={vi.fn()} payPeriod={excluded} disabled={false} onRestore={vi.fn()} onCalculate={vi.fn()} onSaved={vi.fn()} onEnterPay={vi.fn()}
    addBackNotice={{ source: 'expected_entries', result, hoursEntered: false }} />);
  expect(screen.getByRole('listitem').textContent).toBe('Loan $159.10: The import was replaced by newer files. Apply the current import review, or enter it by hand. Enter it under Hours → Tips & Deductions.');
});

it('offers an honest no-hours answer for a usually-paid worker added back with import amounts', async () => {
  mocks.post.mockResolvedValue({}); mocks.delete.mockResolvedValue({});
  const awaiting = { ...period, expected_entries: { fields: [], missing_regulars: [{ employee_id: 8, label: 'Regular Worker', resolved: false, awaiting_hours: true }], outstanding: ['Regular Worker'] } };
  const props = { onUnapprove: vi.fn(), disabled: false, onRestore: vi.fn(), onCalculate: vi.fn(), onSaved: vi.fn().mockResolvedValue(undefined), onEnterPay: vi.fn() };
  const view = render(<ExpectedEntriesPanel {...props} payPeriod={awaiting} />);
  expect(screen.queryByRole('button', { name: 'Not paid this period' })).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: 'No hours this period' }));
  await waitFor(() => expect(mocks.post).toHaveBeenCalledWith('/admin/pay_periods/1/entry_resolutions', { employee_id: 8, payroll_standing_change_id: undefined, note: '' }));
  view.rerender(<ExpectedEntriesPanel {...props} payPeriod={{ ...awaiting, expected_entries: { ...awaiting.expected_entries, missing_regulars: [{ ...awaiting.expected_entries.missing_regulars[0], resolved: true }], outstanding: [] } }} />);
  expect(screen.getByText('Regular Worker · No hours this period')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Undo no hours for Regular Worker' })).toBeTruthy();
});
