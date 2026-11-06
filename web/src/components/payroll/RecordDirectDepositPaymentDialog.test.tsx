// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, expect, it, vi } from 'vitest';
import { RecordDirectDepositPaymentDialog } from './RecordDirectDepositPaymentDialog';
const mocks = vi.hoisted(() => ({ confirm: vi.fn() }));
vi.mock('@/services/api', () => ({ checksApi: { confirmDirectDepositPayment: mocks.confirm } }));
afterEach(() => { cleanup(); vi.clearAllMocks(); });
it('requires a bank reference and completed-transfer attestation before submitting evidence', async () => {
  const user = userEvent.setup();
  const complete = vi.fn().mockResolvedValue(undefined);
  mocks.confirm.mockResolvedValue({});
  render(<RecordDirectDepositPaymentDialog item={{ id: 5, employee_name: 'Example Worker', net_pay: 100 }} onClose={vi.fn()} onComplete={complete} />);
  const submit = screen.getByRole('button', { name: 'Confirm payment' });
  expect((submit as HTMLButtonElement).disabled).toBe(true);
  await user.type(screen.getByLabelText('Bank confirmation or transaction reference'), 'BANK-EXAMPLE');
  expect((submit as HTMLButtonElement).disabled).toBe(true);
  await user.click(screen.getByRole('checkbox'));
  await user.click(submit);
  expect(mocks.confirm).toHaveBeenCalledWith(5, expect.objectContaining({ bank_reference: 'BANK-EXAMPLE', attestation: true }));
  expect(complete).toHaveBeenCalledOnce();
});
