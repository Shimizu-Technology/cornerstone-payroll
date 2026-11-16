// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { ClientPayrollReview } from './ClientPayrollReview';
import { clientPayPeriodsApi } from '@/services/api';
import type { PayPeriod } from '@/types';
vi.mock('@/services/api', () => ({ clientPayPeriodsApi: { approveReview: vi.fn(), requestChanges: vi.fn(), previewPdf: vi.fn() } }));
vi.mock('@/components/documents/PdfPreview', () => ({ PdfPreview: () => null }));
const period = { id: 5, status: 'approved', total_gross: 1200, total_net: 1100,
  payroll_review: { id: 11, revision: 2, status: 'pending', published_at: '2026-11-17T00:00:00Z', checksum_short: 'abc123', acknowledgement: 'I approve this exact payroll review revision for processing.' },
} as PayPeriod;
const onDone = vi.fn();
beforeEach(() => { vi.resetAllMocks(); });
afterEach(cleanup);
it('requires acknowledgement for approval and binds it to the displayed revision', async () => {
  render(<ClientPayrollReview payPeriod={period} companyId={3} onDone={onDone} />);
  const approve = screen.getByRole('button', { name: 'Approve this revision' }) as HTMLButtonElement;
  expect(approve.disabled).toBe(true);
  fireEvent.click(screen.getByRole('checkbox'));
  fireEvent.click(approve);
  await waitFor(() => expect(clientPayPeriodsApi.approveReview).toHaveBeenCalledWith(5, 3, { revision_id: 11, acknowledgement: period.payroll_review!.acknowledgement, notes: undefined }));
  expect(onDone).toHaveBeenCalled();
});
it('requires a change note and preserves it after a failed request', async () => {
  vi.mocked(clientPayPeriodsApi.requestChanges).mockRejectedValueOnce(new Error('Connection lost'));
  render(<ClientPayrollReview payPeriod={period} companyId={3} onDone={onDone} />);
  const request = screen.getByRole('button', { name: 'Request changes' }) as HTMLButtonElement;
  expect(request.disabled).toBe(true);
  const note = screen.getByLabelText('Note for Cornerstone (required to request changes)');
  fireEvent.change(note, { target: { value: 'Add two hours' } });
  fireEvent.click(request);
  expect(await screen.findByText('Connection lost')).toBeTruthy();
  expect(note).toHaveProperty('value', 'Add two hours');
  expect(clientPayPeriodsApi.requestChanges).toHaveBeenCalledWith(5, 3, { revision_id: 11, note: 'Add two hours' });
});
it('offers the audited current preview and keeps a prior request visible in history', async () => {
  vi.mocked(clientPayPeriodsApi.previewPdf).mockResolvedValue({ blob: new Blob(), filename: 'preview.pdf' });
  render(<ClientPayrollReview payPeriod={{ ...period, payroll_review_history: [{ ...period.payroll_review!, id: 10, revision: 1, status: 'superseded', change_request_note: 'Earlier request' }] }} companyId={3} onDone={onDone} />);
  fireEvent.click(screen.getByRole('button', { name: 'View preview' }));
  await waitFor(() => expect(clientPayPeriodsApi.previewPdf).toHaveBeenCalledWith(5, 3, 11));
  expect(screen.getByText('Earlier request')).toBeTruthy();
});

it.each(['approve', 'changes', 'preview'])('reloads stale %s and asks for a fresh review while retaining the note', async action => {
  const stale = Object.assign(new Error('Revision changed'), { status: 422 });
  vi.mocked(clientPayPeriodsApi.approveReview).mockRejectedValueOnce(stale);
  vi.mocked(clientPayPeriodsApi.requestChanges).mockRejectedValueOnce(stale);
  vi.mocked(clientPayPeriodsApi.previewPdf).mockRejectedValueOnce(stale);
  render(<ClientPayrollReview payPeriod={period} companyId={3} onDone={onDone} />);
  fireEvent.change(screen.getByLabelText('Note for Cornerstone (required to request changes)'), { target: { value: 'Add two hours' } });
  fireEvent.click(screen.getByRole('checkbox'));
  fireEvent.click(screen.getByRole('button', { name: action === 'approve' ? 'Approve this revision' : action === 'changes' ? 'Request changes' : 'View preview' }));
  expect(await screen.findByText('This payroll was updated. Review the latest preview.')).toBeTruthy();
  await waitFor(() => expect(onDone).toHaveBeenCalledOnce());
  expect(screen.getByRole('checkbox')).toHaveProperty('checked', false);
  expect(screen.getByLabelText('Note for Cornerstone (required to request changes)')).toHaveProperty('value', 'Add two hours');
});
