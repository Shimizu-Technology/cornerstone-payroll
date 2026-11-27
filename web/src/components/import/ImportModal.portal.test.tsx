// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { ImportModal } from './ImportModal';
import { ApiError } from '@/services/api';
import type { ImportPreviewResponse } from '@/services/api';

const mocks = vi.hoisted(() => ({ apply: vi.fn(), preview: vi.fn(), upload: vi.fn() }));
vi.mock('@/services/api', async original => ({
  ...await original<typeof import('@/services/api')>(),
  payPeriodsApi: { applyImport: mocks.apply, previewImport: mocks.upload, previewPortalSubmission: mocks.preview },
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
  const notices = screen.getByRole('region', { name: 'For your information' });
  expect(within(notices).getByRole('heading', { name: 'For your information (1)' })).toBeTruthy();
  expect(within(notices).getByText('The tips & loans workbook isn’t included')).toBeTruthy();
  expect(within(notices).getByText("No tips or loans: the workbook wasn't included")).toBeTruthy();
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

it('offers an explicit pending-revision retry after refusing duplicate files', async () => {
  mocks.upload.mockRejectedValueOnce(new ApiError('These files were already applied.', 422, { pending_submission_id: 20, pending_revision: 2 }));
  mocks.upload.mockResolvedValueOnce({
    import_id: 31,
    pending_portal_source: { submission_id: 20, revision: 2, period_id: 90, no_changes: true, changes: [] },
    source_package: { id: 2, package_id: 'replacement', package_revision: 2, package_schema_version: '1', current: true, verified_source_count: 1, source_count: 1, disposition_targets: [] },
    preview: { matched: [], unmatched_pdf_names: [], unmatched_excel_names: [], duplicate_employee_matches: [], low_confidence_matches: [], pdf_count: 0, excel_count: 0, matched_count: 0, can_apply: true, tips_paid_out_from_tips: false, source_rows: [] },
  });
  render(<MemoryRouter><ImportModal open payPeriodId={9} companyId={7} onOpenChange={vi.fn()} onImportComplete={vi.fn()} /></MemoryRouter>);
  const file = new File(['same bytes'], 'revel.pdf', { type: 'application/pdf' });
  fireEvent.change(document.querySelector('input[type="file"][accept=".pdf"]')!, { target: { files: [file] } });
  fireEvent.click(screen.getByRole('button', { name: 'Preview Import' }));
  const retry = await screen.findByRole('button', { name: 'Use this import for the client’s revision 2' });
  expect(screen.queryByRole('alert')).toBeNull();
  expect(screen.getByText('These files were already applied. Review them with the changes from the pending client revision.')).toBeTruthy();
  fireEvent.click(retry);
  await waitFor(() => expect(mocks.upload).toHaveBeenLastCalledWith(9, file, undefined, false, undefined, 20, 'mosa_revel'));
  expect(await screen.findByLabelText('Use this import for the client’s revision 2')).toHaveProperty('checked', true);
});

it('puts the retained source files beside the review only when there are files to show', () => {
  const base: ImportPreviewResponse = {
    import_id: 31,
    source_package: { id: 5, package_id: 'synthetic', package_revision: 1, package_schema_version: '1', current: true, verified_source_count: 1, source_count: 1, disposition_targets: [] },
    portal_source: { selection_id: 1, submission_id: 20, revision: 2, period_id: 90, current: true, no_changes: true, changes: [] },
    preview: { matched: [], unmatched_pdf_names: [], unmatched_excel_names: [], duplicate_employee_matches: [], low_confidence_matches: [], pdf_count: 0, excel_count: 0, matched_count: 0, can_apply: false, tips_paid_out_from_tips: false, source_rows: [] },
  };
  const withPdf = { ...base, source_package: { ...base.source_package, documents: [{ id: 3, source_role: 'revel_hours', filename: 'revel.pdf', content_type: 'application/pdf', byte_size: 9 }] } };
  const view = (preview: ImportPreviewResponse) => <MemoryRouter><ImportModal open payPeriodId={9} companyId={7} initialPreview={preview} onOpenChange={vi.fn()} onImportComplete={vi.fn()} /></MemoryRouter>;

  const rendered = render(view(withPdf));
  expect(screen.getByRole('complementary', { name: 'Source files' })).toBeTruthy();
  expect(screen.getByRole('button', { name: /Show source files \(Revel PDF\)/ })).toBeTruthy();
  expect(screen.getByRole('dialog').className).toContain('dialog-full');
  expect(screen.getByRole('button', { name: /Apply Import/ })).toBeTruthy();

  rendered.unmount();
  render(view(base));
  expect(screen.queryByRole('complementary', { name: 'Source files' })).toBeNull();
  expect(screen.getByRole('dialog').className).toContain('dialog-wide');
});
