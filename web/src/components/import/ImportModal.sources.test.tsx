// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { ImportModal } from './ImportModal';
import { payrollIntakeImportsApi } from '@/services/api';
import type { ImportPackageSource, ImportPreviewResponse, ImportPreviewRow, MosaSourceRow, PayrollIntakeImportData } from '@/services/api';

const mocks = vi.hoisted(() => ({ previewImport: vi.fn(), applyImport: vi.fn(), currentImport: vi.fn() }));
vi.mock('@/services/api', async original => ({
  ...await original<typeof import('@/services/api')>(),
  payrollIntakeImportsApi: { list: vi.fn().mockResolvedValue({ imports: [] }) },
  payPeriodsApi: { previewImport: mocks.previewImport, applyImport: mocks.applyImport, currentImport: mocks.currentImport },
}));

const pdfSource: ImportPackageSource = { role: 'revel_hours', label: 'Revel hours PDF', required: true, present: true, filename: 'revel.pdf' };
const workbookMissing: ImportPackageSource = { role: 'supplemental_workbook', label: 'Tips & loans workbook', required: true, present: false, waiver_label: 'No tips or loans this period' };
const workbookPresent: ImportPackageSource = { ...workbookMissing, present: true, filename: 'changes.xlsx' };

function row(overrides: Partial<ImportPreviewRow>): ImportPreviewRow {
  return {
    source_row_id: 1, employee_id: 1, employee_name: 'Avery Server', employment_type: 'hourly', pay_rate: 10, confidence: 1,
    matched_name: 'Avery Server', regular_hours: 40, overtime_hours: 0, total_hours: 40, pdf_employee_name: 'Server, Avery',
    total_tips: 0, tip_pool: null, loan_deduction: 0, ...overrides,
  };
}
const sourceRow = (id: number, name: string, employeeId: number): MosaSourceRow => ({
  id, position: id, source_employee_name: name, employee_id: employeeId, row_kind: 'matched', disposition: 'pending', errors: [], warnings: [],
});

function preview(sources: ImportPackageSource[], options: { rows?: ImportPreviewRow[]; revision?: number; firstRowId?: number } = {}): ImportPreviewResponse {
  const firstId = options.firstRowId ?? 1;
  const matched = options.rows || [row({ source_row_id: firstId }), row({ source_row_id: firstId + 1, employee_id: 2, employee_name: 'Blake Cook', pdf_employee_name: 'Cook, Blake' })];
  return {
    import_id: 30 + (options.revision ?? 1),
    source_package: {
      id: options.revision ?? 1, package_id: `package-${options.revision ?? 1}`, package_revision: options.revision ?? 1, package_schema_version: '1', current: true,
      verified_source_count: sources.filter(source => source.present).length, source_count: sources.filter(source => source.present).length, disposition_targets: [],
      sources, complete: sources.every(source => !source.required || source.present),
    },
    preview: {
      matched, unmatched_pdf_names: [], unmatched_excel_names: [], duplicate_employee_matches: [], low_confidence_matches: [],
      pdf_count: matched.length, excel_count: 0, matched_count: matched.length, can_apply: true, tips_paid_out_from_tips: false,
      source_rows: matched.map(entry => sourceRow(entry.source_row_id, entry.pdf_employee_name || entry.employee_name, entry.employee_id)),
    },
  };
}

const currentPackage = (status: PayrollIntakeImportData['status'], roles: string[]) => ({
  id: 1, source_type: 'mosa_revel', current: true, status, package_revision: 1, package_id: 'package-1',
  documents: roles.map((role, index) => ({ id: index + 1, source_role: role, filename: role === 'revel_hours' ? 'revel.pdf' : 'changes.xlsx', verification_status: 'verified' })),
} as unknown as PayrollIntakeImportData);

const pdf = () => new File(['pdf'], 'revel.pdf', { type: 'application/pdf' });
const workbook = () => new File(['xlsx'], 'changes.xlsx');
const applyButton = () => screen.getByRole('button', { name: /Apply Import/ }) as HTMLButtonElement;

function openUpload() {
  render(<MemoryRouter><ImportModal open payPeriodId={9} companyId={7} onOpenChange={vi.fn()} onImportComplete={vi.fn()} /></MemoryRouter>);
}
function openReview(initial: ImportPreviewResponse) {
  render(<MemoryRouter><ImportModal open payPeriodId={9} companyId={7} initialPreview={initial} onOpenChange={vi.fn()} onImportComplete={vi.fn()} /></MemoryRouter>);
}

afterEach(() => { cleanup(); vi.clearAllMocks(); vi.mocked(payrollIntakeImportsApi.list).mockResolvedValue({ imports: [], disposition_targets: [] }); });

it('previews the Revel PDF on its own', async () => {
  mocks.previewImport.mockResolvedValue(preview([pdfSource, workbookMissing]));
  openUpload();
  const file = pdf();
  fireEvent.change(screen.getByLabelText('Revel hours PDF'), { target: { files: [file] } });
  fireEvent.click(screen.getByRole('button', { name: 'Preview Import' }));

  await waitFor(() => expect(mocks.previewImport).toHaveBeenCalledWith(9, file, undefined, false, undefined, undefined));
  expect(await screen.findByRole('region', { name: 'Files for this import' })).toBeTruthy();
});

it('adds the missing workbook to the open package without asking for a reason', async () => {
  vi.mocked(payrollIntakeImportsApi.list).mockResolvedValue({ imports: [currentPackage('previewed', ['revel_hours'])], disposition_targets: [] });
  mocks.previewImport.mockResolvedValue(preview([pdfSource, workbookPresent], { revision: 2 }));
  openUpload();
  expect(await screen.findByText('In import version 1: revel.pdf')).toBeTruthy();
  const file = workbook();
  fireEvent.change(screen.getByLabelText('Tips & loans workbook'), { target: { files: [file] } });

  expect(screen.queryByLabelText('What changed?')).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: 'Add to import version 1' }));
  await waitFor(() => expect(mocks.previewImport).toHaveBeenCalledWith(9, undefined, file, false, undefined, undefined));
});

it('asks what changed before replacing a file the package already has', async () => {
  vi.mocked(payrollIntakeImportsApi.list).mockResolvedValue({ imports: [currentPackage('previewed', ['revel_hours', 'supplemental_workbook'])], disposition_targets: [] });
  mocks.previewImport.mockResolvedValue(preview([pdfSource, workbookPresent], { revision: 2 }));
  openUpload();
  await screen.findByText('In import version 1: revel.pdf');
  const file = pdf();
  fireEvent.change(screen.getByLabelText('Revel hours PDF'), { target: { files: [file] } });

  expect(screen.getByText('This replaces the Revel hours PDF in import version 1.')).toBeTruthy();
  const previewButton = screen.getByRole('button', { name: 'Preview Import' }) as HTMLButtonElement;
  expect(previewButton.disabled).toBe(true);
  fireEvent.change(screen.getByLabelText('What changed?'), { target: { value: 'MoSa corrected hours' } });
  expect(previewButton.disabled).toBe(false);
  fireEvent.click(previewButton);
  await waitFor(() => expect(mocks.previewImport).toHaveBeenCalledWith(9, file, undefined, false, { supersedesPackageId: 'package-1', reason: 'MoSa corrected hours' }, undefined));
});

it('keeps Apply off until the workbook is added or no tips or loans is confirmed', async () => {
  mocks.applyImport.mockResolvedValue({ results: { success: [], errors: [] }, pay_period: { id: 9 } });
  openReview(preview([pdfSource, workbookMissing]));

  expect(applyButton().disabled).toBe(true);
  expect(screen.getByText(/Apply is off: the Tips & loans workbook is missing/)).toBeTruthy();
  const checklist = screen.getByRole('region', { name: 'Files for this import' });
  expect(within(checklist).getByText('missing')).toBeTruthy();

  fireEvent.click(within(checklist).getByLabelText('No tips or loans this period'));
  expect(applyButton().disabled).toBe(false);
  fireEvent.click(applyButton());
  await waitFor(() => expect(mocks.applyImport).toHaveBeenCalledWith(9, expect.objectContaining({ no_tips_or_loans: true })));
});

it('adds the workbook from the review and keeps the outcomes already chosen', async () => {
  const added = preview([pdfSource, workbookPresent], { revision: 2, firstRowId: 11 });
  mocks.previewImport.mockResolvedValue(added);
  openReview(preview([pdfSource, workbookMissing]));

  const [outcome] = screen.getAllByLabelText('Outcome for Cook, Blake');
  fireEvent.change(outcome, { target: { value: 'excluded' } });
  fireEvent.change(screen.getAllByLabelText('Reason for Cook, Blake')[0], { target: { value: 'Left before this period' } });

  const file = workbook();
  fireEvent.change(screen.getByLabelText('Add Tips & loans workbook'), { target: { files: [file] } });
  await waitFor(() => expect(mocks.previewImport).toHaveBeenCalledWith(9, undefined, file, false));
  await waitFor(() => expect(screen.getByText(/Import version 2/)).toBeTruthy());

  expect((screen.getAllByLabelText('Outcome for Cook, Blake')[0] as HTMLSelectElement).value).toBe('excluded');
  expect((screen.getAllByLabelText('Reason for Cook, Blake')[0] as HTMLInputElement).value).toBe('Left before this period');
  expect((screen.getAllByLabelText('Outcome for Server, Avery')[0] as HTMLSelectElement).value).toBe('included');
  expect(applyButton().disabled).toBe(false);
});

it('lists hand-entered hours that Revel would replace and asks first', async () => {
  mocks.applyImport.mockResolvedValue({ results: { success: [], errors: [] }, pay_period: { id: 9 } });
  const edited = row({ source_row_id: 1, regular_hours: 41, overtime_hours: 2, hand_edited_hours: {
    employee_id: 1, employee_name: 'Avery Server', saved_regular_hours: '36.0', saved_overtime_hours: '2.0', source_regular_hours: '41.0', source_overtime_hours: '2.0',
  } });
  openReview(preview([pdfSource, workbookPresent], { rows: [edited] }));

  const section = screen.getByRole('region', { name: 'Hours entered by hand' });
  expect(within(section).getByText('Revel hours will replace hours entered by hand (1)')).toBeTruthy();
  expect(within(section).getByText(/36 → 41 regular/)).toBeTruthy();
  expect(within(section).queryByText(/overtime/)).toBeNull();
  expect(applyButton().disabled).toBe(true);

  fireEvent.click(within(section).getByLabelText('Replace the hand-entered hours with the Revel hours above.'));
  expect(applyButton().disabled).toBe(false);
  fireEvent.click(applyButton());
  await waitFor(() => expect(mocks.applyImport).toHaveBeenCalledWith(9, expect.objectContaining({ confirm_hours_overwrite: true })));
});
