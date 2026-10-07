// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CheckItem, EarningsStatementItem, PayPeriod } from '@/types';
import { ChecksPanel } from './ChecksPanel';
import { FeedbackProvider } from '@/components/ui/action-feedback';

const apiMocks = vi.hoisted(() => ({
  list: vi.fn(),
  markDelivered: vi.fn(),
  confirmDirectDepositPayment: vi.fn(),
  batchPdf: vi.fn(),
  directDepositStubsPdf: vi.fn(),
}));

vi.mock('@/services/api', () => ({
  checksApi: { list: apiMocks.list, markDelivered: apiMocks.markDelivered, confirmDirectDepositPayment: apiMocks.confirmDirectDepositPayment },
  payStubsApi: { batchPdf: apiMocks.batchPdf, directDepositStubsPdf: apiMocks.directDepositStubsPdf },
}));

vi.mock('@/components/documents/PdfPreview', () => ({
  PdfPreview: ({ artifact, onClose }: { artifact: { blob: Blob; filename: string; title?: string } | null; onClose: () => void }) => artifact ? (
    <section role="dialog" aria-label={artifact.title}>
      <p>{artifact.filename}</p>
      <p>Shared PDF preview</p>
      <button onClick={onClose}>Close PDF preview</button>
    </section>
  ) : null,
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

const statementOnly = {
  id: 43, employee_id: 2, employee_name: 'Casey Zero', gross_pay: 197.67,
  total_deductions: 197.67, net_pay: 0, payment_delivery_method: 'paper_check', statement_only: true,
} satisfies EarningsStatementItem;
const depositStatement = {
  id: 44, employee_id: 3, employee_name: 'Drew Deposit', gross_pay: 600,
  total_deductions: 100, net_pay: 500, payment_delivery_method: 'direct_deposit', statement_only: false,
} satisfies EarningsStatementItem;
const paperStatement = {
  id: check.id, employee_id: check.employee_id, employee_name: check.employee_name,
  gross_pay: check.gross_pay, total_deductions: 240, net_pay: check.net_pay,
  payment_delivery_method: 'paper_check', statement_only: false,
} satisfies EarningsStatementItem;

function renderStatements(statements = [paperStatement, depositStatement, statementOnly], extraProps = {}) {
  apiMocks.list.mockResolvedValue({ checks: statements.some((item) => item.id === check.id) ? [check] : [],
    direct_deposit_items: [], earnings_statement_items: statements, meta });
  return render(<FeedbackProvider><ChecksPanel payPeriod={{ id: 8, status: 'committed', pay_date: '2026-10-08' } as PayPeriod} {...extraProps} /></FeedbackProvider>);
}

describe('ChecksPanel earnings statements', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    const BrowserURL = URL;
    vi.stubGlobal('URL', class extends BrowserURL {
      static createObjectURL = vi.fn(() => 'blob:statement-test');
      static revokeObjectURL = vi.fn();
    });
    apiMocks.batchPdf.mockResolvedValue({ blob: new Blob(['%PDF']), filename: 'statements.pdf' });
    apiMocks.directDepositStubsPdf.mockResolvedValue({ blob: new Blob(['%PDF']), filename: 'deposits.pdf' });
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
    vi.spyOn(window, 'open').mockReturnValue({ addEventListener: vi.fn(), print: vi.fn() } as unknown as Window);
  });
  afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  it('shows a statement-only employee once with amounts and no physical-payment actions', async () => {
    renderStatements();
    const statement = await screen.findByRole('listitem', { name: 'Earnings statement for Casey Zero' });
    expect(within(statement).getByText(/Gross \$197.67 · Deductions \$197.67 · Net \$0.00/)).toBeTruthy();
    expect(within(statement).getByText(/No payment issued/)).toBeTruthy();
    expect(within(statement).queryByRole('button', { name: /Record Issued|Reissue|Void/ })).toBeNull();
    expect(screen.getAllByText('Casey Zero')).toHaveLength(1);
    expect(screen.getByText('3 statements · 1 direct deposit · 1 statement only')).toBeTruthy();
    expect(screen.getByText('Statement only · no payment issued (1)')).toBeTruthy();
  });

  it('prints all methods including zero-net statements through the all-statements endpoint', async () => {
    renderStatements();
    fireEvent.click(await screen.findByRole('button', { name: 'Print all earnings statements' }));
    await waitFor(() => expect(apiMocks.batchPdf).toHaveBeenCalledWith(8, undefined));
    expect(apiMocks.directDepositStubsPdf).not.toHaveBeenCalled();
  });

  it('keeps selections across searches and prints exactly the selected statement IDs', async () => {
    renderStatements();
    fireEvent.click(await screen.findByRole('checkbox', { name: 'Select earnings statement for Casey Zero' }));
    fireEvent.change(screen.getByRole('textbox', { name: 'Search earnings statements' }), { target: { value: 'Deposit' } });
    fireEvent.click(screen.getByRole('checkbox', { name: 'Select all visible earnings statements' }));
    fireEvent.click(screen.getByRole('button', { name: 'Print 2 selected statements' }));
    await waitFor(() => expect(apiMocks.batchPdf).toHaveBeenCalledWith(8, [43, 44]));
    fireEvent.click(screen.getByRole('button', { name: 'Clear selection (2)' }));
    expect(screen.getByRole('button', { name: 'Print all earnings statements' })).toBeTruthy();
  });

  it('applies local statement search within the parent search results', async () => {
    renderStatements([paperStatement, depositStatement, { ...statementOnly, employee_name: 'Casey Example' }], { searchTerm: 'Example' });
    const section = await screen.findByRole('region', { name: 'Earnings statements' });
    await within(section).findByText('Casey Example');
    expect(within(section).getAllByRole('listitem')).toHaveLength(2);
    expect(within(section).queryByText('Drew Deposit')).toBeNull();

    fireEvent.change(within(section).getByRole('textbox', { name: 'Search earnings statements' }), { target: { value: 'CASEY' } });
    expect(within(section).getAllByRole('listitem')).toHaveLength(1);
    expect(within(section).getByText('Casey Example')).toBeTruthy();
    expect(within(section).queryByText('Avery Example')).toBeNull();

    fireEvent.change(within(section).getByRole('textbox', { name: 'Search earnings statements' }), { target: { value: '' } });
    expect(within(section).getAllByRole('listitem')).toHaveLength(2);
    expect(within(section).queryByText('Drew Deposit')).toBeNull();
  });

  it('works for a run containing only statement-only rows and can view or download one', async () => {
    renderStatements([statementOnly]);
    const statement = await screen.findByRole('listitem', { name: 'Earnings statement for Casey Zero' });
    expect((screen.getByRole('button', { name: 'Print all earnings statements' }) as HTMLButtonElement).disabled).toBe(false);
    fireEvent.click(within(statement).getByRole('button', { name: 'View' }));
    const preview = await screen.findByRole('dialog', { name: 'Earnings statement — Casey Zero' });
    expect(within(preview).getByText('Shared PDF preview')).toBeTruthy();
    await waitFor(() => expect(apiMocks.batchPdf).toHaveBeenCalledTimes(1));
    expect(apiMocks.batchPdf).toHaveBeenNthCalledWith(1, 8, [43]);
    fireEvent.click(within(preview).getByRole('button', { name: 'Close PDF preview' }));
    expect(screen.queryByRole('dialog', { name: 'Earnings statement — Casey Zero' })).toBeNull();
    fireEvent.click(within(statement).getByRole('button', { name: 'Download' }));
    await waitFor(() => expect(apiMocks.batchPdf).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:statement-test'));
  });

  it('keeps deposit-only printing separate and refresh removes an obsolete selected row', async () => {
    const view = renderStatements();
    fireEvent.click(await screen.findByRole('button', { name: 'Print direct-deposit statements' }));
    await waitFor(() => expect(apiMocks.directDepositStubsPdf).toHaveBeenCalledWith(8));
    fireEvent.click(screen.getByRole('checkbox', { name: 'Select earnings statement for Casey Zero' }));
    apiMocks.list.mockResolvedValue({ checks: [check], direct_deposit_items: [], earnings_statement_items: [paperStatement], meta });
    view.rerender(<FeedbackProvider><ChecksPanel payPeriod={{ id: 8, status: 'committed' } as PayPeriod} refreshToken={1} /></FeedbackProvider>);
    await waitFor(() => expect(screen.queryByText('Casey Zero')).toBeNull());
    expect(screen.getByRole('button', { name: 'Print all earnings statements' })).toBeTruthy();
  });

  it('ignores a stale list response after moving to another pay run', async () => {
    let resolveOld!: (value: unknown) => void;
    apiMocks.list.mockReturnValueOnce(new Promise((resolve) => { resolveOld = resolve; }));
    const view = render(<ChecksPanel payPeriod={{ id: 8, status: 'committed' } as PayPeriod} />);
    apiMocks.list.mockResolvedValue({ checks: [], direct_deposit_items: [], earnings_statement_items: [statementOnly], meta });
    view.rerender(<ChecksPanel payPeriod={{ id: 9, status: 'committed' } as PayPeriod} />);
    await screen.findByText('Casey Zero');
    await act(async () => {
      resolveOld({ checks: [check], direct_deposit_items: [], earnings_statement_items: [paperStatement], meta });
    });
    expect(apiMocks.list).toHaveBeenCalledTimes(2);
    expect(screen.queryByText('Avery Example')).toBeNull();
    expect(screen.getByText('Casey Zero')).toBeTruthy();
  });

  it('explains an empty run, empty search, and failed statement generation', async () => {
    const view = renderStatements([]);
    await screen.findByText(/No earnings statements are needed/);
    expect((screen.getByRole('button', { name: 'Print all earnings statements' }) as HTMLButtonElement).disabled).toBe(true);
    cleanup();
    renderStatements([statementOnly]);
    await screen.findByText('Casey Zero');
    fireEvent.change(screen.getByRole('textbox', { name: 'Search earnings statements' }), { target: { value: 'not found' } });
    expect(screen.getByText('No earnings statements match this search.')).toBeTruthy();
    apiMocks.batchPdf.mockRejectedValue(new Error('Statement could not be generated. Try again.'));
    fireEvent.click(screen.getByRole('button', { name: 'Download all earnings statements' }));
    expect(await screen.findByRole('alert')).toHaveProperty('textContent', expect.stringContaining('Statement could not be generated'));
    view.unmount();
  });
  it('keeps bank confirmation alongside statement actions and refreshes its exact saved evidence', async () => {
    const deposit = { id: 44, employee_id: 3, employee_name: 'Drew Deposit', net_pay: 500, payment_confirmation: null };
    const response = { checks: [], direct_deposit_items: [deposit], earnings_statement_items: [depositStatement], meta };
    apiMocks.list.mockResolvedValueOnce(response).mockResolvedValue({ ...response, direct_deposit_items: [{ ...deposit, payment_confirmation: { settled_on: '2026-10-07', bank_reference: 'QA-BANK-44', confirmed_at: '2026-10-07T00:00:00Z' } }] });
    apiMocks.confirmDirectDepositPayment.mockResolvedValue({});
    const onChecksChanged = vi.fn().mockResolvedValue(undefined);
    render(<FeedbackProvider><ChecksPanel payPeriod={{ id: 8, status: 'committed' } as PayPeriod} onChecksChanged={onChecksChanged} /></FeedbackProvider>);
    fireEvent.click(await screen.findByRole('button', { name: 'Confirm bank payment' }));
    const dialog = screen.getByRole('dialog', { name: 'Confirm bank payment' });
    expect((within(dialog).getByRole('button', { name: 'Confirm payment' }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(within(dialog).getByLabelText('Bank settlement date'), { target: { value: '2026-10-07' } });
    fireEvent.change(within(dialog).getByLabelText('Bank confirmation or transaction reference'), { target: { value: 'QA-BANK-44' } });
    fireEvent.click(within(dialog).getByRole('checkbox'));
    fireEvent.click(within(dialog).getByRole('button', { name: 'Confirm payment' }));
    await waitFor(() => expect(apiMocks.confirmDirectDepositPayment).toHaveBeenCalledExactlyOnceWith(44, { settled_on: '2026-10-07', bank_reference: 'QA-BANK-44', note: undefined, attestation: true }));
    await screen.findByText('Bank paid 2026-10-07 · QA-BANK-44');
    expect(onChecksChanged).toHaveBeenCalledOnce();
    expect(screen.queryByRole('dialog', { name: 'Confirm bank payment' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Print all earnings statements' })).toBeTruthy();
    expect(screen.getByText('Bank payment recorded for Drew Deposit.')).toBeTruthy();
  });

  it('closes bank confirmation when moving to another run', async () => {
    apiMocks.list.mockResolvedValue({ checks: [], direct_deposit_items: [{ id: 44, employee_id: 3, employee_name: 'Drew Deposit', net_pay: 500 }], earnings_statement_items: [depositStatement], meta });
    const view = render(<FeedbackProvider><ChecksPanel payPeriod={{ id: 8, status: 'committed' } as PayPeriod} /></FeedbackProvider>);
    fireEvent.click(await screen.findByRole('button', { name: 'Confirm bank payment' }));
    apiMocks.list.mockResolvedValue({ checks: [], direct_deposit_items: [], earnings_statement_items: [statementOnly], meta });
    view.rerender(<FeedbackProvider><ChecksPanel payPeriod={{ id: 9, status: 'committed' } as PayPeriod} /></FeedbackProvider>);
    await screen.findByText('Casey Zero');
    expect(screen.queryByRole('dialog', { name: 'Confirm bank payment' })).toBeNull();
    expect(apiMocks.confirmDirectDepositPayment).not.toHaveBeenCalled();
  });

});
