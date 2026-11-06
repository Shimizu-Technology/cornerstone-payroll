// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { PayrollCommitDialog } from './PayrollCommitDialog';
const period = { id: 12, status: 'approved' as const, start_date: '2026-09-01', end_date: '2026-09-15',
  pay_date: '2026-09-30', compliance_warnings: ['Review overtime classification', '<script>not markup</script>'] };
function props() { return { open: true, payPeriod: period, companyName: 'Assigned company', itemCount: 2, totalNet: 1234.56,
  processing: false, onCancel: vi.fn(), onConfirm: vi.fn() }; }
afterEach(cleanup);
describe('Payroll commit confirmation', () => {
  it('opens without committing and shows the exact run, totals and warnings', () => {
    const state = props(); render(<PayrollCommitDialog {...state} />);
    const dialog = screen.getByRole('dialog', { name: 'Commit and finalize payroll?' });
    expect(state.onConfirm).not.toHaveBeenCalled();
    expect(within(dialog).getByText('Assigned company')).toBeTruthy();
    expect(within(dialog).getByText('#12')).toBeTruthy();
    expect(within(dialog).getByText('Sep 30, 2026')).toBeTruthy();
    expect(within(dialog).getByText('$1,234.56')).toBeTruthy();
    expect(within(dialog).getByText('Review overtime classification')).toBeTruthy();
    expect(within(dialog).getByText('<script>not markup</script>')).toBeTruthy();
    expect(dialog.querySelector('script')).toBeNull();
    expect(within(dialog).getByText(/Checks and bank payments require separate issuance/)).toBeTruthy();
    expect(within(dialog).getByText(/corrections workflow/)).toBeTruthy();
  });
  it('cancels without confirming', () => {
    const state = props(); render(<PayrollCommitDialog {...state} />);
    fireEvent.click(screen.getByRole('button', { name: 'Keep reviewing' }));
    expect(state.onCancel).toHaveBeenCalledOnce();
    expect(state.onConfirm).not.toHaveBeenCalled();
  });
  it('confirms only the explicit run ID', () => {
    const state = props(); render(<PayrollCommitDialog {...state} />);
    fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    expect(state.onConfirm).toHaveBeenCalledExactlyOnceWith(12);
  });
  it('prevents confirmation and dismissal while busy', () => {
    const state = { ...props(), processing: true }; render(<PayrollCommitDialog {...state} />);
    fireEvent.click(screen.getByRole('button', { name: 'Committing…' }));
    fireEvent.click(screen.getByRole('button', { name: 'Keep reviewing' }));
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(state.onConfirm).not.toHaveBeenCalled(); expect(state.onCancel).not.toHaveBeenCalled();
  });
  it.each(['calculated', 'committed'] as const)('cannot confirm a %s run', status => {
    const state = { ...props(), payPeriod: { ...period, status } }; render(<PayrollCommitDialog {...state} />);
    fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' }));
    expect(state.onConfirm).not.toHaveBeenCalled();
  });
  it('cannot confirm a voided approved run', () => {
    const state = { ...props(), payPeriod: { ...period, correction_status: 'voided' as const } }; render(<PayrollCommitDialog {...state} />);
    fireEvent.click(screen.getByRole('button', { name: 'Confirm commit' })); expect(state.onConfirm).not.toHaveBeenCalled();
  });
});
