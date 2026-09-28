// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { OrganizationSwitcher } from './OrganizationSwitcher';

const { companyContext, authContext, navigate } = vi.hoisted(() => ({
  companyContext: vi.fn(),
  authContext: vi.fn(),
  navigate: vi.fn(),
}));

vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => companyContext() }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => authContext() }));
vi.mock('react-router', async (importOriginal) => ({
  ...await importOriginal<typeof import('react-router')>(),
  useNavigate: () => navigate,
}));

describe('OrganizationSwitcher', () => {
  afterEach(cleanup);
  const switchOrganization = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();
    authContext.mockReturnValue({ user: { role: 'super_admin' } });
    companyContext.mockReturnValue({
      organizations: [
        { id: 1, name: 'Cornerstone' },
        { id: 2, name: 'Shimizu Technology LLC' },
      ],
      activeOrganizationId: 1,
      activeOrganizationName: 'Cornerstone',
      switchOrganization,
    });
  });

  it('lets a platform owner select an organization and leaves a stale record page', () => {
    render(<MemoryRouter><OrganizationSwitcher /></MemoryRouter>);
    fireEvent.change(screen.getByLabelText('Organization'), { target: { value: '2' } });
    expect(switchOrganization).toHaveBeenCalledWith(2);
    expect(navigate).toHaveBeenCalledWith('/app', expect.objectContaining({ state: expect.any(Object) }));
  });

  it('shows a pinned organization to an ordinary admin', () => {
    authContext.mockReturnValue({ user: { role: 'admin' } });
    render(<MemoryRouter><OrganizationSwitcher /></MemoryRouter>);
    expect(screen.getByText('Cornerstone')).toBeTruthy();
    expect(screen.queryByRole('combobox')).toBeNull();
  });
});
