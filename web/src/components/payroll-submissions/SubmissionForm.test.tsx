// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { webcrypto } from 'node:crypto';
import { SubmissionForm } from './SubmissionForm';
import type { PeriodDetail, SubmissionRevision } from '@/services/payrollSubmissions';
import type { ClientDocument } from '@/services/api';

const mocks = vi.hoisted(() => ({ submit: vi.fn(), employees: vi.fn(), downloadTemplate: vi.fn() }));
vi.mock('@/services/payrollSubmissions', async original => ({
  ...await original<typeof import('@/services/payrollSubmissions')>(),
  clientPayrollSubmissionsApi: mocks,
}));
const period = { ref: '9', submissions: [] } as unknown as PeriodDetail;
const pdf = () => new File(['%PDF'], 'revel.pdf', { type: 'application/pdf' });
const workbook = () => new File(['workbook'], 'tips.XLSX');
beforeEach(() => { vi.stubGlobal('crypto', webcrypto); vi.clearAllMocks(); mocks.employees.mockResolvedValue([]); mocks.submit.mockResolvedValue({ data: period, outcome: 'created' }); mocks.downloadTemplate.mockResolvedValue({ blob: new Blob(['csv']), filename: 'workbook.csv' }); });
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });
const send = () => fireEvent.click(screen.getByRole('button', { name: 'Send to Cornerstone' }));
const uploadPdf = () => fireEvent.change(screen.getByLabelText('Revel hours report (PDF)'), { target: { files: [pdf()] } });

it('requires the workbook choice even with no structured changes', async () => {
  render(<SubmissionForm period={period} onSent={vi.fn()} />);
  uploadPdf(); fireEvent.click(screen.getByLabelText('No changes this period')); send();
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Choose a workbook, a link, or no tips or loans this period');
  expect(mocks.submit).not.toHaveBeenCalled();
});

it.each(['attach', 'link', 'none'] as const)('sends an explicit %s choice independently of no changes', async choice => {
  render(<SubmissionForm period={period} onSent={vi.fn()} />);
  uploadPdf(); fireEvent.click(screen.getByLabelText('No changes this period'));
  fireEvent.click(screen.getByLabelText({ attach: 'Attach the workbook', link: 'Send a link instead', none: 'No tips or loans this period' }[choice]));
  if (choice === 'attach') fireEvent.change(screen.getByLabelText('Tips & loans workbook (Excel)'), { target: { files: [workbook()] } });
  if (choice === 'link') fireEvent.change(screen.getByLabelText('Workbook link (https://)'), { target: { value: 'https://example.test/workbook' } });
  send(); await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
  const form = mocks.submit.mock.calls[0][1] as FormData;
  expect(form.get('workbook_choice')).toBe(choice); expect(form.get('no_changes')).toBe('true');
  expect(form.get('changes')).toBe('[]');
  expect(form.get('changes_workbook') !== null).toBe(choice === 'attach');
  expect(form.get('changes_link_url') !== null).toBe(choice === 'link');
});

it('asks about Excel in Other files and moves it into the visible workbook slot', async () => {
  render(<SubmissionForm period={period} onSent={vi.fn()} />);
  uploadPdf();
  const otherFiles = screen.getByLabelText('Other files') as HTMLInputElement;
  await userEvent.upload(otherFiles, workbook());
  expect(otherFiles.value).toContain('tips.XLSX');
  expect(screen.getByText(/Is this the tips & loans workbook/)).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Yes, move to workbook slot' }));
  expect(screen.getByLabelText('Attach the workbook')).toHaveProperty('checked', true);
  expect(screen.getByText('Selected: tips.XLSX')).toBeTruthy();
  expect(otherFiles.value).toBe('');
  fireEvent.click(screen.getByLabelText('No changes this period'));
  send(); await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
  const form = mocks.submit.mock.calls[0][1] as FormData;
  expect(form.get('changes_workbook')).toBeTruthy(); expect(form.getAll('attachments[]')).toEqual([]);
});

it('carries both source slots forward and lets the client explicitly replace the workbook choice', async () => {
  const current = { id: 1, revision: 1, current: true, superseded: false, submitted_at: '2026-11-14T00:00:00Z', no_changes: true, workbook_choice: 'attach', changes: [], documents: [
    { role: 'revel_payroll', file_size: 1, file_name: 'revel.pdf', document: { id: 1 } as ClientDocument },
    { role: 'changes_workbook', file_size: 1, file_name: 'tips.xlsx', document: { id: 2 } as ClientDocument },
  ] } as SubmissionRevision;
  render(<SubmissionForm period={period} current={current} onSent={vi.fn()} />);
  fireEvent.click(screen.getByRole('button', { name: 'Send update' }));
  await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
  expect((mocks.submit.mock.calls[0][1] as FormData).getAll('keep_document_ids[]')).toEqual(['1', '2']);
  fireEvent.click(screen.getByLabelText('No tips or loans this period'));
  fireEvent.click(screen.getByRole('button', { name: 'Send update' }));
  await waitFor(() => expect(mocks.submit).toHaveBeenCalledTimes(2));
  expect((mocks.submit.mock.calls[1][1] as FormData).getAll('keep_document_ids[]')).toEqual(['1']);
});

it('reuses an interrupted submission key only for identical bytes', async () => {
  mocks.submit.mockRejectedValue(new Error('Connection interrupted'));
  render(<SubmissionForm period={period} onSent={vi.fn()} />);
  uploadPdf();
  fireEvent.click(screen.getByLabelText('No changes this period'));
  fireEvent.click(screen.getByLabelText('Attach the workbook'));
  const input = screen.getByLabelText('Tips & loans workbook (Excel)');
  fireEvent.change(input, { target: { files: [new File(['original'], 'tips.xlsx', { lastModified: 1 })] } });
  send(); await screen.findByText('Connection interrupted');
  const firstKey = (mocks.submit.mock.calls[0][1] as FormData).get('idempotency_key');
  send(); await waitFor(() => expect(mocks.submit).toHaveBeenCalledTimes(2));
  await screen.findByText('Connection interrupted');
  expect((mocks.submit.mock.calls[1][1] as FormData).get('idempotency_key')).toBe(firstKey);
  fireEvent.change(input, { target: { files: [new File(['correct!'], 'tips.xlsx', { lastModified: 1 })] } });
  send(); await waitFor(() => expect(mocks.submit).toHaveBeenCalledTimes(3));
  expect((mocks.submit.mock.calls[2][1] as FormData).get('idempotency_key')).not.toBe(firstKey);
});

const keptRevision = { id: 1, revision: 1, current: true, superseded: false, submitted_at: '2026-11-14T00:00:00Z', no_changes: true, workbook_choice: 'attach', changes: [], documents: [
  { role: 'revel_payroll', file_size: 1, file_name: 'revel.pdf', document: { id: 1 } as ClientDocument },
  { role: 'changes_workbook', file_size: 1, file_name: 'old.xlsx', document: { id: 2 } as ClientDocument },
] } as SubmissionRevision;

it('prompts for corrected Excel despite a kept workbook and replaces the kept source', async () => {
  render(<SubmissionForm period={period} current={keptRevision} onSent={vi.fn()} />);
  await userEvent.upload(screen.getByLabelText('Other files'), workbook());
  fireEvent.click(screen.getByRole('button', { name: 'Send update' }));
  expect(mocks.submit).not.toHaveBeenCalled();
  expect(screen.getByRole('alert').textContent).toContain('confirm it is supporting material');
  fireEvent.click(screen.getByRole('button', { name: 'Use this as the tips & loans workbook (replaces the one from revision 1)' }));
  fireEvent.click(screen.getByRole('button', { name: 'Send update' }));
  await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
  const form = mocks.submit.mock.calls[0][1] as FormData;
  expect(form.getAll('keep_document_ids[]')).toEqual(['1']);
  expect((form.get('changes_workbook') as File).name).toBe('tips.XLSX');
  expect(form.getAll('attachments[]')).toEqual([]);
});

it('retains new Excel with the old workbook only after explicit supporting-material confirmation', async () => {
  render(<SubmissionForm period={period} current={keptRevision} onSent={vi.fn()} />);
  await userEvent.upload(screen.getByLabelText('Other files'), workbook());
  fireEvent.click(screen.getByLabelText('These Excel files are supporting material, not the tips & loans workbook'));
  fireEvent.click(screen.getByRole('button', { name: 'Send update' }));
  await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
  const form = mocks.submit.mock.calls[0][1] as FormData;
  expect(form.get('excel_attachments_supporting')).toBe('true');
  expect(form.getAll('keep_document_ids[]')).toEqual(['1', '2']);
  expect(form.getAll('attachments[]')).toHaveLength(1);
});

it('requires a change row or No changes independently of the workbook answer', async () => {
  render(<SubmissionForm period={period} onSent={vi.fn()} />);
  uploadPdf(); fireEvent.click(screen.getByLabelText('No tips or loans this period')); send();
  expect(screen.getByRole('alert').textContent).toBe('List the changes this period or choose "No changes this period"');
  expect(mocks.submit).not.toHaveBeenCalled();
  fireEvent.click(screen.getByLabelText('No changes this period')); send();
  await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
});

it('starts with every-period rows, blank amounts and a last-period hint; sends a filled row and explicit skip', async () => {
  mocks.employees.mockResolvedValue([{ id: 122, name: 'Morgan Owner' }, { id: 135, name: 'Sloane Owner' }]);
  const defaults: PeriodDetail = { ...period, standing_changes: [
    { kind: 'owner_pay', standing_change_id: 1, employee_id: 122, employee_name: 'Morgan Owner', last_period_amount: '4500.00' },
    { kind: 'owner_pay', standing_change_id: 2, employee_id: 135, employee_name: 'Sloane Owner' },
  ] };
  render(<SubmissionForm period={defaults} onSent={vi.fn()} />);
  await screen.findByText('Morgan Owner (optional)');

  expect((screen.getByLabelText('Amount ($): Morgan Owner') as HTMLInputElement).value).toBe('');
  fireEvent.change(screen.getByLabelText('Amount ($): Morgan Owner'), { target: { value: '8000.12' } });
  fireEvent.click(screen.getByLabelText('None this period: Sloane Owner'));
  uploadPdf(); fireEvent.click(screen.getByLabelText('No tips or loans this period')); send();
  await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
  const rows = JSON.parse((mocks.submit.mock.calls[0][1] as FormData).get('changes') as string);
  expect(rows[0]).toMatchObject({ employee_id: 122, standing_change_id: 1, amount: '8000.12' });
  expect(rows[1]).toMatchObject({ employee_id: 135, standing_change_id: 2, skipped: true });
  expect(rows[0].last_period_amount).toBeUndefined();
});

it('requires configured answers even when No changes is checked', async () => {
  const defaults: PeriodDetail = { ...period, standing_changes: [{ kind: 'owner_pay', standing_change_id: 1, employee_id: 122, employee_name: 'Morgan Owner', required: true }] };
  render(<SubmissionForm period={defaults} onSent={vi.fn()} />);
  uploadPdf(); fireEvent.click(screen.getByLabelText('No tips or loans this period')); send();
  expect(mocks.submit).not.toHaveBeenCalled();
  expect(screen.getAllByRole('alert')[0].textContent).toContain('Complete each required');
  fireEvent.click(screen.getByLabelText('No changes this period')); send();
  expect(mocks.submit).not.toHaveBeenCalled();
  fireEvent.click(screen.getByLabelText('None this period: Morgan Owner')); send();
  await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
  expect(JSON.parse((mocks.submit.mock.calls[0][1] as FormData).get('changes') as string)).toEqual([expect.objectContaining({ standing_change_id: 1, skipped: true })]);
});

it('adds per-person owner pay and extra hours on an explicitly selected saved job', async () => {
  mocks.employees.mockResolvedValue([{ id: 173, name: 'Jordan Worker', wage_rates: [{ id: 7, label: 'Maintenance', rate: '35.0' }] }]);
  render(<SubmissionForm period={period} onSent={vi.fn()} />);
  await waitFor(() => expect(mocks.employees).toHaveBeenCalled());
  fireEvent.click(screen.getByRole('button', { name: 'Add change' }));
  fireEvent.change(screen.getByLabelText('Employee'), { target: { value: '173' } });
  fireEvent.change(screen.getByLabelText('Saved job and rate'), { target: { value: '7' } });
  fireEvent.change(screen.getByLabelText('Hours'), { target: { value: '68' } });
  uploadPdf(); fireEvent.click(screen.getByLabelText('No tips or loans this period')); send();
  await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
  expect(JSON.parse((mocks.submit.mock.calls[0][1] as FormData).get('changes') as string)).toEqual([expect.objectContaining({ employee_id: 173, employee_wage_rate_id: 7, hours: '68' })]);
});

it('hides unavailable fields from the client', () => {
  render(<SubmissionForm period={{ ...period, standing_changes: [{ kind: 'extra_hours', standing_change_id: 1, employee_id: 173, employee_name: 'Jordan Worker', availability_error: 'Saved job and rate are missing or inactive.' }] }} onSent={vi.fn()} />);
  expect(screen.queryByText(/Jordan Worker/)).toBeNull();
  expect(screen.queryByLabelText('Saved job and rate')).toBeNull();
});


it('drops an answered configured field omitted from the client list and sends the update', async () => {
  const onSent = vi.fn();
  const current = { ...keptRevision, changes: [
    { kind: 'owner_pay', employee_id: 122, standing_change_id: 9, label: 'Hidden owner pay', amount: '5000' },
    { kind: 'owner_pay', employee_id: 135, standing_change_id: 8, skipped: true },
  ] } as SubmissionRevision;
  render(<SubmissionForm period={{ ...period, standing_changes: [] }} current={current} onSent={onSent} />);
  expect(screen.queryByText('Hidden owner pay')).toBeNull();
  expect(screen.queryByLabelText('Amount ($)')).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: 'Send update' }));
  await waitFor(() => expect(onSent).toHaveBeenCalledOnce());
  expect(JSON.parse((mocks.submit.mock.calls[0][1] as FormData).get('changes') as string)).toEqual([]);
});

it('shows configured help without employee pickers and respects allow_none', async () => {
  render(<SubmissionForm period={{ ...period, standing_changes: [{ kind: 'owner_pay', standing_change_id: 1, employee_id: 122, label: 'Period owner pay', help_text: 'Pay for these dates only', required: true, allow_none: false }] }} onSent={vi.fn()} />);
  expect(screen.getByText('Pay for these dates only')).toBeTruthy();
  expect(screen.queryByLabelText('Employee')).toBeNull();
  expect(screen.queryByLabelText(/None this period/)).toBeNull();
  uploadPdf(); fireEvent.click(screen.getByLabelText('No tips or loans this period'));
  fireEvent.click(screen.getByLabelText('No changes this period'));
  fireEvent.change(screen.getByLabelText('Amount ($): Period owner pay'), { target: { value: '1400' } }); send();
  await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
  expect(JSON.parse((mocks.submit.mock.calls[0][1] as FormData).get('changes') as string)).toEqual([expect.objectContaining({standing_change_id: 1, employee_id: 122, amount: '1400'})]);
});

it('reopens a carried none when the field now requires a value', async () => {
  const field = { kind: 'owner_pay' as const, employee_id: 122, standing_change_id: 1, label: 'Mo pay', required: true, allow_none: false };
  render(<SubmissionForm period={{ ...period, standing_changes: [field] }} current={{ ...keptRevision, changes: [{ ...field, skipped: true }] }} onSent={vi.fn()} />);
  const input = screen.getByLabelText('Amount ($): Mo pay');
  expect(input).toHaveProperty('disabled', false);
  expect(input.getAttribute('aria-required')).toBe('true');
  expect(screen.queryByLabelText(/None this period/)).toBeNull();
  fireEvent.change(input, { target: { value: '1200' } });
  fireEvent.click(screen.getByRole('button', { name: 'Send update' }));
  await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
  expect(JSON.parse((mocks.submit.mock.calls[0][1] as FormData).get('changes') as string)[0]).not.toHaveProperty('skipped');
});

it('shows indexed server change errors only in the summary after rows are filtered', async () => {
  mocks.submit.mockRejectedValueOnce({ message: 'Check changes', data: { details: { 'changes.1': ['Server first row error'] } } });
  const fields: PeriodDetail = { ...period, standing_changes: [{ kind: 'owner_pay', standing_change_id: 1, employee_id: 122, label: 'Mo pay', required: true }] };
  render(<SubmissionForm period={fields} onSent={vi.fn()} />);
  uploadPdf();
  fireEvent.click(screen.getByLabelText('No tips or loans this period'));
  fireEvent.change(screen.getByLabelText('Amount ($): Mo pay'), { target: { value: '100' } });
  fireEvent.change(screen.getByLabelText('Add a change'), { target: { value: 'wage_change' } });
  fireEvent.click(screen.getByRole('button', { name: 'Add change' }));
  send();
  await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
  expect(screen.getAllByText('Server first row error')).toHaveLength(1);
  expect(screen.getByText('Server first row error').closest('li')).toBeNull();
});

it('renders upload slots, labels, accept filters, and required checks from a custom intake descriptor', async () => {
  const customPeriod: PeriodDetail = {
    ...period,
    intake_descriptor: {
      key: 'cornerstone_workbook',
      label: 'Cornerstone workbook',
      source_label: 'Cornerstone universal workbook',
      parser_version: 'cornerstone_workbook:v1',
      extraction: 'deterministic',
      accepts_pasted_text: false,
      tracks_reviewed_hours: true,
      employee_match: 'employee_id',
      idempotency: 'files_and_workweek',
      reports_overtime: true,
      tips_default: 'paid_in_check',
      overtime_mode: 'source_reports',
      workweek_alignment: 'aligned',
      required_sources: ['universal_workbook'],
      files: [
        {
          role: 'universal_workbook',
          label: 'Cornerstone workbook',
          hint: 'Upload the completed Excel or CSV payroll workbook.',
          accept: ['.xlsx', '.csv'],
          content_type: null,
          max: 1,
          required: true,
          required_by_default: true,
          waivable: null,
          portal_role: 'payroll_workbook',
          portal_label: 'Payroll hours & changes workbook',
          portal_hint: 'Upload the completed Excel or CSV payroll workbook.',
          supports_link: false,
          template_formats: ['xlsx', 'csv'],
          provides: ['regular_hours', 'overtime_hours', 'reported_tips'],
        },
      ],
      portal: { submittable: true, role_map: { payroll_workbook: 'universal_workbook' } },
    },
  };

  const createObjectURL = vi.fn(() => 'blob:mock-url');
  const revokeObjectURL = vi.fn();
  vi.stubGlobal('URL', { ...URL, createObjectURL, revokeObjectURL });

  render(<SubmissionForm period={customPeriod} onSent={vi.fn()} />);
  expect(screen.queryByLabelText('Revel hours report (PDF)')).toBeNull();
  expect(screen.queryByLabelText('Attach the workbook')).toBeNull();
  const input = screen.getByLabelText('Payroll hours & changes workbook') as HTMLInputElement;
  expect(input.accept).toBe('.xlsx,.csv');

  fireEvent.click(screen.getByRole('button', { name: 'Download Excel template (.xlsx)' }));
  await waitFor(() => expect(mocks.downloadTemplate).toHaveBeenCalledWith('9', 'xlsx'));
  fireEvent.click(screen.getByRole('button', { name: 'Download CSV template (.csv)' }));
  await waitFor(() => expect(mocks.downloadTemplate).toHaveBeenCalledWith('9', 'csv'));

  fireEvent.click(screen.getByLabelText('No changes this period'));
  send();
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Attach the Payroll hours & changes workbook');
  expect(mocks.submit).not.toHaveBeenCalled();

  const file = new File(['employee_id,hours\n1,80\n'], 'payroll.csv', { type: 'text/csv' });
  fireEvent.change(input, { target: { files: [file] } });
  send();
  await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
  const form = mocks.submit.mock.calls[0][1] as FormData;
  expect((form.get('payroll_workbook') as File).name).toBe('payroll.csv');
  expect(form.get('workbook_choice')).toBeNull();
});

it('keeps the Revel PDF labeled and enforced as required even when required_sources marks it false (M3)', async () => {
  const relaxedPeriod: PeriodDetail = {
    ...period,
    intake_descriptor: {
      key: 'mosa_revel',
      label: 'Revel hours + Cornerstone workbook',
      source_label: 'Revel Payroll + Cornerstone Workbook',
      extraction: 'deterministic',
      accepts_pasted_text: false,
      tracks_reviewed_hours: true,
      employee_match: 'name_fuzzy',
      reports_overtime: true,
      tips_default: 'paid_in_check',
      overtime_mode: 'source_reports',
      workweek_alignment: 'warn_if_offset',
      required_sources: [],
      files: [
        {
          role: 'revel_hours',
          label: 'Revel hours PDF',
          hint: 'Hours worked, including overtime, from Revel.',
          accept: ['.pdf'],
          content_type: 'application/pdf',
          max: 1,
          required: false,
          required_by_default: true,
          waivable: null,
          portal_role: 'revel_payroll',
          portal_label: 'Revel hours report (PDF)',
          portal_hint: 'Hours worked, including overtime, from Revel.',
          supports_link: false,
          provides: ['regular_hours', 'overtime_hours'],
        },
      ],
      portal: { submittable: true, role_map: { revel_payroll: 'revel_hours' } },
    },
  };

  render(<SubmissionForm period={relaxedPeriod} onSent={vi.fn()} />);
  expect(screen.getByText('(required)')).toBeTruthy();
  expect(screen.queryByText('(optional)')).toBeNull();

  fireEvent.click(screen.getByLabelText('No changes this period'));
  send();
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', 'Attach the Revel payroll PDF');
  expect(mocks.submit).not.toHaveBeenCalled();
});
