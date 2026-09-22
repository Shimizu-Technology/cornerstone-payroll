// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
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
  },
  checksApi: { rehearsalPreviewPdf: apiMocks.rehearsalPreviewPdf, printQueue: apiMocks.printQueue },
  payrollItemsApi: { updatePaymentMethod: vi.fn() },
}));

vi.mock('@/components/checks/UnifiedCheckPrintDialog', () => ({
  UnifiedCheckPrintDialog: ({ open }: { open: boolean }) => open ? <div role="dialog" aria-label="Print prepared checks">Print prepared checks</div> : null,
}));

vi.mock('@/components/payroll/ChecksPanel', () => ({
  ChecksPanel: () => <div>Check register</div>,
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
    expect(screen.getByText('Preview ready')).toBeTruthy();
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

    expect(await screen.findByText('Locked training baseline')).toBeTruthy();
    expect(screen.getByText('Locked baseline records')).toBeTruthy();
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
});
