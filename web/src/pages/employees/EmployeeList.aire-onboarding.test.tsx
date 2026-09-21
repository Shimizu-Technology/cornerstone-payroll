// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes, useLocation } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeList } from './EmployeeList';

const apiMocks = vi.hoisted(() => ({
  listEmployees: vi.fn(),
  listDepartments: vi.fn(),
  aireCandidates: vi.fn(),
  linkAireCandidate: vi.fn(),
}));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ user: { company_id: 1, role: 'admin' }, isClient: false, isManager: true, isSuperAdmin: false }),
}));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 1 }) }));
vi.mock('@/services/api', () => ({
  employeesApi: {
    list: apiMocks.listEmployees,
    aireCandidates: apiMocks.aireCandidates,
    linkAireCandidate: apiMocks.linkAireCandidate,
  },
  departmentsApi: { list: apiMocks.listDepartments },
}));
vi.mock('@/components/employees/EmployeeBulkImportModal', () => ({ EmployeeBulkImportModal: () => null }));

function LocationLabel() {
  const location = useLocation();
  return <p>Onboarding route: {location.pathname}{location.search}</p>;
}

function renderList() {
  render(
    <MemoryRouter initialEntries={['/companies/1/employees']}>
      <Routes>
        <Route path="/companies/:companyId/employees" element={<EmployeeList />} />
        <Route path="/companies/:companyId/employees/new" element={<LocationLabel />} />
        <Route path="/companies/:companyId/employees/:id/overview" element={<LocationLabel />} />
      </Routes>
    </MemoryRouter>,
  );
}

describe('EmployeeList AIRE onboarding', () => {
  beforeEach(() => {
    apiMocks.listDepartments.mockResolvedValue({ data: [] });
    apiMocks.listEmployees.mockResolvedValue({
      data: [], meta: { current_page: 1, total_pages: 1, total_count: 0, per_page: 500 },
    });
  });
  afterEach(() => { cleanup(); vi.clearAllMocks(); });

  it('shows an unlinked AIRE person and opens setup without requiring a pay period', async () => {
    apiMocks.aireCandidates.mockResolvedValue({
      connected: true,
      employees: [{
        id: '91', payroll_integration_id: 'uuid-91', first_name: 'New', last_name: 'Associate',
        full_name: 'New Associate', active: true, time_tracking_enabled: true,
        cornerstone: { status: 'unmapped' }, possible_payroll_matches: [],
      }],
      pagination: { current_page: 1, per_page: 100, total_count: 1, total_pages: 1, truncated: false },
    });

    renderList();

    expect(await screen.findByText('New Associate')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Set up payroll profile' }));
    expect(await screen.findByText(/Onboarding route:.*aire_staff_id=91/)).toBeTruthy();
  });

  it('requires explicit verification before linking a possible terminated profile', async () => {
    apiMocks.aireCandidates.mockResolvedValue({
      connected: true,
      employees: [{
        id: '77', payroll_integration_id: 'uuid-77', first_name: 'Rei', last_name: 'Example',
        full_name: 'Rei Example', active: true, time_tracking_enabled: true,
        cornerstone: { status: 'unmapped' },
        possible_payroll_matches: [{ id: 12, name: 'Rei Example', status: 'terminated' }],
      }],
      pagination: { current_page: 1, per_page: 100, total_count: 1, total_pages: 1, truncated: false },
    });
    apiMocks.linkAireCandidate.mockResolvedValue({ mapping: { employee_id: 12 } });

    renderList();

    expect(await screen.findByText(/Possible existing payroll profile: Rei Example \(terminated\)/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Set up payroll profile' })).toBeNull();
    expect(apiMocks.linkAireCandidate).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Verify link' }));
    expect(apiMocks.linkAireCandidate).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'I verified — link' }));
    await waitFor(() => expect(apiMocks.linkAireCandidate).toHaveBeenCalledWith('77', 12));
  });
});
