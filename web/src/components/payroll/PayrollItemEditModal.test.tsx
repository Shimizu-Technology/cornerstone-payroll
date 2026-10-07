// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, expect, it, vi } from 'vitest';
import { PayrollItemEditModal } from './PayrollItemEditModal';
import type { PayrollItem } from '@/types';

const mocks = vi.hoisted(() => ({ update: vi.fn(), recalculate: vi.fn() }));
vi.mock('@/services/api', () => ({ payrollItemsApi: mocks }));
afterEach(cleanup);

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
