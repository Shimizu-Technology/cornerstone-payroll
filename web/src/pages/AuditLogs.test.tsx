// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AuditLogEntry } from '@/services/api';
import { AuditLogs } from './AuditLogs';

const apiMocks = vi.hoisted(() => ({
  list: vi.fn(),
  exportCsv: vi.fn(),
  users: vi.fn(),
}));

vi.mock('@/services/api', () => ({
  auditLogsApi: { list: apiMocks.list, exportCsv: apiMocks.exportCsv },
  usersApi: { list: apiMocks.users },
}));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ isAdmin: true }),
}));

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({
    activeCompanyId: 7,
    activeCompany: { id: 7, name: 'Activity Client' },
  }),
}));

vi.mock('@/components/layout/Header', () => ({
  Header: ({ title }: { title: string }) => <h1>{title}</h1>,
}));

const access: AuditLogEntry = {
  id: 101,
  action: 'reports#payroll_register_pdf',
  display_action: 'Morgan Manager downloaded the payroll register',
  display_subject: 'Payroll Register',
  summary: '',
  record_type: 'reports',
  record_id: 18,
  user_id: 4,
  user_name: 'Morgan Manager',
  actor_email: 'morgan@example.com',
  actor_role: 'admin',
  event_category: 'document_access',
  subject_name: 'Payroll Register',
  organization_id: 1,
  organization_name: 'Activity Firm',
  company_id: 7,
  company_name: 'Activity Client',
  metadata: { report_key: 'payroll_register', report_target_key: 'native:18', report_format: 'PDF' },
  ip_address: '192.0.2.10',
  user_agent: 'Test browser',
  request_id: 'request-101',
  created_at: '2026-09-23T04:18:42Z',
};

const change: AuditLogEntry = {
  ...access,
  id: 201,
  action: 'employees#update',
  display_action: 'Morgan Manager updated Ada Payroll',
  display_subject: 'Ada Payroll',
  record_type: 'employees',
  record_id: 12,
  event_category: 'activity',
  metadata: { changed_fields: ['pay_rate'], before_values: { pay_rate: '18.00' }, after_values: { pay_rate: '20.00' } },
  request_id: 'request-201',
};

function response(data: AuditLogEntry[], page: number, totalPages: number) {
  return {
    data,
    meta: { current_page: page, per_page: 50, total_count: 2, total_pages: totalPages },
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

describe('AuditLogs pagination', () => {
  afterEach(cleanup);

  beforeEach(() => {
    vi.clearAllMocks();
    apiMocks.users.mockResolvedValue({ data: [] });
  });

  it('appends unseen rows and regroups an access burst across raw pages', async () => {
    apiMocks.list
      .mockResolvedValueOnce(response([access], 1, 2))
      .mockResolvedValueOnce(response([
        access,
        { ...access, id: 102, request_id: 'request-102', created_at: '2026-09-23T04:17:42Z' },
      ], 2, 2));

    render(<AuditLogs />);
    fireEvent.click(await screen.findByRole('button', { name: 'Load more activity' }));

    expect(await screen.findAllByText('Morgan Manager downloaded the payroll register · 2 access records')).toHaveLength(2);
    expect(apiMocks.list).toHaveBeenLastCalledWith(expect.objectContaining({ page: 2, per_page: 50 }));
  });

  it('retries a failed page without replacing the rows already loaded', async () => {
    apiMocks.list
      .mockResolvedValueOnce(response([access], 1, 2))
      .mockRejectedValueOnce(new Error('Older activity could not be loaded'))
      .mockResolvedValueOnce(response([
        { ...access, id: 102, request_id: 'request-102', created_at: '2026-09-23T04:17:42Z' },
      ], 2, 2));

    render(<AuditLogs />);
    fireEvent.click(await screen.findByRole('button', { name: 'Load more activity' }));

    expect(await screen.findByText('Older activity could not be loaded')).toBeTruthy();
    expect(screen.getAllByText('Morgan Manager downloaded the payroll register')).toHaveLength(2);
    fireEvent.click(screen.getByRole('button', { name: 'Try loading more activity again' }));

    expect(await screen.findAllByText('Morgan Manager downloaded the payroll register · 2 access records')).toHaveLength(2);
    expect(apiMocks.list).toHaveBeenCalledTimes(3);
  });

  it('ignores a stale pending page after the filters change', async () => {
    const pendingPage = deferred<ReturnType<typeof response>>();
    apiMocks.list.mockImplementation((params: { page: number; action_filter?: string }) => {
      if (params.page === 2) return pendingPage.promise;
      if (params.action_filter === 'employees') return Promise.resolve(response([change], 1, 1));
      return Promise.resolve(response([access], 1, 2));
    });

    render(<AuditLogs />);
    fireEvent.click(await screen.findByRole('button', { name: 'Load more activity' }));
    await waitFor(() => expect(apiMocks.list).toHaveBeenCalledWith(expect.objectContaining({ page: 2 })));

    fireEvent.change(screen.getByLabelText('Action'), { target: { value: 'employees' } });
    expect(await screen.findAllByText('Morgan Manager updated Ada Payroll')).toHaveLength(2);

    await act(async () => {
      pendingPage.resolve(response([
        { ...access, id: 102, request_id: 'request-102', created_at: '2026-09-23T04:17:42Z' },
      ], 2, 2));
      await pendingPage.promise;
    });

    expect(screen.queryByText('Morgan Manager downloaded the payroll register · 2 access records')).toBeNull();
    expect(screen.getAllByText('Morgan Manager updated Ada Payroll')).toHaveLength(2);
  });
});
