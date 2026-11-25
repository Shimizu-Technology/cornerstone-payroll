// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { ContactChangeActivity } from './ContactChangeActivity';

const api = vi.hoisted(() => ({ list: vi.fn(), confirm: vi.fn(), confirmAll: vi.fn() }));
vi.mock('@/services/api', () => ({ staffEmployeeContactChangesApi: api }));
const auth = vi.hoisted(() => ({ capabilities: [] as string[] }));
vi.mock('@/contexts/AuthContext', () => ({
  useOptionalAuth: () => ({ hasCapability: (capability: string) => auth.capabilities.includes(capability) }),
}));

function featureOffError() {
  return Object.assign(new Error('This record could not be found.'), {
    status: 404, data: { error: "Employee contact and address updates aren't turned on for this company.", code: 'feature_off' },
  });
}

afterEach(() => { cleanup(); auth.capabilities = []; });

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

it('says contact updates are off, hides the filters and Confirm all, and links to the switch for admins', async () => {
  api.list.mockRejectedValue(featureOffError());
  auth.capabilities = ['manage_employee_app_switch'];
  render(<MemoryRouter><ContactChangeActivity staffCompanyId={2} companyName="Example Bakery" /></MemoryRouter>);

  expect(await screen.findByText("Employee contact and address updates aren't turned on for Example Bakery.")).toBeTruthy();
  expect(screen.queryByText(/could not be found/)).toBeNull();
  expect(screen.queryByRole('button', { name: 'Confirm all' })).toBeNull();
  expect(screen.queryByRole('textbox', { name: 'Employee' })).toBeNull();
  expect(screen.getByRole('link', { name: 'Turn it on in the employee app switch' }).getAttribute('href')).toBe('/companies/2/employee-app/switch');
});

it('tells staff without the switch who can turn contact updates on', async () => {
  api.list.mockRejectedValue(featureOffError());
  render(<MemoryRouter><ContactChangeActivity staffCompanyId={2} /></MemoryRouter>);

  expect(await screen.findByText(/aren't turned on for this company/)).toBeTruthy();
  expect(screen.getByText('Ask an admin with access to the employee app switch to turn it on.')).toBeTruthy();
  expect(screen.queryByRole('link')).toBeNull();
});

it('still shows other load errors as errors', async () => {
  api.list.mockRejectedValue(new Error('The server could not complete this request.'));
  render(<MemoryRouter><ContactChangeActivity staffCompanyId={2} /></MemoryRouter>);

  expect(await screen.findByText('The server could not complete this request.')).toBeTruthy();
  expect(screen.queryByText(/aren't turned on/)).toBeNull();
});

it.each([
  ['Confirmed on payroll', () => api.confirm],
  ['Confirm all', () => api.confirmAll],
])('shows the turned-off message when %s finds updates were switched off', async (label, action) => {
  api.list.mockResolvedValue({
    data: [{
      id: 9, employee_id: 1, employee_name: 'Example Worker', change_kind: 'contact',
      before_values: {}, after_values: { phone: '555-0100' }, created_at: '2026-11-25T00:00:00Z',
    }],
    meta: { current_page: 1, total_pages: 1, total_count: 1, through_id: 9 },
  });
  action().mockRejectedValue(featureOffError());
  render(<MemoryRouter><ContactChangeActivity staffCompanyId={2} companyName="Example Bakery" /></MemoryRouter>);
  await screen.findByText('Example Worker');

  fireEvent.click(screen.getByRole('button', { name: label }));
  if (label === 'Confirm all') fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Confirm all' }));

  expect(await screen.findByText("Employee contact and address updates aren't turned on for Example Bakery.")).toBeTruthy();
  expect(screen.queryByText(/could not be found/)).toBeNull();
  expect(screen.queryByText('Example Worker')).toBeNull();
  expect(screen.queryByRole('button', { name: 'Confirmed on payroll' })).toBeNull();
  expect(screen.queryByRole('button', { name: 'Confirm all' })).toBeNull();
  expect(screen.queryByRole('dialog')).toBeNull();
});
