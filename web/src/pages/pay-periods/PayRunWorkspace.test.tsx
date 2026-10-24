// @vitest-environment jsdom

import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { useState, type ReactNode } from 'react';
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
  getPayrollItem: vi.fn(),
  reportTransmittalPreview: vi.fn(),
  reportSignoffPreview: vi.fn(),
  signoffPdf: vi.fn(),
  transmittalPdf: vi.fn(),
  packagePdf: vi.fn(),
  isAdmin: true,
  activeCompany: { id: 7, payroll_environment: 'migration_rehearsal', workspace_can_write: true } as Record<string, unknown>,
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
  payrollItemsApi: { get: apiMocks.getPayrollItem, updatePaymentMethod: apiMocks.updatePaymentMethod },
  transmittalApi: { preview: apiMocks.reportTransmittalPreview },
  reportsApi: { checkSignoffPreview: apiMocks.reportSignoffPreview, checkSignoffPdf: apiMocks.signoffPdf, transmittalLogPdf: apiMocks.transmittalPdf, fullPrintPackagePdf: apiMocks.packagePdf },
}));

vi.mock('@/components/checks/UnifiedCheckPrintDialog', () => ({
  UnifiedCheckPrintDialog: ({ open }: { open: boolean }) => open ? <div role="dialog" aria-label="Print prepared checks">Print prepared checks</div> : null,
}));

vi.mock('@/components/checks/NonEmployeeChecksPanel', () => ({ NonEmployeeChecksPanel: ({ onChecksLoaded }: { onChecksLoaded?: (checks: { voided: boolean }[]) => void }) => <div>Tax and other checks
  <button onClick={() => onChecksLoaded?.([{ voided: true }])}>Load only voided tax checks</button>
  <button onClick={() => onChecksLoaded?.([{ voided: false }])}>Load active tax checks</button>
</div> }));

vi.mock('@/components/payroll/ChecksPanel', () => ({
  ChecksPanel: ({ onChecksChanged, refreshToken }: { onChecksChanged?: () => Promise<void>; refreshToken?: number }) => (
    <div data-testid="workspace-checks-refresh" data-refresh={refreshToken}>
      Check register
      <button onClick={() => void onChecksChanged?.()}>Simulate check status change</button>
    </div>
  ),
}));

vi.mock('@/pages/PayPeriodDetail', () => ({
  PayPeriodDetail: ({ refreshToken, activeTab, navigation, checksContent, activityContent }: { refreshToken?: number; activeTab?: string; navigation?: ReactNode; checksContent?: (options: { searchTerm: string; onChecksLoaded: () => void; refreshToken: number }) => ReactNode; activityContent?: ReactNode }) => {
    const [checkRefresh, setCheckRefresh] = useState(0);
    return <>{navigation}<div data-testid="mounted-processing-refresh-token">{refreshToken}</div>
      <button onClick={() => setCheckRefresh(value => value + 1)}>Correction saved</button>
      {activeTab === 'checks' && checksContent?.({ searchTerm: '', onChecksLoaded: () => {}, refreshToken: checkRefresh })}{activeTab === 'activity' && activityContent}
    </>;
  },
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

  it('redirects the writer overview alias into Payroll and exposes Reports', async () => {
    render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/overview?return_to=%2Fclients']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} /></Routes></MemoryRouter>);
    expect(await screen.findByRole('link', { name: 'Payroll' })).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Reports' })).toBeTruthy();
    expect(await screen.findByTestId('mounted-processing-refresh-token')).toBeTruthy();
  });


  beforeEach(() => {
    vi.clearAllMocks();
    apiMocks.isAdmin = true;
    apiMocks.activeCompany = { id: 7, payroll_environment: 'migration_rehearsal', workspace_can_write: true };
    apiMocks.getPayPeriod.mockResolvedValue({ pay_period: payRun });
    apiMocks.reportTransmittalPreview.mockResolvedValue({ saved_transmittal: null });
    apiMocks.reportSignoffPreview.mockResolvedValue({ entries: [], saved_signoff: null });
    apiMocks.rehearsalPreviewPdf.mockResolvedValue({
      blob: new Blob(['%PDF-1.4'], { type: 'application/pdf' }),
      filename: 'void_rehearsal_checks_2026-09-24.pdf',
    });
    apiMocks.printQueue.mockResolvedValue({ items: [] });
    apiMocks.getPayrollItem.mockResolvedValue({ payroll_item: { ...payrollItem, check_number: '4401', payment_method_change: { eligible: true, mode: 'simple', target_method: 'direct_deposit', original_check_number: '4401', requires_unpaid_confirmation: true, requires_check_cancellation: false, reason: null } } });
    apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
    apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });
    apiMocks.employeesList.mockResolvedValue({ data: [], meta: { total_pages: 1 } });
    apiMocks.recordActivities.mockResolvedValue({
      data: [],
      meta: { current_page: 1, per_page: 20, total_count: 0, total_pages: 0 },
    });
  });

  it('refreshes payment instruments after a correction in the persistent controller', async () => {
    apiMocks.activeCompany = { id: 7, payroll_environment: 'live', workspace_can_write: true };
    apiMocks.getPayPeriod.mockResolvedValue({ pay_period: { ...payRun, status: 'committed' } });
    render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} /></Routes></MemoryRouter>);
    fireEvent.click(await screen.findByRole('button', { name: 'Correction saved' }));
    fireEvent.click(screen.getByRole('link', { name: /Checks & payments/ }));
    expect((await screen.findByTestId('workspace-checks-refresh')).getAttribute('data-refresh')).toBe('1');
    fireEvent.click(screen.getByRole('link', { name: 'Activity' }));
    fireEvent.click(screen.getByRole('button', { name: 'Correction saved' }));
    fireEvent.click(screen.getByRole('link', { name: /Checks & payments/ }));
    expect((await screen.findByTestId('workspace-checks-refresh')).getAttribute('data-refresh')).toBe('2');
  });

  it('labels held correction totals as saved amounts without dropping their retained money', async () => {
    apiMocks.activeCompany = { id: 7, workspace_can_write: false };
    apiMocks.getPayPeriod.mockResolvedValue({ pay_period: { ...payRun, payroll_items: [{ ...payrollItem,
      correction_pay_basis_hold: { reason: 'Review retained original frequency before recalculation.' } }] } });
    render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/overview']}><Routes>
      <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} />
    </Routes></MemoryRouter>);
    const label = await screen.findByText('Saved gross payroll');
    expect(within(label.parentElement!).getByText('$700.00')).toBeTruthy();
    expect(screen.getByText('Saved net payroll')).toBeTruthy();
    expect(screen.getByText('Saved amounts, not a new-pay forecast')).toBeTruthy();
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

  it('routes an assigned reviewer away from processing while preserving record links', async () => {
    apiMocks.activeCompany = { id: 7, payroll_environment: 'migration_rehearsal', workspace_can_write: false };
    render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} /></Routes></MemoryRouter>);
    expect(await screen.findByText('Read-only workspace')).toBeTruthy();
    expect(screen.queryByText('Process payroll')).toBeNull();
    expect(screen.queryByText('Open processing')).toBeNull();
    expect(screen.getByRole('button', { name: 'Open payroll item for Alice Reyes' })).toBeTruthy();
    expect(screen.getByRole('link', { name: /Checks & payments/ })).toBeTruthy();
  });

  it('allows the reviewer to inspect a VOID rehearsal PDF without enabling payment actions', async () => {
    apiMocks.activeCompany = { id: 7, payroll_environment: 'migration_rehearsal', workspace_can_write: false };
    render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/checks']}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} /></Routes></MemoryRouter>);
    fireEvent.click(await screen.findByRole('button', { name: 'Preview rehearsal checks' }));
    expect(await screen.findByText(/Every check is marked VOID/)).toBeTruthy();
    expect(apiMocks.rehearsalPreviewPdf).toHaveBeenCalledWith(12);
    expect(screen.queryByRole('button', { name: 'Print checks' })).toBeNull();
    expect(screen.queryByRole('button', { name: /Change method/ })).toBeNull();
    expect(screen.queryByText('Open processing')).toBeNull();
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
    expect(screen.queryByText('Checks & payments')).toBeNull();
  });

  for (const mode of ['training_baseline', 'backup_snapshot', 'workspace_access']) {
    it.each(['reports', 'work'])(`keeps ${mode} Reports read-only when entering through %s`, async entry => {
      apiMocks.activeCompany = { id: 7, workspace_can_write: mode === 'training_baseline', ...(mode === 'backup_snapshot' ? { test_workspace_purpose: 'backup_snapshot' } : {}) };
      apiMocks.getPayPeriod.mockResolvedValue({ pay_period: { ...payRun, status: 'approved', ...(mode === 'training_baseline' ? { test_workspace_role: 'baseline' } : {}) } });
      render(<MemoryRouter initialEntries={[`/companies/7/pay-runs/12/${entry}`]}><Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} /></Routes></MemoryRouter>);
      if (entry === 'work') fireEvent.click(await screen.findByRole('link', { name: 'Reports' }));
      expect(await screen.findByText('Reports & Documents')).toBeTruthy();
      expect(screen.getByText('Payroll Register', { exact: true })).toBeTruthy();
      for (const name of ['Transmittal Log', 'Full Print Package', 'Check Sign-Off Sheet']) expect(screen.queryByText(name, { exact: true })).toBeNull();
      expect(screen.queryByRole('button', { name: /Generate|Add Row|Edit|Form 500/ })).toBeNull();
      expect(screen.queryByRole('textbox')).toBeNull();
      expect(apiMocks.reportTransmittalPreview).not.toHaveBeenCalled();
      expect(apiMocks.reportSignoffPreview).not.toHaveBeenCalled();
      expect(apiMocks.signoffPdf).not.toHaveBeenCalled();
      expect(apiMocks.transmittalPdf).not.toHaveBeenCalled();
      expect(apiMocks.packagePdf).not.toHaveBeenCalled();
    });
  }

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
    expect(screen.queryByText('Checks & payments')).toBeNull();
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
    const prepareButton = await screen.findByRole('button', { name: 'Prepare checks for payment' });
    await waitFor(() => expect(prepareButton.hasAttribute('disabled')).toBe(false));
    fireEvent.click(prepareButton);
    expect(await screen.findByText((_, element) => element?.tagName === 'P' && element.textContent === '1 paper check totaling $500.00')).toBeTruthy();
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
    await waitFor(() => {
      expect(apiMocks.recordActivities).toHaveBeenCalledWith('pay_periods', 12, { page: 1, per_page: 20 }, 7);
    });
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
    apiMocks.getPayrollItem.mockResolvedValue({ payroll_item: { ...payrollItem, check_number: '4401', payment_method_change: { eligible: true, mode: 'simple', target_method: 'direct_deposit', original_check_number: '4401', requires_unpaid_confirmation: true, requires_check_cancellation: false, reason: null } } });

    render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/checks']}>
      <Routes><Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} /></Routes>
    </MemoryRouter>);

    const phoneCard = await screen.findByRole('group', { name: 'Payment record for Alice Reyes' });
    const desktopRow = screen.getByRole('row', { name: /Alice Reyes/ });
    expect(within(phoneCard).getByText('Paper check · 4401')).toBeTruthy();
    expect(within(phoneCard).getByText('$500.00')).toBeTruthy();
    expect(within(phoneCard).getByText('Assigned')).toBeTruthy();
    expect(within(desktopRow).getByText('Assigned')).toBeTruthy();
    expect(within(desktopRow).getByRole('button', { name: 'Change payment method for Alice Reyes' })).toBeTruthy();
    fireEvent.click(within(phoneCard).getByRole('button', { name: 'Change payment method for Alice Reyes' }));
    expect(await screen.findByRole('textbox', { name: 'Reason for changing this payment (at least 10 characters)' })).toBeTruthy();
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
    apiMocks.getPayrollItem.mockResolvedValue({ payroll_item: { ...payrollItem, check_number: '4401', payment_method_change: { eligible: true, mode: 'simple', target_method: 'direct_deposit', original_check_number: '4401', requires_unpaid_confirmation: true, requires_check_cancellation: false, reason: null } } });

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
    apiMocks.getPayrollItem.mockResolvedValue({ payroll_item: { ...payrollItem, check_number: '4401', payment_method_change: { eligible: true, mode: 'simple', target_method: 'direct_deposit', original_check_number: '4401', requires_unpaid_confirmation: true, requires_check_cancellation: false, reason: null } } });
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
    apiMocks.getPayrollItem.mockResolvedValue({ payroll_item: { ...payrollItem, check_number: '4401', payment_method_change: { eligible: true, mode: 'simple', target_method: 'direct_deposit', original_check_number: '4401', requires_unpaid_confirmation: true, requires_check_cancellation: false, reason: null } } });
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
    fireEvent.click(screen.getAllByRole('button', { name: 'Change payment method for Alice Reyes' })[0]);
    fireEvent.change(await screen.findByRole('textbox', { name: 'Reason for changing this payment (at least 10 characters)' }), { target: { value: 'Payment not yet released' } });
    fireEvent.click(screen.getByRole('checkbox', { name: /I verified that this payment has not been paid/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Save payment method' }));
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
    apiMocks.getPayrollItem.mockResolvedValue({ payroll_item: { ...payrollItem, check_number: '4401', payment_method_change: { eligible: true, mode: 'simple', target_method: 'direct_deposit', original_check_number: '4401', requires_unpaid_confirmation: true, requires_check_cancellation: false, reason: null } } });
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
    fireEvent.click(screen.getByRole('link', { name: /Checks & payments/ }));
    expect(await screen.findAllByText('Prepared')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Simulate check status change' }));
    expect(await screen.findAllByText('Issued')).toHaveLength(2);
    expect(screen.getByTestId('mounted-processing-refresh-token').textContent).toBe('1');
    fireEvent.click(screen.getByRole('link', { name: 'Payroll' }));
    expect(screen.getByTestId('mounted-processing-refresh-token').textContent).toBe('1');
  });
});

it('keeps printing disabled for only voided non-employee checks and enables an active check', async () => {
  vi.clearAllMocks();
  apiMocks.activeCompany = { id: 7, payroll_environment: 'live', workspace_can_write: true };
  apiMocks.getPayPeriod.mockResolvedValue({ pay_period: { ...payRun, status: 'committed', parallel_run: false, payroll_items: [] } });
  apiMocks.printQueue.mockResolvedValue({ items: [] });
  render(<MemoryRouter initialEntries={['/companies/7/pay-runs/12/checks']}><Routes>
    <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayRunWorkspace />} />
  </Routes></MemoryRouter>);
  const print = await screen.findByRole('button', { name: 'Print checks' }) as HTMLButtonElement;
  await waitFor(() => expect(apiMocks.printQueue).toHaveBeenCalled());
  fireEvent.click(screen.getByRole('button', { name: 'Load only voided tax checks' }));
  expect(print.disabled).toBe(true);
  fireEvent.click(screen.getByRole('button', { name: 'Load active tax checks' }));
  expect(print.disabled).toBe(false);
  cleanup();
});
