// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeContactDetails } from './EmployeeContactDetails';
import { StaffEmployeeContactDetails } from './StaffEmployeeContactDetails';
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
  markPlaceholderEmail: vi.fn(),
  unmarkPlaceholderEmail: vi.fn(),
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
  };
});

vi.mock('@/services/staffContactHygieneApi', () => ({
  staffContactHygieneApi: {
    sharedEmails: apiMocks.sharedEmails,
    markPlaceholderEmail: apiMocks.markPlaceholderEmail,
    unmarkPlaceholderEmail: apiMocks.unmarkPlaceholderEmail,
    clearSharedEmails: apiMocks.clearSharedEmails,
  },
}));

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
    contact_revision: '2026-11-01T00:00:00.000000Z',
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

function renderClientPage(initialEntry = '/companies/7/employees/contact-details') {
  return render(
    <MemoryRouter initialEntries={[initialEntry]}>
      <Routes>
        <Route path="/companies/:companyId/employees/contact-details" element={<EmployeeContactDetails />} />
        <Route path="/companies/:companyId/employees" element={<div>Employees list</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

function renderStaffPage(initialEntry = '/companies/7/employees/contact-details') {
  return render(
    <MemoryRouter initialEntries={[initialEntry]}>
      <Routes>
        <Route path="/companies/:companyId/employees/contact-details" element={<StaffEmployeeContactDetails />} />
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

  it('sends only changed fields with row_revision and baseline_values on a phone-only save, leaving address untouched', async () => {
    const maria = buildEmployee({
      id: 101,
      first_name: 'Maria',
      last_name: 'Cruz',
      email: 'maria@example.com',
      phone: '+16715550100',
      address_line1: '100 Marine Corps Dr',
      city: 'Hagatna',
      state: 'GU',
      zip: '96910',
      contact_revision: '2026-11-24T01:00:00.000000Z',
      contact_details_status: { needs_contact_details: false, missing_fields: [], email_issue: null },
    });

    apiMocks.clientList.mockResolvedValue({
      data: [maria],
      meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, needs_contact_details_count: 0 },
    });

    apiMocks.clientUpdate.mockResolvedValue({
      data: {
        ...maria,
        phone: '+16715550199',
        contact_revision: '2026-11-24T01:05:00.000000Z',
      },
      contact_warnings: [],
    });

    renderClientPage();
    expect((await screen.findAllByText('Maria Cruz')).length).toBeGreaterThan(0);

    // Client grid never shows the staff report tab or calls staff hygiene API.
    expect(screen.queryByRole('tab', { name: /Shared & placeholder emails/i })).toBeNull();
    expect(apiMocks.sharedEmails).not.toHaveBeenCalled();

    fireEvent.change(screen.getByLabelText('Mobile for Maria Cruz'), { target: { value: '555-0199' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save Maria Cruz' }));

    await waitFor(() => {
      expect(apiMocks.clientUpdate).toHaveBeenCalledWith(101, {
        phone: '555-0199',
        row_revision: '2026-11-24T01:00:00.000000Z',
        baseline_values: { phone: '+16715550100' },
      });
    });

    expect((screen.getByLabelText('Mobile for Maria Cruz') as HTMLInputElement).value).toBe('+16715550199');
    expect((screen.getByLabelText('Street address for Maria Cruz') as HTMLInputElement).value).toBe('100 Marine Corps Dr');
  });

  it('handles 409 conflict with clear Keep my changes and Discard my changes options', async () => {
    const maria = buildEmployee({
      id: 101,
      first_name: 'Maria',
      last_name: 'Cruz',
      email: 'old@example.com',
      phone: '+16715550100',
      address_line1: '100 Old St',
      city: 'Hagatna',
      state: 'GU',
      zip: '96910',
      contact_revision: 'rev-1',
    });

    const serverLatest: Employee = {
      ...maria,
      email: 'coworker@example.com',
      address_line1: '200 Coworker St',
      contact_revision: 'rev-2',
    };

    apiMocks.clientList.mockResolvedValue({
      data: [maria],
      meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, needs_contact_details_count: 0 },
    });

    apiMocks.clientUpdate
      .mockRejectedValueOnce(
        new ApiError(
          'This employee was updated by someone else.',
          409,
          undefined,
          {
            error: 'This employee was updated by someone else.',
            code: 'contact_revision_conflict',
            conflicting_fields: ['email'],
            contact_revision: 'rev-2',
            current_values: { email: 'coworker@example.com' },
            data: serverLatest,
          },
        ),
      )
      .mockResolvedValueOnce({
        data: {
          ...serverLatest,
          email: 'my.version@example.com',
          contact_revision: 'rev-3',
        },
        contact_warnings: [],
      });

    renderClientPage();
    expect((await screen.findAllByText('Maria Cruz')).length).toBeGreaterThan(0);

    fireEvent.change(screen.getByLabelText('Email for Maria Cruz'), { target: { value: 'my.version@example.com' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save Maria Cruz' }));

    expect((await screen.findAllByText(/Someone else updated this employee while you were editing/i)).length).toBeGreaterThan(0);
    expect(screen.getAllByText(/Someone else changed this to/i).length).toBeGreaterThan(0);
    expect(screen.getAllByText(/coworker@example\.com/i).length).toBeGreaterThan(0);
    expect(screen.getAllByText(/my\.version@example\.com/i).length).toBeGreaterThan(0);

    // Choose "Keep yours" -> retries with latest revision rev-2 and keeps coworker's address change.
    fireEvent.click(screen.getAllByRole('button', { name: 'Keep yours' })[0]);

    await waitFor(() => {
      expect(apiMocks.clientUpdate).toHaveBeenLastCalledWith(101, {
        email: 'my.version@example.com',
        row_revision: 'rev-2',
        baseline_values: { email: 'coworker@example.com' },
      });
    });

    expect((screen.getByLabelText('Email for Maria Cruz') as HTMLInputElement).value).toBe('my.version@example.com');
    expect((screen.getByLabelText('Street address for Maria Cruz') as HTMLInputElement).value).toBe('200 Coworker St');
  });

  it('supports server-backed pagination that preserves filters, refreshes untouched fields, and keeps pending row edits across pages', async () => {
    const page1EmpInitial = buildEmployee({
      id: 101,
      first_name: 'Alice',
      last_name: 'Adams',
      email: 'alice@example.com',
      phone: '',
      address_line1: '10 First St',
      city: 'Hagatna',
      state: 'GU',
      zip: '96910',
    });
    const page2Emp = buildEmployee({
      id: 201,
      first_name: 'Zoe',
      last_name: 'Zeta',
      email: 'zoe@example.com',
      phone: '',
    });
    const page1EmpRefreshed = {
      ...page1EmpInitial,
      address_line1: '99 Updated By Coworker Rd',
    };

    apiMocks.clientList
      .mockResolvedValueOnce({
        data: [page1EmpInitial],
        meta: { current_page: 1, total_pages: 2, total_count: 60, per_page: 50, needs_contact_details_count: 2 },
      })
      .mockResolvedValueOnce({
        data: [page2Emp],
        meta: { current_page: 2, total_pages: 2, total_count: 60, per_page: 50, needs_contact_details_count: 2 },
      })
      .mockResolvedValueOnce({
        data: [page1EmpRefreshed],
        meta: { current_page: 1, total_pages: 2, total_count: 60, per_page: 50, needs_contact_details_count: 2 },
      });

    renderClientPage('/companies/7/employees/contact-details?needs_contact_details=true');
    expect((await screen.findAllByText('Alice Adams')).length).toBeGreaterThan(0);

    // Edit Alice's phone on page 1 without saving yet.
    fireEvent.change(screen.getByLabelText('Mobile for Alice Adams'), { target: { value: '555-0142' } });

    // Navigate to page 2 -> filter preserved, pending edit count stays visible.
    fireEvent.click(screen.getByRole('button', { name: /Next/i }));
    expect((await screen.findAllByText('Zoe Zeta')).length).toBeGreaterThan(0);
    expect(apiMocks.clientList).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({ page: 2, per_page: 50, needs_contact_details: true }),
    );
    expect(screen.getByText(/1 unsaved row/i)).toBeTruthy();

    // Return to page 1 -> untouched address refreshed from server, edited phone kept!
    fireEvent.click(screen.getByRole('button', { name: /Previous/i }));
    expect((await screen.findAllByText('Alice Adams')).length).toBeGreaterThan(0);
    expect((screen.getByLabelText('Mobile for Alice Adams') as HTMLInputElement).value).toBe('555-0142');
    expect((screen.getByLabelText('Street address for Alice Adams') as HTMLInputElement).value).toBe('99 Updated By Coworker Rd');
  });

  it('keeps the original field baseline and row revision after paging away and back so a coworker edit triggers 409 instead of silent overwrite', async () => {
    const page1Initial = buildEmployee({
      id: 101,
      first_name: 'Alice',
      last_name: 'Adams',
      email: 'alice.old@example.com',
      address_line1: '10 First St',
      contact_revision: 'rev-1',
    });
    const page2Emp = buildEmployee({
      id: 201,
      first_name: 'Zoe',
      last_name: 'Zeta',
      email: 'zoe@example.com',
    });
    const page1AfterCoworker = {
      ...page1Initial,
      email: 'coworker.new@example.com',
      address_line1: '88 Coworker Ave',
      contact_revision: 'rev-2',
    };

    apiMocks.clientList
      .mockResolvedValueOnce({
        data: [page1Initial],
        meta: { current_page: 1, total_pages: 2, total_count: 60, per_page: 50, needs_contact_details_count: 2 },
      })
      .mockResolvedValueOnce({
        data: [page2Emp],
        meta: { current_page: 2, total_pages: 2, total_count: 60, per_page: 50, needs_contact_details_count: 2 },
      })
      .mockResolvedValueOnce({
        data: [page1AfterCoworker],
        meta: { current_page: 1, total_pages: 2, total_count: 60, per_page: 50, needs_contact_details_count: 2 },
      });

    apiMocks.clientUpdate.mockRejectedValueOnce(
      new ApiError('Someone else updated this employee while you were editing.', 409, undefined, {
        error: 'Someone else updated this employee while you were editing.',
        code: 'contact_revision_conflict',
        conflicting_fields: ['email'],
        contact_revision: 'rev-2',
        current_values: { email: 'coworker.new@example.com' },
        data: page1AfterCoworker,
      }),
    );

    renderClientPage();
    expect((await screen.findAllByText('Alice Adams')).length).toBeGreaterThan(0);

    fireEvent.change(screen.getByLabelText('Email for Alice Adams'), { target: { value: 'my.edit@example.com' } });
    fireEvent.click(screen.getByRole('button', { name: /Next/i }));
    expect((await screen.findAllByText('Zoe Zeta')).length).toBeGreaterThan(0);

    fireEvent.click(screen.getByRole('button', { name: /Previous/i }));
    expect((await screen.findAllByText('Alice Adams')).length).toBeGreaterThan(0);
    // Untouched field refreshed, edited field stayed my.edit@example.com.
    expect((screen.getByLabelText('Street address for Alice Adams') as HTMLInputElement).value).toBe('88 Coworker Ave');
    expect((screen.getByLabelText('Email for Alice Adams') as HTMLInputElement).value).toBe('my.edit@example.com');

    // Saving must send original rev-1 and baseline alice.old@example.com, NOT coworker's rev-2!
    fireEvent.click(screen.getByRole('button', { name: 'Save Alice Adams' }));
    await waitFor(() => {
      expect(apiMocks.clientUpdate).toHaveBeenCalledWith(101, {
        email: 'my.edit@example.com',
        row_revision: 'rev-1',
        baseline_values: { email: 'alice.old@example.com' },
      });
    });
    expect((await screen.findAllByText(/coworker\.new@example\.com/i)).length).toBeGreaterThan(0);
    expect(screen.getAllByRole('button', { name: 'Use theirs' }).length).toBeGreaterThan(0);
  });

  it('clamps an out-of-range page URL to the last page with results while keeping filters and pagination visible', async () => {
    const page2Emp = buildEmployee({
      id: 205,
      first_name: 'Zoe',
      last_name: 'Zeta',
      email: '',
    });

    apiMocks.clientList
      .mockResolvedValueOnce({
        data: [],
        meta: { current_page: 5, total_pages: 2, total_count: 60, per_page: 50, needs_contact_details_count: 60 },
      })
      .mockResolvedValueOnce({
        data: [page2Emp],
        meta: { current_page: 2, total_pages: 2, total_count: 60, per_page: 50, needs_contact_details_count: 60 },
      });

    renderClientPage('/companies/7/employees/contact-details?needs_contact_details=true&page=5');

    expect((await screen.findAllByText('Zoe Zeta')).length).toBeGreaterThan(0);
    expect(apiMocks.clientList).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({ page: 2, needs_contact_details: true }),
    );
    expect(screen.getByText(/Page/i)).toBeTruthy();
    expect(screen.getByRole('button', { name: /Previous/i })).toBeTruthy();
    expect(screen.getByRole('button', { name: /Needs contact details/i }).getAttribute('aria-pressed')).toBe('true');
  });

  it('preserves pending drafts across switching to the Shared & placeholder emails tab and back', async () => {
    authState.isClient = false;
    authState.user = { id: 2, company_id: 7, role: 'org_admin', name: 'Cornerstone Admin', email: 'staff@example.com' };
    capabilityState.manageClientConfiguration = true;

    const ana = buildEmployee({
      id: 201,
      first_name: 'Ana',
      last_name: 'Reyes',
      email: 'ana.old@example.com',
      contact_revision: 'rev-10',
    });

    apiMocks.adminList.mockResolvedValue({
      data: [ana],
      meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, needs_contact_details_count: 0 },
    });
    apiMocks.sharedEmails.mockResolvedValue({
      summary: { companies_affected: 0, distinct_flagged_emails: 0, total_employee_records: 0, active_employee_records: 0 },
      can_manage_placeholders: true,
      marked_placeholders: [],
      companies: [],
    });

    renderStaffPage();
    expect((await screen.findAllByText('Ana Reyes')).length).toBeGreaterThan(0);

    fireEvent.change(screen.getByLabelText('Email for Ana Reyes'), { target: { value: 'ana.draft@example.com' } });
    expect(screen.getByText(/1 unsaved row/i)).toBeTruthy();

    fireEvent.click(screen.getByRole('tab', { name: /Shared & placeholder emails/i }));
    expect(await screen.findByText('Shared and placeholder emails')).toBeTruthy();

    fireEvent.click(screen.getByRole('tab', { name: /Contact details/i }));
    expect((await screen.findAllByText('Ana Reyes')).length).toBeGreaterThan(0);
    expect((screen.getByLabelText('Email for Ana Reyes') as HTMLInputElement).value).toBe('ana.draft@example.com');
    expect(screen.getByText(/1 unsaved row/i)).toBeTruthy();
  });

  it('offers inline same-person confirmation when saving an employee login email and retries with confirm_same_person_email', async () => {
    const emma = buildEmployee({ id: 105, first_name: 'Emma', last_name: 'Pleadwell' });

    apiMocks.clientList.mockResolvedValue({
      data: [emma],
      meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, needs_contact_details_count: 1 },
    });

    apiMocks.clientUpdate
      .mockRejectedValueOnce(
        new ApiError(
          'This is your own payroll login email. Confirm "this is me" to assign it to this employee.',
          422,
          { email: ['This is your own payroll login email. Confirm "this is me" to assign it to this employee.'] },
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
        },
        contact_warnings: [],
      });

    renderClientPage();
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

  it('shows the staff-only shared-inbox report with mark-as-placeholder before bulk clear for authorized staff', async () => {
    authState.isClient = false;
    authState.user = { id: 2, company_id: 7, role: 'org_admin', name: 'Cornerstone Admin', email: 'staff@example.com' };
    capabilityState.manageClientConfiguration = true;

    apiMocks.adminList.mockResolvedValue({
      data: [buildEmployee({ id: 201, first_name: 'Ana', last_name: 'Reyes', email: 'shared-inbox@example.com' })],
      meta: { current_page: 1, total_pages: 1, total_count: 1, per_page: 50, needs_contact_details_count: 1 },
    });

    const candidateReport = {
      summary: {
        companies_affected: 1,
        distinct_flagged_emails: 1,
        total_employee_records: 5,
        active_employee_records: 4,
      },
      marked_placeholders: [],
      companies: [
        {
          company_id: 7,
          company_name: "MoSa's Demo",
          total_flagged_records: 5,
          active_flagged_records: 4,
          emails: [
            {
              email: 'shared-inbox@example.com',
              classification: 'shared' as const,
              reasons: ['shared_within_company'],
              total_count: 5,
              active_count: 4,
              inactive_count: 1,
              companies_count: 1,
              organization_total_count: 5,
              clearable: false,
              marked_placeholder: false,
              unmarkable: false,
            },
          ],
        },
      ],
    };

    const markedReport = {
      ...candidateReport,
      marked_placeholders: ['shared-inbox@example.com'],
      companies: [
        {
          ...candidateReport.companies[0],
          emails: [
            {
              ...candidateReport.companies[0].emails[0],
              classification: 'placeholder' as const,
              reasons: ['marked_placeholder', 'shared_within_company'],
              clearable: true,
              marked_placeholder: true,
              unmarkable: true,
            },
          ],
        },
      ],
    };

    const clearedReport = {
      summary: {
        companies_affected: 0,
        distinct_flagged_emails: 0,
        total_employee_records: 0,
        active_employee_records: 0,
      },
      marked_placeholders: ['shared-inbox@example.com'],
      companies: [],
    };

    apiMocks.sharedEmails
      .mockResolvedValueOnce(candidateReport)
      .mockResolvedValueOnce(candidateReport)
      .mockResolvedValueOnce(markedReport)
      .mockResolvedValueOnce(clearedReport);

    apiMocks.markPlaceholderEmail.mockResolvedValue({
      data: { email: 'shared-inbox@example.com', marked: true, changed: true },
      message: 'Marked shared-inbox@example.com as a placeholder email.',
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
      message: "Cleared shared-inbox@example.com from 5 employee records at MoSa's Demo.",
    });

    renderStaffPage();

    const sharedTab = await screen.findByRole('tab', { name: /Shared & placeholder emails/i });
    fireEvent.click(sharedTab);

    expect(await screen.findByText('Shared and placeholder emails')).toBeTruthy();
    // Unmarked candidate shows Mark as placeholder, NOT Clear to blank.
    const markButton = await screen.findByRole('button', { name: /Mark as placeholder/i });
    expect(screen.queryByRole('button', { name: /Clear to blank/i })).toBeNull();
    fireEvent.click(markButton);

    await waitFor(() => {
      expect(apiMocks.markPlaceholderEmail).toHaveBeenCalledWith({ email: 'shared-inbox@example.com' });
    });

    // After marking as placeholder, Clear to blank becomes available.
    const clearButton = await screen.findByRole('button', { name: /Clear to blank/i });
    fireEvent.click(clearButton);

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

    expect(await screen.findByText(/Cleared shared-inbox@example.com from 5 employee records/i)).toBeTruthy();
  });

  it('hides the shared-inbox report tab from staff without manage_client_configuration', async () => {
    authState.isClient = false;
    authState.user = { id: 3, company_id: 7, role: 'accountant', name: 'Staff Accountant', email: 'acct@example.com' };
    capabilityState.manageClientConfiguration = false;

    apiMocks.adminList.mockResolvedValue({
      data: [],
      meta: { current_page: 1, total_pages: 1, total_count: 0, per_page: 50, needs_contact_details_count: 0 },
    });

    renderStaffPage('/companies/7/employees/contact-details?tab=shared-emails');

    await waitFor(() => {
      expect(apiMocks.adminList).toHaveBeenCalled();
    });
    expect(screen.queryByRole('tab', { name: /Shared & placeholder emails/i })).toBeNull();
    expect(apiMocks.sharedEmails).not.toHaveBeenCalled();
  });
});
