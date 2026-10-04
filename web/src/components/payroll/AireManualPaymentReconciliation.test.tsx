// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AireManualPaymentReconciliation } from './AireManualPaymentReconciliation';
import type { AireManualAllocation, AirePayrollManualReview, PayrollItem } from '@/types';

const mocks = vi.hoisted(() => ({ review: vi.fn(), create: vi.fn(), retry: vi.fn(), capability: vi.fn() }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ hasCapability: mocks.capability }) }));
vi.mock('@/services/api', () => ({ payPeriodsApi: {
  airePayrollManualReview: mocks.review, createAireManualAllocation: mocks.create, retryAireManualAllocation: mocks.retry,
} }));
const uuid = '282bf986-dd27-46fa-bd70-65ebbc9d9cea';
const entry = { source_time_entry_id: '40', source_time_entry_version: 3, source_kind: 'carryover' as const,
  original_work_date: '2026-08-15', total_hours: 6.1, regular_hours: 5.1, overtime_hours: 1 };
const review: AirePayrollManualReview = {
  start_date: '2026-08-16', end_date: '2026-08-31', generated_at: '2026-09-15T09:00:00+10:00',
  command_access: { can_manage_manual_allocations: true }, cornerstone_manual_allocations: [],
  employees: [{ source_user_id: '91', source_user_uuid: uuid, display_name: 'Manual Employee',
    total_hours: 6.1, regular_hours: 5.1, overtime_hours: 1, adjustments: [entry],
    cornerstone: { status: 'mapped', employee_id: 7, employee_name: 'Manual Employee' } }],
  exclusions: [], issues: { missing_category_count: 0, negative_adjustment_count: 0, pending_approval_count: 0,
    denied_approval_count: 0, open_clock_count: 0, pending_overtime_count: 0, denied_overtime_count: 0 },
  summary: { employee_count: 1, adjustment_count: 1, total_hours: 6.1, regular_hours: 5.1, overtime_hours: 1,
    current_count: 0, carryover_count: 1, correction_count: 0, exclusion_count: 0 },
};
const item = { id: 12, employee_id: 7, employment_type: 'hourly', pay_rate: 15, hours_worked: 5.1,
  overtime_hours: 1, check_number: '0012', check_status: 'prepared', payment_delivery_method: 'paper_check' } as PayrollItem;
const allocation: AireManualAllocation = { id: 9, employee_name: 'Manual Employee', employee_id: 7, payroll_item_id: 12,
  source_time_entry_id: '40', source_time_entry_version: 3, source_user_uuid: uuid,
  original_work_date: entry.original_work_date, regular_hours: 5.1, overtime_hours: 1, status: 'committed' };
const props = { payPeriodId: 67, payPeriodStatus: 'committed' as const, payPeriodVoided: false,
  payrollItems: [item], onChanged: vi.fn() };
beforeEach(() => { vi.resetAllMocks(); mocks.capability.mockReturnValue(true); mocks.review.mockResolvedValue(review); });
afterEach(cleanup);

async function choose() {
  const user = userEvent.setup();
  await screen.findByRole('option', { name: /Manual Employee.*entry 40/ });
  await user.selectOptions(screen.getByLabelText('Exact AIRE time entry'), `${uuid}:40:carryover`);
  await user.selectOptions(screen.getByLabelText('Existing committed payroll item'), '12');
  await user.type(screen.getByLabelText('Evidence and reconciliation reason'), 'Verified hours against existing check 0012');
  return user;
}

describe('AireManualPaymentReconciliation', () => {
  it('sends the exact source identity, version, original date and decimal hours; prepared is unpaid', async () => {
    mocks.create.mockResolvedValue({ manual_allocation: allocation });
    mocks.review.mockResolvedValueOnce(review).mockResolvedValue({ ...review, cornerstone_manual_allocations: [allocation] });
    render(<AireManualPaymentReconciliation {...props} />);
    const user = await choose();
    await user.click(screen.getByRole('button', { name: 'Link hours to payroll item' }));
    await waitFor(() => expect(mocks.create).toHaveBeenCalledWith(67, {
      payroll_item_id: 12, source_time_entry_id: '40', source_time_entry_version: 3, source_user_uuid: uuid,
      original_work_date: '2026-08-15', regular_hours: '5.10', overtime_hours: '1.00',
      note: 'Verified hours against existing check 0012',
    }));
    expect(await screen.findAllByText('Linked; payment evidence pending')).toHaveLength(2);
    expect(screen.queryByText('Payment recorded in AIRE')).toBeNull();
    expect(props.onChanged).toHaveBeenCalled();
  });

  it('keeps an outage record visible and retries its existing ID without another allocation', async () => {
    const pending = { ...allocation, status: 'pending_commit', last_sync_error: 'AIRE unavailable' };
    mocks.create.mockResolvedValue({ manual_allocation: pending });
    mocks.review.mockResolvedValueOnce(review).mockRejectedValueOnce(new Error('Review temporarily unavailable'))
      .mockResolvedValue({ ...review, cornerstone_manual_allocations: [allocation] });
    mocks.retry.mockResolvedValue({ manual_allocation: allocation });
    render(<AireManualPaymentReconciliation {...props} />);
    const user = await choose();
    await user.click(screen.getByRole('button', { name: 'Link hours to payroll item' }));
    expect(await screen.findByText('AIRE unavailable')).toBeTruthy();
    expect(screen.getAllByText('Saved locally; AIRE confirmation pending')).toHaveLength(2);
    // A failed review removes current authorization, so refresh before retrying.
    mocks.review.mockResolvedValueOnce({ ...review, cornerstone_manual_allocations: [pending] });
    await user.click(screen.getByRole('button', { name: 'Refresh reconciliation' }));
    await user.click(await screen.findByRole('button', { name: 'Retry sync for entry 40' }));
    await waitFor(() => expect(mocks.retry).toHaveBeenCalledWith(67, 9));
    expect(mocks.create).toHaveBeenCalledTimes(1);
    expect(screen.queryByText('Payment recorded in AIRE')).toBeNull();
  });

  it('requires refresh after an uncertain create response and uses the saved pending link', async () => {
    mocks.create.mockRejectedValue(new Error('Connection lost'));
    render(<AireManualPaymentReconciliation {...props} />);
    const user = await choose();
    await user.click(screen.getByRole('button', { name: 'Link hours to payroll item' }));
    expect(await screen.findByText(/Refresh this review before creating another link/)).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Link hours to payroll item' }).hasAttribute('disabled')).toBe(true);
    mocks.review.mockResolvedValueOnce({ ...review, cornerstone_manual_allocations: [{ ...allocation, status: 'pending_commit' }] });
    await user.click(screen.getByRole('button', { name: 'Refresh reconciliation' }));
    expect(await screen.findByRole('button', { name: 'Retry sync for entry 40' })).toBeTruthy();
    expect(screen.queryByRole('option', { name: /Manual Employee.*entry 40/ })).toBeNull();
    expect(mocks.create).toHaveBeenCalledTimes(1);
  });

  it('subtracts existing links from regular and OT capacity independently and accepts partial hours', async () => {
    mocks.review.mockResolvedValue({ ...review, cornerstone_manual_allocations: [
      { ...allocation, id: 8, source_time_entry_id: '39', regular_hours: 3, overtime_hours: 0.5 },
    ] });
    render(<AireManualPaymentReconciliation {...props} />);
    const user = await choose();
    expect(screen.getByText(/Available on payroll item 12: 2.10 regular · 0.50 OT/)).toBeTruthy();
    const submit = screen.getByRole('button', { name: 'Link hours to payroll item' });
    expect(submit.hasAttribute('disabled')).toBe(true);
    await user.clear(screen.getByLabelText('Regular hours to link'));
    await user.type(screen.getByLabelText('Regular hours to link'), '2.10');
    await user.clear(screen.getByLabelText('Overtime hours to link'));
    await user.type(screen.getByLabelText('Overtime hours to link'), '0.50');
    expect(submit.hasAttribute('disabled')).toBe(false);
    await user.type(screen.getByLabelText('Overtime hours to link'), '1');
    expect(submit.hasAttribute('disabled')).toBe(true);
    expect(mocks.create).not.toHaveBeenCalled();
  });

  it('does not expose commands without scoped capability or server authorization', async () => {
    mocks.capability.mockReturnValue(false);
    const view = render(<AireManualPaymentReconciliation {...props} />);
    expect(mocks.review).not.toHaveBeenCalled();
    mocks.capability.mockReturnValue(true);
    mocks.review.mockResolvedValue({ ...review, command_access: { can_manage_manual_allocations: false }, cornerstone_manual_allocations: [allocation] });
    view.rerender(<AireManualPaymentReconciliation {...props} />);
    expect(await screen.findByText(/Linking is unavailable for this account and company/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Retry sync/ })).toBeNull();
    expect(screen.queryByLabelText('Exact AIRE time entry')).toBeNull();
  });

  it('excludes missing versions, identities, corrections, void and batched items', async () => {
    mocks.review.mockResolvedValue({ ...review, employees: [
      { ...review.employees[0], adjustments: [entry, { ...entry, source_time_entry_id: '41', source_time_entry_version: undefined },
        { ...entry, source_time_entry_id: '42', source_kind: 'correction' }] },
      { ...review.employees[0], source_user_uuid: null, adjustments: [{ ...entry, source_time_entry_id: '43' }] },
    ] });
    render(<AireManualPaymentReconciliation {...props} payrollItems={[item,
      { ...item, id: 13, voided: true }, { ...item, id: 14, time_tracking_provenance: { allocation_count: 1 } as PayrollItem['time_tracking_provenance'] }]} />);
    await choose();
    expect(screen.queryByRole('option', { name: /entry 41|entry 42|entry 43/ })).toBeNull();
    expect(screen.queryByRole('option', { name: /Item 13|Item 14/ })).toBeNull();
    expect(screen.getByRole('option', { name: /Item 12/ })).toBeTruthy();
  });

  it('prevents a second link for the same source entry and item, preserving other items for partial settlement', async () => {
    mocks.review.mockResolvedValue({ ...review, cornerstone_manual_allocations: [
      { ...allocation, regular_hours: 3, overtime_hours: 0, status: 'committed' },
    ] });
    render(<AireManualPaymentReconciliation {...props} payrollItems={[item, { ...item, id: 15 }]} />);
    const user = userEvent.setup();
    await screen.findByRole('option', { name: /Manual Employee.*entry 40/ });
    await user.selectOptions(screen.getByLabelText('Exact AIRE time entry'), `${uuid}:40:carryover`);
    expect(screen.queryByRole('option', { name: /Item 12/ })).toBeNull();
    expect(screen.getByRole('option', { name: /Item 15/ })).toBeTruthy();
  });

  it('discards a stale review when changing pay periods', async () => {
    let resolveOld!: (value: AirePayrollManualReview) => void;
    mocks.review.mockReturnValueOnce(new Promise<AirePayrollManualReview>(resolve => { resolveOld = resolve; }))
      .mockResolvedValueOnce({ ...review, employees: [] });
    const view = render(<AireManualPaymentReconciliation {...props} />);
    view.rerender(<AireManualPaymentReconciliation {...props} payPeriodId={68} />);
    expect(await screen.findByText(/No eligible source hours/)).toBeTruthy();
    resolveOld(review);
    await waitFor(() => expect(screen.queryByRole('option', { name: /Manual Employee.*entry 40/ })).toBeNull());
  });

  it.each(['draft', 'approved'] as const)('requires commitment for a %s run', async status => {
    render(<AireManualPaymentReconciliation {...props} payPeriodStatus={status} />);
    expect(await screen.findByText(/Commit a nonvoid payroll run/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Link hours to payroll item' })).toBeNull();
  });

  it('only labels a confirmed issued allocation paid and preserves the bank-confirmation guidance', async () => {
    mocks.review.mockResolvedValue({ ...review, cornerstone_manual_allocations: [{ ...allocation, status: 'issued', payment_method: 'direct_deposit' }] });
    render(<AireManualPaymentReconciliation {...props} />);
    expect(await screen.findByText('Payment recorded in AIRE')).toBeTruthy();
    expect(screen.getByText(/Direct deposits require bank confirmation/)).toBeTruthy();
  });
});
