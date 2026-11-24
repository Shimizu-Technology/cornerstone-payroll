// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeContactDetails } from './EmployeeContactDetails';
import { ApiError } from '@/services/api';
import type { Employee } from '@/types';

const authState = vi.hoisted(() => ({
  isClient: true,
  user: { id: 1, company_id: 7, role: 'client', name: 'MoSa Admin', email: 'mosa.admin@example.com' },
}));

const companyState = vi.hoisted(() => ({
  activeCompanyId: 7,
  activeCompany: {
    id: 7,
    name: "MoSa's Demo",
    active: true,
    workspace_can_write: true,
    client_capabilities: ['manage_client_configuration'],
  } as Record<string, unknown>,
}));

const capabilityState = vi.hoisted(() => ({
  manageClientConfiguration: true,
}));

const apiMocks = vi.hoisted(() => ({
  adminList: vi.fn(),
  adminUpdate: vi.fn(),
  clientList: vi.fn(),
  clientUpdate: vi.fn(),
  sharedEmails: vi.fn(),
  clearSharedEmails: vi.fn(),
}));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({
    user: authState.user,
    isClient: authState.isClient,
  }),
}));

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({
    activeCompanyId: companyState.activeCompanyId,
    activeCompany: companyState.activeCompany,
  }),
}));

vi.mock('@/hooks/useSelectedCompanyCapability', () => ({
  useSelectedCompanyCapability: () => capabilityState.manageClientConfiguration,
}));

vi.mock('@/services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/api')>();
  return {
    ...actual,
    employeesApi: {
      list: apiMocks.adminList,
      update: apiMocks.adminUpdate,
    },
    clientEmployeesApi: {
      list: apiMocks.clientList,
      update: apiMocks.clientUpdate,
    },
    employeeContactHygieneApi: {
      sharedEmails: apiMocks.sharedEmails,
      clearSharedEmails: apiMocks.clearSharedEmails,
    },
  };
});

function buildEmployee(overrides: Partial<Employee> = {}): Employee {
  return {
    id: 101,
    company_id: 7,
    first_name: 'Maria',
    last_name: 'Cruz',
    email: '',
    phone: '',
    employment_type: 'hourly',
    pay_rate: 16,
    pay_frequency: 'biweekly',
    filing_status: 'single',
    allowances: 0,
    additional_withholding: 0,
    w4_dependent_credit: 0,
    w4_step2_multiple_jobs: false,
    w4_step4a_other_income: 0,
    w4_step4b_deductions: 0,
    w4_form_version: 2020,
    retirement_rate: 0,
    roth_retirement_rate: 0,
    status: 'active',
    address_line1: '',
    address_line2: '',
    city: '',
    state: 'GU',
    zip: '',
    email_verified_at: null,
    phone_confirmed_by_employee_at: null,
    contact_source: null,
    contact_details_status: {
      needs_contact_details: true,
      missing_fields: ['email', 'phone', 'address_line1', 'city', 'zip'],
      email_issue: null,
    },
    created_at: '2026-11-01T00:00:00Z',
    updated_at: '2026-11-01T00:00:00Z',
    ...overrides,
  };
}

function renderPage(initialEntry = '/companies/7/employees/contact-details') {
  return render(
    <MemoryRouter initialEntries={[initialEntry]}>
      <Routes>
        <Route path="/companies/:companyId/employees/contact-details" element={<EmployeeContactDetails />} />
        <Route path="/companies/:companyId/employees" element={<div>Employees list</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

describe('EmployeeContactDetails', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    authState.isClient = true;
    authState.user = { id: 1, company_id: 7, role: 'client', name: 'MoSa Admin', email: 'mosa.admin@example.com' };
    companyState.activeCompanyId = 7;
    companyState.activeCompany = {
      id: 7,
      name: "MoSa's Demo",
      active: true,
      workspace_can_write: true,
      client_capabilities: ['manage_client_configuration'],
    };
    capabilityState.manageClientConfiguration = true;
  });

  afterEach(cleanup);

  it('lets a client user filter needs-contact-details, edit and save a row, and see coworker warnings inline', async () => {
    const maria = buildEmployee({ id: 101, first_name: 'Maria', last_name: 'Cruz' });
    const jose = buildEmployee({
      id: 102,
      first_name: 'Jose',
      last_name: 'Santos',
      email: 'jose.santos@example.com',
      phone: '+16715550199',
      address_line1: '100 Marine Corps Dr',
      city: 'Hagatna',
      state: 'GU',
      zip: '96910',
      contact_details_status: { needs_contact_details: false, missing_fields: [], email_issue: null },
    });

    apiMocks.clientList.mockResolvedValue({
      data: [maria, jose],
      meta: { current_page: 1, total_pages: 1, total_count: 2, per_page: 250, needs_contact_details_count: 1 },
    });

    apiMocks.clientUpdate.mockResolvedValue({
      data: {
        ...maria,
        email: 'jose.santos@example.com',
        phone: '+16715550101',
        address_line1: '200 Pale San Vitores Rd',
        city: 'Tamuning',
        state: 'GU',
        zip: '96913',
        contact_source: 'client',
        contact_details_status: {
          needs_contact_details: false,
          missing_fields: [],
          email_issue: 'shared_with_coworker',
        },
      },
      contact_warnings: [
        {
          code: 'duplicate_company_email',
          field: 'email',
          message: 'Another employee at this company already uses this email address (Jose Santos).',
        },
      ],
    });

    renderPage();

    expect((await screen.findAllByText('Maria Cruz')).length).toBeGreaterThan(0);
    // Client portal never shows the staff-only shared inbox report tab.
    expect(screen.queryByRole('tab', { name: /Shared & placeholder emails/i })).toBeNull();
    expect(apiMocks.sharedEmails).not.toHaveBeenCalled();

    // Edit Maria's email, mobile (7-digit Guam number), and address in the desktop grid
    const emailInput = screen.getByLabelText('Email for Maria Cruz');
    const phoneInput = screen.getByLabelText('Mobile for Maria Cruz');
    const streetInput = screen.getByLabelText('Street address for Maria Cruz');
    const cityInput = screen.getByLabelText('City for Maria Cruz');
    const zipInput = screen.getByLabelText('ZIP for Maria Cruz');

    fireEvent.change(emailInput, { target: { value: 'jose.santos@example.com' } });
    fireEvent.change(phoneInput, { target: { value: '555-0101' } });
    fireEvent.change(streetInput, { target: { value: '200 Pale San Vitores Rd' } });
    fireEvent.change(cityInput, { target: { value: 'Tamuning' } });
    fireEvent.change(zipInput, { target: { value: '96913' } });

    fireEvent.click(screen.getByRole('button', { name: 'Save Maria Cruz' }));

    await waitFor(() => {
      expect(apiMocks.clientUpdate).toHaveBeenCalledWith(101, {
        email: 'jose.santos@example.com',
        phone: '555-0101',
        address_line1: '200 Pale San Vitores Rd',
        address_line2: '',
        city: 'Tamuning',
        state: 'GU',
        zip: '96913',
      });
    });

    expect((await screen.findAllByText(/Another employee at this company already uses this email address/i)).length).toBeGreaterThan(0);
    expect((screen.getByLabelText('Mobile for Maria Cruz') as HTMLInputElement).value).toBe('+16715550101');

    // Toggle "Needs contact details" filter
    apiMocks.clientList.mockResolvedValueOnce({
      data: [],
      meta: { current_page: 1, total_pages: 1, total_count: 0, per_page: 250, needs_contact_details_count: 0 },
    });
    fireEvent.click(screen.getByRole('button', { name: /Needs contact details/i }));

    await waitFor(() => {
      expect(apiMocks.clientList).toHaveBeenLastCalledWith(
        expect.objectContaining({ needs_contact_details: true }),
      );
    });
  });

  it('offers inline same-person confirmation when saving an employee login email and retries with confirm_same_person_email', async () => {
    const emma = buildEmployee({ id: 105, first_name: 'Emma', last_name: 'Pleadwell' });

    apiMocks.clientList.mockResolvedValue({
      data: [emma],
      meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 250, needs_contact_details_count: 1 },
    });

    apiMocks.clientUpdate
      .mockRejectedValueOnce(
        new ApiError(
          'This email belongs to an existing payroll login. Confirm it belongs to this employee to save.',
          422,
          { email: ['This email belongs to an existing payroll login. Confirm it belongs to this employee to save.'] },
          {
            contact_validation: {
              same_person_confirmation_required: true,
              warnings: [],
            },
          },
        ),
      )
      .mockResolvedValueOnce({
        data: {
          ...emma,
          email: 'emma.client@example.com',
          contact_source: 'client',
          contact_details_status: { needs_contact_details: true, missing_fields: ['phone', 'address_line1', 'city', 'zip'], email_issue: null },
        },
        contact_warnings: [],
      });

    renderPage();
    expect((await screen.findAllByText('Emma Pleadwell')).length).toBeGreaterThan(0);

    fireEvent.change(screen.getByLabelText('Email for Emma Pleadwell'), {
      target: { value: 'emma.client@example.com' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Save Emma Pleadwell' }));

    const checkboxes = await screen.findAllByRole('checkbox', {
      name: /Confirm this login belongs to Emma Pleadwell/i,
    });
    const confirmButtons = screen.getAllByRole('button', { name: 'Confirm & save' });
    expect((confirmButtons[0] as HTMLButtonElement).disabled).toBe(true);

    fireEvent.click(checkboxes[0]);
    expect((confirmButtons[0] as HTMLButtonElement).disabled).toBe(false);

    fireEvent.click(confirmButtons[0]);

    await waitFor(() => {
      expect(apiMocks.clientUpdate).toHaveBeenLastCalledWith(
        105,
        expect.objectContaining({
          email: 'emma.client@example.com',
          confirm_same_person_email: true,
        }),
      );
    });
    expect((await screen.findAllByText('Saved')).length).toBeGreaterThan(0);
  });

  it('shows the staff-only shared-inbox report with single-company confirmation dialog for authorized staff', async () => {
    authState.isClient = false;
    authState.user = { id: 2, company_id: 7, role: 'org_admin', name: 'Cornerstone Admin', email: 'staff@example.com' };
    capabilityState.manageClientConfiguration = true;

    apiMocks.adminList.mockResolvedValue({
      data: [buildEmployee({ id: 201, first_name: 'Ana', last_name: 'Reyes', email: 'shared-inbox@example.com' })],
      meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 250, needs_contact_details_count: 1 },
    });

    apiMocks.sharedEmails
      .mockResolvedValueOnce({
        summary: {
          companies_affected: 2,
          distinct_flagged_emails: 1,
          total_employee_records: 8,
          active_employee_records: 6,
        },
        companies: [
          {
            company_id: 7,
            company_name: "MoSa's Demo",
            total_flagged_records: 5,
            active_flagged_records: 4,
            emails: [
              {
                email: 'shared-inbox@example.com',
                classification: 'shared_inbox',
                reasons: ['shared_across_companies'],
                total_count: 5,
                active_count: 4,
                inactive_count: 1,
                companies_count: 2,
                organization_total_count: 8,
              },
            ],
          },
          {
            company_id: 8,
            company_name: 'Island Bakery',
            total_flagged_records: 3,
            active_flagged_records: 2,
            emails: [
              {
                email: 'shared-inbox@example.com',
                classification: 'shared_inbox',
                reasons: ['shared_across_companies'],
                total_count: 3,
                active_count: 2,
                inactive_count: 1,
                companies_count: 2,
                organization_total_count: 8,
              },
            ],
          },
        ],
      })
      .mockResolvedValueOnce({
        summary: {
          companies_affected: 2,
          distinct_flagged_emails: 1,
          total_employee_records: 8,
          active_employee_records: 6,
        },
        companies: [
          {
            company_id: 7,
            company_name: "MoSa's Demo",
            total_flagged_records: 5,
            active_flagged_records: 4,
            emails: [
              {
                email: 'shared-inbox@example.com',
                classification: 'shared_inbox',
                reasons: ['shared_across_companies'],
                total_count: 5,
                active_count: 4,
                inactive_count: 1,
                companies_count: 2,
                organization_total_count: 8,
              },
            ],
          },
          {
            company_id: 8,
            company_name: 'Island Bakery',
            total_flagged_records: 3,
            active_flagged_records: 2,
            emails: [
              {
                email: 'shared-inbox@example.com',
                classification: 'shared_inbox',
                reasons: ['shared_across_companies'],
                total_count: 3,
                active_count: 2,
                inactive_count: 1,
                companies_count: 2,
                organization_total_count: 8,
              },
            ],
          },
        ],
      })
      .mockResolvedValueOnce({
        summary: {
          companies_affected: 1,
          distinct_flagged_emails: 1,
          total_employee_records: 3,
          active_employee_records: 2,
        },
        companies: [
          {
            company_id: 8,
            company_name: 'Island Bakery',
            total_flagged_records: 3,
            active_flagged_records: 2,
            emails: [
              {
                email: 'shared-inbox@example.com',
                classification: 'shared_inbox',
                reasons: ['shared_across_companies'],
                total_count: 3,
                active_count: 2,
                inactive_count: 1,
                companies_count: 1,
                organization_total_count: 3,
              },
            ],
          },
        ],
      });

    apiMocks.clearSharedEmails.mockResolvedValue({
      data: {
        company_id: 7,
        company_name: "MoSa's Demo",
        email: 'shared-inbox@example.com',
        cleared_count: 5,
        active_cleared_count: 4,
        inactive_cleared_count: 1,
      },
      message: "Cleared shared-inbox@example.com on 5 employee records for MoSa's Demo.",
    });

    renderPage();

    const sharedTab = await screen.findByRole('tab', { name: /Shared & placeholder emails/i });
    fireEvent.click(sharedTab);

    expect(await screen.findByText('Shared and placeholder emails')).toBeTruthy();
    expect(screen.getAllByText('shared-inbox@example.com').length).toBe(2);

    const clearButtons = screen.getAllByRole('button', { name: /Clear to blank/i });
    fireEvent.click(clearButtons[0]);

    const dialog = await screen.findByRole('dialog');
    const confirmAction = within(dialog).getByRole('button', { name: /Clear 5 records/i }) as HTMLButtonElement;
    expect(confirmAction.disabled).toBe(true);

    fireEvent.click(within(dialog).getByRole('checkbox'));
    expect(confirmAction.disabled).toBe(false);

    fireEvent.click(confirmAction);

    await waitFor(() => {
      expect(apiMocks.clearSharedEmails).toHaveBeenCalledWith({
        company_id: 7,
        email: 'shared-inbox@example.com',
      });
    });

    expect(await screen.findByText(/Cleared shared-inbox@example.com on 5 employee records/i)).toBeTruthy();
    // Initial badge load + opening panel + post-clear refresh = 3 calls (never an infinite reload loop).
    expect(apiMocks.sharedEmails).toHaveBeenCalledTimes(3);
  });

  it('hides the shared-inbox report tab from staff without manage_client_configuration', async () => {
    authState.isClient = false;
    authState.user = { id: 3, company_id: 7, role: 'accountant', name: 'Staff Accountant', email: 'acct@example.com' };
    capabilityState.manageClientConfiguration = false;

    apiMocks.adminList.mockResolvedValue({
      data: [],
      meta: { current_page: 1, total_pages: 1, total_count: 0, per_page: 250, needs_contact_details_count: 0 },
    });

    renderPage('/companies/7/employees/contact-details?tab=shared-emails');

    await waitFor(() => {
      expect(apiMocks.adminList).toHaveBeenCalled();
    });
    expect(screen.queryByRole('tab', { name: /Shared & placeholder emails/i })).toBeNull();
    expect(apiMocks.sharedEmails).not.toHaveBeenCalled();
  });
});
