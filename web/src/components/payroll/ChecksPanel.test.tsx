// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { CheckItem, PayPeriod } from '@/types';
import { ChecksPanel } from './ChecksPanel';

const apiMocks = vi.hoisted(() => ({
  list: vi.fn(),
  markDelivered: vi.fn(),
}));

vi.mock('@/services/api', () => ({
  checksApi: { list: apiMocks.list, markDelivered: apiMocks.markDelivered },
  payStubsApi: {},
}));

const check = {
  id: 42,
  pay_period_id: 8,
  employee_id: 1,
  employee_name: 'Avery Example',
  check_number: '8101',
  check_status: 'prepared',
  reconciliation_status: 'prepared',
  check_print_count: 0,
  check_printed_at: null,
  check_prepared_at: '2026-09-27T08:00:00Z',
  voided: false,
  voided_at: null,
  void_reason: null,
  reprint_of_check_number: null,
  gross_pay: 1200,
  net_pay: 960,
  events: [],
} satisfies CheckItem;

const meta = {
  total: 1,
  unprinted: 0,
  prepared: 1,
  printed: 0,
  delivered: 0,
  voided: 0,
  direct_deposit_count: 0,
  check_stock_type: 'bottom_check',
};

describe('ChecksPanel status changes', () => {
  afterEach(cleanup);

  it('notifies its parent after an issued check is refreshed', async () => {
    vi.clearAllMocks();
    apiMocks.list
      .mockResolvedValueOnce({ checks: [check], direct_deposit_items: [], meta })
      .mockResolvedValueOnce({ checks: [{ ...check, check_status: 'delivered' }], direct_deposit_items: [], meta: { ...meta, prepared: 0, delivered: 1 } });
    apiMocks.markDelivered.mockResolvedValue({});
    const onChecksChanged = vi.fn().mockResolvedValue(undefined);

    render(<ChecksPanel payPeriod={{ id: 8, status: 'committed' } as PayPeriod} onChecksChanged={onChecksChanged} />);

    fireEvent.click((await screen.findAllByRole('button', { name: 'Record Issued' }))[0]);
    const dialog = screen.getByRole('dialog', { name: 'Record check issued' });
    fireEvent.click(within(dialog).getByRole('checkbox'));
    fireEvent.click(within(dialog).getByRole('button', { name: 'Record Issued' }));

    await waitFor(() => expect(onChecksChanged).toHaveBeenCalledOnce());
    expect(apiMocks.list).toHaveBeenCalledTimes(2);
  });
});
