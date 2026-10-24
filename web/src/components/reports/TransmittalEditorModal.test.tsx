// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { useState } from 'react';
import userEvent from '@testing-library/user-event';
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

it('submits an explicitly cleared final non-employee check override', async () => {
  api.preview.mockResolvedValue({ ...preview, non_employee_checks: [{ id: 8, payable_to: 'Synthetic Treasurer', amount: 207.09, check_type: 'tax_deposit', check_number: null }],
    saved_transmittal: { ...preview.saved_transmittal, non_employee_check_numbers: { '8': 'MANUAL987' } } });
  const generate = vi.fn();
  render(<TransmittalEditorModal open onClose={vi.fn()} onGenerate={generate} targetLabel="Full Print Package" fixedReports payPeriodId={2} onOpenForm500={vi.fn()} />);
  fireEvent.change(await screen.findByDisplayValue('MANUAL987'), { target: { value: '' } });
  fireEvent.click(screen.getByRole('button', { name: 'Generate Full Print Package' }));
  expect(generate.mock.calls[0][0].nonEmployeeCheckNumbers).toEqual({ 8: '' });
});

it('gives the package editor the shared modal focus contract and restores its trigger', async () => {
  api.preview.mockResolvedValue(preview);
  vi.spyOn(HTMLElement.prototype, 'offsetParent', 'get').mockImplementation(function (this: HTMLElement) { return this.parentElement; });
  const user = userEvent.setup();
  function Package() {
    const [open, setOpen] = useState(false);
    return <><button onClick={() => setOpen(true)}>Edit package</button><TransmittalEditorModal open={open} onClose={() => setOpen(false)} onGenerate={vi.fn()} targetLabel="Full Print Package" fixedReports payPeriodId={2} onOpenForm500={vi.fn()} /></>;
  }
  const { container } = render(<Package />);
  const trigger = screen.getByRole('button', { name: 'Edit package' });
  await user.click(trigger);
  const dialog = screen.getByRole('dialog', { name: 'Edit Full Print Package' });
  expect(dialog.getAttribute('aria-modal')).toBe('true');
  await screen.findByDisplayValue('Saved preparer');
  await waitFor(() => expect(dialog.contains(document.activeElement)).toBe(true));
  expect(container.closest('[inert]')).not.toBeNull();
  const close = within(dialog).getByRole('button', { name: 'Close Full Print Package editor' });
  close.focus();
  await user.tab({ shift: true });
  expect(document.activeElement).toBe(within(dialog).getByRole('button', { name: 'Generate Full Print Package' }));
  await user.tab();
  expect(document.activeElement).toBe(close);
  await user.keyboard('{Escape}');
  await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
  expect(document.activeElement).toBe(trigger);
  expect(container.closest('[inert]')).toBeNull();
  vi.restoreAllMocks();
});
