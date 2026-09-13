// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { PayrollLiabilityCenter as PayrollLiabilityCenterData } from '@/types';
import { PayrollLiabilityCenter } from './PayrollLiabilityCenter';

const apiMocks = vi.hoisted(() => ({ updateDueDate: vi.fn() }));

vi.mock('@/services/api', () => ({
  payrollLiabilityCenterApi: { updateDueDate: apiMocks.updateDueDate },
}));

const center: PayrollLiabilityCenterData = {
  company_id: 7,
  as_of: '2026-09-14',
  totals: {
    calculated_amount: 448,
    prepared_amount: 124,
    paid_amount: 0,
    outstanding_amount: 448,
    unreserved_amount: 324,
    overdue_count: 0,
  },
  obligations: [
    {
      key: '17:United States Treasury',
      pay_period_id: 17,
      authority: 'United States Treasury',
      liability_date: '2026-08-20',
      period_start: '2026-08-01',
      period_end: '2026-08-15',
      pay_date: '2026-08-20',
      due_date: null,
      calculated_amount: 124,
      prepared_amount: 124,
      paid_amount: 0,
      outstanding_amount: 124,
      unreserved_amount: 0,
      status: 'prepared',
      entry_ids: [1, 2],
      categories: [
        { category: 'social_security_employee', amount: 62 },
        { category: 'social_security_employer', amount: 62 },
      ],
    },
    {
      key: '18:United States Treasury',
      pay_period_id: 18,
      authority: 'United States Treasury',
      liability_date: '2026-09-05',
      period_start: '2026-08-16',
      period_end: '2026-08-31',
      pay_date: '2026-09-05',
      due_date: null,
      calculated_amount: 124,
      prepared_amount: 0,
      paid_amount: 0,
      outstanding_amount: 124,
      unreserved_amount: 124,
      status: 'unpaid',
      entry_ids: [3, 4],
      categories: [{ category: 'medicare_employee', amount: 124 }],
    },
    {
      key: '18:Guam Department of Revenue and Taxation',
      pay_period_id: 18,
      authority: 'Guam Department of Revenue and Taxation',
      liability_date: '2026-09-05',
      period_start: '2026-08-16',
      period_end: '2026-08-31',
      pay_date: '2026-09-05',
      due_date: null,
      calculated_amount: 200,
      prepared_amount: 0,
      paid_amount: 0,
      outstanding_amount: 200,
      unreserved_amount: 200,
      status: 'unpaid',
      entry_ids: [5],
      categories: [{ category: 'guam_income_tax_withheld', amount: 200 }],
    },
  ],
  payments: [],
};

describe('PayrollLiabilityCenter', () => {
  beforeEach(() => apiMocks.updateDueDate.mockReset());
  afterEach(cleanup);

  it('distinguishes prepared from paid and prepares the exact available obligation', async () => {
    const user = userEvent.setup();
    const onPrepare = vi.fn();
    render(<PayrollLiabilityCenter center={center} loading={false} error={null} onPrepare={onPrepare} onUpdated={vi.fn()} />);

    expect(screen.getByText('Prepared · not paid')).toBeTruthy();
    expect(screen.getByText('Employee Social Security · $62.00')).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Prepare $124.00' }));
    expect(onPrepare).toHaveBeenCalledWith([center.obligations[1]]);
  });

  it('saves an operator-reviewed due date and applies the returned worksheet', async () => {
    const user = userEvent.setup();
    const updated = { ...center, as_of: '2026-09-15' };
    apiMocks.updateDueDate.mockResolvedValue({ payroll_liability_center: updated });
    const onUpdated = vi.fn();
    render(<PayrollLiabilityCenter center={center} loading={false} error={null} onPrepare={vi.fn()} onUpdated={onUpdated} />);

    const input = screen.getByLabelText('Due date for United States Treasury 2026-08-31');
    fireEvent.change(input, { target: { value: '2026-09-20' } });
    const saveButtons = screen.getAllByRole('button', { name: 'Save' });
    await user.click(saveButtons.find((button) => !(button as HTMLButtonElement).disabled)!);

    await waitFor(() => expect(apiMocks.updateDueDate).toHaveBeenCalledWith({
      pay_period_id: 18,
      authority: 'United States Treasury',
      due_date: '2026-09-20',
    }));
    expect(onUpdated).toHaveBeenCalledWith(updated);
  });
});
