// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { payrollHistoryApi, type ImportedPayPeriodDetail } from '@/services/api';
import { ImportedPayRunDetail } from './ImportedPayRunDetail';

vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 10 }) }));
vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/payroll/HistoricalAdjustmentPanel', () => ({ HistoricalAdjustmentPanel: () => <p>Adjustment panel</p> }));

function record(system: 'prior_provider' | 'quickbooks_online'): ImportedPayPeriodDetail {
  return {
    id: 5, record_type: 'imported', start_date: '2026-10-08', end_date: '2026-10-21', pay_date: '2026-10-28',
    employee_count: 1, total_gross: '1500', total_net: '1200',
    source: { system, label: system === 'prior_provider' ? 'Prior-provider history' : 'QuickBooks import', detail: 'Register', import_batch_id: 3, importer_version: 'v1', locked_by_name: 'Mark' },
    paychecks: [{ id: 9, employee_name: 'Ana Cruz', source_employee_name: 'Ana Cruz', hours_total: '80', gross_pay: '1500', employee_taxes: '200', pretax_deductions: '50', after_tax_deductions: '50', net_pay: '1200', check_number: '1001', provider_payment_reference: '0042', payment_method: 'check' }],
  } as unknown as ImportedPayPeriodDetail;
}

function open(system: 'prior_provider' | 'quickbooks_online') {
  vi.spyOn(payrollHistoryApi, 'importedPayPeriod').mockResolvedValue({ data: record(system), meta: { current_page: 1, per_page: 50, total_count: 1, total_pages: 1 } });
  render(
    <MemoryRouter initialEntries={['/companies/10/imported-pay-runs/5']}>
      <Routes><Route path="/companies/:companyId/imported-pay-runs/:id" element={<ImportedPayRunDetail audience="staff" />} /></Routes>
    </MemoryRouter>,
  );
}

afterEach(() => { cleanup(); vi.restoreAllMocks(); });

describe('Imported pay run adjustments', () => {
  it('offers no adjustment action for prior-provider history, which rejects every adjustment', async () => {
    open('prior_provider');
    await screen.findByText(/Before the first live payroll is committed/);
    expect(screen.queryByRole('button', { name: /adjustments/i })).toBeNull();
    expect(screen.queryByRole('columnheader', { name: 'Ledger' })).toBeNull();
  });

  it('keeps the adjustment action for QuickBooks history', async () => {
    open('quickbooks_online');
    expect((await screen.findAllByRole('button', { name: /adjustments/i })).length).toBeGreaterThan(0);
    expect(screen.getByRole('columnheader', { name: 'Ledger' })).toBeTruthy();
  });
});
