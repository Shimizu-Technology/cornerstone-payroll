// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CheckItem } from '@/types';
import { RecordBulkCheckDeliveryDialog } from './RecordBulkCheckDeliveryDialog';

const apiMocks = vi.hoisted(() => ({ markSelectedIssued: vi.fn() }));
vi.mock('@/services/api', () => ({ checksApi: apiMocks }));

const items = [
  { id: 7, check_number: '1001', employee_name: 'Ari Manual', net_pay: 253.96 },
  { id: 8, check_number: '1002', employee_name: 'Casey Connected', net_pay: 310 },
] as CheckItem[];

describe('RecordBulkCheckDeliveryDialog', () => {
  beforeEach(() => apiMocks.markSelectedIssued.mockReset().mockResolvedValue({ issued_count: 2 }));
  afterEach(cleanup);

  it('reviews the handoff and issues only the selected checks after attestation', async () => {
    const user = userEvent.setup();
    const onComplete = vi.fn().mockResolvedValue(undefined);
    render(<RecordBulkCheckDeliveryDialog payPeriodId={9} items={items} onClose={vi.fn()} onComplete={onComplete} />);

    expect((screen.getByRole('button', { name: 'Record 2 checks issued' }) as HTMLButtonElement).disabled).toBe(true);
    await user.click(screen.getByRole('checkbox', { name: 'Issue check 1002 for Casey Connected' }));
    await user.type(screen.getByLabelText('Recipient or handoff reference (optional)'), 'Front desk');
    await user.click(screen.getByRole('checkbox', { name: /I confirm the selected checks/ }));
    await user.click(screen.getByRole('button', { name: 'Record 1 check issued' }));

    await waitFor(() => expect(apiMocks.markSelectedIssued).toHaveBeenCalledWith(9, expect.objectContaining({
      payroll_item_ids: [7], attestation: true, evidence_reference: 'Front desk',
    })));
    expect(onComplete).toHaveBeenCalledOnce();
  });

});
