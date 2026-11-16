// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { ImportModal } from './ImportModal';
import type { ImportPreviewResponse, ImportPreviewRow, MosaSourceRow } from '@/services/api';

const mocks = vi.hoisted(() => ({ rematchImport: vi.fn(), applyImport: vi.fn(), previewImport: vi.fn(), getEmployee: vi.fn(), reactivate: vi.fn() }));
vi.mock('@/services/api', async original => ({
  ...await original<typeof import('@/services/api')>(),
  payrollIntakeImportsApi: { list: vi.fn().mockResolvedValue({ imports: [] }) },
  payPeriodsApi: { rematchImport: mocks.rematchImport, applyImport: mocks.applyImport, previewImport: mocks.previewImport },
  employeesApi: { get: mocks.getEmployee, reactivate: mocks.reactivate },
}));

const avery: ImportPreviewRow = {
  source_row_id: 1, employee_id: 1, employee_name: 'Avery Server', employment_type: 'hourly', pay_rate: 10, confidence: 1,
  matched_name: 'Avery Server', regular_hours: 40, overtime_hours: 0, total_hours: 40, pdf_employee_name: 'Server, Avery',
  total_tips: 0, tip_pool: null, loan_deduction: 0,
};
const averyRow = (id: number): MosaSourceRow => ({ id, position: 0, source_employee_name: 'Server, Avery', employee_id: 1, row_kind: 'matched', disposition: 'pending', errors: [], warnings: [] });
const inactiveBlake: MosaSourceRow = {
  id: 2, position: 1, source_employee_name: 'Returning, Blake', employee_id: null, row_kind: 'unmatched_revel', disposition: 'pending', warnings: [],
  errors: [{ code: 'unmatched_revel_employee', severity: 'error', employee_id: 22, employee_name: 'Blake Returning', employee_status: 'inactive', message: 'Blake Returning is inactive in Cornerstone.' }],
};

const documents = (pdfSha = 'pdf-sha') => [
  { id: 1, source_role: 'revel_hours', filename: 'revel.pdf', content_type: 'application/pdf', byte_size: 10, sha256: pdfSha },
  { id: 2, source_role: 'supplemental_workbook', filename: 'mosa.xlsx', content_type: 'application/vnd.ms-excel', byte_size: 10, sha256: 'workbook-sha' },
];

function preview(rows: MosaSourceRow[], matched: ImportPreviewRow[], revision = 1, warnings: ImportPreviewResponse['preview']['source_warnings'] = [], pdfSha = 'pdf-sha'): ImportPreviewResponse {
  return {
    import_id: 40 + revision,
    pay_period: { start_date: '2026-11-02', end_date: '2026-11-15' },
    source_package: { id: revision, package_id: `package-${revision}`, package_revision: revision, package_schema_version: '1', current: true, verified_source_count: 2, source_count: 2, disposition_targets: [], documents: documents(pdfSha) },
    preview: {
      matched, unmatched_pdf_names: [], unmatched_excel_names: [], duplicate_employee_matches: [], low_confidence_matches: [],
      pdf_count: rows.length, excel_count: 0, matched_count: matched.length, can_apply: true, tips_paid_out_from_tips: false, source_rows: rows, source_warnings: warnings,
    },
  };
}

function open(initial: ImportPreviewResponse, canReactivateWorkers: boolean) {
  render(<MemoryRouter><ImportModal open payPeriodId={9} companyId={7} initialPreview={initial} canReactivateWorkers={canReactivateWorkers} onOpenChange={vi.fn()} onImportComplete={vi.fn()} /></MemoryRouter>);
}

afterEach(() => { cleanup(); vi.clearAllMocks(); });

it('reactivates an inactive worker from the review, dated from the pay period start, and matches again', async () => {
  const blake = { id: 22, first_name: 'Blake', last_name: 'Returning', status: 'inactive', employment_type: 'hourly' };
  mocks.getEmployee.mockResolvedValue({ data: blake });
  mocks.reactivate.mockResolvedValue({ data: { ...blake, status: 'active' } });
  const blakeMatched = { ...avery, source_row_id: 12, employee_id: 22, employee_name: 'Blake Returning', pdf_employee_name: 'Returning, Blake', regular_hours: 12 };
  mocks.rematchImport.mockResolvedValue(preview([averyRow(11), { ...inactiveBlake, id: 12, employee_id: 22, row_kind: 'matched', errors: [] }], [{ ...avery, source_row_id: 11 }, blakeMatched], 2));
  open(preview([averyRow(1), inactiveBlake], [avery]), true);

  fireEvent.change(screen.getAllByLabelText('Outcome for Server, Avery')[0], { target: { value: 'excluded' } });
  fireEvent.change(screen.getAllByLabelText('Reason for Server, Avery')[0], { target: { value: 'Paid on another run' } });
  expect(screen.getByText('Blake Returning is inactive in Cornerstone.')).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Reactivate Blake Returning' }));

  await waitFor(() => expect(mocks.getEmployee).toHaveBeenCalledWith(22, 7));
  const dialog = await screen.findByRole('dialog', { name: 'Reactivate Blake' });
  expect((within(dialog).getByLabelText(/Reactivation effective date/) as HTMLInputElement).value).toBe('2026-11-02');
  fireEvent.click(within(dialog).getByRole('button', { name: 'Reactivate employee' }));

  await waitFor(() => expect(mocks.reactivate).toHaveBeenCalledWith(22, { effective_date: '2026-11-02', internal_notes: undefined }));
  await waitFor(() => expect(mocks.rematchImport).toHaveBeenCalledWith(9));
  expect(await screen.findByText('Blake Returning is active again and is now matched in this import.')).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Reactivate Blake Returning' })).toBeNull();
  expect((screen.getAllByLabelText('Outcome for Returning, Blake')[0] as HTMLSelectElement).value).toBe('included');
  expect((screen.getAllByLabelText('Outcome for Server, Avery')[0] as HTMLSelectElement).value).toBe('excluded');
});

it('tells staff without reactivation access who can do it', () => {
  open(preview([averyRow(1), inactiveBlake], [avery]), false);

  expect(screen.queryByRole('button', { name: /Reactivate/ })).toBeNull();
  expect(screen.getByText('A manager or admin can reactivate Blake Returning.')).toBeTruthy();
  expect(screen.getByRole('link', { name: 'Open profile for Returning, Blake (opens in a new tab)' })).toBeTruthy();
});

it('groups what blocks Apply apart from notices, each notice one line with details on request', () => {
  open(preview([averyRow(1), inactiveBlake], [avery], 1, [
    { code: 'pay_period_workweek_offset', severity: 'warning', message: 'This pay period starts on a different day than the client’s saved overtime workweek. Overtime is used exactly as the source reports it.' },
    { code: 'legacy_mosa_workbook', severity: 'warning', message: 'This is the legacy MoSa workbook. Use the generated template next payroll.' },
  ]), true);

  const needs = screen.getByRole('region', { name: 'Needs your action' });
  expect(within(needs).getByRole('heading', { name: 'Needs your action (2)' })).toBeTruthy();
  expect(within(needs).getByRole('button', { name: 'Next row needing attention (1)' })).toBeTruthy();
  // The older-workbook notice stays with its required tip choice until that is saved.
  expect(within(needs).getByText(/This is the legacy MoSa workbook/)).toBeTruthy();
  expect(within(needs).getByRole('button', { name: 'Choose how the workbook’s tips were paid' })).toBeTruthy();

  const notices = screen.getByRole('region', { name: 'For your information' });
  expect(within(notices).getByRole('heading', { name: 'For your information (1)' })).toBeTruthy();
  const workweek = within(notices).getByText('This pay period and the overtime workweek start on different days').closest('details')!;
  expect(workweek.open).toBe(false);
  fireEvent.click(within(workweek).getByText('This pay period and the overtime workweek start on different days'));
  expect(workweek.open).toBe(true);
  expect(within(workweek).getByText(/Overtime is used exactly as the source reports it/)).toBeTruthy();
});

it('moves the older-workbook notice to the information group once its tip choice is saved', () => {
  const data = preview([averyRow(1)], [avery], 1, [
    { code: 'legacy_mosa_workbook', severity: 'warning', message: 'This is the legacy MoSa workbook. Use the generated template next payroll.' },
  ]);
  data.preview.tip_treatment_confirmed = true;
  open(data, true);

  expect(screen.queryByRole('region', { name: 'Needs your action' })).toBeNull();
  const notices = screen.getByRole('region', { name: 'For your information' });
  expect(within(notices).getByText('Older MoSa workbook format')).toBeTruthy();
});

it('shows a serious notice on its own without counting it as something that keeps Apply off', () => {
  open(preview([averyRow(1)], [avery], 1, [
    { code: 'duplicate_source', severity: 'error', message: 'This exact payroll source is retained as superseded revision 1.' },
  ]), true);

  expect(screen.getByRole('alert').textContent).toContain('retained as superseded revision 1');
  expect(screen.queryByRole('region', { name: 'Needs your action' })).toBeNull();
  expect((screen.getByRole('button', { name: /Apply Import/ }) as HTMLButtonElement).disabled).toBe(false);
});

it('does not offer "No tips or loans" when the client sent a workbook link', () => {
  const data = preview([averyRow(1)], [avery]);
  data.source_package.sources = [
    { role: 'revel_hours', label: 'Revel hours PDF', required: true, present: true, filename: 'revel.pdf' },
    { role: 'supplemental_workbook', label: 'Tips & loans workbook', required: true, present: false, waiver_label: 'No tips or loans this period' },
  ];
  data.portal_source = { selection_id: 1, submission_id: 2, revision: 1, period_id: 3, current: true, changes: [], no_changes: false,
    workbook_choice: 'link', changes_link_url: 'https://example.test/workbook' } as unknown as ImportPreviewResponse['portal_source'];
  open(data, true);

  const checklist = screen.getByRole('region', { name: 'Files for this import' });
  expect(within(checklist).queryByLabelText('No tips or loans this period')).toBeNull();
  expect(within(checklist).getByText('The client sent a link to the workbook. Attach the workbook from the link above.')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Add the Tips & loans workbook' })).toBeTruthy();
  expect((screen.getByRole('button', { name: /Apply Import/ }) as HTMLButtonElement).disabled).toBe(true);
});

const blake = { id: 22, first_name: 'Blake', last_name: 'Returning', status: 'inactive', employment_type: 'hourly' };
const blakeMatchedRow = (id: number): MosaSourceRow => ({ ...inactiveBlake, id, employee_id: 22, row_kind: 'matched', errors: [] });
const blakeMatched = { ...avery, source_row_id: 12, employee_id: 22, employee_name: 'Blake Returning', pdf_employee_name: 'Returning, Blake', regular_hours: 12 };

async function reactivateBlake() {
  fireEvent.click(screen.getByRole('button', { name: 'Reactivate Blake Returning' }));
  const dialog = await screen.findByRole('dialog', { name: 'Reactivate Blake' });
  fireEvent.click(within(dialog).getByRole('button', { name: 'Reactivate employee' }));
  await waitFor(() => expect(mocks.rematchImport).toHaveBeenCalledWith(9));
}

it('does not carry outcomes into a review of different files, and says why', async () => {
  mocks.getEmployee.mockResolvedValue({ data: blake });
  mocks.reactivate.mockResolvedValue({ data: { ...blake, status: 'active' } });
  // Another window replaced the Revel PDF while this review was open.
  mocks.rematchImport.mockResolvedValue(preview([averyRow(11), blakeMatchedRow(12)], [{ ...avery, source_row_id: 11 }, blakeMatched], 3, [], 'other-pdf-sha'));
  open(preview([averyRow(1), inactiveBlake], [avery]), true);

  fireEvent.change(screen.getAllByLabelText('Outcome for Server, Avery')[0], { target: { value: 'excluded' } });
  fireEvent.change(screen.getAllByLabelText('Reason for Server, Avery')[0], { target: { value: 'Paid on another run' } });
  await reactivateBlake();

  expect(await screen.findByText(/The import’s files changed since this review opened, so choose each row’s outcome again/)).toBeTruthy();
  expect((screen.getAllByLabelText('Outcome for Server, Avery')[0] as HTMLSelectElement).value).toBe('included');
});

it('locks outcomes while matching runs again, so a change made meanwhile is not lost', async () => {
  mocks.getEmployee.mockResolvedValue({ data: blake });
  mocks.reactivate.mockResolvedValue({ data: { ...blake, status: 'active' } });
  let finish: (value: ImportPreviewResponse) => void = () => undefined;
  mocks.rematchImport.mockReturnValue(new Promise<ImportPreviewResponse>((resolve) => { finish = resolve; }));
  open(preview([averyRow(1), inactiveBlake], [avery]), true);

  fireEvent.change(screen.getAllByLabelText('Outcome for Server, Avery')[0], { target: { value: 'excluded' } });
  await reactivateBlake();

  expect((screen.getAllByLabelText('Outcome for Server, Avery')[0] as HTMLSelectElement).disabled).toBe(true);
  expect((screen.getAllByLabelText('Reason for Server, Avery')[0] as HTMLInputElement).disabled).toBe(true);
  finish(preview([averyRow(11), blakeMatchedRow(12)], [{ ...avery, source_row_id: 11 }, blakeMatched], 2));
  await screen.findByText('Blake Returning is active again and is now matched in this import.');
  expect((screen.getAllByLabelText('Outcome for Server, Avery')[0] as HTMLSelectElement).disabled).toBe(false);
});

it('locks the client no-pay decision while matching runs again', async () => {
  mocks.getEmployee.mockResolvedValue({ data: blake });
  mocks.reactivate.mockResolvedValue({ data: { ...blake, status: 'active' } });
  let finish: (value: ImportPreviewResponse) => void = () => undefined;
  mocks.rematchImport.mockReturnValue(new Promise<ImportPreviewResponse>((resolve) => { finish = resolve; }));
  const prefill: ImportPreviewResponse['client_change_prefill'] = { submission_id: 20, revision: 2, rows: [
    { change_index: -2, kind: 'owner_pay', employee_id: 1, employee_name: 'Avery Server', requires_pay_decision: true },
  ] };
  open({ ...preview([averyRow(1), inactiveBlake], [avery]), client_change_prefill: prefill }, true);

  fireEvent.click(screen.getByLabelText('No pay this period for Avery Server'));
  await reactivateBlake();

  expect((screen.getByLabelText('No pay this period for Avery Server') as HTMLInputElement).disabled).toBe(true);
  expect((screen.getByLabelText('Reason for no pay for Avery Server') as HTMLInputElement).disabled).toBe(true);
  finish({ ...preview([averyRow(11), blakeMatchedRow(12)], [{ ...avery, source_row_id: 11 }, blakeMatched], 2), client_change_prefill: prefill });
  await screen.findByText('Blake Returning is active again and is now matched in this import.');
  expect((screen.getByLabelText('No pay this period for Avery Server') as HTMLInputElement).disabled).toBe(false);
});

it('ignores a worker that finishes loading after staff went Back', async () => {
  let finish: (value: { data: typeof blake }) => void = () => undefined;
  mocks.getEmployee.mockReturnValue(new Promise((resolve) => { finish = resolve; }));
  mocks.previewImport.mockResolvedValue(preview([averyRow(1), inactiveBlake], [avery]));
  render(<MemoryRouter><ImportModal open payPeriodId={9} companyId={7} canReactivateWorkers onOpenChange={vi.fn()} onImportComplete={vi.fn()} /></MemoryRouter>);
  fireEvent.change(screen.getByLabelText('Revel hours PDF'), { target: { files: [new File(['pdf'], 'revel.pdf', { type: 'application/pdf' })] } });
  fireEvent.click(screen.getByRole('button', { name: 'Preview Import' }));

  fireEvent.click(await screen.findByRole('button', { name: 'Reactivate Blake Returning' }));
  await waitFor(() => expect(mocks.getEmployee).toHaveBeenCalledWith(22, 7));
  fireEvent.click(screen.getByRole('button', { name: 'Back' }));
  finish({ data: blake });

  await screen.findByRole('button', { name: 'Preview Import' });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(screen.queryByRole('dialog', { name: 'Reactivate Blake' })).toBeNull();
});

const pendingRevision = (submissionId: number): ImportPreviewResponse['pending_portal_source'] => ({ submission_id: submissionId, revision: 2, period_id: 3, no_changes: true, changes: [] });

it('keeps the selected client revision after matching again when it is still the one offered', async () => {
  mocks.getEmployee.mockResolvedValue({ data: blake });
  mocks.reactivate.mockResolvedValue({ data: { ...blake, status: 'active' } });
  mocks.applyImport.mockResolvedValue({ results: { success: [], errors: [] }, pay_period: { id: 9 } });
  const rematched = preview([averyRow(11), blakeMatchedRow(12)], [{ ...avery, source_row_id: 11 }, blakeMatched], 2);
  rematched.pending_portal_source = pendingRevision(5);
  mocks.rematchImport.mockResolvedValue(rematched);
  const initial = preview([averyRow(1), inactiveBlake], [avery]);
  initial.pending_portal_source = pendingRevision(5);
  open(initial, true);

  fireEvent.click(screen.getByLabelText('Use this import for the client’s revision 2'));
  await reactivateBlake();
  await screen.findByText('Blake Returning is active again and is now matched in this import.');

  expect((screen.getByLabelText('Use this import for the client’s revision 2') as HTMLInputElement).checked).toBe(true);
  fireEvent.click(screen.getByRole('button', { name: /Apply Import/ }));
  await waitFor(() => expect(mocks.applyImport).toHaveBeenCalledWith(9, expect.objectContaining({ use_submission_id: 5 })));
});

it('locks the client revision choice while matching runs again', async () => {
  mocks.getEmployee.mockResolvedValue({ data: blake });
  mocks.reactivate.mockResolvedValue({ data: { ...blake, status: 'active' } });
  let finish: (value: ImportPreviewResponse) => void = () => undefined;
  mocks.rematchImport.mockReturnValue(new Promise<ImportPreviewResponse>((resolve) => { finish = resolve; }));
  const initial = preview([averyRow(1), inactiveBlake], [avery]);
  initial.pending_portal_source = pendingRevision(5);
  open(initial, true);

  fireEvent.click(screen.getByLabelText('Use this import for the client’s revision 2'));
  await reactivateBlake();

  expect((screen.getByLabelText('Use this import for the client’s revision 2') as HTMLInputElement).disabled).toBe(true);
  const rematched = preview([averyRow(11), blakeMatchedRow(12)], [{ ...avery, source_row_id: 11 }, blakeMatched], 2);
  rematched.pending_portal_source = pendingRevision(5);
  finish(rematched);
  await screen.findByText('Blake Returning is active again and is now matched in this import.');
  const checkbox = screen.getByLabelText('Use this import for the client’s revision 2') as HTMLInputElement;
  expect(checkbox.disabled).toBe(false);
  expect(checkbox.checked).toBe(true);
});

it('clears the client revision selection when matching again offers a different revision', async () => {
  mocks.getEmployee.mockResolvedValue({ data: blake });
  mocks.reactivate.mockResolvedValue({ data: { ...blake, status: 'active' } });
  const rematched = preview([averyRow(11), blakeMatchedRow(12)], [{ ...avery, source_row_id: 11 }, blakeMatched], 2);
  rematched.pending_portal_source = pendingRevision(6);
  mocks.rematchImport.mockResolvedValue(rematched);
  const initial = preview([averyRow(1), inactiveBlake], [avery]);
  initial.pending_portal_source = pendingRevision(5);
  open(initial, true);

  fireEvent.click(screen.getByLabelText('Use this import for the client’s revision 2'));
  await reactivateBlake();
  await screen.findByText('Blake Returning is active again and is now matched in this import.');

  expect((screen.getByLabelText('Use this import for the client’s revision 2') as HTMLInputElement).checked).toBe(false);
});
