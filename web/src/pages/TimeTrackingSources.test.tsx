// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { TimeTrackingSources } from './TimeTrackingSources';

const apiMocks = vi.hoisted(() => ({
  list: vi.fn(),
  getAireAccountLink: vi.fn(),
  createAireAccountLink: vi.fn(),
  disconnectAireAccountLink: vi.fn(),
  update: vi.fn(),
  create: vi.fn(),
  deactivate: vi.fn(),
  testConnection: vi.fn(),
}));

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({
    activeCompanyId: 7,
    activeCompany: { id: 7, name: 'Cornerstone Client' },
  }),
}));

vi.mock('@/services/api', () => ({
  timeTrackingSourcesApi: apiMocks,
}));

const source = {
  id: 4,
  company_id: 7,
  name: 'AIRE',
  source_type: 'aire_services' as const,
  base_url: 'https://aire.example.com',
  active: true,
  shared_secret_configured: true,
  delegation_token_configured: false,
  last_synced_at: null,
};

afterEach(() => cleanup());

describe('TimeTrackingSources AIRE account connection', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    Object.values(apiMocks).forEach((mock) => mock.mockReset());
    apiMocks.list.mockResolvedValue({ time_tracking_sources: [source] });
    window.history.replaceState({}, '', '/time-tracking-sources');
  });

  it('walks an unlinked operator through a one-time AIRE connection', async () => {
    const user = userEvent.setup();
    const navigateToAuthorization = vi.fn();
    apiMocks.getAireAccountLink.mockResolvedValue({ account_link: { connected: false } });
    apiMocks.createAireAccountLink.mockResolvedValue({
      authorization_url: 'https://aire-services-guam.netlify.app/admin/payroll-link?token=request',
      expires_at: '2026-09-15T08:10:00Z',
    });

    render(<TimeTrackingSources navigateToAuthorization={navigateToAuthorization} />);

    expect(await screen.findByText('Connect once—no token copying or routine renewal')).toBeTruthy();
    const connect = screen.getByRole('button', { name: 'Connect my AIRE account' });
    expect((connect as HTMLButtonElement).disabled).toBe(false);
    expect(screen.queryByLabelText(/delegation token/i)).toBeNull();

    await user.click(connect);

    expect(apiMocks.createAireAccountLink).toHaveBeenCalledWith(4);
    expect(navigateToAuthorization).toHaveBeenCalledWith(
      'https://aire-services-guam.netlify.app/admin/payroll-link?token=request'
    );
  });

  it('shows the linked AIRE identity and persistent connection behavior', async () => {
    const user = userEvent.setup();
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    apiMocks.getAireAccountLink.mockResolvedValue({
      account_link: {
        connected: true,
        aire_user_name: 'Chels Admin',
        aire_user_email: 'chels@aire.gu',
        linked_at: '2026-09-15T08:00:00Z',
      },
    });
    apiMocks.disconnectAireAccountLink.mockResolvedValue({ account_link: { connected: false } });

    render(<TimeTrackingSources />);

    expect(await screen.findByText('Connected as Chels Admin')).toBeTruthy();
    expect(screen.getByText('chels@aire.gu')).toBeTruthy();
    expect(screen.getByText(/does not expire on a timer/i)).toBeTruthy();
    const disconnect = screen.getByRole('button', { name: 'Disconnect' });
    expect((disconnect as HTMLButtonElement).disabled).toBe(false);
    await waitFor(() => expect(apiMocks.getAireAccountLink).toHaveBeenCalledWith(4));

    await user.click(disconnect);

    expect(apiMocks.disconnectAireAccountLink).toHaveBeenCalledWith(4);
    expect(await screen.findByText('Connect once—no token copying or routine renewal')).toBeTruthy();
  });
});
