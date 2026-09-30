// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AirePayrollRecordsDialog } from './AirePayrollRecordsDialog';
import type { AirePayrollRecord } from '@/types';

const record: AirePayrollRecord = {
  id: 9,
  source_name: 'AIRE Services',
  source_active: true,
  external_batch_id: 'AIRE-PAY-20260915',
  external_batch_checksum: 'a'.repeat(64),
  contract_version: '2.0',
  source_cutoff_at: '2026-09-23T09:00:00+10:00',
  payable_line_status: {
    line_count: 1,
    total_hours: 8,
    regular_hours: 8,
    overtime_hours: 0,
    in_payroll: { line_count: 1, total_hours: 8, regular_hours: 8, overtime_hours: 0 },
    payment_pending: { line_count: 0, total_hours: 0, regular_hours: 0, overtime_hours: 0 },
    paid: { line_count: 0, total_hours: 0, regular_hours: 0, overtime_hours: 0 },
    needs_attention: { line_count: 0, total_hours: 0, regular_hours: 0, overtime_hours: 0 },
    held: { entry_count: 1, total_hours: 1.5 },
    synchronization: { pending_event_count: 0, failed_event_count: 0, last_confirmed_at: null },
  },
};

beforeEach(() => {
  Object.defineProperty(HTMLElement.prototype, 'offsetParent', {
    configurable: true,
    get() { return this.parentElement; },
  });
});

afterEach(() => cleanup());

describe('AirePayrollRecordsDialog', () => {
  it('starts at a visible close control before the long record details', async () => {
    const onClose = vi.fn();
    render(<AirePayrollRecordsDialog open onClose={onClose} records={[record]} />);

    const closeButton = screen.getByRole('button', { name: 'Close linked AIRE records' });
    await waitFor(() => expect(document.activeElement).toBe(closeButton));
    expect(screen.getByText('Exact payable-line status')).toBeTruthy();

    await userEvent.click(closeButton);
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
