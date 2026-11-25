// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import type { CompanyListItem } from '@/services/api';
import { EmployeeAppTurnOnStep } from './EmployeeAppTurnOnStep';

const auth = vi.hoisted(() => ({ capabilities: ['manage_employee_app_switch'] as string[] }));
vi.mock('@/contexts/AuthContext', () => ({
  useOptionalAuth: () => ({ hasCapability: (capability: string) => auth.capabilities.includes(capability) }),
}));
const companyContext = vi.hoisted(() => ({ companies: [] as Partial<CompanyListItem>[] }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => companyContext }));

afterEach(() => {
  cleanup();
  auth.capabilities = ['manage_employee_app_switch'];
  companyContext.companies = [];
});

function renderStep(audience: 'admin' | 'client' = 'admin') {
  return render(<MemoryRouter><EmployeeAppTurnOnStep companyId={3} audience={audience} /></MemoryRouter>);
}

it('links to the switch for an eligible company', () => {
  companyContext.companies = [{ id: 3, name: 'Example Bakery', active: true, test_workspace: false, employee_app_switch_eligible: true }];
  renderStep();

  expect(screen.getByRole('link', { name: 'Turn it on in the employee app switch' }).getAttribute('href')).toBe('/companies/3/employee-app/switch');
});

it.each([
  [{ active: false, test_workspace: false }, "Example Bakery is inactive, so the employee app can't be turned on for it."],
  [{ active: true, test_workspace: true }, "The employee app can't be turned on in a practice copy."],
  [{ active: true, test_workspace: false }, "The employee app can't be turned on for Example Bakery."],
])('says why the switch can\'t turn on an ineligible company instead of promising a step (%o)', (fields, message) => {
  companyContext.companies = [{ id: 3, name: 'Example Bakery', ...fields, employee_app_switch_eligible: false }];

  for (const audience of ['admin', 'client'] as const) {
    const { unmount } = renderStep(audience);
    expect(screen.getByText(message)).toBeTruthy();
    expect(screen.queryByRole('link')).toBeNull();
    expect(screen.queryByText(/Ask an admin|Ask your Cornerstone contact/)).toBeNull();
    unmount();
  }
  auth.capabilities = [];
  renderStep();
  expect(screen.getByText(message)).toBeTruthy();
  expect(screen.queryByText(/Ask an admin/)).toBeNull();
});

it('keeps the who-to-ask step for staff without the switch at an eligible company', () => {
  auth.capabilities = [];
  companyContext.companies = [{ id: 3, name: 'Example Bakery', active: true, employee_app_switch_eligible: true }];
  renderStep();

  expect(screen.getByText('Ask an admin with access to the employee app switch to turn it on.')).toBeTruthy();
  expect(screen.queryByRole('link')).toBeNull();
});
