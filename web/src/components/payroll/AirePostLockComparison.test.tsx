// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { AirePostLockComparison } from './AirePostLockComparison';
import { summarizeEmployees } from './airePaymentSummary';

const apiMocks = vi.hoisted(() => ({ compare: vi.fn() }));

vi.mock('@/services/api', () => ({ payPeriodsApi: { airePostLockComparison: apiMocks.compare } }));

beforeEach(() => {
  apiMocks.compare.mockResolvedValue({ comparison: {
    batch_id: 'FINAL-1', cutoff_at: '2026-10-22T17:00:00+10:00',
    summary: {
      paid: { regular_hours: 2, overtime_hours: 0, entry_count: 1 },
      awaiting_payment: { regular_hours: 1, overtime_hours: 0, entry_count: 1 },
      owed: { regular_hours: 8, overtime_hours: 0, entry_count: 1 },
      held: { regular_hours: 4, overtime_hours: 0, entry_count: 1 },
      correction: { regular_hours: 0, overtime_hours: 0, entry_count: 0 },
      mismatch: { regular_hours: 0, overtime_hours: 0, entry_count: 0 },
      needs_attention: true, unmapped_count: 0,
    },
    rows: [
      { employee_name: 'Test Worker', source_time_entry_id: '101', work_date: '2026-10-05', source_kind: 'current', status: 'owed', regular_hours: 8, overtime_hours: 0 },
      { employee_name: 'Test Worker', source_time_entry_id: '101', work_date: '2026-10-05', source_kind: 'linked_payroll', status: 'paid', regular_hours: 2, overtime_hours: 0, payment_reference: '1001' },
    ],
  } });
});

afterEach(() => { cleanup(); vi.clearAllMocks(); });

it('shows current employee payment status and keeps cutoff evidence available', async () => {
  render(<AirePostLockComparison payPeriodId={11} />);

  expect(await screen.findByText('AIRE hours and payments')).toBeTruthy();
  expect(screen.getByText('Still to pay')).toBeTruthy();
  expect(screen.getByText('Pay 6.00 hrs · Oct 5, 2026')).toBeTruthy();
  expect(screen.getByText(/check\/payment 1001/)).toBeTruthy();
  fireEvent.click(screen.getByText('Cutoff and source details'));
  expect(screen.getByText(/historical snapshot/)).toBeTruthy();
  expect(screen.getAllByText(/payment 1001/)).toHaveLength(2);
  expect(apiMocks.compare).toHaveBeenCalledWith(11);
});

it('withholds a stale comparison when AIRE verification fails', async () => {
  apiMocks.compare.mockRejectedValue(new Error('Final batch checksum changed'));
  render(<AirePostLockComparison payPeriodId={11} />);

  expect((await screen.findByRole('alert')).textContent).toContain('Current AIRE payment status is unavailable');
  expect(screen.queryByText('Still to pay')).toBeNull();
});

it('subtracts exact paid and pending links from historical cutoff hours without touching held time', () => {
  const rows = [
    { employee_name: 'Ari Manual', source_user_uuid: 'ari', source_time_entry_id: '1', work_date: '2026-09-01', source_kind: 'current', status: 'owed', regular_hours: 8, overtime_hours: 0 },
    { employee_name: 'Ari Manual', source_user_uuid: 'ari', source_time_entry_id: '2', work_date: '2026-09-01', source_kind: 'current', status: 'owed', regular_hours: 0, overtime_hours: 2 },
    { employee_name: 'Ari Manual', source_user_uuid: 'ari', source_time_entry_id: '1', work_date: '2026-09-01', source_kind: 'linked_payroll', status: 'paid', regular_hours: 8, overtime_hours: 0 },
    { employee_name: 'Ari Manual', source_user_uuid: 'ari', source_time_entry_id: '2', work_date: '2026-09-01', source_kind: 'linked_payroll', status: 'paid', regular_hours: 0, overtime_hours: 2 },
    { employee_name: 'Ari Manual', source_user_uuid: 'ari', source_time_entry_id: '3', work_date: '2026-09-02', source_kind: 'held', status: 'held', regular_hours: 4, overtime_hours: 0 },
  ] as import('@/types').AirePostLockComparison['rows'];
  const employee = summarizeEmployees(rows)[0];
  expect(employee.owed).toEqual({ regular: 0, overtime: 0 });
  expect(employee.paid).toEqual({ regular: 8, overtime: 2 });
  expect(employee.held).toEqual({ regular: 4, overtime: 0 });
});
