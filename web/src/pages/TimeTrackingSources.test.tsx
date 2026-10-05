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
  connection_uuid: '3b7b6e19-d047-4c3f-a449-f98ea7d49f4b',
  identity_verified: false,
  source_instance_id: null,
  source_protocol: null,
  source_protocol_version: null,
  source_capabilities: [],
  identity_verified_at: null,
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

  it.each(['aire_services', 'custom'] as const)('sends visible authorization configuration only for %s', async sourceType => {
    const configured = { ...source, source_type: sourceType, authorization_origin: 'https://neutral.example.test',
      supported_operations: sourceType === 'custom' ? ['time_summary_v1'] : undefined };
    apiMocks.list.mockResolvedValue({ time_tracking_sources: [configured] });
    apiMocks.getAireAccountLink.mockResolvedValue({ account_link: { connected: false } });
    apiMocks.update.mockResolvedValue({ time_tracking_source: configured });
    render(<TimeTrackingSources />);
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Save source' }));
    await waitFor(() => expect(apiMocks.update).toHaveBeenCalled());
    const payload = apiMocks.update.mock.calls[0][1];
    if (sourceType === 'custom') expect(payload.authorization_origin).toBe('https://neutral.example.test');
    else expect(payload).not.toHaveProperty('authorization_origin');
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
    const connect = screen.getByRole('button', { name: 'Connect my time tracking account' });
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

  it('tests and pins the source installation without asking for an identifier', async () => {
    const user = userEvent.setup();
    apiMocks.getAireAccountLink.mockResolvedValue({ account_link: { connected: false } });
    apiMocks.testConnection.mockResolvedValue({
      ok: true,
      message: 'Connected to AIRE.',
      source: 'aire_services',
      employee_count: 3,
      identity_verified: true,
      connection_uuid: source.connection_uuid,
      source_instance_id: '642b5fd9-53ed-4798-b69b-fe354fe70334',
      source_protocol: 'shimizu_time_payroll',
      source_protocol_version: '1.0',
      source_capabilities: ['time_summary_v1', 'finalized_batch_v2'],
      identity_verified_at: '2026-10-01T01:00:00Z',
      cockpit_ready: true,
    });

    render(<TimeTrackingSources />);

    expect(await screen.findAllByText('Test required')).not.toHaveLength(0);
    await user.click(screen.getAllByRole('button', { name: 'Test connection' })[0]);

    expect(apiMocks.testConnection).toHaveBeenCalledWith(4);
    expect(await screen.findAllByText('Verified')).not.toHaveLength(0);
    expect(screen.getByText(/source installation identity is verified/i)).toBeTruthy();
    expect(screen.getByText(/Verified contract 1.0: 2 supported features/i)).toBeTruthy();
  });
});
