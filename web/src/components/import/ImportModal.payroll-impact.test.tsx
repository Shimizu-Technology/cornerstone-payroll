// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import { ImportModal } from './ImportModal';
import type { ImportPreviewResponse } from '@/services/api';

const apply = vi.hoisted(() => vi.fn());
vi.mock('@/services/api', async original => ({
  ...await original<typeof import('@/services/api')>(),
  payrollIntakeImportsApi: { list: vi.fn().mockResolvedValue({ imports: [] }) },
  payPeriodsApi: { applyImport: apply },
}));
afterEach(() => { cleanup(); vi.clearAllMocks(); });

function preview(selected: number | null = 22): ImportPreviewResponse {
  return {
    import_id: 30,
    source_package: { id: 1, package_id: 'synthetic', package_revision: 1, package_schema_version: '1', current: true, verified_source_count: 1, source_count: 1, disposition_targets: [] },
    preview: {
      matched: [{ source_row_id: 10, employee_id: 7, employee_name: 'Alex Example', employment_type: 'hourly', pay_rate: 15.5, confidence: 1, matched_name: 'Alex Example', regular_hours: 0, overtime_hours: 0, total_hours: 0, pdf_employee_name: null, total_tips: 0, tip_pool: null, loan_deduction: 89,
        workbook_only: true, missing_revel_hours_with_deductions: true,
        wage_rate_options: [{ id: 21, label: 'Main Kitchen', rate: 15.5 }, { id: 22, label: 'Shared Kitchen', rate: 16.5 }],
        selected_wage_rate_id: selected, wage_rate_default_source: selected ? 'Last committed payroll, paid 2026-10-22' : 'Choose a job and rate — the last committed payroll does not identify one active job.',
      }],
      source_rows: [{ id: 10, position: 0, row_kind: 'matched', employee_id: 7, source_employee_name: 'Alex Example', disposition: 'pending', errors: [], warnings: [] }],
      unmatched_pdf_names: [], unmatched_excel_names: [], duplicate_employee_matches: [], low_confidence_matches: [], pdf_count: 0, excel_count: 1, matched_count: 1, can_apply: true, tips_paid_out_from_tips: false,
    },
  };
}

function mount(data = preview()): void {
  render(<MemoryRouter><ImportModal open payPeriodId={9} companyId={7} initialPreview={data} onOpenChange={vi.fn()} onImportComplete={vi.fn()} /></MemoryRouter>);
}

it('shows missing-hours instructions and the committed default in both responsive layouts', async () => {
  mount();
  expect(screen.getAllByText(/No Revel hours — enter hours from MoSa's email before calculating/)).toHaveLength(2);
  expect(screen.getAllByText('Last committed payroll, paid 2026-10-22')).toHaveLength(2);
  screen.getAllByRole('combobox', { name: 'Job and rate for Alex Example' }).forEach(select => expect((select as HTMLSelectElement).value).toBe('22'));
});

it('blocks apply until a missing choice is supplied and submits only the selected saved job ID', async () => {
  apply.mockResolvedValue({ results: { success: [{ employee_id: 7 }], errors: [] }, pay_period: { id: 9 } });
  mount(preview(null));
  expect(screen.getByRole('alert').textContent).toContain('Choose a job and rate for Alex Example');
  const button = screen.getByRole('button', { name: /Apply Import/ });
  expect((button as HTMLButtonElement).disabled).toBe(true);
  fireEvent.change(screen.getAllByRole('combobox', { name: 'Job and rate for Alex Example' })[0], { target: { value: '21' } });
  expect((button as HTMLButtonElement).disabled).toBe(false);
  fireEvent.click(button);
  await waitFor(() => expect(apply).toHaveBeenCalledWith(9, expect.objectContaining({ wage_rate_choices: { '7': 21 } })));
});

it('keeps a changed rate selection through an apply error and retry', async () => {
  apply.mockRejectedValueOnce(new Error('Preview again if rates changed.'));
  mount();
  fireEvent.change(screen.getAllByRole('combobox', { name: 'Job and rate for Alex Example' })[0], { target: { value: '21' } });
  fireEvent.click(screen.getByRole('button', { name: /Apply Import/ }));
  await screen.findByText('Preview again if rates changed.');
  expect((screen.getAllByRole('combobox', { name: 'Job and rate for Alex Example' })[0] as HTMLSelectElement).value).toBe('21');
});

it.each(['unmatched_revel', 'unmatched_workbook'])('links an unmatched non-active %s worker to their profile without including pay', rowKind => {
  const data = preview();
  data.preview.matched = [];
  data.preview.source_rows = [{ id: 11, position: 0, row_kind: rowKind, employee_id: null, source_employee_name: 'Example, Avery', disposition: 'pending', warnings: [], errors: [{ code: 'unmatched_employee', severity: 'error', employee_id: 139, message: 'Avery Example is inactive in Cornerstone.' }] }];
  data.preview.can_apply = false;
  mount(data);
  const link = screen.getByRole('link', { name: /Open profile for Example, Avery/ });
  expect(link.getAttribute('href')).toBe('/companies/7/employees/139/edit');
  expect(link.getAttribute('target')).toBe('_blank');
  expect((screen.getByRole('button', { name: /Apply Import/ }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.queryByRole('option', { name: /Include in pay/ })).toBeNull();
});
it('does not show a profile link for a source row with no identified worker', () => {
  const data = preview();
  data.preview.matched = [];
  data.preview.source_rows = [{ id: 11, position: 0, row_kind: 'unmatched_revel', employee_id: null, source_employee_name: 'Unknown', disposition: 'pending', warnings: [], errors: [{ code: 'unmatched_employee', severity: 'error', message: 'Match this Revel hours row to a Cornerstone employee.' }] }];
  mount(data);
  expect(screen.queryByRole('link', { name: /Open profile/ })).toBeNull();
});
