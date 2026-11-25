// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { SharedInboxReportPanel } from './SharedInboxReportPanel';
import type { SharedEmailReportResponse } from '@/services/staffContactHygieneApi';

const sharedEmails = vi.hoisted(() => vi.fn());

vi.mock('@/services/staffContactHygieneApi', () => ({
  staffContactHygieneApi: { sharedEmails, markPlaceholderEmail: vi.fn(), unmarkPlaceholderEmail: vi.fn(), clearSharedEmails: vi.fn() },
}));

function reportFor(companyId: number, companyName: string, email: string): SharedEmailReportResponse {
  return {
    summary: { companies_affected: 1, distinct_flagged_emails: 1, total_employee_records: 2, active_employee_records: 2 },
    can_manage_placeholders: false,
    can_clear: true,
    marked_placeholders: [],
    placeholder_marks: [],
    companies: [{
      company_id: companyId, company_name: companyName, total_flagged_records: 2, active_flagged_records: 2,
      emails: [{
        email, classification: 'shared', reasons: ['shared_within_company'], total_count: 2, active_count: 2,
        inactive_count: 0, companies_count: 1, organization_total_count: 2, clearable: false, marked_placeholder: false,
        unmarkable: false,
      }],
    }],
  } as SharedEmailReportResponse;
}

afterEach(() => {
  cleanup();
  sharedEmails.mockReset();
});

describe('SharedInboxReportPanel', () => {
  it('asks for the selected company and reloads when the selection changes', async () => {
    let answerFirst: (report: SharedEmailReportResponse) => void = () => {};
    sharedEmails
      .mockImplementationOnce(() => new Promise<SharedEmailReportResponse>((resolve) => { answerFirst = resolve; }))
      .mockResolvedValueOnce(reportFor(9, 'Harbor Finch Kitchen', 'front@kitchen.example'));

    const { rerender } = render(<SharedInboxReportPanel activeCompanyId={1} />);
    expect(sharedEmails).toHaveBeenLastCalledWith(1);

    rerender(<SharedInboxReportPanel activeCompanyId={9} />);
    expect(sharedEmails).toHaveBeenLastCalledWith(9);
    expect((await screen.findAllByText('front@kitchen.example')).length).toBeGreaterThan(0);

    // The earlier company's answer arrives late and is dropped.
    answerFirst(reportFor(1, 'Live Grill', 'office@live.example'));
    await waitFor(() => expect(screen.queryByText('office@live.example')).toBeNull());
    expect(screen.queryByText('Live Grill')).toBeNull();
    expect(sharedEmails).toHaveBeenCalledTimes(2);
  });
});
