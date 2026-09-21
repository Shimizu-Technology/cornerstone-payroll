// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { PayPeriod, PayrollItem } from '@/types';
import { PayRunWorkspace } from './PayRunWorkspace';

const apiMocks = vi.hoisted(() => ({
  getPayPeriod: vi.fn(),
  rehearsalPreviewPdf: vi.fn(),
  activeCompany: { id: 7, payroll_environment: 'migration_rehearsal' } as Record<string, unknown>,
}));

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({
    activeCompany: apiMocks.activeCompany,
  }),
}));

vi.mock('@/services/api', () => ({
  payPeriodsApi: { get: apiMocks.getPayPeriod },
  checksApi: { rehearsalPreviewPdf: apiMocks.rehearsalPreviewPdf },
  payrollItemsApi: { updatePaymentMethod: vi.fn() },
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
    apiMocks.activeCompany = { id: 7, payroll_environment: 'migration_rehearsal' };
    apiMocks.getPayPeriod.mockResolvedValue({ pay_period: payRun });
    apiMocks.rehearsalPreviewPdf.mockResolvedValue({
      blob: new Blob(['%PDF-1.4'], { type: 'application/pdf' }),
      filename: 'void_rehearsal_checks_2026-09-24.pdf',
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

  it('routes sealed backups to a review-only workspace', async () => {
    apiMocks.activeCompany = {
      id: 7,
      payroll_environment: 'migration_rehearsal',
      test_workspace_purpose: 'backup_snapshot',
      test_workspace_sealed_at: '2026-09-22T00:00:00Z',
    };

    render(
      <MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}>
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
});
