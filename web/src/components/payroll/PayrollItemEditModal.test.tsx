// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { PayrollItemEditModal } from './PayrollItemEditModal';
import type { PayrollItem } from '@/types';

const mocks = vi.hoisted(() => ({ update: vi.fn(), recalculate: vi.fn() }));
vi.mock('@/services/api', () => ({ payrollItemsApi: mocks }));
afterEach(cleanup);
beforeEach(() => { mocks.update.mockReset(); mocks.recalculate.mockReset(); });

it('loads saved hours before autofocus and explicitly clears a request previously capped to zero', async () => {
  const user = userEvent.setup();
  const item = { id: 8, employee_id: 2, employee_name: 'Synthetic Employee', employment_type: 'hourly', pay_rate: 25,
    hours_worked: '80.0', overtime_hours: '0.0', gross_pay: 2000, net_pay: 1500,
    payroll_field_entries: [{ id: 9, label: 'Synthetic 401(k)', kind: 'deduction', tax_treatment: 'pre_tax_deduction', category: 'retirement', amount: 0, metadata: { uncapped_amount: '1070.0' }, source: 'manual', active: true, employee_paid: true }],
  } as unknown as PayrollItem;
  mocks.update.mockResolvedValue({ payroll_item: item });
  mocks.recalculate.mockResolvedValue({ payroll_item: item });
  render(<PayrollItemEditModal open onOpenChange={vi.fn()} payPeriodId={12} item={item} onSaved={vi.fn()} />);
  const dialog = await screen.findByRole('dialog');
  expect(dialog.querySelector('input')?.value).toBe('80');
  const amount = screen.getByRole('textbox', { name: 'Synthetic 401(k) requested amount' });
  expect((amount as HTMLInputElement).value).toBe('1070.00');
  await user.clear(amount);
  await user.type(amount, '0');
  await user.click(screen.getByRole('button', { name: 'Save & Recalculate' }));
  await waitFor(() => expect(mocks.update).toHaveBeenCalled());
  expect(mocks.update.mock.calls[0][2]).toMatchObject({ hours_worked: 80, payroll_field_entries: [{ id: 9, amount: 0, replace_request: true }] });
});


const savedItem = {
  id: 2, employee_id: 2, employee_name: 'Synthetic Correction Employee', employment_type: 'hourly',
  pay_rate: 25, hours_worked: 4, gross_pay: 100, net_pay: 82.35,
  custom_deductions: [{ label: 'Mistaken standalone deduction', amount: 10 }],
  payroll_adjustments: [],
  payroll_field_entries: [],
} as unknown as PayrollItem;
function mountSaved(item = savedItem) {
  const onSaved = vi.fn();
  const onOpenChange = vi.fn();
  mocks.update.mockResolvedValue({ payroll_item: item });
  mocks.recalculate.mockResolvedValue({ payroll_item: { ...item, custom_deductions: [], net_pay: 92.35 } });
  render(<PayrollItemEditModal open onOpenChange={onOpenChange} payPeriodId={3} item={item} onSaved={onSaved} />);
  return { onSaved, onOpenChange };
}
it('displays the saved deduction and explicitly clears its last row before normal recalculation', async () => {
  const user = userEvent.setup();
  const { onSaved } = mountSaved();
  expect((screen.getByRole('textbox', { name: 'Mistaken standalone deduction amount' }) as HTMLInputElement).value).toBe('10.00');
  await user.click(screen.getByRole('button', { name: 'Remove Mistaken standalone deduction' }));
  await user.click(screen.getByRole('button', { name: 'Save & Recalculate' }));
  expect(mocks.update).toHaveBeenCalledWith(3, 2, expect.objectContaining({ custom_deductions: [] }));
  expect(mocks.recalculate).toHaveBeenCalledWith(3, 2);
  expect(onSaved).toHaveBeenCalledWith(expect.objectContaining({ net_pay: 92.35, custom_deductions: [] }));
  expect(mocks.update.mock.calls[0][2]).not.toHaveProperty('payroll_adjustments');
  expect(mocks.update.mock.calls[0][2]).not.toHaveProperty('payroll_field_entries');
  expect(savedItem.custom_deductions).toEqual([{ label: 'Mistaken standalone deduction', amount: 10 }]);
});
it('edits only the requested deduction amount and retains other saved labels and amounts', async () => {
  const user = userEvent.setup();
  mountSaved({ ...savedItem, custom_deductions: [...(savedItem.custom_deductions || []), { label: 'Other saved deduction', amount: 2 }] });
  const amount = screen.getByRole('textbox', { name: 'Mistaken standalone deduction amount' });
  await user.clear(amount);
  await user.type(amount, '5.25');
  await user.click(screen.getByRole('button', { name: 'Save & Recalculate' }));
  expect(mocks.update.mock.calls[0][2].custom_deductions).toEqual([
    { label: 'Mistaken standalone deduction', amount: 5.25 }, { label: 'Other saved deduction', amount: 2 },
  ]);
});
it('omits untouched legacy deductions and recurring fields from the update', async () => {
  const user = userEvent.setup();
  mountSaved({ ...savedItem, net_pay: 77.35,
    payroll_adjustments: [{ label: 'Recurring setup', amount: 3, treatment: 'post_tax_deduction', notes: 'Retained setup', active: true }],
    payroll_field_entries: [{ id: 9, label: 'Saved retirement', amount: 2, kind: 'deduction', tax_treatment: 'pre_tax_deduction', category: 'retirement', source: 'employee_default', active: true, employee_paid: true }],
  } as PayrollItem);
  await user.click(screen.getByRole('button', { name: 'Save & Recalculate' }));
  expect(mocks.update.mock.calls[0][2]).not.toHaveProperty('custom_deductions');
  expect(mocks.update.mock.calls[0][2]).not.toHaveProperty('payroll_adjustments');
  expect(mocks.update.mock.calls[0][2]).not.toHaveProperty('payroll_field_entries');
});
it('cancels an unsaved deduction removal without changing the original or calling the API', async () => {
  const user = userEvent.setup();
  const { onOpenChange } = mountSaved();
  await user.click(screen.getByRole('button', { name: 'Remove Mistaken standalone deduction' }));
  await user.click(screen.getByRole('button', { name: 'Cancel' }));
  expect(onOpenChange).toHaveBeenCalledWith(false);
  expect(mocks.update).not.toHaveBeenCalled();
  expect(mocks.recalculate).not.toHaveBeenCalled();
  expect(savedItem.custom_deductions?.[0].amount).toBe(10);
});
it('retains the removed-row intent after a failed save and retries the same explicit empty array', async () => {
  const user = userEvent.setup();
  const { onSaved, onOpenChange } = mountSaved();
  mocks.update.mockRejectedValueOnce(new Error('Calculation changed; review and try again.'));
  await user.click(screen.getByRole('button', { name: 'Remove Mistaken standalone deduction' }));
  await user.click(screen.getByRole('button', { name: 'Save & Recalculate' }));
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Calculation changed; review and try again.');
  expect(screen.queryByRole('textbox', { name: 'Mistaken standalone deduction amount' })).toBeNull();
  expect(onSaved).not.toHaveBeenCalled();
  expect(onOpenChange).not.toHaveBeenCalled();
  expect(mocks.recalculate).not.toHaveBeenCalled();
  await user.click(screen.getByRole('button', { name: 'Save & Recalculate' }));
  expect(mocks.update).toHaveBeenCalledTimes(2);
  for (const call of mocks.update.mock.calls) expect(call[2].custom_deductions).toEqual([]);
  expect(onSaved).toHaveBeenCalledTimes(1);
});
it('requires a positive deduction amount or an explicit removal instead of silently dropping zero', async () => {
  const user = userEvent.setup();
  mountSaved();
  const amount = screen.getByRole('textbox', { name: 'Mistaken standalone deduction amount' });
  await user.clear(amount);
  await user.type(amount, '0');
  await user.click(screen.getByRole('button', { name: 'Save & Recalculate' }));
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Enter a positive amount for Mistaken standalone deduction, or remove that deduction.');
  expect(mocks.update).not.toHaveBeenCalled();
  expect(mocks.recalculate).not.toHaveBeenCalled();
});
it('does not introduce legacy deduction controls or payload for an item without saved deductions', async () => {
  const user = userEvent.setup();
  mountSaved({ ...savedItem, custom_deductions: [] });
  expect(screen.queryByText('Saved one-time deductions')).toBeNull();
  await user.click(screen.getByRole('button', { name: 'Save & Recalculate' }));
  expect(mocks.update.mock.calls[0][2]).not.toHaveProperty('custom_deductions');
});


it('disables saved deduction edits and removal during the existing save request', async () => {
  const user = userEvent.setup();
  const { onSaved } = mountSaved();
  let resolveUpdate!: (value: { payroll_item: PayrollItem }) => void;
  mocks.update.mockImplementation(() => new Promise(resolve => { resolveUpdate = resolve; }));
  await user.click(screen.getByRole('button', { name: 'Save & Recalculate' }));
  expect((screen.getByRole('textbox', { name: 'Mistaken standalone deduction amount' }) as HTMLInputElement).disabled).toBe(true);
  const remove = screen.getByRole('button', { name: 'Remove Mistaken standalone deduction' });
  expect((remove as HTMLButtonElement).disabled).toBe(true);
  await user.click(remove);
  expect(mocks.update).toHaveBeenCalledTimes(1);
  expect(mocks.update.mock.calls[0][2]).not.toHaveProperty('custom_deductions');
  resolveUpdate({ payroll_item: savedItem });
  await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1));
});
