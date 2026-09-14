// @vitest-environment jsdom

import { render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

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

describe('TimeTrackingSources AIRE account connection', () => {
  beforeEach(() => {
    Object.values(apiMocks).forEach((mock) => mock.mockReset());
    apiMocks.list.mockResolvedValue({ time_tracking_sources: [source] });
    window.history.replaceState({}, '', '/time-tracking-sources');
  });

  it('walks an unlinked operator through a one-time AIRE connection', async () => {
    apiMocks.getAireAccountLink.mockResolvedValue({ account_link: { connected: false } });

    render(<TimeTrackingSources />);

    expect(await screen.findByText('Connect once—no token copying or routine renewal')).toBeTruthy();
    expect((screen.getByRole('button', { name: 'Connect my AIRE account' }) as HTMLButtonElement).disabled).toBe(false);
    expect(screen.queryByLabelText(/delegation token/i)).toBeNull();
  });

  it('shows the linked AIRE identity and persistent connection behavior', async () => {
    apiMocks.getAireAccountLink.mockResolvedValue({
      account_link: {
        connected: true,
        aire_user_name: 'Chels Admin',
        aire_user_email: 'chels@aire.gu',
        linked_at: '2026-09-15T08:00:00Z',
      },
    });

    render(<TimeTrackingSources />);

    expect(await screen.findByText('Connected as Chels Admin')).toBeTruthy();
    expect(screen.getByText('chels@aire.gu')).toBeTruthy();
    expect(screen.getByText(/does not expire on a timer/i)).toBeTruthy();
    expect((screen.getByRole('button', { name: 'Disconnect' }) as HTMLButtonElement).disabled).toBe(false);
    await waitFor(() => expect(apiMocks.getAireAccountLink).toHaveBeenCalledWith(4));
  });
});
