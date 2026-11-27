// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import type { PayrollIntakeDescriptor } from '@/services/api';
import type { PayPeriod } from '@/types';
import { PayPeriodDetail } from '@/pages/PayPeriodDetail';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  employeesList: vi.fn(),
  liabilities: vi.fn(),
  payrollFieldInputs: vi.fn(),
  nonEmployeeChecksList: vi.fn(),
}));

vi.mock('@/services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/api')>();
  return {
    ...actual,
    payPeriodsApi: {
      ...actual.payPeriodsApi,
      get: apiMocks.get,
      liabilities: apiMocks.liabilities,
      payrollFieldInputs: apiMocks.payrollFieldInputs,
    },
    employeesApi: {
      ...actual.employeesApi,
      list: apiMocks.employeesList,
    },
    nonEmployeeChecksApi: {
      ...actual.nonEmployeeChecksApi,
      list: (...args: unknown[]) => apiMocks.nonEmployeeChecksList(...args) ?? Promise.resolve({ non_employee_checks: [] }),
    },
  };
});

vi.mock('@/components/import/ImportModal', () => ({
  ImportModal: ({ open, descriptor, onOpenChange }: { open: boolean; descriptor?: PayrollIntakeDescriptor | null; onOpenChange: (open: boolean) => void }) =>
    open ? (
      <div role="dialog" aria-label="Reviewed-hours import modal" data-descriptor-key={descriptor?.key || ''}>
        <span>Active descriptor: {descriptor?.key}</span>
        <button type="button" onClick={() => onOpenChange(false)}>Close modal</button>
      </div>
    ) : null,
}));

vi.mock('@/components/import/PayrollIntakeImportModal', () => ({ PayrollIntakeImportModal: () => null }));
vi.mock('@/components/payroll/TimeTrackingImportModal', () => ({ TimeTrackingImportModal: () => null }));
vi.mock('@/components/payroll/AirePayrollRecordsDialog', () => ({ AirePayrollRecordsDialog: () => null }));
vi.mock('@/components/checks/UnifiedCheckPrintDialog', () => ({ UnifiedCheckPrintDialog: () => null }));

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const mosaDescriptor: PayrollIntakeDescriptor = {
  key: 'mosa_revel',
  label: 'Revel hours + Cornerstone workbook',
  source_label: 'Revel Payroll + Cornerstone Workbook',
  parser_version: 'mosa_revel:v1',
  extraction: 'deterministic',
  accepts_pasted_text: false,
  tracks_reviewed_hours: true,
  employee_match: 'name_fuzzy',
  idempotency: 'files_period_roster_loans_and_workweek',
  reports_overtime: true,
  tips_default: 'paid_in_check',
  overtime_mode: 'source_reports',
  workweek_alignment: 'warn_if_offset',
  required_sources: ['revel_hours', 'supplemental_workbook'],
  files: [],
  portal: { submittable: true, role_map: {} },
};

const secondReviewedDescriptor: PayrollIntakeDescriptor = {
  ...mosaDescriptor,
  key: 'custom_reviewed_workbook',
  label: 'Custom reviewed workbook',
  source_label: 'Custom Reviewed Workbook',
  parser_version: 'custom_reviewed_workbook:v1',
};

it('passes the selected second reviewed-hours descriptor to ImportModal when multiple reviewed-hours adapters are enabled', async () => {
  const period = {
    id: 12,
    company_id: 7,
    start_date: '2026-09-07',
    end_date: '2026-09-20',
    pay_date: '2026-09-24',
    status: 'draft',
    cycle: 'regular',
    run_purpose: 'regular',
    payroll_items: [],
    payroll_intake_source_types: ['mosa_revel', 'custom_reviewed_workbook'],
    payroll_intake_adapters: [mosaDescriptor, secondReviewedDescriptor],
    time_tracking: { active_source_types: [], linked_aire_records: [] },
  } as unknown as PayPeriod;

  apiMocks.employeesList.mockResolvedValue({ data: [], meta: { total_pages: 1 } });
  apiMocks.liabilities.mockResolvedValue({ payroll_liability_reconciliation: null });
  apiMocks.payrollFieldInputs.mockResolvedValue({ payroll_field_inputs: { fields: [], assignments: [] } });

  render(
    <MemoryRouter initialEntries={['/companies/7/pay-runs/12/work']}>
      <Routes>
        <Route path="/companies/:companyId/pay-runs/:id/:tab" element={<PayPeriodDetail initialPayPeriod={period} activeTab="work" />} />
      </Routes>
    </MemoryRouter>,
  );

  const moreActions = await screen.findByLabelText('More payroll actions');
  fireEvent.click(moreActions);
  fireEvent.click(screen.getByRole('button', { name: 'Import (Custom reviewed workbook)' }));

  const dialog = await screen.findByRole('dialog', { name: 'Reviewed-hours import modal' });
  expect(dialog.getAttribute('data-descriptor-key')).toBe('custom_reviewed_workbook');
  expect(screen.getByText('Active descriptor: custom_reviewed_workbook')).toBeTruthy();

  fireEvent.click(screen.getByRole('button', { name: 'Close modal' }));
  await waitFor(() => expect(screen.queryByRole('dialog', { name: 'Reviewed-hours import modal' })).toBeNull());

  fireEvent.click(moreActions);
  fireEvent.click(screen.getByRole('button', { name: 'Import (MoSa)' }));
  const firstDialog = await screen.findByRole('dialog', { name: 'Reviewed-hours import modal' });
  expect(firstDialog.getAttribute('data-descriptor-key')).toBe('mosa_revel');
});
