// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { RecordActivityTimeline } from './RecordActivityTimeline';

const apiMocks = vi.hoisted(() => ({ list: vi.fn() }));

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
    render(<RecordActivityTimeline companyId={7} recordId={12} recordType="employees" />);

    expect(await screen.findByText('Morgan Manager updated Ada Payroll')).toBeTruthy();
    expect(screen.getByText('morgan@example.com')).toBeTruthy();
    expect(screen.getByText('Pay rate')).toBeTruthy();
    expect(screen.getByText('18.00')).toBeTruthy();
    expect(screen.getByText('20.00')).toBeTruthy();
    expect(screen.getByText(/contents are hidden to protect sensitive information/)).toBeTruthy();
    expect(screen.getByText('Browser or device signature')).toBeTruthy();
    const technicalSummary = screen.getByText('Technical details');
    fireEvent.click(technicalSummary);
    expect(technicalSummary.closest('details')?.open).toBe(true);
    expect(apiMocks.list).toHaveBeenCalledWith('employees', 12, { page: 1, per_page: 20 }, 7);
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

    render(<RecordActivityTimeline companyId={7} recordId={12} recordType="employees" />);
    fireEvent.click(await screen.findByRole('button', { name: 'Load older activity' }));

    expect(await screen.findByText('Morgan Manager added Ada Payroll')).toBeTruthy();
    expect(screen.getAllByText('Morgan Manager updated Ada Payroll')).toHaveLength(1);
    expect(apiMocks.list).toHaveBeenLastCalledWith('employees', 12, { page: 2, per_page: 20 }, 7);
  });

  it('offers a retry when the initial request fails', async () => {
    apiMocks.list.mockRejectedValueOnce(new Error('History service unavailable'));

    render(<RecordActivityTimeline companyId={7} recordId={12} recordType="employees" />);

    expect(await screen.findByText('History service unavailable')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));

    await waitFor(() => expect(apiMocks.list).toHaveBeenCalledTimes(2));
    expect(await screen.findByText('Morgan Manager updated Ada Payroll')).toBeTruthy();
  });
});
