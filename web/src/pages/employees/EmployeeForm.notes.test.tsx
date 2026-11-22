// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeForm } from './EmployeeForm';

const mocks = vi.hoisted(() => ({
  getEmployee: vi.fn(),
  listNotes: vi.fn(),
  isClient: false,
  isSuperAdmin: false,
  role: 'accountant',
  capabilities: [] as string[],
}));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({
    user: { company_id: 1, role: mocks.role, capabilities: mocks.capabilities },
    isClient: mocks.isClient,
    isSuperAdmin: mocks.isSuperAdmin,
    hasCapability: (capability: string) => mocks.capabilities.includes(capability),
  }),
}));

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => ({
    refreshCompanies: vi.fn(),
    activeCompanyId: 1,
    activeCompany: { id: 1, pay_frequency: 'biweekly', client_capabilities: ['manage_client_configuration'] },
  }),
}));

vi.mock('@/hooks/useSelectedCompanyCapability', () => ({
  useSelectedCompanyCapability: () => true,
}));

vi.mock('@/hooks/useEmployeeIntakeSettings', () => ({
  useEmployeeIntakeSettings: () => ({ settings: { enabled: false }, loading: false }),
}));

vi.mock('@/components/layout/Header', () => ({ Header: () => null }));
vi.mock('@/components/employees/EmployeePayItemsPanel', () => ({ EmployeePayItemsPanel: () => null }));
vi.mock('@/components/employees/EmployeeDocumentsPanel', () => ({ EmployeeDocumentsPanel: () => null }));
vi.mock('@/components/employees/EmployeeClassificationTransitionDialog', () => ({
  EmployeeClassificationTransitionDialog: () => null,
}));
vi.mock('@/components/employees/EmployeeWorkProfilePanel', () => ({ EmployeeWorkProfilePanel: () => null }));

vi.mock('@/services/employee-notes-api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/employee-notes-api')>();
  return {
    ...actual,
    employeeNotesApi: {
      list: mocks.listNotes,
      create: vi.fn(),
      hide: vi.fn(),
      original: vi.fn(),
    },
  };
});

vi.mock('@/services/api', async (original) => ({
  ...await original<typeof import('@/services/api')>(),
  employeesApi: { get: mocks.getEmployee },
  clientEmployeesApi: { get: mocks.getEmployee },
  departmentsApi: { list: vi.fn().mockResolvedValue({ data: [] }) },
  clientDepartmentsApi: { list: vi.fn().mockResolvedValue({ data: [] }) },
  employeeWageRatesApi: { list: vi.fn().mockResolvedValue({ wage_rates: [] }) },
}));

const employeeRecord = {
  id: 7,
  company_id: 1,
  first_name: 'Avery',
  last_name: 'Example',
  status: 'active' as const,
  employment_type: 'hourly' as const,
  pay_rate: 18,
  hire_date: '2024-01-01',
  wage_rates: [],
  default_custom_earnings: [],
  default_payroll_adjustments: [],
};

describe('EmployeeForm staff notes visibility', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.isClient = false;
    mocks.isSuperAdmin = false;
    mocks.role = 'accountant';
    mocks.capabilities = [];
    mocks.getEmployee.mockResolvedValue({ data: employeeRecord });
    mocks.listNotes.mockResolvedValue({ data: [] });
    HTMLElement.prototype.scrollIntoView = vi.fn();
  });

  afterEach(cleanup);

  it('shows the staff notes panel for staff once the employee loads for the current company', async () => {
    render(
      <MemoryRouter initialEntries={['/companies/1/employees/7/edit']}>
        <Routes>
          <Route path="/companies/:companyId/employees/:id/edit" element={<EmployeeForm />} />
        </Routes>
      </MemoryRouter>,
    );

    await screen.findByDisplayValue('Avery');
    expect(await screen.findByText('Staff only')).toBeTruthy();
    expect(await screen.findByText('No staff notes yet')).toBeTruthy();
    expect(mocks.listNotes).toHaveBeenCalledWith(1, 7);
  });

  it('does not render the staff notes panel or call notes API for client users', async () => {
    mocks.isClient = true;
    mocks.role = 'client';

    render(
      <MemoryRouter initialEntries={['/companies/1/employees/7/edit']}>
        <Routes>
          <Route path="/companies/:companyId/employees/:id/edit" element={<EmployeeForm />} />
        </Routes>
      </MemoryRouter>,
    );

    await screen.findByDisplayValue('Avery');
    expect(screen.queryByText('Staff only')).toBeNull();
    expect(mocks.listNotes).not.toHaveBeenCalled();
  });

  it('does not mount the notes panel when loading the employee fails', async () => {
    mocks.getEmployee.mockRejectedValue(new Error('Employee not found'));

    render(
      <MemoryRouter initialEntries={['/companies/1/employees/7/edit']}>
        <Routes>
          <Route path="/companies/:companyId/employees/:id/edit" element={<EmployeeForm />} />
        </Routes>
      </MemoryRouter>,
    );

    expect(await screen.findByText('Employee not found')).toBeTruthy();
    await waitFor(() => {
      expect(screen.queryByText('Staff only')).toBeNull();
    });
    expect(mocks.listNotes).not.toHaveBeenCalled();
  });
});
