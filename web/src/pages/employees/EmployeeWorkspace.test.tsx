// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Employee } from '@/types';
import { EmployeeWorkspace } from './EmployeeWorkspace';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  employeePayHistory: vi.fn(),
  batchPdf: vi.fn(),
  resolveConfigurationReviewItem: vi.fn(),
  recordActivities: vi.fn(),
}));

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({ activeCompanyId: 1 }),
}));

vi.mock('@/services/api', () => ({
  employeesApi: {
    get: apiMocks.get,
    resolveConfigurationReviewItem: apiMocks.resolveConfigurationReviewItem,
  },
  reportsApi: { employeePayHistory: apiMocks.employeePayHistory },
  payStubsApi: { batchPdf: apiMocks.batchPdf },
  recordActivitiesApi: { list: apiMocks.recordActivities },
}));

vi.mock('@/components/employees/EmployeeRetirementElectionPanel', () => ({
  EmployeeRetirementElectionPanel: () => null,
}));

vi.mock('@/components/documents/PdfPreview', () => ({
  PdfPreview: ({ artifact }: { artifact: { title: string } | null }) => artifact ? <div role="dialog">{artifact.title}</div> : null,
}));

const employee = {
  id: 2,
  company_id: 1,
  first_name: 'Mo',
  last_name: 'Owner',
  employment_type: 'salary',
  salary_type: 'variable',
  pay_rate: 0,
  pay_frequency: 'biweekly',
  filing_status: 'married',
  allowances: 0,
  additional_withholding: 0,
  w4_dependent_credit: 0,
  w4_step2_multiple_jobs: false,
  w4_step4a_other_income: 0,
  w4_step4b_deductions: 0,
  w4_form_version: 2025,
  retirement_rate: 0,
  roth_retirement_rate: 0,
  status: 'active',
  configuration_source: 'quickbooks_history',
  configuration_review_status: 'needs_review',
  configuration_review_items: [{
    code: 'certify_variable_salary_pay',
    message: 'Confirm how this variable salary is determined for each pay period.',
    fields: ['salary_type', 'pay_rate'],
    requires_certification_evidence: true,
  }],
  configuration_review_resolutions: [],
  created_at: '2026-09-01T00:00:00Z',
  updated_at: '2026-09-01T00:00:00Z',
} as Employee;

describe('EmployeeWorkspace imported setup certification', () => {
  afterEach(cleanup);

  beforeEach(() => {
    vi.clearAllMocks();
    apiMocks.get.mockResolvedValue({ data: employee });
    apiMocks.employeePayHistory.mockResolvedValue({ report: { history: [], summary: {} } });
    apiMocks.resolveConfigurationReviewItem.mockResolvedValue({
      data: {
        ...employee,
        configuration_review_status: 'complete',
        configuration_review_items: [],
      },
    });
    apiMocks.recordActivities.mockResolvedValue({
      data: [],
      meta: { current_page: 1, per_page: 20, total_count: 0, total_pages: 0 },
    });
  });

  it('requires authoritative source evidence and sends it with the certification', async () => {
    render(
      <MemoryRouter initialEntries={['/companies/1/employees/2/pay-setup']}>
        <Routes>
          <Route path="/companies/:companyId/employees/:id/:tab" element={<EmployeeWorkspace />} />
        </Routes>
      </MemoryRouter>,
    );

    const button = await screen.findByRole('button', { name: 'Record certification' });
    expect(button.hasAttribute('disabled')).toBe(true);

    fireEvent.change(screen.getByLabelText('Source document or record'), {
      target: { value: 'Signed owner compensation instruction dated 09/01/2026' },
    });
    fireEvent.change(screen.getByLabelText('Effective date'), { target: { value: '2026-09-01' } });
    fireEvent.change(screen.getByLabelText('What was verified or corrected?'), {
      target: { value: 'Confirmed that Mo supplies a separate approved amount for every regular payroll.' },
    });
    fireEvent.click(button);

    await waitFor(() => expect(apiMocks.resolveConfigurationReviewItem).toHaveBeenCalledWith(2, {
      code: 'certify_variable_salary_pay',
      resolution_note: 'Confirmed that Mo supplies a separate approved amount for every regular payroll.',
      source_reference: 'Signed owner compensation instruction dated 09/01/2026',
      effective_on: '2026-09-01',
      acknowledgement: 'MARK SETUP ITEM REVIEWED',
    }));
    expect(await screen.findByText('Setup review item documented.')).toBeTruthy();
  });

  it('shows direct deposit and its external transfer limitation on the overview', async () => {
    apiMocks.get.mockResolvedValue({ data: { ...employee, payment_delivery_method: 'direct_deposit' } });
    render(
      <MemoryRouter initialEntries={['/companies/1/employees/2/overview']}>
        <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<EmployeeWorkspace />} /></Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText(/Cornerstone prepares an earnings stub; the bank transfer is handled and confirmed outside the app/)).toBeTruthy();
    expect(screen.getAllByText('Direct deposit').length).toBeGreaterThan(0);
  });

  it('identifies an unreviewed payment method as a paper check default', async () => {
    render(
      <MemoryRouter initialEntries={['/companies/1/employees/2/overview']}>
        <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<EmployeeWorkspace />} /></Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText(/Payment method has not been reviewed/)).toBeTruthy();
    expect(screen.getAllByText('Paper check (default)').length).toBeGreaterThan(0);
    expect(screen.getByText('Set each pay period')).toBeTruthy();
  });

  it('shows direct deposit in pay history instead of an unassigned check', async () => {
    apiMocks.employeePayHistory.mockResolvedValue({ report: {
      summary: {},
      history: [{
        key: 'native:4', record_type: 'native', payroll_item_id: 4, pay_period_id: 5,
        pay_date: '2026-09-19', period_description: 'September payroll',
        source: { system: 'cornerstone', label: 'Cornerstone', locked: true },
        gross_pay: 900, total_deductions: 100, net_pay: 800,
        payment_delivery_method: 'direct_deposit', check_number: null,
      }],
    } });
    render(
      <MemoryRouter initialEntries={['/companies/1/employees/2/pay-history']}>
        <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<EmployeeWorkspace />} /></Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByRole('columnheader', { name: 'Payment' })).toBeTruthy();
    expect(screen.getByRole('cell', { name: 'Direct deposit' })).toBeTruthy();
    expect(screen.queryByText('Not assigned')).toBeNull();
    expect(screen.getByRole('button', { name: 'View stub for Sep 19, 2026' })).toBeTruthy();
  });

  it('previews a Cornerstone stub from history and offers no stub for imported history', async () => {
    apiMocks.batchPdf.mockResolvedValue({ blob: new Blob(['%PDF']), filename: 'paystub.pdf' });
    apiMocks.employeePayHistory.mockResolvedValue({ report: { summary: {}, history: [
      {
        key: 'native:4', record_type: 'native', payroll_item_id: 4, pay_period_id: 5,
        pay_date: '2026-09-19', period_description: 'September payroll',
        source: { system: 'cornerstone', label: 'Cornerstone', locked: true },
        gross_pay: 900, total_deductions: 100, net_pay: 800, check_number: null,
      },
      {
        key: 'imported:9', record_type: 'imported', payroll_item_id: null, pay_period_id: null,
        historical_pay_period_id: 9, pay_date: '2025-09-19', period_description: 'Imported payroll',
        source: { system: 'quickbooks_online', label: 'QuickBooks', locked: true },
        gross_pay: 900, total_deductions: 100, net_pay: 800, check_number: null,
      },
    ] } });
    render(<MemoryRouter initialEntries={['/companies/1/employees/2/pay-history']}>
      <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<EmployeeWorkspace />} /></Routes>
    </MemoryRouter>);

    fireEvent.click(await screen.findByRole('button', { name: 'View stub for Sep 19, 2026' }));
    await waitFor(() => expect(apiMocks.batchPdf).toHaveBeenCalledWith(5, [4]));
    expect(await screen.findByRole('dialog')).toHaveProperty('textContent', 'Pay stub · Sep 19, 2026');
    expect(screen.queryByRole('button', { name: 'View stub for Sep 19, 2025' })).toBeNull();
  });

  it('combines complete record activity with employment and classification context', async () => {
    render(
      <MemoryRouter initialEntries={['/companies/1/employees/2/activity']}>
        <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<EmployeeWorkspace />} /></Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText('Complete activity history')).toBeTruthy();
    expect(screen.getByText('Employment milestones')).toBeTruthy();
    expect(screen.getByText('Classification history')).toBeTruthy();
    expect(apiMocks.recordActivities).toHaveBeenCalledWith('employees', 2, { page: 1, per_page: 20 }, 1);
  });
});
