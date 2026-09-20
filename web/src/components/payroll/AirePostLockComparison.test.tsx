// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { AirePostLockComparison } from './AirePostLockComparison';

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

it('shows actual paid evidence separately from AIRE unallocated hours at cutoff', async () => {
  render(<AirePostLockComparison payPeriodId={11} />);

  expect(await screen.findByText('Final AIRE cutoff vs. payroll payments')).toBeTruthy();
  expect(screen.getByText('Linked · payment not confirmed')).toBeTruthy();
  expect(screen.getAllByText('AIRE unallocated at cutoff')).toHaveLength(2);
  expect(screen.getByText(/payment 1001/)).toBeTruthy();
  expect(apiMocks.compare).toHaveBeenCalledWith(11);
});

it('withholds a stale comparison when AIRE verification fails', async () => {
  apiMocks.compare.mockRejectedValue(new Error('Final batch checksum changed'));
  render(<AirePostLockComparison payPeriodId={11} />);

  expect((await screen.findByRole('alert')).textContent).toContain('No final comparison is being shown');
  expect(screen.queryByText('AIRE unallocated at cutoff')).toBeNull();
});
