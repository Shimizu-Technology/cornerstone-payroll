// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { PayrollHistoryReview } from './PayrollHistoryReview';
import type { HistoryReviewItem } from '@/services/payroll-history-review';

const mocks = vi.hoisted(() => ({ list: vi.fn(), change: vi.fn(), onSaved: vi.fn(async () => undefined) }));
vi.mock('@/services/payroll-history-review', async (importOriginal) => ({
  ...await importOriginal<typeof import('@/services/payroll-history-review')>(),
  payrollHistoryReviewApi: { list: mocks.list, change: mocks.change },
}));

const openItem: HistoryReviewItem = {
  id: 11, subject_type: 'voided_pay_period', status: 'open', subject_digest: 'a'.repeat(64),
  resolution_codes: ['void_replaced', 'void_reissued', 'other'],
  resolution_code: null, resolved_by: null, resolved_at: null, resolution_reference: null,
  facts: { id: 17, start_date: '2026-02-01', end_date: '2026-02-14', pay_date: '2026-02-20', status: 'committed',
    gross_pay: '1200', item_count: 1, void_reason: 'Rate corrected', checks_printed: 1, checks_delivered_or_cleared: 0,
    direct_deposits_confirmed: 0, replacements: [{ id: 18, status: 'committed', pay_date: '2026-02-20', start_date: '2026-02-01',
      end_date: '2026-02-14', gross_pay: '1240', item_count: 1 }] },
};

const resolvedItem: HistoryReviewItem = {
  id: 12, subject_type: 'legacy_basis_gap', status: 'resolved', subject_digest: 'b'.repeat(64),
  resolution_code: 'legacy_basis_accepted', resolved_by: 'Sample Reviewer', resolved_at: '2026-05-12T01:00:00Z',
  resolution_reference: 'Reconciled to the original wage statements', resolution_codes: ['legacy_basis_accepted'],
  facts: { employee_name: 'Sample Employee', paychecks: [{ id: 19, pay_date: '2026-02-20', gross_pay: '1000',
    social_security_tax: '62', medicare_tax: '14.5', missing_bases: ['social_security_taxable_wages'] }] },
};

function mount() {
  return render(<PayrollHistoryReview companyId={7} year={2026} onSaved={mocks.onSaved} onRefresh={vi.fn(async () => undefined)} />);
}

describe('PayrollHistoryReview', () => {
  beforeEach(() => vi.clearAllMocks());
  afterEach(cleanup);

  it('renders open items before resolved items and shows their payroll facts in read-only mode', async () => {
    mocks.list.mockResolvedValue({ data: [resolvedItem, openItem], can_review: false });
    mount();
    const region = screen.getByRole('region', { name: 'Payroll history review' });
    await within(region).findByText('Void reason: Rate corrected');
    expect(mocks.list).toHaveBeenCalledWith(7, 2026);
    expect(within(region).getAllByRole('heading', { level: 3 }).map((heading) => heading.textContent))
      .toEqual(['Voided payroll #17', 'Sample Employee · Missing stored taxable wages']);
    expect(within(region).getByText(/Possible replacement #18.*\$1,240.00/)).toBeTruthy();
    expect(within(region).getByText(/Stored employee tax.*\$62.00.*\$14.50/)).toBeTruthy();
    expect(within(region).getByText(/Reviewed by Sample Reviewer on/)).toBeTruthy();
    expect(within(region).queryByRole('button', { name: /resolve|reopen/i })).toBeNull();
  });

  it('requires a valid resolution code and a sufficiently long reference, then allows reopening', async () => {
    mocks.list.mockResolvedValue({ data: [openItem], can_review: true });
    const closed = { ...openItem, status: 'resolved', resolution_code: 'void_replaced',
      resolved_at: '2026-05-12T01:00:00Z', resolved_by: 'Sample Reviewer', resolution_reference: 'Checked the replacement payroll' };
    mocks.change.mockResolvedValueOnce({ data: closed }).mockResolvedValueOnce({ data: openItem });
    mount();
    fireEvent.click(await screen.findByRole('button', { name: 'Resolve Voided payroll #17' }));
    const dialog = screen.getByRole('dialog', { name: 'Resolve payroll history review' });
    const select = within(dialog).getByLabelText('Resolution reason') as HTMLSelectElement;
    const reference = within(dialog).getByLabelText('Review reference');
    const submit = within(dialog).getByRole('button', { name: 'Confirm resolution' }) as HTMLButtonElement;
    expect([...select.options].map((option) => option.value)).toEqual(['', 'void_replaced', 'void_reissued', 'other']);
    expect(submit.disabled).toBe(true);
    fireEvent.change(select, { target: { value: 'void_replaced' } });
    fireEvent.change(reference, { target: { value: '  short  ' } });
    expect(submit.disabled).toBe(true);
    fireEvent.change(reference, { target: { value: '  Checked the replacement payroll  ' } });
    fireEvent.click(submit);
    await waitFor(() => expect(mocks.change).toHaveBeenCalledWith(7, 2026, openItem,
      { resolution_code: 'void_replaced', reference: 'Checked the replacement payroll' }));
    expect(await screen.findByText('No payroll history items need review for this year.')).toBeTruthy();
    expect(screen.getByText('Checked the replacement payroll')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Reopen Voided payroll #17' }));
    fireEvent.change(screen.getByLabelText('Why are you reopening this item?'), { target: { value: 'New evidence' } });
    fireEvent.click(screen.getByRole('button', { name: 'Confirm reopen' }));
    expect(await screen.findByRole('button', { name: 'Resolve Voided payroll #17' })).toBeTruthy();
    expect(mocks.change).toHaveBeenLastCalledWith(7, 2026, closed, { reason: 'New evidence' });
  });
});
