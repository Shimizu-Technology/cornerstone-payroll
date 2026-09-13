// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CheckRegister as CheckRegisterData } from '@/types';
import { guamBusinessDate } from '@/lib/payrollBusinessDate';
import { CheckRegister } from './CheckRegister';

const apiMocks = vi.hoisted(() => ({ get: vi.fn(), recordEvent: vi.fn(), exportCsv: vi.fn() }));

vi.mock('@/services/api', () => ({ checkRegisterApi: apiMocks }));

const register: CheckRegisterData = {
  from: '2026-01-01',
  to: '2026-09-14',
  rows: [
    {
      source_type: 'payroll_item',
      source_id: 22,
      pay_period_id: 8,
      check_number: '8200',
      previous_check_numbers: [],
      payee: 'Mo Shimizu',
      amount: '1425.75',
      register_date: '2026-08-20',
      status: 'issued',
      reconciliation_status: 'outstanding',
      issued_on: '2026-08-20',
      issued_by: 'Payroll Admin',
      issuance_method: 'hand_delivery',
      issuance_reference: 'Reception log',
      latest_reconciliation_event: null,
    },
  ],
  summary: {
    count: 1,
    amount: '1425.75',
    reconciled_count: 0,
    outstanding_count: 1,
    action_required_count: 0,
    by_status: {
      unprepared: { count: 0, amount: '0.0' },
      prepared: { count: 0, amount: '0.0' },
      issued: { count: 1, amount: '1425.75' },
      cleared: { count: 0, amount: '0.0' },
      replacement_required: { count: 0, amount: '0.0' },
      voided: { count: 0, amount: '0.0' },
    },
  },
};

describe('CheckRegister', () => {
  beforeEach(() => {
    apiMocks.get.mockReset().mockResolvedValue({ check_register: register });
    apiMocks.recordEvent.mockReset().mockResolvedValue({ event: {} });
    apiMocks.exportCsv.mockReset();
    vi.stubGlobal('crypto', { randomUUID: () => 'event-key-1' });
  });
  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it('makes issued-but-uncleared checks visible and records clearing evidence', async () => {
    const user = userEvent.setup();
    render(<MemoryRouter><CheckRegister companyId={7} /></MemoryRouter>);

    expect(await screen.findByText('Mo Shimizu')).toBeTruthy();
    expect(screen.getAllByText('Issued')).toHaveLength(2);
    expect(screen.getByText('$1,425.75 · Register date 8/20/2026')).toBeTruthy();

    await user.click(screen.getByRole('button', { name: 'Mark Cleared' }));
    await user.type(screen.getByLabelText('Evidence reference'), 'August statement line 15');
    await user.click(screen.getByRole('button', { name: 'Save Evidence' }));

    await waitFor(() => expect(apiMocks.recordEvent).toHaveBeenCalledWith(expect.objectContaining({
      source_type: 'payroll_item',
      source_id: 22,
      event_type: 'cleared',
      evidence_type: 'bank_statement',
      evidence_reference: 'August statement line 15',
      idempotency_key: 'event-key-1',
    })));
  });

  it('uses the Guam business date at the UTC day boundary', () => {
    expect(guamBusinessDate(new Date('2026-08-31T16:30:00Z'))).toBe('2026-09-01');
  });

  it('reuses one idempotency key when a save is retried', async () => {
    const user = userEvent.setup();
    apiMocks.recordEvent.mockRejectedValueOnce(new Error('Temporary failure')).mockResolvedValueOnce({ event: {} });
    render(<MemoryRouter><CheckRegister companyId={7} /></MemoryRouter>);
    await screen.findByText('Mo Shimizu');
    await user.click(screen.getByRole('button', { name: 'Mark Cleared' }));
    await user.type(screen.getByLabelText('Evidence reference'), 'Statement reference');
    await user.click(screen.getByRole('button', { name: 'Save Evidence' }));
    await screen.findByText('Temporary failure');
    await user.click(screen.getByRole('button', { name: 'Save Evidence' }));
    await waitFor(() => expect(apiMocks.recordEvent).toHaveBeenCalledTimes(2));
    expect(apiMocks.recordEvent.mock.calls.map(([payload]) => payload.idempotency_key)).toEqual(['event-key-1', 'event-key-1']);
  });
});
