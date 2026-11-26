// @vitest-environment jsdom

import { MemoryRouter } from 'react-router';
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import type { ClientPortalThread, PortalFileRequest } from '@/services/api';
import { clientPayrollSubmissionsApi, type PayrollSubmissionsApi } from '@/services/payrollSubmissions';
import { PeriodConversation } from './PeriodConversation';

const auth = vi.hoisted(() => ({ isClientViewer: false }));
vi.mock('@/contexts/AuthContext', () => ({ useOptionalAuth: () => auth }));

afterEach(() => { cleanup(); auth.isClientViewer = false; });

const conversation = (status: PortalFileRequest['status']): ClientPortalThread => ({
  id: 5, company_id: 1, subject: 'Payroll', status: 'open', unread: false, created_at: '2026-11-12T00:00:00Z', updated_at: '2026-11-12T00:00:00Z',
  messages: [{ id: 1, thread_id: 5, kind: 'file_request', author_name: 'Dafne', created_at: '2026-11-12T00:00:00Z',
    file_request: { id: 2, thread_id: 5, title: 'Timesheet', category: 'payroll_source', status, status_label: status, created_at: '2026-11-12T00:00:00Z', lock_version: 0 } }],
});

function view(status: PortalFileRequest['status']): void {
  const api = { ...clientPayrollSubmissionsApi, threads: { ...clientPayrollSubmissionsApi.threads, get: vi.fn().mockResolvedValue({ data: conversation(status) }), markRead: vi.fn() } } as unknown as PayrollSubmissionsApi;
  render(<MemoryRouter><PeriodConversation api={api} periodRef="7" threadId={5} onThreadCreated={vi.fn()} /></MemoryRouter>);
}

it('asks the client for a requested file, then shows it as under review once sent', async () => {
  view('requested');
  expect(await screen.findByText(/Cornerstone asked for a file/)).toBeTruthy();
  expect(screen.getByRole('link', { name: 'Send it in Messages' })).toBeTruthy();
  cleanup();
  view('responded');
  expect(await screen.findByText(/Cornerstone is reviewing it/)).toBeTruthy();
  expect(screen.queryByRole('link', { name: 'Send it in Messages' })).toBeNull();
});

it('shows a client viewer a failed load, with the view-only note instead of the message form', async () => {
  auth.isClientViewer = true;
  const api = { ...clientPayrollSubmissionsApi, threads: { ...clientPayrollSubmissionsApi.threads, get: vi.fn().mockRejectedValue(new Error('Could not load the conversation')), markRead: vi.fn() } } as unknown as PayrollSubmissionsApi;
  render(<MemoryRouter><PeriodConversation api={api} periodRef="7" threadId={5} onThreadCreated={vi.fn()} /></MemoryRouter>);

  expect((await screen.findByRole('alert')).textContent).toBe('Could not load the conversation');
  expect(screen.getByText('Your access is view-only. Ask your account manager for changes.')).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Send message' })).toBeNull();
});
