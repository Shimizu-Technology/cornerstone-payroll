// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { ImportModal } from './ImportModal';
import type { ImportPreviewResponse } from '@/services/api';

const mocks = vi.hoisted(() => ({ apply: vi.fn(), preview: vi.fn() }));
vi.mock('@/services/api', async original => ({
  ...await original<typeof import('@/services/api')>(),
  payPeriodsApi: { applyImport: mocks.apply, previewPortalSubmission: mocks.preview },
  payrollIntakeImportsApi: { list: vi.fn().mockResolvedValue({ imports: [] }) },
}));
beforeEach(() => { vi.clearAllMocks(); });
afterEach(cleanup);

it('keeps retained evidence in the import company even from an unscoped route', async () => {
  const preview: ImportPreviewResponse = {
    import_id: 30,
    source_package: { id: 1, package_id: 'synthetic', package_revision: 1, package_schema_version: '1', current: true, verified_source_count: 1, source_count: 1, disposition_targets: [] },
    portal_source: { selection_id: 1, submission_id: 20, revision: 2, period_id: 90, current: true, no_changes: true, changes: [] },
    preview: { matched: [], unmatched_pdf_names: [], unmatched_excel_names: [], duplicate_employee_matches: [], low_confidence_matches: [], pdf_count: 0, excel_count: 0, matched_count: 0, can_apply: false, tips_paid_out_from_tips: false, source_rows: [] },
  };
  render(<MemoryRouter initialEntries={['/settings/payroll-submissions/90']}>
    <ImportModal open payPeriodId={9} companyId={7} initialPreview={preview} onOpenChange={vi.fn()} onImportComplete={vi.fn()} />
  </MemoryRouter>);
  expect((await screen.findByRole('link', { name: 'Open retained portal submission' })).getAttribute('href')).toBe('/companies/7/payroll-submissions/90');
});


it('requires a deliberate pending revision selection and sends it with apply', async () => {
  const preview: ImportPreviewResponse = {
    import_id: 30,
    pending_portal_source: { submission_id: 20, revision: 2, period_id: 90, no_changes: false, workbook_choice: 'link', changes_link_url: 'https://example.test/tips', notes: 'Please check all three changes', changes: [
      { kind: 'owner_pay', label: 'Owner pay', amount: '1200', basis: 'each', note: 'Both owners' },
      { kind: 'new_hire', label: 'New hire', name: 'New Colleague', starting_wage: '12', wage_unit: 'hourly' },
      { kind: 'extra_hours', label: 'Extra hours', employee_name: 'Avery', hours: '6' },
    ] },
    source_package: { id: 1, package_id: 'synthetic', package_revision: 1, package_schema_version: '1', current: true, verified_source_count: 1, source_count: 1, disposition_targets: [] },
    preview: { matched: [], unmatched_pdf_names: [], unmatched_excel_names: [], duplicate_employee_matches: [], low_confidence_matches: [], pdf_count: 0, excel_count: 0, matched_count: 0, can_apply: true, tips_paid_out_from_tips: false, source_rows: [{ id: 1, position: 1, source_employee_name: 'Avery', employee_id: 1, row_kind: 'matched', disposition: 'included', errors: [], warnings: [] }], source_warnings: [ { code: 'missing_workbook', severity: 'warning', message: "No tips or loans: the workbook wasn't included" } ] },
  };
  mocks.apply.mockResolvedValue({ results: { success: [], errors: [] }, pay_period: {} });
  render(<MemoryRouter><ImportModal open payPeriodId={9} companyId={7} initialPreview={preview} onOpenChange={vi.fn()} onImportComplete={vi.fn()} /></MemoryRouter>);
  const choice = screen.getByLabelText('Use this import for the client’s revision 2');
  expect(choice).toHaveProperty('checked', false);
  expect(screen.getByRole('alert').textContent).toContain("No tips or loans: the workbook wasn't included");
  expect(screen.getByText(/Both owners/)).toBeTruthy();
  expect(screen.getByText(/New Colleague/)).toBeTruthy();
  expect(screen.getByText(/Avery · 6/)).toBeTruthy();
  expect(screen.getByText('Please check all three changes')).toBeTruthy();
  expect(screen.getByText('Workbook choice: Link sent')).toBeTruthy();
  expect(screen.getByRole('link', { name: 'Open retained portal submission' }).getAttribute('href')).toBe('/companies/7/payroll-submissions/90');
  expect(screen.getByRole('link', { name: 'Client’s tips & loans workbook link' }).getAttribute('href')).toBe('https://example.test/tips');
  fireEvent.click(choice);
  fireEvent.click(screen.getByRole('button', { name: /Apply/ }));
  await waitFor(() => expect(mocks.apply).toHaveBeenCalledWith(9, expect.objectContaining({ use_submission_id: 20 })));
});

it.each(['resolve', 'reject'] as const)('locks Apply and Back until workbook attachment settles (%s)', async outcome => {
  const preview: ImportPreviewResponse = {
    import_id: 30,
    source_package: { id: 1, package_id: 'synthetic', package_revision: 1, package_schema_version: '1', current: true, verified_source_count: 1, source_count: 1, disposition_targets: [] },
    portal_source: { selection_id: 1, submission_id: 20, revision: 2, period_id: 90, current: true, no_changes: true, changes: [], changes_link_url: 'https://example.test/workbook' },
    preview: { matched: [], unmatched_pdf_names: [], unmatched_excel_names: [], duplicate_employee_matches: [], low_confidence_matches: [], pdf_count: 0, excel_count: 0, matched_count: 0, can_apply: true, tips_paid_out_from_tips: false, source_rows: [{ id: 1, position: 1, source_employee_name: 'Avery', employee_id: 1, row_kind: 'matched', disposition: 'included', errors: [], warnings: [] }], source_warnings: [{ code: 'missing_workbook', severity: 'warning', message: 'Workbook missing' }] },
  };
  let resolve!: (value: ImportPreviewResponse) => void;
  let reject!: (reason: Error) => void;
  mocks.preview.mockReturnValue(new Promise<ImportPreviewResponse>((yes, no) => { resolve = yes; reject = no; }));
  render(<MemoryRouter><ImportModal open payPeriodId={9} companyId={7} initialPreview={preview} onOpenChange={vi.fn()} onImportComplete={vi.fn()} /></MemoryRouter>);
  fireEvent.change(screen.getByLabelText('Downloaded workbook (Excel)'), { target: { files: [new File(['bytes'], 'tips.xlsx')] } });
  fireEvent.click(screen.getByRole('button', { name: 'Attach workbook and refresh review' }));
  const apply = screen.getByRole('button', { name: /Apply Import/ });
  const back = screen.getByRole('button', { name: 'Back' });
  expect(apply).toHaveProperty('disabled', true);
  expect(back).toHaveProperty('disabled', true);
  fireEvent.click(apply); fireEvent.click(back);
  expect(mocks.apply).not.toHaveBeenCalled();
  if (outcome === 'resolve') resolve({ ...preview, import_id: 31 });
  else reject(new Error('Attachment failed'));
  await waitFor(() => expect(apply).toHaveProperty('disabled', false));
  expect(back).toHaveProperty('disabled', false);
});
