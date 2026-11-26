// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { StrictMode } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { PortalAlertRecipientsPanel } from './PortalAlertRecipientsPanel';
import type { PortalAlertRecipients } from '@/services/portal-notifications-api';

const mocks = vi.hoisted(() => ({ get: vi.fn(), update: vi.fn() }));
vi.mock('@/services/portal-notifications-api', () => ({ portalAlertRecipientsApi: { get: mocks.get, update: mocks.update } }));

const base: PortalAlertRecipients = {
  company_id: 4,
  eligible_users: [
    { id: 1, name: 'Dana Synthetic', email: 'dana@example.test', role: 'manager', selected: false, team_role: null },
    { id: 2, name: 'Morgan Synthetic', email: 'morgan@example.test', role: 'admin', selected: false, team_role: null },
  ],
  lead_user_id: null,
  backup_user_id: null,
  ineligible_listed_users: [],
  extra_emails: [],
  recipient_count: 0,
  max_extra_emails: 20,
  unnotified_event_count: 2,
  email_delivery_enabled: false,
};

describe('PortalAlertRecipientsPanel', () => {
  afterEach(cleanup);
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.get.mockResolvedValue({ data: base });
  });

  it('warns when no account team is assigned and says email is off', async () => {
    const onCount = vi.fn();
    render(<PortalAlertRecipientsPanel companyId={4} onRecipientCountChange={onCount} />);
    const warning = await screen.findByRole('alert');
    expect(warning.textContent).toContain('No Cornerstone account team is assigned to this client.');
    expect(warning.textContent).toContain('2 in the last 30 days had nobody to notify');
    expect(screen.getByText(/Email delivery is off for now/)).toBeTruthy();
    expect(onCount).toHaveBeenLastCalledWith(0);
    expect(screen.getByRole('button', { name: 'Save account team' }).hasAttribute('disabled')).toBe(true);
  });

  it('assigns Lead and Backup, ticks staff, and saves normalized deduplicated extra addresses', async () => {
    mocks.update.mockResolvedValue({
      data: {
        ...base,
        recipient_count: 3,
        lead_user_id: 1,
        backup_user_id: 2,
        extra_emails: ['owner@example.test'],
        eligible_users: base.eligible_users.map((user) => ({
          ...user,
          selected: true,
          team_role: user.id === 1 ? 'lead' : 'backup',
        })),
      },
    });
    render(<PortalAlertRecipientsPanel companyId={4} />);

    // Picking a Lead and Backup automatically selects both users on the account team.
    const leadSelect = await screen.findByLabelText('Account lead');
    const backupSelect = screen.getByLabelText('Backup (optional)');
    fireEvent.change(leadSelect, { target: { value: '1' } });
    fireEvent.change(backupSelect, { target: { value: '2' } });
    expect((screen.getByLabelText(/Dana Synthetic/) as HTMLInputElement).checked).toBe(true);
    expect((screen.getByLabelText(/Morgan Synthetic/) as HTMLInputElement).checked).toBe(true);

    const input = screen.getByLabelText('Extra email address');
    fireEvent.change(input, { target: { value: 'not-an-email' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add address' }));
    expect(screen.getByText('Enter a valid email address.')).toBeTruthy();

    fireEvent.change(input, { target: { value: '  Owner@Example.TEST ' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add address' }));
    fireEvent.change(input, { target: { value: 'owner@example.test' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add address' }));
    expect(screen.getByText('That address is already on the list.')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Save account team' }));
    await waitFor(() => expect(mocks.update).toHaveBeenCalledWith(4, {
      user_ids: [1, 2],
      emails: ['owner@example.test'],
      lead_user_id: 1,
      backup_user_id: 2,
    }));
    expect(await screen.findByText('Account team saved.')).toBeTruthy();
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('clears Lead when that person is unticked or switched to Backup', async () => {
    mocks.get.mockResolvedValue({
      data: {
        ...base,
        recipient_count: 1,
        lead_user_id: 1,
        eligible_users: base.eligible_users.map((user) => ({
          ...user,
          selected: user.id === 1,
          team_role: user.id === 1 ? 'lead' : null,
        })),
      },
    });
    render(<PortalAlertRecipientsPanel companyId={4} />);

    const leadSelect = await screen.findByLabelText('Account lead') as HTMLSelectElement;
    const backupSelect = screen.getByLabelText('Backup (optional)') as HTMLSelectElement;
    expect(leadSelect.value).toBe('1');

    // Choosing Dana as Backup clears Lead.
    fireEvent.change(backupSelect, { target: { value: '1' } });
    expect(leadSelect.value).toBe('');
    expect(backupSelect.value).toBe('1');

    // Unticking Dana clears Backup too.
    fireEvent.click(screen.getByLabelText(/Dana Synthetic/));
    expect(backupSelect.value).toBe('');
  });

  it('removes an extra address and reports a failed save without losing the draft', async () => {
    mocks.get.mockResolvedValue({ data: { ...base, recipient_count: 1, extra_emails: ['books@example.test'] } });
    mocks.update.mockRejectedValue(new Error('Check these email addresses'));
    render(<PortalAlertRecipientsPanel companyId={4} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Remove books@example.test' }));
    expect(screen.getByText('Saving with nobody selected leaves this client without an account team.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Save account team' }));
    expect(await screen.findByText('Check these email addresses')).toBeTruthy();
    expect(screen.queryByText('books@example.test')).toBeNull();
  });

  it('shows listed users who are no longer eligible', async () => {
    mocks.get.mockResolvedValue({ data: { ...base, recipient_count: 0, ineligible_listed_users: [{ id: 9, name: 'Former Staffer' }] } });
    render(<PortalAlertRecipientsPanel companyId={4} />);
    expect(await screen.findByText(/will be removed when you save: Former Staffer/)).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Save account team' }).hasAttribute('disabled')).toBe(false);
  });

  it('is read-only when the workspace cannot be changed', async () => {
    mocks.get.mockResolvedValue({ data: { ...base, recipient_count: 1, extra_emails: ['books@example.test'] } });
    render(<PortalAlertRecipientsPanel companyId={4} readOnly />);
    const list = await screen.findByText('books@example.test');
    expect(within(list.closest('li') as HTMLElement).queryByRole('button')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Save account team' })).toBeNull();
    expect(screen.queryByLabelText('Extra email address')).toBeNull();
    expect((screen.getByLabelText('Account lead') as HTMLSelectElement).disabled).toBe(true);
  });

  it('offers a retry when account team cannot load', async () => {
    mocks.get.mockRejectedValueOnce(new Error('Unavailable')).mockResolvedValueOnce({ data: base });
    render(<PortalAlertRecipientsPanel companyId={4} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Retry account team' }));
    expect(await screen.findByLabelText(/Dana Synthetic/)).toBeTruthy();
  });

  it('ignores a response for a previously selected client', async () => {
    let resolveFirst!: (value: { data: PortalAlertRecipients }) => void;
    mocks.get.mockImplementationOnce(() => new Promise((resolve) => { resolveFirst = resolve; }))
      .mockResolvedValueOnce({ data: { ...base, company_id: 5, extra_emails: ['second@example.test'], recipient_count: 1 } });
    const { rerender } = render(<PortalAlertRecipientsPanel companyId={4} />);
    rerender(<PortalAlertRecipientsPanel companyId={5} />);
    expect(await screen.findByText('second@example.test')).toBeTruthy();
    resolveFirst({ data: { ...base, extra_emails: ['first@example.test'], recipient_count: 1 } });
    await waitFor(() => expect(screen.queryByText('first@example.test')).toBeNull());
  });

  it('ignores the older of two overlapping loads', async () => {
    let resolveFirst!: (value: { data: PortalAlertRecipients }) => void;
    mocks.get.mockImplementationOnce(() => new Promise((resolve) => { resolveFirst = resolve; }))
      .mockResolvedValueOnce({ data: { ...base, extra_emails: ['newest@example.test'], recipient_count: 1 } });
    render(<StrictMode><PortalAlertRecipientsPanel companyId={4} /></StrictMode>);
    expect(await screen.findByText('newest@example.test')).toBeTruthy();
    resolveFirst({ data: { ...base, extra_emails: ['stale@example.test'], recipient_count: 1 } });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(screen.queryByText('stale@example.test')).toBeNull();
  });

  it('keeps a successful save when an older load finishes afterwards', async () => {
    let resolveFirst!: (value: { data: PortalAlertRecipients }) => void;
    const onCount = vi.fn();
    const saved = { ...base, recipient_count: 1, eligible_users: base.eligible_users.map((user) => ({ ...user, selected: user.id === 2 })) };
    mocks.get.mockImplementationOnce(() => new Promise((resolve) => { resolveFirst = resolve; }))
      .mockResolvedValueOnce({ data: base });
    mocks.update.mockResolvedValue({ data: saved });
    render(<StrictMode><PortalAlertRecipientsPanel companyId={4} onRecipientCountChange={onCount} /></StrictMode>);
    fireEvent.click(await screen.findByLabelText(/Morgan Synthetic/));
    fireEvent.click(screen.getByRole('button', { name: 'Save account team' }));
    expect(await screen.findByText('Account team saved.')).toBeTruthy();

    resolveFirst({ data: base });
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect((screen.getByLabelText(/Morgan Synthetic/) as HTMLInputElement).checked).toBe(true);
    expect(screen.queryByRole('alert')).toBeNull();
    expect(onCount).toHaveBeenLastCalledWith(1);
  });

  it('ignores a request from a panel replaced for another client', async () => {
    let resolveOld!: (value: { data: PortalAlertRecipients }) => void;
    const onCount = vi.fn();
    mocks.get.mockImplementationOnce(() => new Promise((resolve) => { resolveOld = resolve; }))
      .mockResolvedValueOnce({ data: { ...base, company_id: 5, recipient_count: 3, extra_emails: ['b@example.test'] } });
    const { rerender } = render(<PortalAlertRecipientsPanel key={4} companyId={4} onRecipientCountChange={onCount} />);
    rerender(<PortalAlertRecipientsPanel key={5} companyId={5} onRecipientCountChange={onCount} />);
    expect(await screen.findByText('b@example.test')).toBeTruthy();

    resolveOld({ data: { ...base, recipient_count: 0 } });
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(onCount).toHaveBeenLastCalledWith(3);
    expect(onCount).not.toHaveBeenCalledWith(0);
    expect(screen.queryByRole('alert')).toBeNull();
  });

  it('ignores a save that finishes after the panel is gone', async () => {
    let resolveSave!: (value: { data: PortalAlertRecipients }) => void;
    const onCount = vi.fn();
    mocks.update.mockImplementationOnce(() => new Promise((resolve) => { resolveSave = resolve; }));
    const { unmount } = render(<PortalAlertRecipientsPanel companyId={4} onRecipientCountChange={onCount} />);
    fireEvent.click(await screen.findByLabelText(/Dana Synthetic/));
    fireEvent.click(screen.getByRole('button', { name: 'Save account team' }));
    unmount();
    onCount.mockClear();
    resolveSave({ data: { ...base, recipient_count: 7 } });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(onCount).not.toHaveBeenCalled();
  });
});
