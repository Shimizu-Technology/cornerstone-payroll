// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { TransmittalEditorModal } from './ReportsDownloadPanel';
const api = vi.hoisted(() => ({ preview: vi.fn() }));
vi.mock('@/services/api', () => ({ transmittalApi: api, reportsApi: {} }));
afterEach(() => { cleanup(); vi.clearAllMocks(); });
const preview = { company: { name: 'Synthetic Payroll' }, payroll_checks: { numbers: [], count: 0 }, non_employee_checks: [], tax_totals: { fit: 207.09, total_fica: 611.50 }, saved_transmittal: { preparer_name: 'Saved preparer', notes: [], report_list: ['Custom standalone enclosure'], payroll_check_numbers: [], custom_entries: [] } };
it('shows the actual fixed package inventory while preserving intentionally empty notes', async () => {
  api.preview.mockResolvedValue(preview);
  const generate = vi.fn();
  render(<TransmittalEditorModal open onClose={vi.fn()} onGenerate={generate} targetLabel="Full Print Package" fixedReports payPeriodId={2} onOpenForm500={vi.fn()} />);
  await screen.findByDisplayValue('Saved preparer');
  const report = await screen.findByRole('textbox', { name: 'Included report 5' });
  expect((report as HTMLInputElement).value).toBe('Employee Installment Loan Report');
  expect((report as HTMLInputElement).readOnly).toBe(true);
  expect(screen.queryByPlaceholderText('Add a report...')).toBeNull();
  expect(screen.getByPlaceholderText('Add a note...')).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: 'Generate Full Print Package' }));
  await waitFor(() => expect(generate).toHaveBeenCalled());
  expect(generate.mock.calls[0][0].notes).toEqual([]);
  expect(generate.mock.calls[0][0].reportList).toHaveLength(5);
});
it('keeps standalone cover enclosures editable', async () => {
  api.preview.mockResolvedValue(preview);
  render(<TransmittalEditorModal open onClose={vi.fn()} onGenerate={vi.fn()} targetLabel="Transmittal Log" payPeriodId={2} onOpenForm500={vi.fn()} />);
  await screen.findByDisplayValue('Saved preparer');
  const report = await screen.findByRole('textbox', { name: 'Included report 1' });
  expect((report as HTMLInputElement).value).toBe('Custom standalone enclosure');
  expect((report as HTMLInputElement).readOnly).toBe(false);
  expect(screen.getByPlaceholderText('Add a report...')).toBeTruthy();
});

it('blocks generation on an unavailable saved cover and allows retry', async () => {
  api.preview.mockRejectedValueOnce(new Error('Offline')).mockResolvedValue(preview);
  const generate = vi.fn();
  render(<TransmittalEditorModal open onClose={vi.fn()} onGenerate={generate} targetLabel="Full Print Package" fixedReports payPeriodId={2} onOpenForm500={vi.fn()} />);
  await screen.findByRole('alert');
  expect((screen.getByRole('button', { name: 'Generate Full Print Package' }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.click(screen.getByRole('button', { name: 'Retry cover details' }));
  await screen.findByDisplayValue('Saved preparer');
  fireEvent.click(screen.getByRole('button', { name: 'Generate Full Print Package' }));
  expect(generate).toHaveBeenCalledTimes(1);
});
