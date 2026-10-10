// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { CheckItem, EarningsStatementItem, PayPeriod, PaymentCancellationSync } from '@/types';
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


describe('ChecksPanel paper status scope', () => {
  const noPaperMeta = { ...meta, total: 0, unprinted: 0, prepared: 0, printed: 0, delivered: 0, voided: 0 };
  const bankConfirmation = { settled_on: '2026-11-22', bank_reference: 'SYNTHETIC-P01-BANK-20261122-4H', confirmed_at: '2026-11-22T07:02:00Z' };
  const deposit = { id: depositStatement.id, employee_id: depositStatement.employee_id, employee_name: depositStatement.employee_name, net_pay: depositStatement.net_pay };
  const countLabel = (count: number, label: string) => (_: string, element: Element | null) =>
    Boolean(element?.tagName === 'SPAN' && element.textContent === `${count} ${label}`);

  beforeEach(() => { apiMocks.list.mockReset(); });
  afterEach(cleanup);

  it.each([false, true])('omits paper status pills for DD-only payroll, confirmed=%s', async (confirmed) => {
    apiMocks.list.mockResolvedValue({ checks: [], direct_deposit_items: [{ ...deposit, payment_confirmation: confirmed ? bankConfirmation : null }], earnings_statement_items: [depositStatement], meta: { ...noPaperMeta, direct_deposit_count: 1 } });
    render(<ChecksPanel payPeriod={{ id: 8, status: 'committed' } as PayPeriod} />);
    await screen.findByText(depositStatement.employee_name);
    expect(screen.queryByRole('group', { name: 'Paper check status' })).toBeNull();
    expect(screen.queryByText(countLabel(0, 'issued'))).toBeNull();
    expect(screen.queryByText(countLabel(0, 'not prepared'))).toBeNull();
    expect(screen.getByText(countLabel(0, 'paper checks'))).toBeTruthy();
    expect(screen.getByText(countLabel(1, 'direct-deposit stubs'))).toBeTruthy();
    if (confirmed) {
      expect(screen.getByText(`Bank paid ${bankConfirmation.settled_on} · ${bankConfirmation.bank_reference}`)).toBeTruthy();
      expect(screen.queryByRole('button', { name: 'Confirm bank payment' })).toBeNull();
    } else {
      expect(screen.getByRole('button', { name: 'Confirm bank payment' })).toBeTruthy();
    }
  });

  it('scopes issued counts to the paper item in a mixed confirmed-bank run', async () => {
    const delivered = { ...check, check_status: 'delivered' as const };
    apiMocks.list.mockResolvedValue({ checks: [delivered], direct_deposit_items: [{ ...deposit, payment_confirmation: bankConfirmation }], earnings_statement_items: [paperStatement, depositStatement], meta: { ...meta, prepared: 0, delivered: 1, direct_deposit_count: 1 } });
    render(<ChecksPanel payPeriod={{ id: 8, status: 'committed' } as PayPeriod} />);
    await screen.findByText(depositStatement.employee_name);
    const group = screen.getByRole('group', { name: 'Paper check status' });
    expect(within(group).getByText('Paper check status')).toBeTruthy();
    expect(within(group).getByText(countLabel(1, 'issued'))).toBeTruthy();
    expect(screen.getByText(`Bank paid ${bankConfirmation.settled_on} · ${bankConfirmation.bank_reference}`)).toBeTruthy();
    expect(within(group).queryByText(/Bank paid/)).toBeNull();
  });

  it('preserves every supplied paper status count including voided history', async () => {
    const statuses = ['unprinted', 'prepared', 'printed', 'delivered', 'voided'] as const;
    const paperChecks = statuses.map((status, index) => ({ ...check, id: 42 + index, employee_name: `Paper Employee ${index}`, check_number: String(8101 + index), check_status: status, voided: status === 'voided' }));
    apiMocks.list.mockResolvedValue({ checks: paperChecks, direct_deposit_items: [], earnings_statement_items: [], meta: { ...meta, total: 5, unprinted: 1, prepared: 1, printed: 1, delivered: 1, voided: 1 } });
    render(<ChecksPanel payPeriod={{ id: 8, status: 'committed' } as PayPeriod} />);
    await screen.findByText(countLabel(5, 'paper checks'));
    const group = screen.getByRole('group', { name: 'Paper check status' });
    for (const label of ['not prepared', 'prepared', 'printed', 'issued', 'voided']) {
      expect(within(group).getByText(countLabel(1, label))).toBeTruthy();
    }
  });

  it('omits irrelevant paper status pills for an empty run', async () => {
    apiMocks.list.mockResolvedValue({ checks: [], direct_deposit_items: [], earnings_statement_items: [], meta: noPaperMeta });
    render(<ChecksPanel payPeriod={{ id: 8, status: 'committed' } as PayPeriod} />);
    await screen.findByText(countLabel(0, 'paper checks'));
    expect(screen.queryByRole('group', { name: 'Paper check status' })).toBeNull();
    expect(screen.queryByText(countLabel(0, 'issued'))).toBeNull();
  });
});

const pendingCancellation = { status: 'pending' as const, pending_count: 2, acknowledged_count: 1,
  oldest_pending_at: '2026-10-08T01:00:00Z', errors: [], hours_reserved: true };

function renderCancellationStatement(state: PaymentCancellationSync = pendingCancellation, confirmed = false) {
  const item = { ...depositStatement, payment_cancellation_sync: state };
  apiMocks.list.mockResolvedValue({ checks: [], earnings_statement_items: [item],
    direct_deposit_items: [{ ...item, payment_confirmation: confirmed ? { settled_on: '2026-10-08', bank_reference: 'Bank completed 42', confirmed_at: '2026-10-08T04:00:00Z' } : null }],
    meta: { ...meta, total: 0, prepared: 0, direct_deposit_count: 1 } });
  return render(<FeedbackProvider><ChecksPanel payPeriod={{ id: 8, company_id: 7, status: 'committed' } as PayPeriod}
    timeTrackingReviewHref="/companies/7/pay-runs/8/work?return_to=%2Fcompanies%2F7%2Fpay-runs%2F8%2Fchecks#time-tracking-sync" /></FeedbackProvider>);
}

describe('ChecksPanel cancellation sync evidence', () => {
  beforeEach(() => vi.clearAllMocks());
  afterEach(cleanup);

  it('shows pending reservation coverage without disabling truthful bank confirmation', async () => {
    renderCancellationStatement();
    expect(await screen.findByText('Check cancellation pending time tracking confirmation')).toBeTruthy();
    expect(screen.getByText(/2 cancellation records awaiting confirmation/)).toBeTruthy();
    expect(screen.getByText(/payroll hours remain reserved in time tracking/)).toBeTruthy();
    const link = screen.getByRole('link', { name: 'Review time tracking sync' });
    expect(link.getAttribute('href')).toBe('/companies/7/pay-runs/8/work?return_to=%2Fcompanies%2F7%2Fpay-runs%2F8%2Fchecks#time-tracking-sync');
    const confirm = screen.getByRole('button', { name: 'Confirm bank payment' }) as HTMLButtonElement;
    expect(confirm.disabled).toBe(false);
    fireEvent.click(confirm);
    expect(await screen.findByRole('dialog', { name: 'Confirm bank payment' })).toBeTruthy();
    expect(apiMocks.confirmDirectDepositPayment).not.toHaveBeenCalled();
  });

  it('keeps actual completed bank evidence visible while source cancellation still waits', async () => {
    renderCancellationStatement(pendingCancellation, true);
    expect(await screen.findByText(/Bank paid 2026-10-08 · Bank completed 42/)).toBeTruthy();
    expect(screen.getByText('Check cancellation pending time tracking confirmation')).toBeTruthy();
    expect(screen.getByText(/separate from any recorded bank payment/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Confirm bank payment' })).toBeNull();
  });

  it('distinguishes a failed cancellation from bank evidence and provides review guidance', async () => {
    renderCancellationStatement({ ...pendingCancellation, status: 'error', errors: ['The connected source could not confirm this cancellation.'] }, true);
    expect(await screen.findByText('Check cancellation sync needs attention')).toBeTruthy();
    expect(screen.getByText('The connected source could not confirm this cancellation.')).toBeTruthy();
    expect(screen.getByText(/Bank paid 2026-10-08/)).toBeTruthy();
  });

  it('clears waiting guidance only after the API reports acknowledgement', async () => {
    const view = renderCancellationStatement();
    await screen.findByText('Check cancellation pending time tracking confirmation');
    apiMocks.list.mockResolvedValue({ checks: [], earnings_statement_items: [{ ...depositStatement,
      payment_cancellation_sync: { ...pendingCancellation, status: 'acknowledged', pending_count: 0, oldest_pending_at: null, hours_reserved: false } }],
      direct_deposit_items: [], meta: { ...meta, total: 0, direct_deposit_count: 1 } });
    view.rerender(<FeedbackProvider><ChecksPanel payPeriod={{ id: 8, company_id: 7, status: 'committed' } as PayPeriod} refreshToken={1} /></FeedbackProvider>);
    expect(await screen.findByText('Check cancellation confirmed by time tracking')).toBeTruthy();
    expect(screen.queryByText(/payroll hours remain reserved/)).toBeNull();
    expect(screen.queryByRole('link', { name: 'Review time tracking sync' })).toBeNull();
  });

  it('does not invent a sync label for an ordinary no-source payment', async () => {
    renderStatements([depositStatement]);
    await screen.findByText('Drew Deposit');
    expect(screen.queryByText(/Check cancellation/)).toBeNull();
  });

  it('shows the same cancellation status in paper card and table without copying it to another item', async () => {
    apiMocks.list.mockResolvedValue({ checks: [{ ...check, payment_cancellation_sync: pendingCancellation },
      { ...check, id: 99, employee_id: 99, employee_name: 'Other Employee', check_number: '8199' }],
      direct_deposit_items: [], earnings_statement_items: [], meta: { ...meta, total: 2 } });
    render(<ChecksPanel payPeriod={{ id: 8, status: 'committed' } as PayPeriod} />);
    const notices = await screen.findAllByText('Check cancellation pending time tracking confirmation');
    expect(notices).toHaveLength(2);
    const otherRow = screen.getAllByRole('row').find(row => within(row).queryByText('Other Employee'))!;
    expect(within(otherRow).queryByText(/Check cancellation/)).toBeNull();
  });
});
