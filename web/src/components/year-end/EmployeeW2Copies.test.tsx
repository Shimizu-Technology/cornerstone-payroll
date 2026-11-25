// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { EmployeeW2Copies } from './EmployeeW2Copies';

const mocks = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn(), patch: vi.fn() }));
vi.mock('@/services/api', () => ({ apiClient: mocks }));
const auth = vi.hoisted(() => ({ capabilities: [] as string[] }));
vi.mock('@/contexts/AuthContext', () => ({
  useOptionalAuth: () => ({ hasCapability: (capability: string) => auth.capabilities.includes(capability) }),
}));

const off = {
  can_post: false, blocker: 'feature_off',
  blocker_message: "Tax forms are turned off in the employee app for this client, so copies can't be posted yet.",
  w2_delivery: null, documents: [],
};

afterEach(() => { cleanup(); vi.resetAllMocks(); auth.capabilities = []; });

function renderCard() {
  render(<MemoryRouter><EmployeeW2Copies companyId={4} companyName="Example Bakery" year={2026} canWrite checklistLoading={false} /></MemoryRouter>);
}

it('links to the employee app switch when tax forms are off and the user can turn them on', async () => {
  mocks.get.mockResolvedValue(off);
  auth.capabilities = ['manage_employee_app_switch'];
  renderCard();

  expect(await screen.findByText(off.blocker_message)).toBeTruthy();
  expect(screen.getByRole('link', { name: 'Turn it on in the employee app switch' }).getAttribute('href')).toBe('/companies/4/employee-app/switch');
});

it('says who can turn tax forms on for everyone else', async () => {
  mocks.get.mockResolvedValue(off);
  renderCard();

  expect(await screen.findByText('Ask an admin with access to the employee app switch to turn it on.')).toBeTruthy();
  expect(screen.queryByRole('link')).toBeNull();
});

it('adds no switch step for other blockers', async () => {
  mocks.get.mockResolvedValue({ ...off, blocker: 'not_final', blocker_message: "The W-2s aren't marked ready on the current figures." });
  auth.capabilities = ['manage_employee_app_switch'];
  renderCard();

  expect(await screen.findByText("The W-2s aren't marked ready on the current figures.")).toBeTruthy();
  expect(screen.queryByText(/employee app switch/)).toBeNull();
});
