// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { webcrypto } from 'node:crypto';
import { SubmissionForm } from './SubmissionForm';
import type { PeriodDetail, SubmissionRevision } from '@/services/payrollSubmissions';
import type { ClientDocument } from '@/services/api';

const mocks = vi.hoisted(() => ({ submit: vi.fn(), employees: vi.fn() }));
vi.mock('@/services/payrollSubmissions', async original => ({
  ...await original<typeof import('@/services/payrollSubmissions')>(),
  clientPayrollSubmissionsApi: mocks,
}));
const period = { ref: '9', submissions: [] } as unknown as PeriodDetail;
const pdf = () => new File(['%PDF'], 'revel.pdf', { type: 'application/pdf' });
const workbook = () => new File(['workbook'], 'tips.XLSX');
beforeEach(() => { vi.stubGlobal('crypto', webcrypto); vi.clearAllMocks(); mocks.employees.mockResolvedValue([]); mocks.submit.mockResolvedValue({ data: period, outcome: 'created' }); });
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
  mocks.employees.mockResolvedValue([{ id: 122, name: 'Monique Owner' }, { id: 135, name: 'Sara Owner' }]);
  const defaults: PeriodDetail = { ...period, standing_changes: [
    { kind: 'owner_pay', standing_change_id: 1, employee_id: 122, employee_name: 'Monique Owner', last_period_amount: '8421.13' },
    { kind: 'owner_pay', standing_change_id: 2, employee_id: 135, employee_name: 'Sara Owner' },
  ] };
  render(<SubmissionForm period={defaults} onSent={vi.fn()} />);
  await screen.findByText('Every period · Monique Owner');
  expect(screen.getByText('Last period: $8,421.13')).toBeTruthy();
  expect((screen.getAllByLabelText('Amount ($)')[0] as HTMLInputElement).value).toBe('');
  fireEvent.change(screen.getAllByLabelText('Amount ($)')[0], { target: { value: '8000.12' } });
  fireEvent.click(screen.getAllByLabelText('Not this period')[1]);
  uploadPdf(); fireEvent.click(screen.getByLabelText('No tips or loans this period')); send();
  await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
  const rows = JSON.parse((mocks.submit.mock.calls[0][1] as FormData).get('changes') as string);
  expect(rows[0]).toMatchObject({ employee_id: 122, standing_change_id: 1, amount: '8000.12' });
  expect(rows[1]).toMatchObject({ employee_id: 135, standing_change_id: 2, skipped: true });
  expect(rows[0].last_period_amount).toBeUndefined();
});

it('requires a value or skip for defaults and records No changes as skips without deleting defaults', async () => {
  const defaults: PeriodDetail = { ...period, standing_changes: [{ kind: 'owner_pay', standing_change_id: 1, employee_id: 122, employee_name: 'Monique Owner' }] };
  render(<SubmissionForm period={defaults} onSent={vi.fn()} />);
  uploadPdf(); fireEvent.click(screen.getByLabelText('No tips or loans this period')); send();
  expect(mocks.submit).not.toHaveBeenCalled();
  expect(screen.getByRole('alert').textContent).toContain('positive amount');
  fireEvent.click(screen.getByLabelText('No changes this period')); send();
  await waitFor(() => expect(mocks.submit).toHaveBeenCalledOnce());
  expect(JSON.parse((mocks.submit.mock.calls[0][1] as FormData).get('changes') as string)).toEqual([expect.objectContaining({ standing_change_id: 1, skipped: true })]);
});

it('adds per-person owner pay and extra hours on an explicitly selected saved job', async () => {
  mocks.employees.mockResolvedValue([{ id: 173, name: 'Addison Worker', wage_rates: [{ id: 7, label: 'Maintenance', rate: '35.0' }] }]);
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

it('shows an unavailable default without guessing another employee or rate', () => {
  render(<SubmissionForm period={{ ...period, standing_changes: [{ kind: 'extra_hours', standing_change_id: 1, employee_id: 173, employee_name: 'Addison Worker', availability_error: 'Saved job and rate are missing or inactive.' }] }} onSent={vi.fn()} />);
  expect(screen.getByRole('alert').textContent).toContain('missing or inactive');
  expect((screen.getByLabelText('Saved job and rate') as HTMLSelectElement).value).toBe('');
});
