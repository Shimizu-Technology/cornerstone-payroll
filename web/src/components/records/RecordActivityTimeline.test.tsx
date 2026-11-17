// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ReactElement } from 'react';
import { MemoryRouter } from 'react-router';
import { RecordActivityTimeline } from './RecordActivityTimeline';

const apiMocks = vi.hoisted(() => ({ list: vi.fn() }));
const authState = vi.hoisted(() => ({ capabilities: ['view_audit_history'] as string[] }));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ hasCapability: (capability: string) => authState.capabilities.includes(capability) }),
}));

vi.mock('@/services/api', () => ({
  recordActivitiesApi: { list: apiMocks.list },
}));

const activity = {
  id: 91,
  action: 'employees#update',
  display_action: 'Morgan Manager updated Ada Payroll',
  display_subject: 'Ada Payroll',
  summary: 'Morgan Manager updated Ada Payroll · Activity Client',
  record_type: 'employees',
  record_id: 12,
  user_id: 4,
  user_name: 'Morgan Manager',
  actor_email: 'morgan@example.com',
  actor_role: 'manager',
  event_category: 'activity',
  subject_name: 'Ada Payroll',
  organization_id: 1,
  organization_name: 'Activity Firm',
  company_id: 7,
  company_name: 'Activity Client',
  metadata: {
    changed_fields: ['pay_rate', 'ssn'],
    before_values: { pay_rate: '18.00' },
    after_values: { pay_rate: '20.00' },
    redacted_fields: ['ssn'],
  },
  ip_address: '192.0.2.10',
  user_agent: 'Mozilla/5.0 Test Browser',
  request_id: 'request-91',
  created_at: '2026-09-23T01:30:00Z',
};

const renderTimeline = (element: ReactElement) => render(<MemoryRouter>{element}</MemoryRouter>);

describe('RecordActivityTimeline', () => {
  afterEach(cleanup);

  beforeEach(() => {
    vi.clearAllMocks();
    apiMocks.list.mockResolvedValue({
      data: [activity],
      meta: { current_page: 1, per_page: 20, total_count: 1, total_pages: 1 },
    });
  });

  it('shows plain-language activity, before-and-after values, and redaction guidance', async () => {
    renderTimeline(<RecordActivityTimeline companyId={7} recordId={12} recordType="employees" />);

    expect(await screen.findByText('Morgan Manager updated Ada Payroll')).toBeTruthy();
    expect(screen.getByText('morgan@example.com')).toBeTruthy();
    expect(screen.getByText('Pay rate')).toBeTruthy();
    expect(screen.getByText('18.00')).toBeTruthy();
    expect(screen.getByText('20.00')).toBeTruthy();
    expect(screen.getByText(/contents are hidden to protect sensitive information/)).toBeTruthy();
    expect(screen.getByText('Browser or device signature')).toBeTruthy();
    const technicalSummary = screen.getByText('Technical evidence');
    fireEvent.click(technicalSummary);
    expect(technicalSummary.closest('details')?.open).toBe(true);
    expect(apiMocks.list).toHaveBeenCalledWith('employees', 12, { page: 1, per_page: 20 }, 7);
  });

  it('suppresses request-only employee keys that have no stored values', async () => {
    apiMocks.list.mockResolvedValue({
      data: [{
        ...activity,
        id: 92,
        action: 'pay_periods#run_payroll',
        display_action: 'Morgan Manager processed payroll for Sep 1 – 15, 2026',
        metadata: { changed_fields: ['hours.104', 'hours.105'] },
      }],
      meta: { current_page: 1, per_page: 20, total_count: 1, total_pages: 1 },
    });

    renderTimeline(<RecordActivityTimeline companyId={7} recordId={12} recordType="pay_periods" />);

    expect(await screen.findByText(/processed payroll/)).toBeTruthy();
    expect(screen.queryByText('Hours 104')).toBeNull();
    expect(screen.queryByText('Before')).toBeNull();
    expect(screen.queryByText('After')).toBeNull();
  });

  it('marks approve, roll back and approve again as separate milestones', async () => {
    apiMocks.list.mockResolvedValue({
      data: [
        { ...activity, id: 3, action: 'pay_periods#approve', display_action: 'Morgan Manager approved payroll again', metadata: {} },
        { ...activity, id: 2, action: 'pay_periods#unapprove', display_action: 'Morgan Manager reopened payroll approval', metadata: {} },
        { ...activity, id: 1, action: 'pay_periods#approve', display_action: 'Morgan Manager approved payroll', metadata: {} },
      ],
      meta: { current_page: 1, per_page: 20, total_count: 3, total_pages: 1 },
    });

    renderTimeline(<RecordActivityTimeline companyId={7} recordId={12} recordType="pay_periods" />);

    expect(await screen.findByText('Morgan Manager approved payroll again')).toBeTruthy();
    expect(screen.getAllByText('Approved')).toHaveLength(2);
    expect(screen.getByText('Approval rolled back')).toBeTruthy();
  });

  it('lists whose entries a calculation changed', async () => {
    apiMocks.list.mockResolvedValue({
      data: [{
        ...activity,
        id: 93,
        action: 'pay_periods#run_payroll',
        display_action: 'Morgan Manager calculated payroll with changed entries for 12 employees',
        detail_lines: Array.from({ length: 11 }, (_, index) => `Worker ${index + 1}: regular hours 0 → 40`),
        metadata: { input_change_count: 12 },
      }],
      meta: { current_page: 1, per_page: 20, total_count: 1, total_pages: 1 },
    });

    renderTimeline(<RecordActivityTimeline companyId={7} recordId={12} recordType="pay_periods" />);

    expect(await screen.findByText('Worker 1: regular hours 0 → 40')).toBeTruthy();
    expect(screen.getByText('Worker 10: regular hours 0 → 40')).toBeTruthy();
    expect(screen.queryByText('Worker 11: regular hours 0 → 40')).toBeNull();
    expect(screen.getByText('and 2 more')).toBeTruthy();
  });

  it('hides report editor loads until asked, then reloads with them', async () => {
    apiMocks.list
      .mockResolvedValueOnce({
        data: [activity],
        meta: { current_page: 1, per_page: 20, total_count: 1, total_pages: 1, hidden_report_detail_count: 3 },
      })
      .mockResolvedValueOnce({
        data: [activity, { ...activity, id: 45, display_action: 'Morgan Manager viewed a preview of the transmittal log' }],
        meta: { current_page: 1, per_page: 20, total_count: 2, total_pages: 1, hidden_report_detail_count: 0 },
      });

    renderTimeline(<RecordActivityTimeline companyId={7} recordId={12} recordType="pay_periods" />);

    expect(await screen.findByText(/3 transmittal and sign-off detail loads are hidden/)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Show them' }));

    expect(await screen.findByText('Morgan Manager viewed a preview of the transmittal log')).toBeTruthy();
    expect(apiMocks.list).toHaveBeenLastCalledWith('pay_periods', 12, { page: 1, per_page: 20, include_report_details: true }, 7);
    expect(screen.getByRole('button', { name: 'Hide them' })).toBeTruthy();
  });

  it('loads older activity without replacing the newest entries', async () => {
    apiMocks.list
      .mockResolvedValueOnce({
        data: [activity],
        meta: { current_page: 1, per_page: 20, total_count: 2, total_pages: 2 },
      })
      .mockResolvedValueOnce({
        data: [activity, { ...activity, id: 44, display_action: 'Morgan Manager added Ada Payroll' }],
        meta: { current_page: 2, per_page: 20, total_count: 2, total_pages: 2 },
      });

    renderTimeline(<RecordActivityTimeline companyId={7} recordId={12} recordType="employees" />);
    fireEvent.click(await screen.findByRole('button', { name: 'Load older activity' }));

    expect(await screen.findByText('Morgan Manager added Ada Payroll')).toBeTruthy();
    expect(screen.getAllByText('Morgan Manager updated Ada Payroll')).toHaveLength(1);
    expect(apiMocks.list).toHaveBeenLastCalledWith('employees', 12, { page: 2, per_page: 20 }, 7);
  });

  it('offers a retry when the initial request fails', async () => {
    apiMocks.list.mockRejectedValueOnce(new Error('History service unavailable'));

    renderTimeline(<RecordActivityTimeline companyId={7} recordId={12} recordType="employees" />);

    expect(await screen.findByText('History service unavailable')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));

    await waitFor(() => expect(apiMocks.list).toHaveBeenCalledTimes(2));
    expect(await screen.findByText('Morgan Manager updated Ada Payroll')).toBeTruthy();
  });
});

it('shows an explicit empty history and unknown creator', async () => {
  apiMocks.list.mockResolvedValue({ data: [], creator: null, meta: { current_page: 1, total_pages: 0 } });
  renderTimeline(<RecordActivityTimeline companyId={7} recordId={12} recordType="employees" />);
  expect(await screen.findByText('No recorded activity yet')).toBeTruthy();
  expect(screen.getByText('Unknown (before tracking)')).toBeTruthy();
  cleanup();
});

it('exposes an accessible loading state while history is pending', () => {
  apiMocks.list.mockReturnValue(new Promise(() => {}));
  renderTimeline(<RecordActivityTimeline companyId={7} recordId={12} recordType="employees" />);
  expect(screen.getByRole('status', { name: 'Loading activity history' })).toBeTruthy();
  cleanup();
});

it('links to Activity History only for people who can open it', async () => {
  apiMocks.list.mockResolvedValue({ data: [], creator: null, meta: { current_page: 1, total_pages: 0 } });
  authState.capabilities = ['view_audit_history'];
  renderTimeline(<RecordActivityTimeline companyId={7} recordId={12} recordType="companies" />);
  const link = await screen.findByRole('link', { name: 'View in Activity History' });
  expect(link.getAttribute('href')).toBe('/settings/audit-logs?record_type=companies&record_id=12&company_id=7');
  cleanup();

  authState.capabilities = ['staff_workspace'];
  renderTimeline(<RecordActivityTimeline companyId={7} recordId={12} recordType="companies" />);
  expect(await screen.findByText('No recorded activity yet')).toBeTruthy();
  expect(screen.queryByRole('link', { name: 'View in Activity History' })).toBeNull();
  authState.capabilities = ['view_audit_history'];
  cleanup();
});
