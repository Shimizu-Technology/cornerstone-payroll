// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { ContactChangeActivity } from './ContactChangeActivity';

const api = vi.hoisted(() => ({ list: vi.fn(), confirmAll: vi.fn() }));
vi.mock('@/services/api', () => ({ staffEmployeeContactChangesApi: api }));

afterEach(cleanup);

it('uses singular copy for one matching change and applies the same trimmed search when confirming', async () => {
  api.list.mockResolvedValue({
    data: [{
      id: 8, employee_id: 1, employee_name: 'Example Worker', change_kind: 'address',
      before_values: {}, after_values: { address_line1: '100 Example Lane' }, created_at: '2026-11-25T00:00:00Z',
    }],
    meta: { current_page: 1, total_pages: 1, total_count: 1, through_id: 8 },
  });
  api.confirmAll.mockResolvedValue({ confirmed_count: 1 });
  render(<ContactChangeActivity staffCompanyId={2} />);
  await screen.findByText('Example Worker');

  fireEvent.change(screen.getByRole('textbox', { name: 'Employee' }), { target: { value: '  Example  ' } });
  await screen.findByText('Example Worker');
  expect(api.list).toHaveBeenLastCalledWith(2, { status: 'unconfirmed', search: 'Example', kind: undefined }, 1);

  fireEvent.click(screen.getByRole('button', { name: 'Confirm all' }));
  expect(screen.getByText('Mark 1 change matching these filters as confirmed on payroll.')).toBeTruthy();
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Confirm all' }));
  await screen.findByText('1 change confirmed on payroll.');
  expect(api.confirmAll).toHaveBeenCalledWith(2, { search: 'Example', kind: undefined }, 8);
});
