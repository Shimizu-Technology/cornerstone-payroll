// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { PayPeriod } from '@/types';
import { ApiError } from '@/services/api';
import { PayrollCommitDialog } from './PayrollCommitDialog';
const api = vi.hoisted(() => ({ get: vi.fn() }));
vi.mock('@/services/api', async importOriginal => ({ ...await importOriginal<typeof import('@/services/api')>(), payPeriodsApi: { get: api.get } }));
const request = { id: 1, title: "Riley's timesheet", status: 'requested', status_label: 'Waiting for the file' };
const period = { id: 12, company_id: 7, status: 'approved', start_date: '2026-09-01', end_date: '2026-09-15',
  pay_date: '2026-09-30', compliance_warnings: ['Review overtime classification', '<script>not markup</script>'],
  payroll_items: [{ net_pay: 1234.56, payment_delivery_method: 'paper_check' }],
  check_number_summary: { next_check_number: 1200, last_used_check_number: 1199, can_change: true },
  outstanding_file_requests: [] } as unknown as PayPeriod;
function props(payPeriod = period) { return { open: true, payPeriod, companyName: 'Assigned company', itemCount: 1, totalNet: 1234.56,
  processing: false, onCancel: vi.fn(), onConfirm: vi.fn().mockResolvedValue(undefined) }; }
async function loaded() { await waitFor(() => expect(screen.queryByText(/Loading current requests/)).toBeNull()); }
beforeEach(() => { vi.resetAllMocks(); api.get.mockResolvedValue({ pay_period: period }); });
afterEach(cleanup);
describe('Payroll commit confirmation', () => {
  it('loads current details on every opening and submits exactly what staff saw', async () => {
    const state = props({ ...period, check_number_summary: { ...period.check_number_summary!, next_check_number: 800 } });
    const view = render(<PayrollCommitDialog {...state} />);
    expect(screen.getByRole('button', { name: 'Confirm commit' })).toHaveProperty('disabled', true);
    await loaded();
    expect(api.get).toHaveBeenCalledExactlyOnceWith(12, 7);
    expect(screen.getByText('$1,234.56')).toBeTruthy();
    expect(screen.getByText('<script>not markup</script>')).toBeTruthy();
    expect(screen.getByRole('dialog').querySelector('script')).toBeNull();
    expect(screen.getByText('Paper checks will be numbered from 1200 (last used: 1199)')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    expect(state.onConfirm).toHaveBeenCalledExactlyOnceWith(12, { acknowledged_outstanding_file_request_ids: [], expected_next_check_number: 1200 });
    await act(async () => {});
    view.rerender(<PayrollCommitDialog {...state} open={false} />);
    api.get.mockResolvedValue({ pay_period: { ...period, check_number_summary: { ...period.check_number_summary, next_check_number: 1300 } } });
    view.rerender(<PayrollCommitDialog {...state} />); await loaded();
    expect(screen.getByText(/numbered from 1300/)).toBeTruthy();
  });
  it('displays the staff history summary while retaining other warnings and allowing commit', async () => {
    const entries = [
      { employee_name: 'Demo Employee', note: 'Voided pay period needs review.' },
      { employee_name: 'Another Employee', note: 'Reversed paycheck needs review.' },
    ];
    const note = entries.map(entry => `${entry.employee_name}: ${entry.note}`).join('\n');
    api.get.mockResolvedValue({ pay_period: {
      ...period, annual_fica_review_note: note, annual_fica_review: { employee_count: 2, entries },
      compliance_warnings: [...period.compliance_warnings!, note],
    } });
    const state = props();
    render(<PayrollCommitDialog {...state} />);
    expect(await screen.findByText("2 payroll history items awaiting accountant review. This payroll isn't affected.")).toBeTruthy();
    expect(screen.queryByText(/Voided pay period|Reversed paycheck/)).toBeNull();
    expect(screen.getByText('Review overtime classification')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    expect(state.onConfirm).toHaveBeenCalledExactlyOnceWith(12, { acknowledged_outstanding_file_request_ids: [], expected_next_check_number: 1200 });
  });
  it('cancels without confirming', async () => {
    const state = props(); render(<PayrollCommitDialog {...state} />); await loaded();
    fireEvent.click(screen.getByRole('button', { name: 'Keep reviewing' }));
    expect(state.onCancel).toHaveBeenCalledOnce(); expect(state.onConfirm).not.toHaveBeenCalled();
  });
  it('prevents duplicate confirmation and dismissal while committing', async () => {
    const state = props(); state.onConfirm.mockReturnValue(new Promise(() => {}));
    render(<PayrollCommitDialog {...state} />); await loaded();
    fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    expect(screen.getByRole('button', { name: 'Committing…' }).getAttribute('aria-busy')).toBe('true');
    expect(screen.getAllByRole('status').some(status => status.lastElementChild?.textContent === 'Committing payroll… This can take a few seconds.')).toBe(true);
    fireEvent.click(screen.getByRole('button', { name: 'Committing…' }));
    fireEvent.click(screen.getByRole('button', { name: 'Keep reviewing' })); fireEvent.keyDown(document, { key: 'Escape' });
    expect(state.onConfirm).toHaveBeenCalledOnce(); expect(state.onCancel).not.toHaveBeenCalled();
  });
  it.each(['calculated', 'committed'] as const)('cannot confirm a freshly loaded %s run', async status => {
    api.get.mockResolvedValue({ pay_period: { ...period, status } });
    const state = props(); render(<PayrollCommitDialog {...state} />); await loaded();
    fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' })); expect(state.onConfirm).not.toHaveBeenCalled();
  });
  it.each([true, false])('blocks pending client changes with setting %s', async required => {
    api.get.mockResolvedValue({ pay_period: { ...period, client_payroll_approval_required: required,
      payroll_review: { status: 'changes_requested', changes_requested_by_name: 'Client Approver', change_request_note: 'Add two hours' } } });
    const state = props(); render(<PayrollCommitDialog {...state} />); await loaded();
    expect(screen.getByRole('alert').textContent).toBe('Client Approver requested changes: Add two hours. Unapprove to make changes.');
    fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' })); expect(state.onConfirm).not.toHaveBeenCalled();
  });
  it('requires acknowledgement by name and sends exact IDs', async () => {
    api.get.mockResolvedValue({ pay_period: { ...period, outstanding_file_requests: [request] } });
    const state = props(); render(<PayrollCommitDialog {...state} />); await loaded();
    expect(screen.getByText(/Riley's timesheet/)).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Confirm commit' })).toHaveProperty('disabled', true);
    fireEvent.click(screen.getByRole('checkbox')); fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    expect(state.onConfirm).toHaveBeenCalledExactlyOnceWith(12, { acknowledged_outstanding_file_request_ids: [1], expected_next_check_number: 1200 });
  });
  it.each(['outstanding_file_requests_changed', 'check_number_changed'])('reloads after %s and requires another confirmation', async code => {
    api.get.mockResolvedValueOnce({ pay_period: { ...period, outstanding_file_requests: [request] } })
      .mockResolvedValue({ pay_period: { ...period, outstanding_file_requests: [request, { ...request, id: 2, title: 'Signed W-4' }],
        check_number_summary: { ...period.check_number_summary, next_check_number: 1300 } } });
    const state = props(); state.onConfirm.mockRejectedValueOnce(new ApiError('Review the updated details and confirm again.', 409, undefined, { code }));
    render(<PayrollCommitDialog {...state} />); await loaded();
    fireEvent.click(screen.getByRole('checkbox')); fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    await screen.findByText(/Signed W-4/); await loaded();
    const alert = screen.getByRole('alert');
    expect(alert.className).toContain('bg-warning-50');
    expect(document.activeElement).toBe(alert);
    expect(alert.textContent).toBe(code === 'check_number_changed'
      ? 'The next check number changed to 1300 (it was 1200). Check your stock, then confirm again.'
      : 'A file request was added or resolved. Review the list and tick the box again.');
    expect(alert.closest('section')?.getAttribute('aria-label')).toBe(code === 'check_number_changed' ? 'Check numbering' : 'Outstanding client file requests');
    expect(screen.queryByText(/Reload the record/)).toBeNull();
    expect(screen.getByText(/numbered from 1300/)).toBeTruthy();
    expect(screen.getByRole('checkbox')).toHaveProperty('checked', false);
    expect(screen.getByRole('button', { name: 'Confirm commit' })).toHaveProperty('disabled', true);
    expect(state.onConfirm).toHaveBeenCalledOnce();
    fireEvent.click(screen.getByRole('checkbox')); fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    expect(state.onConfirm).toHaveBeenLastCalledWith(12, { acknowledged_outstanding_file_request_ids: [1, 2], expected_next_check_number: 1300 });
  });
  it('keeps ordinary errors visible without reloading', async () => {
    const state = props(); state.onConfirm.mockRejectedValueOnce(new ApiError('Recalculate payroll', 422));
    render(<PayrollCommitDialog {...state} />); await loaded(); fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    expect(await screen.findByText('Recalculate payroll')).toBeTruthy(); expect(api.get).toHaveBeenCalledOnce();
  });
  it('fails closed if either refresh fails', async () => {
    api.get.mockRejectedValueOnce(new Error('Could not load current details'));
    const state = props(); const view = render(<PayrollCommitDialog {...state} />); await loaded();
    expect(screen.getByRole('button', { name: 'Confirm commit' })).toHaveProperty('disabled', true); view.unmount();
    api.get.mockResolvedValueOnce({ pay_period: period }).mockRejectedValueOnce(new Error('Offline'));
    state.onConfirm.mockRejectedValueOnce(new ApiError('Changed', 409, undefined, { code: 'check_number_changed' }));
    render(<PayrollCommitDialog {...state} />); await loaded(); fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    await screen.findByText('Could not reload the commit details. Close this dialog and try again.');
    expect(screen.getByRole('button', { name: 'Confirm commit' })).toHaveProperty('disabled', true);
  });
  it('omits numbering for bank-only runs', async () => {
    api.get.mockResolvedValue({ pay_period: { ...period, payroll_items: [{ payment_delivery_method: 'direct_deposit' }] } });
    const state = props(); render(<PayrollCommitDialog {...state} />); await loaded();
    expect(screen.queryByText(/Paper checks will/)).toBeNull(); fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    expect(state.onConfirm).toHaveBeenCalledExactlyOnceWith(12, { acknowledged_outstanding_file_request_ids: [] });
  });
  it('hides stale totals and requests on the initial load and while reloading after a conflict', async () => {
    let finish!: (data: { pay_period: PayPeriod }) => void;
    api.get.mockReturnValueOnce(new Promise(resolve => { finish = resolve; }));
    const stale = { ...period, outstanding_file_requests: [request], payroll_items: [] };
    const state = props(stale);
    const view = render(<PayrollCommitDialog {...state} />);
    expect(screen.getByText('Loading current requests and check numbering…').getAttribute('role')).toBe('status');
    expect(screen.queryByText(/Riley's timesheet/)).toBeNull();
    expect(screen.queryByText('Total net pay')).toBeNull();
    expect(screen.queryByText('$0.00')).toBeNull();
    await act(async () => finish({ pay_period: { ...period, outstanding_file_requests: [request] } })); await loaded();
    expect(screen.getByText('$1,234.56')).toBeTruthy();
    api.get.mockReturnValueOnce(new Promise(resolve => { finish = resolve; }));
    state.onConfirm.mockRejectedValueOnce(new ApiError('Changed. Reload the record.', 409, undefined, { code: 'check_number_changed' }));
    fireEvent.click(screen.getByRole('checkbox')); fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    await screen.findByText('Loading current requests and check numbering…');
    expect(screen.queryByText(/Riley's timesheet/)).toBeNull();
    expect(screen.queryByText('$1,234.56')).toBeNull();
    expect(screen.queryByText(/numbered from 1200/)).toBeNull();
    expect(screen.getByRole('button', { name: 'Committing…' })).toHaveProperty('disabled', true);
    await act(async () => finish({ pay_period: { ...period, check_number_summary: { ...period.check_number_summary!, next_check_number: 1300 } } }));
    await loaded();
    expect(screen.getByRole('alert').textContent).toContain('changed to 1300 (it was 1200)');
    view.unmount();
  });

  it('explains a resolved last request and still requires an explicit second confirmation', async () => {
    api.get.mockResolvedValueOnce({ pay_period: { ...period, outstanding_file_requests: [request] } }).mockResolvedValue({ pay_period: period });
    const state = props(); state.onConfirm.mockRejectedValueOnce(new ApiError('Changed. Reload the record.', 409, undefined, { code: 'outstanding_file_requests_changed' }));
    render(<PayrollCommitDialog {...state} />); await loaded();
    fireEvent.click(screen.getByRole('checkbox')); fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    await screen.findByText('None outstanding.');
    expect(screen.getByRole('alert').textContent).toContain('No requests remain outstanding.');
    expect(screen.getByRole('alert').textContent).toContain("Resolved: Riley's timesheet");
    expect(screen.queryByRole('checkbox')).toBeNull();
    expect(state.onConfirm).toHaveBeenCalledOnce();
    fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    expect(state.onConfirm).toHaveBeenLastCalledWith(12, { acknowledged_outstanding_file_request_ids: [], expected_next_check_number: 1200 });
  });

  it('requires per-item checkboxes for unverified employee changes and reloads cleanly on 409 unverified_changes_changed', async () => {
    const changeA = {
      id: 501,
      updated_at: '2026-11-28T01:00:00.000000Z',
      employee_id: 21,
      employee_name: 'Jordan Sample',
      event_kind: 'compensation_change',
      status: 'pending_verification',
      summary: 'Pay rate or compensation changed (pay rate)',
    };
    const changeB = {
      id: 502,
      updated_at: '2026-11-28T01:05:00.000000Z',
      employee_id: 22,
      employee_name: 'Morgan Example',
      event_kind: 'w4_change',
      status: 'returned_to_client',
      summary: 'W-4 withholding changed (filing status)',
    };
    const changeAUpdated = { ...changeA, updated_at: '2026-11-28T01:10:00.000000Z' };

    api.get
      .mockResolvedValueOnce({ pay_period: { ...period, unverified_employee_changes: [changeA, changeB] } })
      .mockResolvedValue({ pay_period: { ...period, unverified_employee_changes: [changeAUpdated, changeB] } });

    const state = props();
    state.onConfirm.mockRejectedValueOnce(new ApiError('Changed', 409, undefined, { code: 'unverified_changes_changed' }));

    render(<PayrollCommitDialog {...state} />);
    await loaded();

    expect(screen.getByText('Changed since last payroll, not verified (2)')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /select all/i })).toBeNull();
    const checkboxes = screen.getAllByRole('checkbox');
    expect(checkboxes).toHaveLength(2);
    expect(screen.getByRole('button', { name: 'Confirm commit' })).toHaveProperty('disabled', true);

    fireEvent.click(checkboxes[0]);
    expect(screen.getByRole('button', { name: 'Confirm commit' })).toHaveProperty('disabled', true);

    fireEvent.click(checkboxes[1]);
    expect(screen.getByRole('button', { name: 'Confirm commit' })).toHaveProperty('disabled', false);

    fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    await waitFor(() => expect(api.get).toHaveBeenCalledTimes(2));
    await loaded();

    const alert = screen.getByRole('alert');
    expect(document.activeElement).toBe(alert);
    expect(alert.textContent).toContain('Unverified employee changes were added, edited, or resolved');

    const reloadedBoxes = screen.getAllByRole('checkbox');
    expect(reloadedBoxes).toHaveLength(2);
    reloadedBoxes.forEach((box) => expect(box).toHaveProperty('checked', false));
    expect(screen.getByRole('button', { name: 'Confirm commit' })).toHaveProperty('disabled', true);

    fireEvent.click(reloadedBoxes[0]);
    fireEvent.click(reloadedBoxes[1]);
    fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));

    expect(state.onConfirm).toHaveBeenLastCalledWith(12, {
      acknowledged_outstanding_file_request_ids: [],
      expected_next_check_number: 1200,
      acknowledged_verification_items: [
        { id: 501, updated_at: '2026-11-28T01:10:00.000000Z' },
        { id: 502, updated_at: '2026-11-28T01:05:00.000000Z' },
      ],
    });
  });

  it('groups more than 10 unverified employee changes by employee with individual checkboxes and no select-all shortcut', async () => {
    const manyChanges = Array.from({ length: 11 }, (_, idx) => ({
      id: 600 + idx,
      updated_at: `2026-11-28T02:00:${String(idx).padStart(2, '0')}.000000Z`,
      employee_id: idx < 6 ? 31 : 32,
      employee_name: idx < 6 ? 'Jordan Sample' : 'Morgan Example',
      event_kind: 'compensation_change',
      status: 'pending_verification',
      summary: `Change #${idx + 1}`,
    }));
    api.get.mockResolvedValue({ pay_period: { ...period, unverified_employee_changes: manyChanges } });

    render(<PayrollCommitDialog {...props()} />);
    await loaded();

    expect(screen.getByText('Jordan Sample (0/6 acknowledged)')).toBeTruthy();
    expect(screen.getByText('Morgan Example (0/5 acknowledged)')).toBeTruthy();
    expect(screen.getAllByRole('checkbox')).toHaveLength(11);
    expect(screen.queryByRole('button', { name: /select all/i })).toBeNull();
  });

});
