// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
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
beforeEach(() => { vi.clearAllMocks(); mocks.employees.mockResolvedValue([]); mocks.submit.mockResolvedValue({ data: period, outcome: 'created' }); });
afterEach(cleanup);
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
