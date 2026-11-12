// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { StrictMode } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { NotificationSettings } from './NotificationSettings';
import type { NotificationSettings as Settings } from '@/services/portal-notifications-api';

const mocks = vi.hoisted(() => ({ get: vi.fn(), update: vi.fn(), navigate: vi.fn(), switchCompany: vi.fn() }));
vi.mock('@/services/portal-notifications-api', () => ({ notificationSettingsApi: { get: mocks.get, update: mocks.update } }));
vi.mock('react-router', () => ({ useNavigate: () => mocks.navigate }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ switchCompany: mocks.switchCompany, activeCompany: null }) }));

const settings: Settings = {
  email_delivery_enabled: false,
  digest_time_label: '7:00 AM Chamorro Time',
  categories: [
    { key: 'client_messages', label: 'Client messages', description: 'A client sends a message.', delivery_mode: 'immediate', default_mode: 'immediate' },
    { key: 'employee_changes', label: 'Employee change requests', description: 'A client submits a change.', delivery_mode: 'digest', default_mode: 'digest' },
  ],
  recent_alerts: [
    { id: 1, category: 'client_messages', label: 'Client messages', company_name: 'Synthetic Client', status: 'skipped', delivery_mode: 'immediate',
      skip_reason: 'email_delivery_disabled', occurred_at: '2026-11-12T00:00:00Z', deliver_after: '2026-11-12T00:02:00Z', sent_at: null, attempts: 0 },
    { id: 2, category: 'employee_changes', label: 'Employee change requests', company_name: 'Synthetic Client', status: 'pending', delivery_mode: 'digest',
      skip_reason: null, occurred_at: '2026-11-12T00:00:00Z', deliver_after: '2026-11-12T21:00:00Z', sent_at: null, attempts: 0 },
  ],
};

describe('NotificationSettings', () => {
  afterEach(cleanup);
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.get.mockResolvedValue({ data: settings });
    mocks.update.mockImplementation(async (modes: Record<string, string>) => ({
      data: { ...settings, categories: settings.categories.map((category) => ({ ...category, delivery_mode: modes[category.key] })) },
    }));
  });

  it('shows defaults, the delivery-off notice and what happened to recent alerts', async () => {
    render(<NotificationSettings />);
    expect(await screen.findByText(/Your choices are saved and alerts are recorded/)).toBeTruthy();
    expect((screen.getByLabelText('Client messages') as HTMLSelectElement).value).toBe('immediate');
    expect((screen.getByLabelText('Employee change requests') as HTMLSelectElement).value).toBe('digest');
    expect(screen.getByText(/Daily digests arrive at 7:00 AM Chamorro Time/)).toBeTruthy();
    expect(screen.getByText('Email delivery is off for now.')).toBeTruthy();
    expect(screen.getByText(/In the next daily digest/)).toBeTruthy();
    expect(screen.queryByText('Clients with no alert recipients')).toBeNull();
  });

  it('saves only after a change and confirms', async () => {
    render(<NotificationSettings />);
    const save = await screen.findByRole('button', { name: 'Save settings' });
    expect(save.hasAttribute('disabled')).toBe(true);
    fireEvent.change(screen.getByLabelText('Employee change requests'), { target: { value: 'off' } });
    fireEvent.click(save);
    await waitFor(() => expect(mocks.update).toHaveBeenCalledWith({ client_messages: 'immediate', employee_changes: 'off' }));
    expect(await screen.findByText('Notification settings saved.')).toBeTruthy();
  });

  it('lets administrators open a client that has nobody to notify', async () => {
    mocks.switchCompany.mockReturnValue(true);
    mocks.get.mockResolvedValue({ data: { ...settings, administration: { clients_without_recipients: [
      { company_id: 7, company_name: 'Quiet Client', event_count: 3, last_occurred_at: '2026-11-12T00:00:00Z' },
    ] } } });
    render(<NotificationSettings />);
    expect(await screen.findByText('Quiet Client')).toBeTruthy();
    expect(screen.getByText(/3 items with nobody notified/)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Choose recipients' }));
    expect(mocks.switchCompany).toHaveBeenCalledWith(7);
    expect(mocks.navigate).toHaveBeenCalledWith('/settings/client-documents');
  });

  it('shows a retry when settings cannot load', async () => {
    mocks.get.mockRejectedValueOnce(new Error('Offline')).mockResolvedValueOnce({ data: settings });
    render(<NotificationSettings />);
    fireEvent.click(await screen.findByRole('button', { name: 'Retry' }));
    expect(await screen.findByLabelText('Client messages')).toBeTruthy();
  });

  it('shows a loading state until settings arrive', async () => {
    let resolveLoad!: (value: { data: Settings }) => void;
    mocks.get.mockImplementationOnce(() => new Promise((resolve) => { resolveLoad = resolve; }));
    render(<NotificationSettings />);
    expect(screen.getByText('Loading notification settings…')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Save settings' })).toBeNull();
    resolveLoad({ data: settings });
    expect(await screen.findByRole('button', { name: 'Save settings' })).toBeTruthy();
    expect(screen.queryByText('Loading notification settings…')).toBeNull();
  });

  it('shows empty recent alerts and an empty administrator list', async () => {
    mocks.get.mockResolvedValue({ data: { ...settings, email_delivery_enabled: true, recent_alerts: [],
      administration: { clients_without_recipients: [] } } });
    render(<NotificationSettings />);
    expect(await screen.findByText('No portal alerts yet.')).toBeTruthy();
    expect(screen.getByText('Every client with recent portal activity has alert recipients.')).toBeTruthy();
    expect(screen.queryByText(/Email delivery is off for now/)).toBeNull();
  });

  it('keeps choices after a failed save and saves them on retry', async () => {
    mocks.update.mockRejectedValueOnce(new Error('Could not reach the server'));
    render(<NotificationSettings />);
    fireEvent.change(await screen.findByLabelText('Client messages'), { target: { value: 'digest' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save settings' }));
    expect(await screen.findByText('Could not reach the server')).toBeTruthy();
    expect((screen.getByLabelText('Client messages') as HTMLSelectElement).value).toBe('digest');
    expect(screen.getByRole('button', { name: 'Save settings' }).hasAttribute('disabled')).toBe(false);

    fireEvent.click(screen.getByRole('button', { name: 'Save settings' }));
    expect(await screen.findByText('Notification settings saved.')).toBeTruthy();
    expect(mocks.update).toHaveBeenLastCalledWith({ client_messages: 'digest', employee_changes: 'digest' });
    expect(screen.queryByText('Could not reach the server')).toBeNull();
  });

  it('keeps a successful save when an older load finishes afterwards', async () => {
    let resolveFirst!: (value: { data: Settings }) => void;
    mocks.get.mockImplementationOnce(() => new Promise((resolve) => { resolveFirst = resolve; }))
      .mockResolvedValueOnce({ data: settings });
    // StrictMode starts the load twice, as in development.
    render(<StrictMode><NotificationSettings /></StrictMode>);
    fireEvent.change(await screen.findByLabelText('Employee change requests'), { target: { value: 'off' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save settings' }));
    expect(await screen.findByText('Notification settings saved.')).toBeTruthy();

    resolveFirst({ data: settings }); // started before the save, finishes after it
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect((screen.getByLabelText('Employee change requests') as HTMLSelectElement).value).toBe('off');
    expect(screen.getByRole('button', { name: 'Save settings' }).hasAttribute('disabled')).toBe(true);
  });
});
