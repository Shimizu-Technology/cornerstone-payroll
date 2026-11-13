// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { ImportModal } from './ImportModal';
import { ApiError, payrollIntakeImportsApi } from '@/services/api';
import type { PayrollIntakeImportData } from '@/services/api';
import type { ImportPreviewResponse, ImportPreviewRow } from '@/services/api';

const mocks = vi.hoisted(() => ({
  currentImport: vi.fn(), applyImport: vi.fn(), listItems: vi.fn(), createItem: vi.fn(), updateItem: vi.fn(),
}));
vi.mock('@/services/api', async original => ({
  ...await original<typeof import('@/services/api')>(),
  payrollIntakeImportsApi: { list: vi.fn().mockResolvedValue({ imports: [] }) },
  payPeriodsApi: { currentImport: mocks.currentImport, applyImport: mocks.applyImport },
  payrollItemsApi: { list: mocks.listItems, create: mocks.createItem, update: mocks.updateItem },
}));

function row(overrides: Partial<ImportPreviewRow>): ImportPreviewRow {
  return {
    source_row_id: 1, employee_id: 1, employee_name: 'Avery Server', employment_type: 'hourly', pay_rate: 10, confidence: 1,
    matched_name: 'Avery Server', regular_hours: 40, overtime_hours: 0, total_hours: 40, pdf_employee_name: 'Server, Avery',
    total_tips: 0, tip_pool: null, loan_deduction: 0, ...overrides,
  };
}
const sourceRow = (id: number, name: string, employeeId: number) => ({
  id, position: id, source_employee_name: name, employee_id: employeeId, row_kind: 'matched', disposition: 'pending' as const, errors: [], warnings: [],
});
const unmatchedRow = { id: 9, position: 9, source_employee_name: 'Ghost, Gary', employee_id: null, row_kind: 'unmatched_revel', disposition: 'pending' as const, errors: [], warnings: [] };
function preview(owners: ImportPreviewRow[], extraRows: typeof unmatchedRow[] = []): ImportPreviewResponse {
  return {
    import_id: 30,
    source_package: { id: 1, package_id: 'abcdef123456', package_revision: 1, package_schema_version: '1', current: true, verified_source_count: 1, source_count: 1, disposition_targets: [] },
    portal_source: { selection_id: 5, submission_id: 20, revision: 2, period_id: 90, current: true, no_changes: true, changes: [] },
    preview: {
      matched: [row({ source_row_id: 1 }), ...owners], unmatched_pdf_names: [], unmatched_excel_names: [], duplicate_employee_matches: [], low_confidence_matches: [],
      pdf_count: 2, excel_count: 0, matched_count: 2, can_apply: true, tips_paid_out_from_tips: false,
      source_rows: [sourceRow(1, 'Server, Avery', 1), ...owners.map(owner => sourceRow(owner.source_row_id, owner.pdf_employee_name || owner.employee_name, owner.employee_id)), ...extraRows],
    },
  };
}
const ownerMissing = row({ source_row_id: 2, employee_id: 2, employee_name: 'Monique Owner', pdf_employee_name: 'Owner, Monique', employment_type: 'salary', regular_hours: 0, total_hours: 0, period_pay_required: true, period_pay_missing: true, current_period_pay: null });
const ownerSaved = { ...ownerMissing, period_pay_missing: false, current_period_pay: '4500.00', period_pay_source: 'payroll_worksheet' as const, overwrite_required: true };

function open(initial: ImportPreviewResponse) {
  const onImportComplete = vi.fn();
  render(<MemoryRouter><ImportModal open payPeriodId={9} companyId={7} initialPreview={initial} onOpenChange={vi.fn()} onImportComplete={onImportComplete} /></MemoryRouter>);
  return onImportComplete;
}
const applyButton = () => screen.getByRole('button', { name: /Apply Import/ }) as HTMLButtonElement;
// The phone cards and the desktop table both render; jsdom shows both.
const ownerInput = () => screen.getByLabelText('Pay for Monique Owner this period') as HTMLInputElement;

beforeEach(() => { mocks.listItems.mockResolvedValue({ payroll_items: [] }); });
afterEach(() => { cleanup(); vi.clearAllMocks(); });

it('keeps Apply off and says why until each owner has their own pay, with no dead-end button', () => {
  open(preview([ownerMissing]));
  expect(applyButton().disabled).toBe(true);
  expect(screen.getByText('Apply is off: pay is missing for Monique Owner.')).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Return to payroll worksheet' })).toBeNull();
  expect(screen.getByText(/A combined amount for several owners is not accepted/)).toBeTruthy();
  expect((screen.getByRole('button', { name: 'Save pay for Monique Owner' }) as HTMLButtonElement).disabled).toBe(true);
});

it('saves one person’s pay on their own paycheck row, stays in the review, and then allows Apply', async () => {
  mocks.createItem.mockResolvedValue({ payroll_item: { id: 70 } });
  mocks.currentImport.mockResolvedValue(preview([ownerSaved]));
  open(preview([ownerMissing]));
  fireEvent.change(ownerInput(), { target: { value: '4500' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save pay for Monique Owner' }));
  await waitFor(() => expect(mocks.createItem).toHaveBeenCalledWith(9, { employee_id: 2, salary_override: 4500 }, { expectedImportId: 30 }));
  expect(mocks.currentImport).toHaveBeenCalledWith(9);
  await waitFor(() => expect(screen.queryByRole('alert', { name: 'Pay needed' })).toBeNull());
  // Saved pay sits on an existing non-import row, so replacing it must be confirmed.
  expect(applyButton().disabled).toBe(true);
  expect(screen.getByText('Apply is off: replacing saved entries is not confirmed.')).toBeTruthy();
  fireEvent.click(screen.getByLabelText(/Replace existing hours, tips and direct loan deductions/));
  await waitFor(() => expect(applyButton().disabled).toBe(false));
  expect(screen.queryByText(/^Apply is off/)).toBeNull();
});

it('offers each variable-pay employee separately, including one absent from the files', () => {
  const second = { ...ownerMissing, source_row_id: 3, employee_id: 3, employee_name: 'Sara Owner', payroll_setup_only: true };
  open(preview([ownerMissing, second]));
  expect(screen.getByLabelText('Pay for Monique Owner this period')).toBeTruthy();
  expect(screen.getByLabelText('Pay for Sara Owner this period')).toBeTruthy();
  expect(screen.getAllByText('From payroll setup, absent from source files. Review this person’s period pay.')).toHaveLength(2);
  expect(applyButton().disabled).toBe(true);
});

it('updates the paycheck row that already exists instead of creating a second one', async () => {
  mocks.listItems.mockResolvedValue({ payroll_items: [{ id: 71, employee_id: 2 }] });
  mocks.updateItem.mockResolvedValue({ payroll_item: { id: 71 } });
  mocks.currentImport.mockResolvedValue(preview([ownerSaved]));
  open(preview([ownerMissing]));
  fireEvent.change(ownerInput(), { target: { value: '1200.5' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save pay for Monique Owner' }));
  await waitFor(() => expect(mocks.updateItem).toHaveBeenCalledWith(9, 71, { salary_override: 1200.5 }, { expectedImportId: 30 }));
  expect(mocks.createItem).not.toHaveBeenCalled();
});

it('keeps the typed pay and shows the problem when the save fails', async () => {
  mocks.createItem.mockRejectedValue(new Error('Pay this period must be greater than zero'));
  open(preview([ownerMissing]));
  fireEvent.change(ownerInput(), { target: { value: '10' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save pay for Monique Owner' }));
  expect((await screen.findAllByText(/Could not save pay for Monique Owner/)).length).toBeGreaterThan(0);
  expect(Number(ownerInput().value)).toBe(10);
  expect(mocks.currentImport).not.toHaveBeenCalled();
  expect(applyButton().disabled).toBe(true);
});

it('does not replace the review if the saved review changed underneath it', async () => {
  mocks.createItem.mockResolvedValue({ payroll_item: { id: 70 } });
  mocks.currentImport.mockResolvedValue({ ...preview([ownerSaved]), import_id: 99 });
  open(preview([ownerMissing]));
  fireEvent.change(ownerInput(), { target: { value: '4500' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save pay for Monique Owner' }));
  expect((await screen.findAllByText(/saved review changed/)).length).toBeGreaterThan(0);
  expect(applyButton().disabled).toBe(true);
});

it('lists what blocks Apply, jumps to each item, and keeps outcomes already chosen when it reloads', async () => {
  mocks.createItem.mockResolvedValue({ payroll_item: { id: 70 } });
  mocks.currentImport.mockResolvedValue(preview([ownerSaved], [unmatchedRow]));
  const scrolled = vi.fn();
  Element.prototype.scrollIntoView = scrolled;
  open(preview([ownerMissing], [unmatchedRow]));
  const needs = screen.getByRole('region', { name: 'Needs attention' });
  expect(within(needs).getByText('2 things to finish before you can apply')).toBeTruthy();
  expect(screen.getByText('Apply is off: pay is missing for Monique Owner; 1 source row needs an outcome.')).toBeTruthy();
  fireEvent.click(within(needs).getByRole('button', { name: 'Enter pay for Monique Owner' }));
  expect(scrolled).toHaveBeenCalled();
  expect(document.activeElement).toBe(screen.getByRole('alert', { name: 'Pay needed' }));
  fireEvent.click(within(needs).getByRole('button', { name: 'Next row needing attention (1)' }));
  expect((document.activeElement as HTMLElement).getAttribute('aria-label')).toBe('Outcome for Ghost, Gary');
  fireEvent.change(document.activeElement as HTMLSelectElement, { target: { value: 'informational' } });
  fireEvent.change(screen.getAllByLabelText('Reason for Ghost, Gary')[0], { target: { value: 'Not on this payroll' } });
  fireEvent.change(ownerInput(), { target: { value: '4500' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save pay for Monique Owner' }));
  await waitFor(() => expect(mocks.currentImport).toHaveBeenCalled());
  await waitFor(() => expect(screen.queryByRole('alert', { name: 'Pay needed' })).toBeNull());
  expect((screen.getAllByLabelText('Outcome for Ghost, Gary')[0] as HTMLSelectElement).value).toBe('informational');
  expect((screen.getAllByLabelText('Reason for Ghost, Gary')[0] as HTMLInputElement).value).toBe('Not on this payroll');
});

it('keeps an outcome changed while the pay save is still running', async () => {
  let finishSave: (value: unknown) => void = () => undefined;
  mocks.createItem.mockReturnValue(new Promise((resolve) => { finishSave = resolve; }));
  mocks.currentImport.mockResolvedValue(preview([ownerSaved], [unmatchedRow]));
  open(preview([ownerMissing], [unmatchedRow]));
  fireEvent.change(ownerInput(), { target: { value: '4500' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save pay for Monique Owner' }));
  await waitFor(() => expect(mocks.createItem).toHaveBeenCalled());
  fireEvent.change(screen.getAllByLabelText('Outcome for Ghost, Gary')[0], { target: { value: 'informational' } });
  fireEvent.change(screen.getAllByLabelText('Reason for Ghost, Gary')[0], { target: { value: 'Not on this payroll' } });
  finishSave({ payroll_item: { id: 70 } });
  await waitFor(() => expect(screen.queryByRole('alert', { name: 'Pay needed' })).toBeNull());
  expect((screen.getAllByLabelText('Outcome for Ghost, Gary')[0] as HTMLSelectElement).value).toBe('informational');
  expect((screen.getAllByLabelText('Reason for Ghost, Gary')[0] as HTMLInputElement).value).toBe('Not on this payroll');
});

it('reloads the current amounts when the server refuses a stale save', async () => {
  mocks.createItem.mockRejectedValue(new ApiError('This review is out of date or someone already entered this pay. Nothing was saved.', 409));
  mocks.currentImport.mockResolvedValue(preview([ownerSaved]));
  open(preview([ownerMissing]));
  fireEvent.change(ownerInput(), { target: { value: '9999' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save pay for Monique Owner' }));
  expect((await screen.findAllByText(/Nothing was saved/)).length).toBeGreaterThan(0);
  await waitFor(() => expect(mocks.currentImport).toHaveBeenCalledWith(9));
  await waitFor(() => expect(screen.queryByRole('alert', { name: 'Pay needed' })).toBeNull());
});

it('lists a missing job and rate choice among the things to finish', () => {
  const twoRates = row({ source_row_id: 1, wage_rate_options: [{ id: 11, label: 'Main Kitchen', rate: 15.5 }, { id: 12, label: 'Shared Kitchen', rate: 16.5 }], selected_wage_rate_id: null, wage_rate_default_source: 'Choose a job and rate' });
  const initial = preview([]);
  initial.preview.matched = [twoRates];
  open(initial);
  const needs = screen.getByRole('region', { name: 'Needs attention' });
  expect(within(needs).getByRole('button', { name: 'Choose job and rate for Avery Server' })).toBeTruthy();
  expect(screen.getByText(/Apply is off: no job and rate chosen for Avery Server/)).toBeTruthy();
});

it('says the pay was saved and offers a reload when only the review reload fails', async () => {
  mocks.createItem.mockResolvedValue({ payroll_item: { id: 70 } });
  mocks.currentImport.mockRejectedValueOnce(new Error('Network error')).mockResolvedValueOnce(preview([ownerSaved]));
  open(preview([ownerMissing]));
  fireEvent.change(ownerInput(), { target: { value: '4500' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save pay for Monique Owner' }));
  expect((await screen.findAllByText(/Pay for Monique Owner was saved, but the review could not reload/)).length).toBeGreaterThan(0);
  fireEvent.click(screen.getAllByRole('button', { name: 'Reload review' })[0]);
  await waitFor(() => expect(screen.queryByRole('alert', { name: 'Pay needed' })).toBeNull());
  expect(mocks.createItem).toHaveBeenCalledTimes(1);
  expect(screen.queryByText(/could not reload/)).toBeNull();
});

it('ignores a pay save that finishes after the review was closed and reopened', async () => {
  // The pay-run import reuses one modal instance; the portal mounts a new one each time.
  vi.mocked(payrollIntakeImportsApi.list).mockResolvedValue({ imports: [
    { id: 1, source_type: 'mosa_revel', current: true, status: 'previewed', package_revision: 1 } as PayrollIntakeImportData,
  ], disposition_targets: [] });
  let finishSave: (value: unknown) => void = () => undefined;
  mocks.createItem.mockReturnValue(new Promise((resolve) => { finishSave = resolve; }));
  mocks.currentImport.mockResolvedValue(preview([ownerMissing]));
  const props = { payPeriodId: 9, companyId: 7, onOpenChange: vi.fn(), onImportComplete: vi.fn() };
  const { rerender } = render(<MemoryRouter><ImportModal open {...props} /></MemoryRouter>);
  fireEvent.click(await screen.findByRole('button', { name: /Continue import version 1/ }));
  fireEvent.change(await screen.findByLabelText('Pay for Monique Owner this period'), { target: { value: '4500' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save pay for Monique Owner' }));
  await waitFor(() => expect(mocks.createItem).toHaveBeenCalled());

  fireEvent.keyDown(document, { key: 'Escape' });
  expect(props.onOpenChange).toHaveBeenCalledWith(false);
  rerender(<MemoryRouter><ImportModal open={false} {...props} /></MemoryRouter>);
  rerender(<MemoryRouter><ImportModal open {...props} /></MemoryRouter>);
  fireEvent.click(await screen.findByRole('button', { name: /Continue import version 1/ }));
  expect(await screen.findByRole('alert', { name: 'Pay needed' })).toBeTruthy();
  expect(mocks.currentImport).toHaveBeenCalledTimes(2);

  finishSave({ payroll_item: { id: 70 } });
  await new Promise((resolve) => setTimeout(resolve, 20));
  // The old save neither reloads nor changes the reopened review.
  expect(mocks.currentImport).toHaveBeenCalledTimes(2);
  expect(screen.getByRole('alert', { name: 'Pay needed' })).toBeTruthy();
  expect(ownerInput().value).toBe('');
  expect(screen.getByRole('button', { name: 'Save pay for Monique Owner' }).textContent).not.toMatch(/Saving/);
  expect(screen.queryByText(/Could not save|was saved/)).toBeNull();
});
