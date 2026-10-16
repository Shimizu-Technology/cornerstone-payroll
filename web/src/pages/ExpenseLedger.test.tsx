// @vitest-environment jsdom

import { cleanup, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Expense } from '@/services/api';
import { ExpenseLedger } from './ExpenseLedger';

const state = vi.hoisted(() => ({
  testWorkspace: true,
  list: vi.fn(),
  show: vi.fn(),
  create: vi.fn(),
  update: vi.fn(),
  recordPayment: vi.fn(),
  reversePayment: vi.fn(),
  voidExpense: vi.fn(),
  uploadArtifact: vi.fn(),
  vendorList: vi.fn(),
  vendorCreate: vi.fn(),
}));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ user: { id: 1, role: 'org_admin', organization_id: 1 } }),
}));
vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({
    activeOrganizationId: 1,
    activeCompany: { id: state.testWorkspace ? 2 : 1, name: 'Payroll client', test_workspace: state.testWorkspace },
  }),
}));
vi.mock('@/contexts/FinanceBookContext', () => ({
  useFinanceBook: () => ({ activeBook: { id: 1, organization_id: 1, name: 'Firm book' } }),
  FinanceBookSelector: () => null,
}));
vi.mock('@/services/api', () => ({
  expensesApi: {
    list: state.list, show: state.show, create: state.create, update: state.update,
    recordPayment: state.recordPayment, reversePayment: state.reversePayment,
    void: state.voidExpense, uploadArtifact: state.uploadArtifact,
  },
  expenseVendorsApi: { list: state.vendorList, create: state.vendorCreate },
}));

function bill(paid = false): Expense {
  return {
    id: 17, organization_id: 1, expense_vendor_id: 9, vendor_name: 'Synthetic vendor',
    category: 'Supplies', entry_kind: 'bill', description: 'Retained bill detail from server',
    expense_on: '2026-10-01', due_on: '2026-10-31', currency: 'USD',
    total_amount: '100.00', amount_paid: paid ? '20.00' : '0.00',
    balance_due: paid ? '80.00' : '100.00', payment_status: paid ? 'partial' : 'open',
    artifact_count: 1,
    artifacts: [{ id: 31, filename: 'synthetic-bill.pdf', content_type: 'application/pdf',
      byte_size: 100, sha256: 'a'.repeat(64), created_at: '2026-10-01T00:00:00Z' }],
    payments: paid ? [{ id: 23, amount: '20.00', paid_on: '2026-10-02',
      payment_method: 'ach', reference_number: 'SYNTHETIC-PAYMENT' }] : [],
  };
}

function respondWithBill(expense = bill()) {
  // List rows intentionally contain no detailed payments or artifacts.
  state.list.mockResolvedValue({
    expenses: [{ ...expense, payments: undefined, artifacts: undefined }],
    meta: { page: 1, per_page: 50, total_count: 1 },
    summary: { currencies: [{ currency: 'USD', total_amount: expense.total_amount,
      amount_paid: expense.amount_paid, balance_due: expense.balance_due }], overdue_count: 0 },
  });
  state.show.mockResolvedValue({ expense });
}

function expectNoWrites() {
  for (const mutation of [state.vendorCreate, state.create, state.update, state.recordPayment,
    state.reversePayment, state.voidExpense, state.uploadArtifact]) {
    expect(mutation).not.toHaveBeenCalled();
  }
}

async function openBill() {
  const card = await screen.findByRole('button', { name: /Open Synthetic vendor/ });
  await userEvent.click(card);
  const detail = screen.getByRole('complementary', { name: 'Bill or purchase details' });
  await within(detail).findByText('Retained bill detail from server');
  return within(detail);
}

describe('ExpenseLedger read access in payroll test workspaces', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    vi.stubGlobal('innerWidth', 1280);
    state.testWorkspace = true;
    respondWithBill();
    state.vendorList.mockResolvedValue({ expense_vendors: [
      { id: 9, organization_id: 1, name: 'Synthetic vendor', active: true },
    ] });
  });
  afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

  it.each([false, true])('opens saved bill details while keeping mutations blocked (payment present: %s)', async (paid) => {
    respondWithBill(bill(paid));
    render(<ExpenseLedger />);
    await screen.findByRole('button', { name: /Open Synthetic vendor/ });
    expect(state.show).not.toHaveBeenCalled();
    expect(screen.getByText('Select a bill or purchase')).toBeTruthy();

    const detail = await openBill();
    expect(state.show).toHaveBeenCalledExactlyOnceWith(17);
    expect(detail.getByRole('button', { name: 'synthetic-bill.pdf' })).toBeTruthy();
    expect(screen.queryByText('Select a bill or purchase')).toBeNull();
    expect(screen.queryByRole('alert')).toBeNull();
    for (const name of ['Vendor', 'Bill or purchase']) {
      const button = screen.getByRole('button', { name }) as HTMLButtonElement;
      expect(button.disabled).toBe(true);
      await userEvent.click(button);
    }
    expect(detail.queryByText('Attach PDF or image')).toBeNull();
    await userEvent.type(detail.getByRole('spinbutton', { name: 'Amount' }), '10');
    const payment = detail.getByRole('button', { name: 'Record verified payment' }) as HTMLButtonElement;
    expect(payment.disabled).toBe(true);
    await userEvent.click(payment);
    if (paid) {
      expect(detail.getByText(/SYNTHETIC-PAYMENT/)).toBeTruthy();
      const reverse = detail.getByRole('button', { name: 'Reverse' }) as HTMLButtonElement;
      expect(reverse.disabled).toBe(true);
      await userEvent.click(reverse);
    } else {
      await userEvent.type(detail.getByRole('textbox', { name: 'Void reason' }), 'Synthetic QA reason');
      const voidRecord = detail.getByRole('button', { name: 'Void record' }) as HTMLButtonElement;
      expect(voidRecord.disabled).toBe(true);
      await userEvent.click(voidRecord);
    }
    expectNoWrites();
  });

  it('fetches details again after a fresh mount in a test workspace instead of relying on retained live selection', async () => {
    state.testWorkspace = false;
    const view = render(<ExpenseLedger />);
    await openBill();
    expect(state.show).toHaveBeenCalledExactlyOnceWith(17);
    view.unmount();

    state.testWorkspace = true;
    render(<ExpenseLedger />);
    await screen.findByRole('button', { name: /Open Synthetic vendor/ });
    expect(screen.getByText('Select a bill or purchase')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'synthetic-bill.pdf' })).toBeNull();
    await openBill();
    expect(state.show).toHaveBeenCalledTimes(2);
    expect(state.show).toHaveBeenLastCalledWith(17);
    expectNoWrites();
  });

  it('shows a real detail read error and allows the same bill to be opened again without any write', async () => {
    state.show.mockRejectedValueOnce(new Error('Bill detail temporarily unavailable'));
    render(<ExpenseLedger />);
    const card = await screen.findByRole('button', { name: /Open Synthetic vendor/ });
    await userEvent.click(card);
    expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Bill detail temporarily unavailable');
    expect(screen.getByText('Select a bill or purchase')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'synthetic-bill.pdf' })).toBeNull();

    await openBill();
    await waitFor(() => expect(screen.queryByRole('alert')).toBeNull());
    expect(state.show).toHaveBeenCalledTimes(2);
    expectNoWrites();
  });

  it('preserves live finance drafts after switching to a test workspace and closes both forms without saving', async () => {
    const user = userEvent.setup();
    state.testWorkspace = false;
    const view = render(<ExpenseLedger />);
    await screen.findByRole('button', { name: /Open Synthetic vendor/ });
    await user.click(screen.getByRole('button', { name: 'Vendor' }));
    const vendor = within(screen.getByRole('region', { name: 'Add vendor' }));
    await user.type(vendor.getByRole('textbox', { name: 'Vendor name' }), 'Unsaved QA vendor');
    await user.type(vendor.getByRole('textbox', { name: 'Email (optional)' }), 'draft@example.invalid');

    await user.click(screen.getByRole('button', { name: 'Bill or purchase' }));
    const expense = within(screen.getByRole('region', { name: 'Add expense' }));
    await user.selectOptions(expense.getByRole('combobox', { name: 'Vendor' }), '9');
    await user.type(expense.getByRole('textbox', { name: 'Category' }), 'Office');
    await user.type(expense.getByRole('spinbutton', { name: 'Amount' }), '23.45');
    await user.type(expense.getByRole('textbox', { name: 'Description' }), 'Unsaved bill draft');
    const detail = await openBill();
    await user.type(detail.getByRole('spinbutton', { name: 'Amount' }), '12.34');
    await user.type(detail.getByRole('textbox', { name: 'Reference' }), 'UNSAVED-PAYMENT');

    state.testWorkspace = true;
    view.rerender(<ExpenseLedger />);
    expect(vendor.getByRole('textbox', { name: 'Vendor name' })).toHaveProperty('value', 'Unsaved QA vendor');
    expect(vendor.getByRole('textbox', { name: 'Email (optional)' })).toHaveProperty('value', 'draft@example.invalid');
    expect(expense.getByRole('combobox', { name: 'Vendor' })).toHaveProperty('value', '9');
    expect(expense.getByRole('textbox', { name: 'Category' })).toHaveProperty('value', 'Office');
    expect(expense.getByRole('spinbutton', { name: 'Amount' })).toHaveProperty('value', '23.45');
    expect(expense.getByRole('textbox', { name: 'Description' })).toHaveProperty('value', 'Unsaved bill draft');
    expect(detail.getByRole('spinbutton', { name: 'Amount' })).toHaveProperty('value', '12.34');
    expect(detail.getByRole('textbox', { name: 'Reference' })).toHaveProperty('value', 'UNSAVED-PAYMENT');
    for (const button of [vendor.getByRole('button', { name: 'Save vendor' }),
      expense.getByRole('button', { name: 'Save vendor bill' }),
      detail.getByRole('button', { name: 'Record verified payment' })]) {
      expect(button).toHaveProperty('disabled', true);
      await user.click(button);
    }
    expectNoWrites();

    await user.click(vendor.getByRole('button', { name: 'Close vendor form' }));
    expect(screen.queryByRole('region', { name: 'Add vendor' })).toBeNull();
    expect(expense.getByRole('textbox', { name: 'Description' })).toHaveProperty('value', 'Unsaved bill draft');
    await user.click(expense.getByRole('button', { name: 'Close expense form' }));
    expect(screen.queryByRole('region', { name: 'Add expense' })).toBeNull();
    expect(detail.getByRole('spinbutton', { name: 'Amount' })).toHaveProperty('value', '12.34');
    expect(detail.getByRole('textbox', { name: 'Reference' })).toHaveProperty('value', 'UNSAVED-PAYMENT');
    expectNoWrites();
  });
});
