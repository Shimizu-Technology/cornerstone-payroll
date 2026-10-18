// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { CommandPalette } from './CommandPalette';

const access = vi.hoisted(() => ({ configuration: false, fields: false }));
vi.mock('@/hooks/useSelectedCompanyCapability', () => ({ useSelectedCompanyCapability: () => access.configuration }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({
  isAdmin: false, isSuperAdmin: false, isAccountant: true, isClient: false,
  hasCapability: (capability: string) => capability === 'manage_payroll_fields' && access.fields,
}) }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({
  companies: [], activeCompany: { id: 1 }, canSwitchCompany: false, switchCompany: vi.fn(),
}) }));
beforeEach(() => { access.configuration = false; access.fields = false; Element.prototype.scrollIntoView = vi.fn(); });
afterEach(cleanup);

describe('Payroll Fields command permission', () => {
  it.each([
    { configuration: false, fields: true },
    { configuration: true, fields: false },
    { configuration: false, fields: false },
  ])('matches the route permission for %j', async ({ configuration, fields }) => {
    access.configuration = configuration;
    access.fields = fields;
    const user = userEvent.setup();
    render(<MemoryRouter><CommandPalette open onOpenChange={vi.fn()} /></MemoryRouter>);
    await user.type(screen.getByPlaceholderText('Search sidebar pages, reports, actions, or clients...'), 'Payroll Fields');
    expect(screen.queryByRole('button', { name: /^Payroll Fields/ }) !== null).toBe(fields);
  });
});
