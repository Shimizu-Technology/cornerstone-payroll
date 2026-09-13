// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CheckItem } from '@/types';
import { guamBusinessDate } from '@/lib/payrollBusinessDate';
import { RecordCheckDeliveryDialog } from './RecordCheckDeliveryDialog';

const apiMocks = vi.hoisted(() => ({ markDelivered: vi.fn() }));

vi.mock('@/services/api', () => ({ checksApi: apiMocks }));

describe('RecordCheckDeliveryDialog', () => {
  beforeEach(() => apiMocks.markDelivered.mockReset().mockResolvedValue({ data: {}, meta: {} }));
  afterEach(cleanup);

  it('requires an attestation and submits explicit issuance evidence', async () => {
    const user = userEvent.setup();
    const onComplete = vi.fn().mockResolvedValue(undefined);
    const item = { id: 44, check_number: '9001', employee_name: 'Sarah Shimizu' } as CheckItem;
    render(<RecordCheckDeliveryDialog item={item} onClose={vi.fn()} onComplete={onComplete} />);

    const save = screen.getByRole('button', { name: 'Record Issued' }) as HTMLButtonElement;
    expect(save.disabled).toBe(true);
    await user.selectOptions(screen.getByLabelText('How it was issued'), 'mail');
    await user.type(screen.getByLabelText('Reference (optional)'), 'USPS receipt 123');
    await user.click(screen.getByRole('checkbox'));
    expect(save.disabled).toBe(false);
    await user.click(save);

    await waitFor(() => expect(apiMocks.markDelivered).toHaveBeenCalledWith(44, expect.objectContaining({
      delivery_method: 'mail',
      attestation: true,
      evidence_reference: 'USPS receipt 123',
    })));
    expect(onComplete).toHaveBeenCalledOnce();
  });

  it('uses the Guam business date at the UTC day boundary', () => {
    expect(guamBusinessDate(new Date('2026-08-31T16:30:00Z'))).toBe('2026-09-01');
  });
});
