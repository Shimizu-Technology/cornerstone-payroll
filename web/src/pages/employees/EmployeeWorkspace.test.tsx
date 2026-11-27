// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
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
  update: vi.fn(),
  appGet: vi.fn(async () => ({ data: { enabled: false, status: 'not_invited' } })),
}));
const companyState = vi.hoisted(() => ({ activeCompany: undefined as Record<string, unknown> | undefined }));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ hasCapability: () => true }),
  useOptionalAuth: () => ({ hasCapability: () => true }),
}));

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({ activeCompanyId: 1, activeCompany: companyState.activeCompany }),
}));

vi.mock('@/services/api', () => ({
  apiClient: { get: apiMocks.appGet },
  employeesApi: {
    get: apiMocks.get,
    update: apiMocks.update,
    resolveConfigurationReviewItem: apiMocks.resolveConfigurationReviewItem,
  },
  reportsApi: { employeePayHistory: apiMocks.employeePayHistory },
  payStubsApi: { batchPdf: apiMocks.batchPdf },
  recordActivitiesApi: { list: apiMocks.recordActivities },
  tippedOccupationsApi: { history: async () => ({ data: [], codes: {} }) },
}));

vi.mock('@/components/employees/EmployeeRetirementElectionPanel', () => ({
  EmployeeRetirementElectionPanel: () => null,
}));
vi.mock('@/components/employees/EmployeeRetirementYearPanel', () => ({ EmployeeRetirementYearPanel: () => null }));
vi.mock('@/components/employees/EmployeeNotesPanel', () => ({ EmployeeNotesPanel: () => null }));

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

  it('tells staff which new-hire documents are needed and links straight to them', async () => {
    apiMocks.get.mockResolvedValue({ data: { ...employee, document_readiness: { total: 2, required: 2, satisfied: 1, ready_for_payroll: false, missing: ['Signed withholding election'] } } });
    render(
      <MemoryRouter initialEntries={['/companies/1/employees/2/overview']}>
        <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<EmployeeWorkspace />} /></Routes>
      </MemoryRouter>,
    );

    const card = (await screen.findByRole('heading', { name: "Before this employee's first payroll" })).closest('section')!;
    expect(within(card).getByText(/Upload and verify: Signed withholding election\./)).toBeTruthy();
    expect(within(card).getByRole('link', { name: /Upload or verify/ }).getAttribute('href'))
      .toBe('/companies/1/employees/2/edit?return_to=%2Fcompanies%2F1%2Femployees%2F2%2Foverview#employee-documents');
  });

  it('shows no documents card once the new hire is payroll ready', async () => {
    apiMocks.get.mockResolvedValue({ data: { ...employee, document_readiness: { total: 2, required: 2, satisfied: 2, ready_for_payroll: true, missing: [] } } });
    render(
      <MemoryRouter initialEntries={['/companies/1/employees/2/overview']}>
        <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<EmployeeWorkspace />} /></Routes>
      </MemoryRouter>,
    );

    await screen.findByText('Employment context');
    expect(screen.queryByRole('heading', { name: "Before this employee's first payroll" })).toBeNull();
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
        payment_delivery_method: 'direct_deposit', payment_method_label: 'Direct deposit', check_number: null,
      }],
    } });
    render(
      <MemoryRouter initialEntries={['/companies/1/employees/2/pay-history']}>
        <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<EmployeeWorkspace />} /></Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByRole('columnheader', { name: 'Payment' })).toBeTruthy();
    expect(screen.getByRole('cell', { name: /Direct deposit/ })).toBeTruthy();
    const phoneCard = screen.getByRole('group', { name: 'Pay history for Sep 19, 2026' });
    expect(within(phoneCard).getByText('Direct deposit')).toBeTruthy();
    expect(within(phoneCard).getByText('$800.00')).toBeTruthy();
    expect(screen.queryByText('Not assigned')).toBeNull();
    expect(screen.getAllByRole('button', { name: 'View stub for Sep 19, 2026' })[0]).toBeTruthy();
  });

  it('keeps an unconfirmed bank payment open with a way to confirm it, and drops the link once confirmed', async () => {
    const deposit = {
      record_type: 'native', pay_period_id: 5,
      source: { system: 'cornerstone', label: 'Cornerstone', locked: true },
      gross_pay: 900, total_deductions: 100, net_pay: 800,
      payment_delivery_method: 'direct_deposit', check_number: null,
    };
    apiMocks.employeePayHistory.mockResolvedValue({ report: { summary: {}, history: [
      { ...deposit, key: 'native:4', payroll_item_id: 4, pay_date: '2026-09-19', period_description: 'September payroll',
        payment_evidence: { status: 'unissued', label: 'Transfer not confirmed', effective_on: null } },
      { ...deposit, key: 'native:6', payroll_item_id: 6, pay_period_id: 7, pay_date: '2026-08-19', period_description: 'August payroll',
        payment_evidence: { status: 'issued', label: 'Transfer confirmed', effective_on: '2026-08-19' } },
    ] } });
    render(
      <MemoryRouter initialEntries={['/companies/1/employees/2/pay-history']}>
        <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<EmployeeWorkspace />} /></Routes>
      </MemoryRouter>,
    );

    const phoneCard = await screen.findByRole('group', { name: 'Pay history for Sep 19, 2026' });
    expect(within(phoneCard).getByText(/Bank payment not confirmed yet/)).toBeTruthy();
    const links = screen.getAllByRole('link', { name: 'Confirm bank payment for Sep 19, 2026' });
    expect(links).toHaveLength(2);
    for (const link of links) expect(link.getAttribute('href')).toContain('/pay-runs/5/checks');
    expect(screen.queryByText(/handled outside the app/)).toBeNull();
    expect(within(screen.getByRole('group', { name: 'Pay history for Aug 19, 2026' })).getByText('Transfer confirmed')).toBeTruthy();
    expect(screen.queryByRole('link', { name: 'Confirm bank payment for Aug 19, 2026' })).toBeNull();
  });

  it('keeps a zero-net loan statement discoverable with an accurate payment label on phone and desktop', async () => {
    apiMocks.employeePayHistory.mockResolvedValue({ report: {
      summary: {},
      history: [{
        key: 'native:4', record_type: 'native', payroll_item_id: 4, pay_period_id: 5,
        pay_date: '2026-10-08', period_description: 'October payroll',
        source: { system: 'cornerstone', label: 'Cornerstone', locked: true },
        hours_worked: 21.37, gross_pay: 197.67, total_deductions: 197.67, net_pay: 0,
        payment_delivery_method: 'paper_check', payment_method_label: '$0 net · earnings statement only', check_number: null,
      }],
    } });
    render(
      <MemoryRouter initialEntries={['/companies/1/employees/2/pay-history']}>
        <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<EmployeeWorkspace />} /></Routes>
      </MemoryRouter>,
    );
    expect(await screen.findByRole('cell', { name: '$0 net · earnings statement only' })).toBeTruthy();
    const phoneCard = screen.getByRole('group', { name: 'Pay history for Oct 8, 2026' });
    expect(within(phoneCard).getByText('$0 net · earnings statement only')).toBeTruthy();
    expect(screen.getAllByRole('button', { name: 'View stub for Oct 8, 2026' })).toHaveLength(2);
    expect(screen.queryByText('Paper check · not assigned')).toBeNull();
  });

  it('changes year and source filters without losing the selected employee or return context', async () => {
    const native = {
      key: 'native:4', record_type: 'native', payroll_item_id: 4, pay_period_id: 5,
      pay_date: '2026-09-19', period_description: 'Current native payroll',
      source: { system: 'cornerstone', label: 'Cornerstone', locked: true },
      gross_pay: 900, total_deductions: 100, net_pay: 800, check_number: '30000',
    };
    apiMocks.employeePayHistory.mockResolvedValue({ report: { summary: {}, history: [
      native,
      { ...native, key: 'native:6', payroll_item_id: 6, pay_period_id: 7,
        pay_date: '2025-09-19', period_description: 'Prior native payroll' },
      { ...native, key: 'imported:9', record_type: 'imported', payroll_item_id: null,
        pay_period_id: null, historical_pay_period_id: 9, pay_date: '2025-08-19',
        period_description: 'Prior imported payroll', basis_label: 'As imported',
        source: { system: 'quickbooks_online', label: 'QuickBooks', locked: true } },
    ] } });
    const returnTo = '/companies/1/pay-runs/5/work';
    render(<MemoryRouter initialEntries={[`/companies/1/employees/2/pay-history?history_year=2026&history_source=cornerstone&return_to=${encodeURIComponent(returnTo)}`]}>
      <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<EmployeeWorkspace />} /></Routes>
    </MemoryRouter>);

    const year = await screen.findByRole('combobox', { name: 'Year' });
    const source = screen.getByRole('combobox', { name: 'Source' });
    expect(year).toHaveProperty('value', '2026');
    expect(source).toHaveProperty('value', 'cornerstone');
    expect(screen.getByRole('group', { name: 'Pay history for Sep 19, 2026' })).toBeTruthy();
    fireEvent.change(year, { target: { value: '2025' } });
    expect(screen.getByRole('group', { name: 'Pay history for Sep 19, 2025' })).toBeTruthy();
    expect(screen.queryByRole('group', { name: 'Pay history for Sep 19, 2026' })).toBeNull();
    expect(source).toHaveProperty('value', 'cornerstone');
    fireEvent.change(source, { target: { value: 'quickbooks' } });
    expect(screen.getByRole('group', { name: 'Pay history for Aug 19, 2025' })).toBeTruthy();
    expect(screen.queryByRole('group', { name: 'Pay history for Sep 19, 2025' })).toBeNull();
    // The imported row says it is as imported, on phone and desktop.
    expect(screen.getAllByText('As imported')).toHaveLength(2);
    expect(year).toHaveProperty('value', '2025');
    const href = screen.getByRole('link', { name: 'Overview' }).getAttribute('href')!;
    const destination = new URL(href, 'https://payroll.example');
    expect(destination.pathname).toBe('/companies/1/employees/2/overview');
    expect(destination.searchParams.get('history_year')).toBe('2025');
    expect(destination.searchParams.get('history_source')).toBe('quickbooks');
    expect(destination.searchParams.get('return_to')).toBe(returnTo);
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

    fireEvent.click((await screen.findAllByRole('button', { name: 'View stub for Sep 19, 2026' }))[0]);
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
    await waitFor(() => expect(apiMocks.recordActivities).toHaveBeenCalledWith('employees', 2, { page: 1, per_page: 20 }, 1));
  });
  it('retains retirement year alongside source-hour filters between employee sections', async () => {
    render(<MemoryRouter initialEntries={['/companies/1/employees/2/pay-setup?retirement_year=2027&hours_source=8&hours_start=2026-09-01&history_year=2026']}><Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<EmployeeWorkspace />} /></Routes></MemoryRouter>);
    await screen.findByRole('button', { name: 'Record certification' });
    for (const name of ['Hours & payroll', 'Pay setup']) {
      const href = screen.getByRole('link', { name }).getAttribute('href');
      expect(href).toContain('retirement_year=2027');
      expect(href).toContain('hours_source=8');
      expect(href).toContain('hours_start=2026-09-01');
      expect(href).toContain('history_year=2026');
    }
  });

});

describe('EmployeeWorkspace Contact card', () => {
  const withContact = {
    ...employee, email: 'mo.old@example.net', phone: '+16715550100', city: 'Hagatna', state: 'GU', zip: '96910', contact_revision: 'rev-1',
    intake_readiness: { profile_incomplete: true, missing_fields: ['address_line1'] },
  } as unknown as Employee;

  function renderOverview() {
    return render(
      <MemoryRouter initialEntries={['/companies/1/employees/2/overview']}>
        <Routes><Route path="/companies/:companyId/employees/:id/:tab" element={<EmployeeWorkspace />} /></Routes>
      </MemoryRouter>,
    );
  }

  beforeEach(() => {
    vi.clearAllMocks();
    companyState.activeCompany = undefined;
    apiMocks.get.mockResolvedValue({ data: withContact });
    apiMocks.employeePayHistory.mockResolvedValue({ report: { history: [], summary: {} } });
  });
  afterEach(cleanup);

  it('opens the card from Edit contact details, and an address and email save refreshes intake and the app panel', async () => {
    renderOverview();
    fireEvent.click(await screen.findByRole('button', { name: 'Edit contact details' }));
    expect(document.activeElement).toBe(screen.getByLabelText('Email for Mo Owner'));
    expect(screen.getByText('Profile incomplete')).toBeTruthy();
    const panelReads = apiMocks.appGet.mock.calls.length;

    const saved = { ...withContact, email: 'mo.new@example.net', address_line1: '1 Example St', contact_revision: 'rev-2' };
    apiMocks.update.mockResolvedValueOnce({ data: saved, contact_warnings: [] });
    apiMocks.get.mockResolvedValue({ data: { ...saved, intake_readiness: { profile_incomplete: false, missing_fields: [] } } });
    fireEvent.change(screen.getByLabelText('Email for Mo Owner'), { target: { value: 'mo.new@example.net' } });
    fireEvent.change(screen.getByLabelText('Street address for Mo Owner'), { target: { value: '1 Example St' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save Mo Owner' }));

    await waitFor(() => expect(apiMocks.update).toHaveBeenCalledWith(2, expect.objectContaining({
      email: 'mo.new@example.net', address_line1: '1 Example St', row_revision: 'rev-1', response_view: 'contact',
    }), 1));
    expect(await screen.findByText('mo.new@example.net')).toBeTruthy();
    await waitFor(() => expect(screen.queryByText('Profile incomplete')).toBeNull());
    await waitFor(() => expect(apiMocks.appGet.mock.calls.length).toBeGreaterThan(panelReads));
  });

  it('shows contact read-only and hides Edit contact details in a read-only workspace', async () => {
    companyState.activeCompany = { id: 1, workspace_can_write: false };
    renderOverview();
    expect(await screen.findByText('mo.old@example.net')).toBeTruthy();
    await screen.findByText(/employee app isn't turned on/);
    expect(screen.queryByRole('button', { name: 'Edit contact details' })).toBeNull();
    expect(screen.queryByRole('link', { name: 'Edit contact details' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Edit contact for Mo Owner' })).toBeNull();
  });
});
