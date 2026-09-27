// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { PayPeriod, PayrollItem } from '@/types';
import { PayRunWorkspace } from './PayRunWorkspace';

const apiMocks = vi.hoisted(() => ({
  getPayPeriod: vi.fn(),
  rehearsalPreviewPdf: vi.fn(),
  printQueue: vi.fn(),
  promotedPaymentPreview: vi.fn(),
  preparePromotedPayment: vi.fn(),
  liabilities: vi.fn(),
  payrollFieldInputs: vi.fn(),
  employeesList: vi.fn(),
  recordActivities: vi.fn(),
  updatePaymentMethod: vi.fn(),
  isAdmin: true,
  activeCompany: { id: 7, payroll_environment: 'migration_rehearsal' } as Record<string, unknown>,
}));

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({
    activeCompany: apiMocks.activeCompany,
  }),
}));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ isAdmin: apiMocks.isAdmin }),
}));

vi.mock('@/services/api', () => ({
  payPeriodsApi: {
    get: apiMocks.getPayPeriod,
    promotedPaymentPreview: apiMocks.promotedPaymentPreview,
    preparePromotedPayment: apiMocks.preparePromotedPayment,
    liabilities: apiMocks.liabilities,
    payrollFieldInputs: apiMocks.payrollFieldInputs,
  },
  employeesApi: { list: apiMocks.employeesList },
  recordActivitiesApi: { list: apiMocks.recordActivities },
  checksApi: { rehearsalPreviewPdf: apiMocks.rehearsalPreviewPdf, printQueue: apiMocks.printQueue },
  payrollItemsApi: { updatePaymentMethod: apiMocks.updatePaymentMethod },
}));

vi.mock('@/components/checks/UnifiedCheckPrintDialog', () => ({
  UnifiedCheckPrintDialog: ({ open }: { open: boolean }) => open ? <div role="dialog" aria-label="Print prepared checks">Print prepared checks</div> : null,
}));

vi.mock('@/components/payroll/ChecksPanel', () => ({
  ChecksPanel: ({ onChecksChanged }: { onChecksChanged?: () => Promise<void> }) => (
    <div>
      Check register
      <button onClick={() => void onChecksChanged?.()}>Simulate check status change</button>
    </div>
  ),
}));

vi.mock('@/pages/PayPeriodDetail', () => ({
  PayPeriodDetail: ({ refreshToken }: { refreshToken?: number }) => (
    <div data-testid="mounted-processing-refresh-token">{refreshToken}</div>
  ),
}));

vi.mock('@/components/documents/PdfPreview', () => ({
  PdfPreview: ({ artifact }: { artifact: { filename: string; title?: string; note?: string } | null }) => artifact ? (
    <section aria-label="PDF preview">
      <h2>{artifact.title}</h2>
      <p>{artifact.note}</p>
      <p>{artifact.filename}</p>
    </section>
  ) : null,
}));

const payrollItem = {
  id: 31,
  pay_period_id: 12,
  employee_id: 19,
  employee_name: 'Alice Reyes',
  employment_type: 'hourly',
  pay_rate: 15,
  gross_pay: 700,
  net_pay: 500,
  effective_payment_delivery_method: 'paper_check',
  voided: false,
} as PayrollItem;

const payRun = {
  id: 12,
  company_id: 7,
  start_date: '2026-09-07',
  end_date: '2026-09-20',
  pay_date: '2026-09-24',
  status: 'calculated',
  parallel_run: true,
  run_purpose: 'regular',
  includes_base_salary: true,
  includes_recurring_items: true,
  cycle: 'regular',
  payroll_items: [payrollItem],
} as PayPeriod & { payroll_items: PayrollItem[] };

describe('PayRunWorkspace rehearsal checks', () => {
  afterEach(cleanup);

  beforeEach(() => {
    vi.clearAllMocks();
    apiMocks.isAdmin = true;
    apiMocks.activeCompany = { id: 7, payroll_environment: 'migration_rehearsal' };
    apiMocks.getPayPeriod.mockResolvedValue({ pay_period: payRun });
    apiMocks.rehearsalPreviewPdf.mockResolvedValue({
      blob: new Blob(['%PDF-1.4'], { type: 'application/pdf' }),
      filename: 'void_rehearsal_checks_2026-09-24.pdf',
    });
    apiMocks.printQueue.mockResolvedValue({ items: [] });
    apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
    apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
    apiMocks.employeesList.mockResolvedValue({ data: [], meta: { total_pages: 1 } });
    apiMocks.recordActivities.mockResolvedValue({
      data: [],
      meta: { current_page: 1, per_page: 20, total_count: 0, total_pages: 0 },
    });
  });

  it('describes and previews rehearsal checks with only the VOID marking', async () => {
    render(
      <MemoryRouter initialEntries={['/companies/7/pay-runs/12/checks']}>
        <Routes>
          <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText(/The PDF marks every check VOID/)).toBeTruthy();
    expect(screen.getByText('Rehearsal preview - no check number')).toBeTruthy();
    expect(screen.getAllByText('Preview ready')).toBeTruthy();
    expect(document.body.textContent).not.toMatch(/TEST ONLY|NOT NEGOTIABLE|VOID - TEST/);

    fireEvent.click(screen.getByRole('button', { name: 'Preview rehearsal checks' }));

    expect(await screen.findByRole('heading', { name: 'Preview rehearsal checks' })).toBeTruthy();
    expect(screen.getByText(/Every check is marked VOID/)).toBeTruthy();
    expect(screen.getByText('void_rehearsal_checks_2026-09-24.pdf')).toBeTruthy();
    expect(document.body.textContent).not.toMatch(/TEST ONLY|NOT NEGOTIABLE|VOID - TEST/);
    expect(apiMocks.rehearsalPreviewPdf).toHaveBeenCalledWith(12);
  });

  it('keeps a training baseline read-only and out of payroll processing', async () => {
    apiMocks.getPayPeriod.mockResolvedValue({
      pay_period: { ...payRun, status: 'approved', test_workspace_role: 'baseline', training_baseline_locked: true },
    });

    render(
      <MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}>
        <Routes>
          <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText('Locked reference history')).toBeTruthy();
    expect(screen.getByText('Locked reference records')).toBeTruthy();
    expect(screen.queryByText('Process payroll')).toBeNull();
    expect(screen.queryByText('Checks & direct deposit')).toBeNull();
  });

  it.each(['work', 'checks'])('routes sealed backups from %s to a review-only workspace', async (tab) => {
    apiMocks.activeCompany = {
      id: 7,
      payroll_environment: 'migration_rehearsal',
      test_workspace_purpose: 'backup_snapshot',
      test_workspace_sealed_at: '2026-09-22T00:00:00Z',
    };

    render(
      <MemoryRouter initialEntries={[`/companies/7/pay-runs/12/${tab}`]}>
        <Routes>
          <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText('Read-only snapshot')).toBeTruthy();
    expect(screen.getByText('Read-only payroll records')).toBeTruthy();
    expect(screen.queryByText('Process payroll')).toBeNull();
    expect(screen.queryByText('Checks & direct deposit')).toBeNull();
    expect(screen.queryByText('Open processing')).toBeNull();
  });

  it('lets an admin safely prepare an unpaid promoted payroll without recalculating it', async () => {
    const promotedRun = {
      ...payRun,
      status: 'committed',
      parallel_run: false,
      promotion_source_pay_period_id: 91,
      promotion_payment_disposition: 'record_only',
    } as PayPeriod & { payroll_items: PayrollItem[] };
    apiMocks.activeCompany = { id: 7, payroll_environment: 'live' };
    apiMocks.getPayPeriod.mockResolvedValue({ pay_period: promotedRun });
    apiMocks.promotedPaymentPreview.mockResolvedValue({
      promoted_payment: {
        eligible: true,
        blockers: [],
        pay_period_id: 12,
        start_date: promotedRun.start_date,
        end_date: promotedRun.end_date,
        pay_date: promotedRun.pay_date,
        paper_check_count: 1,
        paper_check_total: '500.00',
        direct_deposit_count: 0,
        current_next_check_number: 4401,
        suggested_first_check_number: '4401',
        suggested_last_check_number: '4401',
        prepared_at: null,
        prepared_by_name: null,
      },
    });
    const preparedRun = {
      ...promotedRun,
      promotion_payment_disposition: 'process_in_cornerstone',
      promoted_payment_prepared_at: '2026-09-22T03:00:00Z',
      payroll_items: [{ ...payrollItem, check_number: '4401', check_date: '2026-09-22' }],
    } as PayPeriod & { payroll_items: PayrollItem[] };
    apiMocks.preparePromotedPayment.mockResolvedValue({
      promoted_payment: {
        paper_check_count: 1,
        paper_check_total: '500.00',
        suggested_first_check_number: '4401',
        suggested_last_check_number: '4401',
      },
      pay_period: preparedRun,
    });

    render(
      <MemoryRouter initialEntries={['/companies/7/pay-runs/12/checks']}>
        <Routes>
          <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText('Promoted payroll is recorded but unpaid')).toBeTruthy();
    expect(screen.getByText(/without recalculating pay or adding YTD/)).toBeTruthy();
    fireEvent.click(await screen.findByRole('button', { name: 'Prepare checks for payment' }));
    expect(screen.getByText((_, element) => element?.tagName === 'P' && element.textContent === '1 paper check totaling $500.00')).toBeTruthy();
    fireEvent.change(screen.getByLabelText('Date to print on checks'), { target: { value: '2026-09-22' } });
    fireEvent.click(screen.getByRole('checkbox', { name: /has not been paid/i }));
    fireEvent.click(screen.getByRole('button', { name: 'Assign check numbers' }));

    await waitFor(() => expect(apiMocks.preparePromotedPayment).toHaveBeenCalledWith(12, {
      acknowledgement: 'PREPARE PROMOTED PAYROLL FOR PAYMENT',
      starting_check_number: '4401',
      check_date: '2026-09-22',
    }));
    expect(await screen.findByRole('dialog', { name: 'Print prepared checks' })).toBeTruthy();
    expect(screen.getByText(/1 check is numbered and ready/)).toBeTruthy();
  });

  it('explains the admin handoff to accountants without offering the recovery action', async () => {
    apiMocks.isAdmin = false;
    apiMocks.activeCompany = { id: 7, payroll_environment: 'live' };
    apiMocks.getPayPeriod.mockResolvedValue({
      pay_period: {
        ...payRun,
        status: 'committed',
        parallel_run: false,
        promotion_source_pay_period_id: 91,
        promotion_payment_disposition: 'record_only',
      },
    });

    render(
      <MemoryRouter initialEntries={['/companies/7/pay-runs/12/checks']}>
        <Routes>
          <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText(/Ask an organization administrator/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Prepare checks for payment' })).toBeNull();
    expect(apiMocks.promotedPaymentPreview).not.toHaveBeenCalled();
  });

  it('combines complete record activity with payroll milestones', async () => {
    render(
      <MemoryRouter initialEntries={['/companies/7/pay-runs/12/activity']}>
        <Routes>
          <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText('Complete activity history')).toBeTruthy();
    expect(screen.getByText('Payroll milestones')).toBeTruthy();
    expect(apiMocks.recordActivities).toHaveBeenCalledWith('pay_periods', 12, { page: 1, per_page: 20 }, 7);
  });
});

describe('PayRunWorkspace check status refresh', () => {
  afterEach(cleanup);

  it('keeps the phone payment card linked to the same switch workflow', async () => {
    vi.clearAllMocks();
    apiMocks.isAdmin = true;
    apiMocks.activeCompany = { id: 7, payroll_environment: 'live' };
    apiMocks.getPayPeriod.mockResolvedValue({ pay_period: {
      ...payRun,
      status: 'committed',
      parallel_run: false,
      payroll_items: [{ ...payrollItem, check_number: '4401', check_status: 'unprinted' }],
    } });
    apiMocks.printQueue.mockResolvedValue({ items: [] });

    render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/checks']}>
      <Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} /></Routes>
    </MemoryRouter>);

    const phoneCard = await screen.findByRole('group', { name: 'Payment record for Alice Reyes' });
    const desktopRow = screen.getByRole('row', { name: /Alice Reyes/ });
    expect(within(phoneCard).getByText('Paper check · 4401')).toBeTruthy();
    expect(within(phoneCard).getByText('$500.00')).toBeTruthy();
    expect(within(phoneCard).getByText('Assigned')).toBeTruthy();
    expect(within(desktopRow).getByText('Assigned')).toBeTruthy();
    expect(within(desktopRow).getByRole('button', { name: 'Switch for this run' })).toBeTruthy();
    fireEvent.click(within(phoneCard).getByRole('button', { name: 'Switch for this run' }));
    expect(screen.getByRole('textbox', { name: 'Reason (at least 10 characters)' })).toBeTruthy();
  });

  it('updates the pay-run summary when a check action changes its status', async () => {
    vi.clearAllMocks();
    apiMocks.isAdmin = true;
    apiMocks.activeCompany = { id: 7, payroll_environment: 'live' };
    apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
    apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
    apiMocks.employeesList.mockResolvedValue({ data: [], meta: { total_pages: 1 } });
    apiMocks.recordActivities.mockResolvedValue({ data: [], meta: { current_page: 1, per_page: 20, total_count: 0, total_pages: 0 } });
    const preparedRun = {
      ...payRun,
      status: 'committed',
      parallel_run: false,
      payroll_items: [{ ...payrollItem, check_number: '4401', check_status: 'prepared' }],
    } as PayPeriod & { payroll_items: PayrollItem[] };
    const issuedRun = {
      ...preparedRun,
      payroll_items: [{ ...preparedRun.payroll_items[0], check_status: 'delivered' }],
    };
    apiMocks.getPayPeriod.mockResolvedValueOnce({ pay_period: preparedRun }).mockResolvedValueOnce({ pay_period: issuedRun });
    apiMocks.printQueue.mockResolvedValue({ items: [] });

    render(
      <MemoryRouter initialEntries={['/companies/7/pay-runs/12/checks']}>
        <Routes>
          <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findAllByText('Prepared')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Simulate check status change' }));
    expect(await screen.findAllByText('Issued')).toBeTruthy();
    expect(screen.queryByText('Prepared')).toBeNull();
    expect(apiMocks.getPayPeriod).toHaveBeenCalledTimes(2);
  });

  it('keeps the newest check status when summary refreshes finish out of order', async () => {
    vi.clearAllMocks();
    apiMocks.isAdmin = true;
    apiMocks.activeCompany = { id: 7, payroll_environment: 'live' };
    apiMocks.printQueue.mockResolvedValue({ items: [] });
    const preparedRun = {
      ...payRun,
      status: 'committed',
      parallel_run: false,
      payroll_items: [{ ...payrollItem, check_number: '4401', check_status: 'prepared' }],
    } as PayPeriod & { payroll_items: PayrollItem[] };
    const issuedRun = {
      ...preparedRun,
      payroll_items: [{ ...preparedRun.payroll_items[0], check_status: 'delivered' }],
    };
    let resolveFirstRefresh!: (response: { pay_period: typeof preparedRun }) => void;
    let resolveSecondRefresh!: (response: { pay_period: typeof issuedRun }) => void;
    apiMocks.getPayPeriod
      .mockResolvedValueOnce({ pay_period: preparedRun })
      .mockImplementationOnce(() => new Promise((resolve) => { resolveFirstRefresh = resolve; }))
      .mockImplementationOnce(() => new Promise((resolve) => { resolveSecondRefresh = resolve; }));

    render(
      <MemoryRouter initialEntries={['/companies/7/pay-runs/12/checks']}>
        <Routes>
          <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findAllByText('Prepared')).toBeTruthy();
    const changeButton = screen.getByRole('button', { name: 'Simulate check status change' });
    fireEvent.click(changeButton);
    fireEvent.click(changeButton);
    await waitFor(() => expect(apiMocks.getPayPeriod).toHaveBeenCalledTimes(3));

    await act(async () => { resolveSecondRefresh({ pay_period: issuedRun }); });
    expect(screen.getAllByText('Issued')).toBeTruthy();
    await act(async () => { resolveFirstRefresh({ pay_period: preparedRun }); });
    expect(screen.getAllByText('Issued')).toBeTruthy();
    expect(screen.queryByText('Prepared')).toBeNull();
  });

  it('does not replace a newer payment-method switch with an older check refresh', async () => {
    vi.clearAllMocks();
    apiMocks.isAdmin = true;
    apiMocks.activeCompany = { id: 7, payroll_environment: 'live' };
    apiMocks.printQueue.mockResolvedValue({ items: [] });
    apiMocks.updatePaymentMethod.mockResolvedValue({});
    const checkRun = {
      ...payRun,
      status: 'committed',
      parallel_run: false,
      payroll_items: [{ ...payrollItem, check_number: '4401', check_status: 'unprinted' }],
    } as PayPeriod & { payroll_items: PayrollItem[] };
    const depositRun = {
      ...checkRun,
      payroll_items: [{ ...checkRun.payroll_items[0], effective_payment_delivery_method: 'direct_deposit' }],
    };
    let resolveCheckRefresh!: (response: { pay_period: typeof checkRun }) => void;
    let resolveSwitchRefresh!: (response: { pay_period: typeof depositRun }) => void;
    apiMocks.getPayPeriod
      .mockResolvedValueOnce({ pay_period: checkRun })
      .mockImplementationOnce(() => new Promise((resolve) => { resolveCheckRefresh = resolve; }))
      .mockImplementationOnce(() => new Promise((resolve) => { resolveSwitchRefresh = resolve; }));

    render(
      <MemoryRouter initialEntries={['/companies/7/pay-runs/12/checks']}>
        <Routes>
          <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findAllByText('Assigned')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Simulate check status change' }));
    fireEvent.click(screen.getAllByRole('button', { name: 'Switch for this run' })[0]);
    fireEvent.change(screen.getByRole('textbox', { name: 'Reason (at least 10 characters)' }), { target: { value: 'Payment not yet released' } });
    fireEvent.click(screen.getByRole('checkbox', { name: /I confirm this payment has not been issued/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Confirm switch' }));
    await waitFor(() => expect(apiMocks.getPayPeriod).toHaveBeenCalledTimes(3));

    await act(async () => { resolveSwitchRefresh({ pay_period: depositRun }); });
    expect(screen.getAllByText('Stub ready')).toBeTruthy();
    await act(async () => { resolveCheckRefresh({ pay_period: checkRun }); });
    expect(screen.getAllByText('Stub ready')).toBeTruthy();
    expect(screen.queryByText('Assigned')).toBeNull();
  });

  it('refreshes the mounted processing view after a check changes on the checks tab', async () => {
    vi.clearAllMocks();
    apiMocks.isAdmin = true;
    apiMocks.activeCompany = { id: 7, payroll_environment: 'live' };
    apiMocks.printQueue.mockResolvedValue({ items: [] });
    const preparedRun = {
      ...payRun,
      status: 'committed',
      parallel_run: false,
      payroll_items: [{ ...payrollItem, check_number: '4401', check_status: 'prepared' }],
    } as PayPeriod & { payroll_items: PayrollItem[] };
    const issuedRun = {
      ...preparedRun,
      payroll_items: [{ ...preparedRun.payroll_items[0], check_status: 'delivered' }],
    };
    apiMocks.getPayPeriod.mockResolvedValueOnce({ pay_period: preparedRun }).mockResolvedValueOnce({ pay_period: issuedRun });

    render(
      <MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}>
        <Routes>
          <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} />
        </Routes>
      </MemoryRouter>,
    );

    expect((await screen.findByTestId('mounted-processing-refresh-token')).textContent).toBe('0');
    fireEvent.click(screen.getByRole('link', { name: /Checks & direct deposit/ }));
    expect(await screen.findAllByText('Prepared')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Simulate check status change' }));
    expect(await screen.findAllByText('Issued')).toBeTruthy();
    expect(screen.getByTestId('mounted-processing-refresh-token').textContent).toBe('1');
    fireEvent.click(screen.getByRole('link', { name: 'Process payroll' }));
    expect(screen.getByTestId('mounted-processing-refresh-token').textContent).toBe('1');
  });
});
