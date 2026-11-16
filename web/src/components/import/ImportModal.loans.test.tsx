// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { ImportModal } from './ImportModal';
import { ApiError } from '@/services/api';
import type { ImportPreviewResponse, ImportPreviewRow, InstallmentLoanSetupOffer, MosaSourceRow } from '@/services/api';

const mocks = vi.hoisted(() => ({ rematchImport: vi.fn(), applyImport: vi.fn(), setUpLoan: vi.fn() }));
vi.mock('@/services/api', async original => ({
  ...await original<typeof import('@/services/api')>(),
  payrollIntakeImportsApi: { list: vi.fn().mockResolvedValue({ imports: [] }) },
  payPeriodsApi: { rematchImport: mocks.rematchImport, applyImport: mocks.applyImport, setUpImportInstallmentLoan: mocks.setUpLoan },
}));

const createOffer: InstallmentLoanSetupOffer = {
  action: 'create', name: 'Installment loan', starting_balance: '600.0', payment_amount: '50.0', first_deduction_date: '2026-11-19',
  beginning_balance: '0.0', new_amount: '600.0', estimated_ending_balance: '550.0',
  message: 'The workbook has an installment loan for Elena Mercer ($600.00 balance, $50.00 this payroll), but Employee Loans has none. Set it up so this payroll and later ones deduct it.',
};
const emma = (extra: Partial<ImportPreviewRow> = {}): ImportPreviewRow => ({
  source_row_id: 1, employee_id: 5, employee_name: 'Elena Mercer', employment_type: 'hourly', pay_rate: 12, confidence: 1,
  matched_name: 'Elena Mercer', regular_hours: 40, overtime_hours: 0, total_hours: 40, pdf_employee_name: 'Mercer, Elena',
  total_tips: 0, tip_pool: null, loan_deduction: 0, installment_payment: 50, ...extra,
});
const emmaSource = (id: number, message?: string): MosaSourceRow => ({
  id, position: 0, source_employee_name: 'Mercer, Elena', employee_id: 5, row_kind: 'matched', disposition: 'pending', warnings: [],
  errors: message ? [{ code: 'loan_reconciliation_required', severity: 'error', message }] : [],
});
const documents = [
  { id: 1, source_role: 'revel_hours', filename: 'revel.pdf', content_type: 'application/pdf', byte_size: 10, sha256: 'pdf-sha' },
  { id: 2, source_role: 'supplemental_workbook', filename: 'mosa.xlsx', content_type: 'application/vnd.ms-excel', byte_size: 10, sha256: 'workbook-sha' },
];

function preview(rows: MosaSourceRow[], matched: ImportPreviewRow[], revision = 1, loanSetup: ImportPreviewResponse['loan_setup'] = { allowed: true, reason: null }): ImportPreviewResponse {
  return {
    import_id: 40 + revision,
    loan_setup: loanSetup,
    pay_period: { start_date: '2026-11-02', end_date: '2026-11-15' },
    source_package: { id: revision, package_id: `package-${revision}`, package_revision: revision, package_schema_version: '1', current: true, verified_source_count: 2, source_count: 2, disposition_targets: [], documents },
    preview: {
      matched, unmatched_pdf_names: [], unmatched_excel_names: [], duplicate_employee_matches: [], low_confidence_matches: [],
      pdf_count: rows.length, excel_count: 1, matched_count: matched.length, can_apply: true, tips_paid_out_from_tips: false, source_rows: rows, source_warnings: [],
    },
  };
}

function open(initial: ImportPreviewResponse) {
  render(<MemoryRouter><ImportModal open payPeriodId={9} companyId={7} initialPreview={initial} onOpenChange={vi.fn()} onImportComplete={vi.fn()} /></MemoryRouter>);
}

afterEach(() => { cleanup(); vi.clearAllMocks(); });

it('sets up the workbook’s new installment loan from the review, then matches again so the row reconciles', async () => {
  mocks.setUpLoan.mockResolvedValue({ loan_id: 77, already_set_up: false });
  mocks.rematchImport.mockResolvedValue(preview([emmaSource(11)], [emma({ source_row_id: 11, loan_reconciliation_matches: [{ employee_loan_id: 77, tracking_mode: 'balance_tracked', name: 'Emma advance', amount: 50 }] })], 2));
  open(preview([emmaSource(1, createOffer.message)], [emma({ installment_loan_setup: createOffer })]));

  const setup = screen.getAllByRole('region', { name: 'Installment loan for Elena Mercer' })[0];
  expect(within(setup).getByText(/\$600\.00 starting balance · \$50\.00 this payroll/)).toBeTruthy();
  // The offer explains itself; its reconciliation message is not repeated.
  expect(screen.queryByText(createOffer.message)).toBeNull();
  fireEvent.click(within(setup).getByRole('button', { name: 'Set up installment loan' }));
  expect((within(setup).getByLabelText('Starting balance') as HTMLInputElement).value).toBe('600.0');
  expect((within(setup).getByLabelText('Payment per payroll') as HTMLInputElement).value).toBe('50.0');
  expect((within(setup).getByLabelText('First deduction pay date') as HTMLInputElement).value).toBe('2026-11-19');
  fireEvent.change(within(setup).getByLabelText('Loan name'), { target: { value: ' Emma advance ' } });
  fireEvent.click(within(setup).getByRole('button', { name: 'Create loan' }));
  fireEvent.click(within(setup).getByRole('button', { name: /Creat/ }));

  await waitFor(() => expect(mocks.setUpLoan).toHaveBeenCalledTimes(1));
  await waitFor(() => expect(mocks.setUpLoan).toHaveBeenCalledWith(9, { import_id: 41, employee_id: 5, name: 'Emma advance',
    starting_balance: '600.0', payment_amount: '50.0' }));
  // The server always uses this payroll's pay date, so the form never sends one.
  expect(mocks.setUpLoan.mock.calls[0][1]).not.toHaveProperty('first_deduction_date');
  await waitFor(() => expect(mocks.rematchImport).toHaveBeenCalledWith(9, 'Matched again after Elena Mercer’s installment loan was set up'));
  expect(await screen.findByText('Elena Mercer’s installment loan is set up and matches this import.')).toBeTruthy();
  expect(screen.queryAllByRole('region', { name: 'Installment loan for Elena Mercer' })).toHaveLength(0);
  expect(screen.getAllByText('Matched loan: Emma advance').length).toBeGreaterThan(0);
  expect((screen.getAllByLabelText('Outcome for Mercer, Elena')[0] as HTMLSelectElement).value).toBe('included');
});

it('keeps staff’s job picks when a loan setup matches the files again', async () => {
  const options = [{ id: 1, label: 'Hourly rate', rate: 12 }, { id: 2, label: 'Joint', rate: 12 }];
  const kai = (sourceRowId: number): ImportPreviewRow => emma({ source_row_id: sourceRowId, employee_id: 6, employee_name: 'Kai Frontline', pdf_employee_name: 'Frontline, Kai',
    installment_payment: 0, wage_rate_options: options, selected_wage_rate_id: 1, wage_rate_needs_review: true, wage_rate_default_source: 'Primary job (Hourly rate).' });
  const kaiSource = (id: number): MosaSourceRow => ({ ...emmaSource(id), source_employee_name: 'Frontline, Kai', employee_id: 6 });
  mocks.setUpLoan.mockResolvedValue({ loan_id: 77, already_set_up: false });
  mocks.rematchImport.mockResolvedValue(preview([emmaSource(11), kaiSource(12)], [emma({ source_row_id: 11 }), kai(12)], 2));
  open(preview([emmaSource(1, createOffer.message), kaiSource(2)], [emma({ installment_loan_setup: createOffer }), kai(2)]));

  fireEvent.change(screen.getAllByLabelText('Job and rate for Kai Frontline')[0], { target: { value: '2' } });
  const setup = screen.getAllByRole('region', { name: 'Installment loan for Elena Mercer' })[0];
  fireEvent.click(within(setup).getByRole('button', { name: 'Set up installment loan' }));
  expect((within(setup).getByLabelText('First deduction pay date') as HTMLInputElement).readOnly).toBe(true);
  fireEvent.click(within(setup).getByRole('button', { name: 'Create loan' }));

  expect(await screen.findByText('Elena Mercer’s installment loan is set up and matches this import.')).toBeTruthy();
  expect((screen.getAllByLabelText('Job and rate for Kai Frontline')[0] as HTMLSelectElement).value).toBe('2');
  expect(screen.queryByText('Hours on the primary job for 1 worker')).toBeNull();
});

it('checks the figures before sending and shows a refused setup in the form without matching again', async () => {
  mocks.setUpLoan.mockRejectedValue(new ApiError('Elena Mercer isn’t active. Reactivate them before setting up the loan.', 422));
  open(preview([emmaSource(1, createOffer.message)], [emma({ installment_loan_setup: createOffer })]));
  const setup = screen.getAllByRole('region', { name: 'Installment loan for Elena Mercer' })[0];
  fireEvent.click(within(setup).getByRole('button', { name: 'Set up installment loan' }));

  fireEvent.change(within(setup).getByLabelText('Payment per payroll'), { target: { value: '700' } });
  fireEvent.click(within(setup).getByRole('button', { name: 'Create loan' }));
  expect(within(setup).getByRole('alert').textContent).toBe('The payment per payroll can’t be more than the starting balance.');
  expect(mocks.setUpLoan).not.toHaveBeenCalled();

  fireEvent.change(within(setup).getByLabelText('Payment per payroll'), { target: { value: '50' } });
  fireEvent.click(within(setup).getByRole('button', { name: 'Create loan' }));
  expect((await within(setup).findByRole('alert')).textContent).toBe('Elena Mercer isn’t active. Reactivate them before setting up the loan.');
  expect(mocks.rematchImport).not.toHaveBeenCalled();
});

it('offers to resume a paused loan instead of adding another', async () => {
  const resume: InstallmentLoanSetupOffer = { action: 'resume', employee_loan_id: 70, name: 'Emma loan', current_balance: '600.0', payment_amount: '50.0',
    message: 'Emma loan for Elena Mercer is paused in Employee Loans. Resume it so this payroll deducts the installment.' };
  mocks.setUpLoan.mockResolvedValue({ loan_id: 70, already_set_up: false });
  mocks.rematchImport.mockResolvedValue(preview([emmaSource(11)], [emma({ source_row_id: 11 })], 2));
  open(preview([emmaSource(1, resume.message)], [emma({ installment_loan_setup: resume })]));

  const setup = screen.getAllByRole('region', { name: 'Installment loan for Elena Mercer' })[0];
  expect(within(setup).getByText(/Emma loan is paused in Employee Loans with \$600\.00 left/)).toBeTruthy();
  expect(within(setup).queryByRole('button', { name: 'Set up installment loan' })).toBeNull();
  fireEvent.click(within(setup).getByRole('button', { name: 'Resume Emma loan' }));

  await waitFor(() => expect(mocks.setUpLoan).toHaveBeenCalledWith(9, { import_id: 41, employee_id: 5 }));
  await waitFor(() => expect(mocks.rematchImport).toHaveBeenCalledWith(9, 'Matched again after Emma loan for Elena Mercer was resumed'));
  expect(await screen.findByText('Emma loan for Elena Mercer is resumed and matches this import.')).toBeTruthy();
});

it('tells staff who cannot set up loans why, instead of showing the button', () => {
  open(preview([emmaSource(1, createOffer.message)], [emma({ installment_loan_setup: createOffer })], 1,
    { allowed: false, reason: 'Your access can’t set up employee loans for this client. Ask an admin to set up the loan in Employee Loans, then match the files again.' }));
  const setup = screen.getAllByRole('region', { name: 'Installment loan for Elena Mercer' })[0];
  expect(within(setup).getByText(/Ask an admin to set up the loan in Employee Loans/)).toBeTruthy();
  expect(within(setup).queryByRole('button')).toBeNull();
});

it('shows other loan problems on a matched row', () => {
  const message = 'The workbook has 2 installment loan rows for Elena Mercer. Ask the client to combine them into one row, or set up the loans in Employee Loans.';
  open(preview([emmaSource(1, message)], [emma()]));
  expect(screen.getAllByText(message).length).toBeGreaterThan(0);
});

it('defaults equal-rate jobs to the primary job without blocking Apply, and sends a department job staff choose', async () => {
  const options = [{ id: 1, label: 'Hourly rate', rate: 12 }, { id: 2, label: 'Joint', rate: 12 }];
  const row = emma({ installment_payment: 0, wage_rate_options: options, selected_wage_rate_id: 1, wage_rate_needs_review: true,
    wage_rate_default_source: 'Primary job (Hourly rate). The last committed payroll doesn’t show one job. Every job pays the same rate; change the job if these hours belong to another.' });
  mocks.applyImport.mockResolvedValue({ results: { success: [{ employee_id: 5, name: 'Elena Mercer' }], skipped: [], errors: [] }, pay_period: { id: 9 } });
  open(preview([{ ...emmaSource(1), disposition: 'included' }], [row]));

  expect(screen.getByText('Hours on the primary job for 1 worker')).toBeTruthy();
  expect(screen.queryByText(/Choose job and rate for/)).toBeNull();
  const select = screen.getAllByLabelText('Job and rate for Elena Mercer')[0] as HTMLSelectElement;
  expect(select.value).toBe('1');
  fireEvent.change(select, { target: { value: '2' } });
  expect(screen.queryByText('Hours on the primary job for 1 worker')).toBeNull();

  fireEvent.click(screen.getByRole('button', { name: /Apply/ }));
  await waitFor(() => expect(mocks.applyImport).toHaveBeenCalledWith(9, expect.objectContaining({ wage_rate_choices: { 5: 2 } })));
});
