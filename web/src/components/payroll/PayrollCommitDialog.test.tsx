// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { PayrollItem } from '@/types';
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

it('shows the numbering summary and limits the settings link to permitted staff', () => {
  const state = { ...props(), payPeriod: { ...period, payroll_items: [{ payment_delivery_method: 'paper_check' } as PayrollItem], check_number_summary: { next_check_number: 1200, last_used_check_number: 1199, can_change: true } } };
  const { rerender } = render(<PayrollCommitDialog {...state} />);
  expect(screen.getByText('Paper checks will be numbered from 1200 (last used: 1199)')).toBeTruthy();
  expect(screen.getByRole('link', { name: 'Review check settings' }).getAttribute('href')).toBe('/check-settings');
  rerender(<PayrollCommitDialog {...state} payPeriod={{ ...state.payPeriod, check_number_summary: { ...state.payPeriod.check_number_summary, can_change: false } }} />);
  expect(screen.queryByRole('link', { name: 'Review check settings' })).toBeNull();
});

it('warns about reused stock and hides numbering for bank-only runs', () => {
  const payPeriod = { ...period, payroll_items: [{ payment_delivery_method: 'paper_check' } as PayrollItem], check_number_summary: { next_check_number: 1001, last_used_check_number: 5000, can_change: true } };
  const { rerender } = render(<PayrollCommitDialog {...props()} payPeriod={payPeriod} />);
  expect(screen.getByRole('alert').textContent).toContain('The next check number (1001) is at or below the last one used (5000)');
  rerender(<PayrollCommitDialog {...props()} payPeriod={{ ...payPeriod, payroll_items: [{ payment_delivery_method: 'direct_deposit' } as PayrollItem] }} />);
  expect(screen.queryByText(/Paper checks will/)).toBeNull();
  expect(screen.queryByRole('alert')).toBeNull();
});
