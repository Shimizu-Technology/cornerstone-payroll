// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { PayrollIntakeImportModal } from './PayrollIntakeImportModal';
import type { PayrollIntakeDescriptor } from '@/services/api';
import type { Employee } from '@/types';

const apiMocks = vi.hoisted(() => ({
  list: vi.fn(),
  downloadTemplate: vi.fn(),
  preview: vi.fn(),
  apply: vi.fn(),
}));

vi.mock('@/services/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/services/api')>();
  return {
    ...actual,
    payrollIntakeImportsApi: {
      ...actual.payrollIntakeImportsApi,
      list: apiMocks.list,
      downloadTemplate: apiMocks.downloadTemplate,
      preview: apiMocks.preview,
      apply: apiMocks.apply,
    },
  };
});

const universalDescriptor: PayrollIntakeDescriptor = {
  key: 'cornerstone_workbook',
  label: 'Cornerstone workbook',
  source_label: 'Cornerstone universal workbook',
  parser_version: 'cornerstone_workbook:v1',
  extraction: 'deterministic',
  accepts_pasted_text: false,
  tracks_reviewed_hours: false,
  employee_match: 'employee_id',
  idempotency: 'files_and_workweek',
  reports_overtime: true,
  tips_default: 'paid_in_check',
  overtime_mode: 'weekly_split',
  workweek_alignment: 'aligned',
  required_sources: ['cornerstone_workbook'],
  files: [
    {
      role: 'cornerstone_workbook',
      label: 'Cornerstone workbook (.xlsx or .csv)',
      hint: 'Upload the completed Excel or CSV workbook.',
      accept: ['.xlsx', '.csv'],
      content_type: null,
      max: 1,
      required: true,
      required_by_default: true,
      waivable: null,
      portal_role: 'payroll_workbook',
      portal_label: 'Cornerstone payroll workbook',
      portal_hint: 'Upload the completed Excel or CSV workbook.',
      supports_link: false,
      template_formats: ['xlsx', 'csv'],
      provides: ['regular_hours', 'overtime_hours', 'pto_hours', 'holiday_hours', 'reported_tips', 'bonus', 'loan_deduction'],
    },
  ],
  portal: { submittable: true, role_map: { payroll_workbook: 'cornerstone_workbook' } },
};

const employees: Employee[] = [
  {
    id: 101,
    company_id: 7,
    first_name: 'Employee',
    last_name: '01',
    employment_type: 'hourly',
    pay_rate: 20,
    pay_frequency: 'biweekly',
    status: 'active',
  } as Employee,
];

beforeEach(() => {
  vi.clearAllMocks();
  apiMocks.list.mockResolvedValue({ imports: [], disposition_targets: [] });
  apiMocks.downloadTemplate.mockImplementation((_payPeriodId: number, format: 'xlsx' | 'csv') => Promise.resolve({
    blob: new Blob([`template-${format}`]),
    filename: `fixture-co-cornerstone-workbook-2026-06-27.${format}`,
  }));
  vi.stubGlobal('URL', {
    ...URL,
    createObjectURL: vi.fn(() => 'blob:template-url'),
    revokeObjectURL: vi.fn(),
  });
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

it('shows Excel and CSV template download buttons, hides pasted text, and previews + applies universal workbook rows', async () => {
  const onImportComplete = vi.fn();
  apiMocks.preview.mockResolvedValue({
    import: {
      id: 55,
      company_id: 7,
      pay_period_id: 12,
      package_id: 'pkg-12345678',
      package_revision: 1,
      package_schema_version: 'v1',
      source_type: 'cornerstone_workbook',
      status: 'previewed',
      current: true,
      documents: [{ id: 1, verification_status: 'verified', filename: 'filled.csv' }],
      warnings: [],
      rows: [
        {
          id: 901,
          source_employee_name: 'Employee 01',
          employee_id: 101,
          disposition: 'included',
          disposition_reason: null,
          target_pay_period_id: null,
          week1_hours: 42,
          week2_hours: 40,
          regular_hours: 80,
          overtime_hours: 2,
          pto_hours: 4,
          holiday_hours: 8,
          week1_tips: 0,
          week2_tips: 0,
          reported_tips: 50,
          tips_paid_out: 0,
          bonus: 100,
          loan_deduction: 25,
          payroll_components: [{ kind: 'earning', label: 'Mileage', amount: 30 }],
          errors: [],
          warnings: [],
        },
      ],
    },
    disposition_targets: [],
  });
  apiMocks.apply.mockResolvedValue({
    import: { id: 55, status: 'applied', rows: [], documents: [], warnings: [], package_id: 'pkg-12345678', package_revision: 1, package_schema_version: 'v1', company_id: 7, pay_period_id: 12, source_type: 'cornerstone_workbook', current: true },
    pay_period: { id: 12, payroll_items: [] },
    results: { applied: [{ row_id: 901 }], skipped: [], errors: [] },
  });

  render(
    <PayrollIntakeImportModal
      open
      onOpenChange={vi.fn()}
      payPeriodId={12}
      descriptor={universalDescriptor}
      employees={employees}
      onImportComplete={onImportComplete}
    />,
  );

  expect(screen.getByText('Cornerstone Workbook Intake')).toBeTruthy();
  expect(screen.queryByLabelText('Paste email body or copied table')).toBeNull();

  const clickedDownloads: string[] = [];
  const clickSpy = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (this: HTMLAnchorElement) {
    clickedDownloads.push(this.download);
  });

  fireEvent.click(screen.getByRole('button', { name: 'Download Excel template (.xlsx)' }));
  await waitFor(() => expect(apiMocks.downloadTemplate).toHaveBeenCalledWith(12, 'xlsx', 'cornerstone_workbook'));
  await waitFor(() => expect(clickedDownloads).toContain('fixture-co-cornerstone-workbook-2026-06-27.xlsx'));

  fireEvent.click(screen.getByRole('button', { name: 'Download CSV template (.csv)' }));
  await waitFor(() => expect(apiMocks.downloadTemplate).toHaveBeenCalledWith(12, 'csv', 'cornerstone_workbook'));
  await waitFor(() => expect(clickedDownloads).toEqual([
    'fixture-co-cornerstone-workbook-2026-06-27.xlsx',
    'fixture-co-cornerstone-workbook-2026-06-27.csv',
  ]));
  clickSpy.mockRestore();

  const fileInput = document.querySelector('input[type="file"]') as HTMLInputElement;
  expect(fileInput.accept).toBe('.xlsx,.csv');
  fireEvent.change(fileInput, { target: { files: [new File(['csv'], 'filled.csv', { type: 'text/csv' })] } });

  fireEvent.click(screen.getByRole('button', { name: 'Preview Intake' }));
  await screen.findByText('Reported Tips');
  expect(screen.getByText('Paid-Out Tips')).toBeTruthy();
  expect(screen.getAllByText('Reported tips').length).toBe(2);
  expect(screen.getAllByText('Paid-out tips').length).toBe(2);
  expect((screen.getByLabelText('Reported tips') as HTMLInputElement).value).toBe('50.00');
  expect((screen.getByLabelText('Paid-out tips') as HTMLInputElement).value).toBe('0.00');
  // Summary distinguishes $50.00 reported tips from $0.00 paid-out tips
  expect(screen.getAllByText('$50.00').length).toBeGreaterThanOrEqual(1);
  expect(screen.getAllByText('$0.00').length).toBeGreaterThanOrEqual(1);
  // Desktop table and mobile card both display extended workbook fields
  expect(screen.getAllByText('PTO').length).toBe(2);
  expect(screen.getAllByText('Holiday').length).toBe(2);
  expect(screen.getAllByText('Bonus').length).toBe(2);
  expect(screen.getAllByText('One-Time').length).toBe(2);
  expect(screen.getAllByText('Loan').length).toBe(2);
  expect(screen.getAllByText('Mileage: $30.00').length).toBe(2);
  expect(screen.getByText('4.00 hrs')).toBeTruthy();
  expect(screen.getByText('8.00 hrs')).toBeTruthy();
  expect(screen.getAllByText('$100.00').length).toBe(2);
  expect(screen.getAllByText('$25.00').length).toBe(2);

  fireEvent.click(screen.getByRole('button', { name: 'Apply Reviewed Rows' }));
  await waitFor(() => expect(apiMocks.apply).toHaveBeenCalledOnce());
  expect(apiMocks.apply.mock.calls[0][2].rows[0]).toMatchObject({
    id: 901,
    employee_id: 101,
    regular_hours: 80,
    overtime_hours: 2,
    pto_hours: 4,
    holiday_hours: 8,
    bonus: 100,
    loan_deduction: 25,
  });
  expect(onImportComplete).toHaveBeenCalledOnce();
});

it('replaces single-file uploads on drag-and-drop, defers paid-out tip clamping until blur, and preserves source-reported hours', async () => {
  const sourceReportedDescriptor: PayrollIntakeDescriptor = {
    ...universalDescriptor,
    overtime_mode: 'source_reports',
  };
  apiMocks.preview.mockResolvedValue({
    import: {
      id: 56,
      company_id: 7,
      pay_period_id: 12,
      package_id: 'pkg-87654321',
      package_revision: 1,
      package_schema_version: 'v1',
      source_type: 'cornerstone_workbook',
      status: 'previewed',
      current: true,
      documents: [{ id: 2, verification_status: 'verified', filename: 'second.csv' }],
      warnings: [],
      rows: [
        {
          id: 902,
          source_employee_name: 'Employee 01',
          employee_id: 101,
          disposition: 'included',
          disposition_reason: null,
          target_pay_period_id: null,
          week1_hours: 0,
          week2_hours: 0,
          regular_hours: 152,
          overtime_hours: 8,
          pto_hours: 0,
          holiday_hours: 0,
          week1_tips: 0,
          week2_tips: 0,
          reported_tips: 50,
          tips_paid_out: 50,
          bonus: 0,
          loan_deduction: 0,
          payroll_components: [],
          errors: [],
          warnings: [],
        },
      ],
    },
    disposition_targets: [],
  });

  render(
    <PayrollIntakeImportModal
      open
      onOpenChange={vi.fn()}
      payPeriodId={12}
      descriptor={sourceReportedDescriptor}
      employees={employees}
      onImportComplete={vi.fn()}
    />,
  );

  // Single-file slot replaces previous file on both file input and drag-and-drop
  const fileInput = document.querySelector('input[type="file"]') as HTMLInputElement;
  fireEvent.change(fileInput, { target: { files: [new File(['first'], 'first.csv', { type: 'text/csv' })] } });
  expect(screen.getByText('first.csv')).toBeTruthy();

  const dropZone = screen.getByText(/Upload Cornerstone workbook/i).closest('div') as HTMLElement;
  fireEvent.drop(dropZone, {
    dataTransfer: { files: [new File(['second'], 'second.csv', { type: 'text/csv' })] },
  });
  expect(screen.queryByText('first.csv')).toBeNull();
  expect(screen.getByText('second.csv')).toBeTruthy();

  fireEvent.click(screen.getByRole('button', { name: 'Preview Intake' }));
  await screen.findByText('Reported Tips');

  // Typing "4" then "40" into Reported tips must not prematurely clamp Paid-out tips to 4
  const reportedInput = screen.getByLabelText('Reported tips') as HTMLInputElement;
  const paidOutInput = screen.getByLabelText('Paid-out tips') as HTMLInputElement;
  expect(reportedInput.value).toBe('50.00');
  expect(paidOutInput.value).toBe('50.00');

  fireEvent.focus(reportedInput);
  fireEvent.change(reportedInput, { target: { value: '4' } });
  expect(paidOutInput.value).toBe('50.00');
  fireEvent.change(reportedInput, { target: { value: '40' } });
  fireEvent.blur(reportedInput);

  expect(reportedInput.value).toBe('40.00');
  expect(paidOutInput.value).toBe('40.00');

  // Editing Week 1 hours in source_reports mode must not overwrite regular/overtime hours
  const week1Input = screen.getByLabelText('Week 1 hours') as HTMLInputElement;
  fireEvent.focus(week1Input);
  fireEvent.change(week1Input, { target: { value: '45' } });
  fireEvent.blur(week1Input);
  expect(screen.getByText('152.00 regular · 8.00 OT')).toBeTruthy();
});
