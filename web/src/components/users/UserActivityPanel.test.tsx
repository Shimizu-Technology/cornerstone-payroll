// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AuditLogEntry } from '@/services/api';
import type { User } from '@/types';
import { UserActivityPanel } from './UserActivityPanel';

const apiMocks = vi.hoisted(() => ({ list: vi.fn() }));

vi.mock('@/services/api', () => ({
  auditLogsApi: { list: apiMocks.list },
}));

const user: User = {
  id: 7,
  email: 'ada@example.com',
  name: 'Ada Payroll',
  role: 'accountant',
  created_at: '2026-01-02T00:00:00Z',
  updated_at: '2026-09-23T00:00:00Z',
  last_login_at: '2026-09-23T01:30:00Z',
  last_active_at: '2026-09-23T01:35:00Z',
  invited_by_name: 'Morgan Manager',
};

const signIn: AuditLogEntry = {
  id: 91,
  action: 'authentication#signed_in',
  display_action: 'Ada Payroll signed in',
  display_subject: 'Ada Payroll',
  summary: 'Ada Payroll signed in',
  record_type: 'users',
  record_id: 7,
  user_id: 7,
  user_name: 'Ada Payroll',
  actor_email: 'ada@example.com',
  actor_role: 'accountant',
  event_category: 'security',
  subject_name: 'Ada Payroll',
  organization_id: 1,
  organization_name: 'Cornerstone',
  company_id: null,
  company_name: null,
  metadata: { source: 'clerk_session' },
  ip_address: '192.0.2.10',
  user_agent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0.0.0 Safari/537.36',
  request_id: 'request-91',
  created_at: '2026-09-23T01:30:00Z',
};

const emptyResponse = {
  data: [],
  meta: { current_page: 1, per_page: 25, total_count: 0, total_pages: 0 },
};

describe('UserActivityPanel', () => {
  afterEach(cleanup);

  beforeEach(() => {
    vi.clearAllMocks();
    apiMocks.list.mockResolvedValue(emptyResponse);
  });

  it('loads only exact successful security events and explains the Clerk boundary', async () => {
    apiMocks.list.mockImplementation(async (params: Record<string, unknown>) => (
      params.event_action
        ? { data: [signIn], meta: { current_page: 1, per_page: 25, total_count: 1, total_pages: 1 } }
        : emptyResponse
    ));

    render(<UserActivityPanel user={user} onClose={vi.fn()} />);
    fireEvent.click(screen.getByRole('tab', { name: 'Sign-in history' }));

    expect(await screen.findByText('Successful sign-in')).toBeTruthy();
    expect(screen.getByText('Chrome on macOS')).toBeTruthy();
    expect(screen.getByText('192.0.2.10')).toBeTruthy();
    expect(screen.getByText('Chrome')).toBeTruthy();
    expect(screen.getByText('macOS')).toBeTruthy();
    expect(screen.getByText('Desktop')).toBeTruthy();
    expect(screen.getByText(/Failed sign-in attempts are managed by Clerk/)).toBeTruthy();
    const recordedTime = document.querySelector('time[datetime="2026-09-23T01:30:00Z"]');
    expect(recordedTime?.textContent).toContain('Sep 23, 2026');
    expect(recordedTime?.textContent).toContain('11:30:00 AM');
    await waitFor(() => expect(apiMocks.list).toHaveBeenLastCalledWith({
      user_id: 7,
      event_action: 'authentication#signed_in',
      event_category: 'security',
      page: 1,
      per_page: 25,
      sort_direction: 'desc',
    }));

    fireEvent.click(screen.getByText('Technical details'));
    expect(screen.getByText(signIn.user_agent as string)).toBeTruthy();
    expect(screen.getByText('request-91')).toBeTruthy();
  });

  it('uses unknown labels for malformed browser signatures', async () => {
    apiMocks.list.mockImplementation(async (params: Record<string, unknown>) => (
      params.event_action
        ? { data: [{ ...signIn, user_agent: 'not-a-real-user-agent', ip_address: null, request_id: null }], meta: { current_page: 1, per_page: 25, total_count: 1, total_pages: 1 } }
        : emptyResponse
    ));

    render(<UserActivityPanel user={user} onClose={vi.fn()} />);
    fireEvent.click(screen.getByRole('tab', { name: 'Sign-in history' }));

    expect(await screen.findByText('Unknown browser/device')).toBeTruthy();
    expect(screen.getByText('Unknown browser')).toBeTruthy();
    expect(screen.getByText('Unknown platform')).toBeTruthy();
    expect(screen.getByText('Unknown')).toBeTruthy();
    expect(screen.getByText('Not captured')).toBeTruthy();
  });

  it('shows a precise empty state when no successful sign-ins are recorded', async () => {
    render(<UserActivityPanel user={user} onClose={vi.fn()} />);
    fireEvent.click(screen.getByRole('tab', { name: 'Sign-in history' }));

    expect(await screen.findByText('No successful sign-ins recorded yet')).toBeTruthy();
    expect(screen.getByText(/starts a Clerk session and makes an authenticated request/)).toBeTruthy();
  });

  it('loads older sign-ins without duplicating rows shifted across pages', async () => {
    const olderSignIn = {
      ...signIn,
      id: 44,
      ip_address: '192.0.2.44',
      created_at: '2026-09-22T01:30:00Z',
    };
    apiMocks.list.mockImplementation(async (params: Record<string, unknown>) => {
      if (!params.event_action) return emptyResponse;
      if (params.page === 2) {
        return { data: [signIn, olderSignIn], meta: { current_page: 2, per_page: 25, total_count: 2, total_pages: 2 } };
      }
      return { data: [signIn], meta: { current_page: 1, per_page: 25, total_count: 2, total_pages: 2 } };
    });

    render(<UserActivityPanel user={user} onClose={vi.fn()} />);
    fireEvent.click(screen.getByRole('tab', { name: 'Sign-in history' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Load older activity' }));

    await screen.findByText('192.0.2.44');
    expect(screen.getAllByText('Successful sign-in')).toHaveLength(2);
    expect(screen.getAllByText('192.0.2.10')).toHaveLength(1);
  });

  it('keeps the three history tabs usable in a horizontally scrollable mobile rail', () => {
    render(<UserActivityPanel user={user} onClose={vi.fn()} />);

    const tabList = screen.getByRole('tablist', { name: 'User history views' });
    expect(tabList.className).toContain('min-w-[33rem]');
    expect(tabList.parentElement?.className).toContain('overflow-x-auto');
    screen.getAllByRole('tab').forEach((tab) => expect(tab.className).toContain('min-h-11'));
  });
});
