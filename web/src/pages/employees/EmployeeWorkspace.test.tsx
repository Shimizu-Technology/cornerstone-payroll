// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Employee } from '@/types';
import { EmployeeWorkspace } from './EmployeeWorkspace';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  employeePayHistory: vi.fn(),
  resolveConfigurationReviewItem: vi.fn(),
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
}));

vi.mock('@/components/employees/EmployeeRetirementElectionPanel', () => ({
  EmployeeRetirementElectionPanel: () => null,
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
});
