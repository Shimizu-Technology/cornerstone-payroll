// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { ClientPayrollReview } from './ClientPayrollReview';
import { clientPayPeriodsApi } from '@/services/api';
import type { PayPeriod } from '@/types';
vi.mock('@/services/api', () => ({ clientPayPeriodsApi: { approveReview: vi.fn(), requestChanges: vi.fn(), previewPdf: vi.fn() } }));
vi.mock('@/components/documents/PdfPreview', () => ({ PdfPreview: () => null }));
const auth = vi.hoisted(() => ({ isClientViewer: false }));
vi.mock('@/contexts/AuthContext', () => ({ useOptionalAuth: () => auth }));
const period = { id: 5, status: 'approved', can_decide_payroll_review: true, total_gross: 1200, total_net: 1100,
  payroll_review: { id: 11, revision: 2, status: 'pending', published_at: '2026-11-17T00:00:00Z', checksum_short: 'abc123', acknowledgement: 'I approve this exact payroll review revision for processing.' },
} as PayPeriod;
const onDone = vi.fn();
beforeEach(() => { vi.resetAllMocks(); });
afterEach(() => { cleanup(); auth.isClientViewer = false; });
it('hides the decision from a client viewer even when the period says decisions are open', () => {
  auth.isClientViewer = true;
  render(<ClientPayrollReview payPeriod={period} companyId={3} onDone={onDone} />);
  expect(period.can_decide_payroll_review).toBe(true);
  expect(screen.queryByRole('button', { name: 'Approve this revision' })).toBeNull();
  expect(screen.queryByRole('button', { name: 'Request changes' })).toBeNull();
  expect(screen.queryByLabelText('Note for Cornerstone (required to request changes)')).toBeNull();
  expect(screen.getByText('Your access is view-only. Ask your account manager for changes.')).toBeTruthy();
});
it('lets a client viewer open the preview but not approve or request changes', () => {
  auth.isClientViewer = true;
  render(<ClientPayrollReview payPeriod={{ ...period, can_decide_payroll_review: false }} companyId={3} onDone={onDone} />);
  expect(screen.getByRole('button', { name: 'View preview' })).toBeTruthy();
  expect(screen.getByText('Your access is view-only. Ask your account manager for changes.')).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Approve this revision' })).toBeNull();
  expect(screen.queryByRole('button', { name: 'Request changes' })).toBeNull();
});
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
  const stale = Object.assign(new Error('Revision changed'), { status: 422, data: { code: 'stale_payroll_review_revision' } });
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

it('shows no review card for an unpublished internal revision after setting-off payroll commits', () => {
  const { container } = render(<ClientPayrollReview payPeriod={{ ...period, status: 'committed', client_payroll_approval_required: false,
    payroll_review: { ...period.payroll_review!, published_at: null }, payroll_review_history: [] }} companyId={3} onDone={onDone} />);
  expect(container.textContent).toBe('');
});

it.each([422, 409])('shows an ordinary %s error without reloading or resetting acknowledgement', async status => {
  vi.mocked(clientPayPeriodsApi.approveReview).mockRejectedValueOnce(Object.assign(new Error('Select an active client portal user.'), { status, data: { code: 'invalid_approver' } }));
  render(<ClientPayrollReview payPeriod={period} companyId={3} onDone={onDone} />);
  fireEvent.click(screen.getByRole('checkbox'));
  fireEvent.click(screen.getByRole('button', { name: 'Approve this revision' }));
  expect(await screen.findByText('Select an active client portal user.')).toBeTruthy();
  expect(onDone).not.toHaveBeenCalled();
  expect(screen.getByRole('checkbox')).toHaveProperty('checked', true);
});
it('hides an already published review when the setting is disabled', () => {
  const { container } = render(<ClientPayrollReview payPeriod={{ ...period, client_payroll_approval_required: false }} companyId={3} onDone={onDone} />);
  expect(container.textContent).toBe('');
});

it('offers all pay stubs explicitly and preserves a failed download for retry', async () => {
  vi.mocked(clientPayPeriodsApi.previewPdf).mockRejectedValueOnce(new Error('Download failed. Try again.'));
  render(<ClientPayrollReview payPeriod={period} companyId={3} onDone={onDone} />);
  fireEvent.click(screen.getByRole('button', { name: 'All pay stubs (including paper-check employees)' }));
  expect(await screen.findByText('Download failed. Try again.')).toBeTruthy();
  expect(clientPayPeriodsApi.previewPdf).toHaveBeenCalledWith(5, 3, 11, 'all_stubs');
  expect((screen.getByRole('button', { name: 'All pay stubs (including paper-check employees)' }) as HTMLButtonElement).disabled).toBe(false);
});

it('shows the published preview without decision controls when access is read-only', () => {
  render(<ClientPayrollReview payPeriod={{ ...period, can_decide_payroll_review: false }} companyId={3} onDone={onDone} />);
  expect(screen.getByRole('button', { name: 'View preview' })).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Approve this revision' })).toBeNull();
  expect(screen.queryByRole('button', { name: 'Request changes' })).toBeNull();
});

it('identifies an override and displays its reason in the client portal', () => {
  render(<ClientPayrollReview payPeriod={{ ...period, status: 'committed', payroll_review: {
    ...period.payroll_review!,
    status: 'approved',
    approval_method: 'cornerstone_override',
    override_reason: 'Client requested staff approval.',
  } }} companyId={3} onDone={onDone} />);
  expect(screen.getByRole('status').textContent).toContain('Approved by Cornerstone on your behalf');
  expect(screen.getByText('Client requested staff approval.')).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Approve this revision' })).toBeNull();
});

it('shows honest approval confirmation across queued, sent, and not_sent states', () => {
  const { rerender } = render(
    <ClientPayrollReview
      payPeriod={{
        ...period,
        can_decide_payroll_review: false,
        payroll_review: { ...period.payroll_review!, status: 'approved', approved_by_name: 'Casey Manager', notification_status: 'queued', notification_queued: true },
      }}
      companyId={3}
      onDone={onDone}
    />,
  );
  expect(screen.getByRole('status').textContent).toContain('Notification requested for your Cornerstone account team.');
  expect(screen.getByRole('status').textContent).not.toContain('was notified by email');

  rerender(
    <ClientPayrollReview
      payPeriod={{
        ...period,
        can_decide_payroll_review: false,
        payroll_review: { ...period.payroll_review!, status: 'approved', approved_by_name: 'Casey Manager', notification_status: 'sent', notification_queued: false },
      }}
      companyId={3}
      onDone={onDone}
    />,
  );
  expect(screen.getByRole('status').textContent).toContain('Your Cornerstone account team was notified by email.');
  expect(screen.getByRole('status').textContent).not.toContain('Notification requested');

  rerender(
    <ClientPayrollReview
      payPeriod={{
        ...period,
        can_decide_payroll_review: false,
        payroll_review: { ...period.payroll_review!, status: 'approved', approved_by_name: 'Casey Manager', notification_status: 'not_sent', notification_queued: false },
      }}
      companyId={3}
      onDone={onDone}
    />,
  );
  expect(screen.getByRole('status').textContent).toContain('Recorded. Cornerstone will see it in Client Inbox.');
  expect(screen.getByRole('status').textContent).not.toContain('Notification requested');
});

it('shows honest change-request confirmation across queued, sent, and not_sent states', () => {
  const { rerender } = render(
    <ClientPayrollReview
      payPeriod={{
        ...period,
        can_decide_payroll_review: false,
        payroll_review: {
          ...period.payroll_review!,
          status: 'changes_requested',
          changes_requested_by_name: 'Casey Manager',
          change_request_note: 'Fix regular hours',
          notification_status: 'queued',
          notification_queued: true,
        },
      }}
      companyId={3}
      onDone={onDone}
    />,
  );
  expect(screen.getByRole('status').textContent).toContain('Notification requested for your Cornerstone account team.');

  rerender(
    <ClientPayrollReview
      payPeriod={{
        ...period,
        can_decide_payroll_review: false,
        payroll_review: {
          ...period.payroll_review!,
          status: 'changes_requested',
          changes_requested_by_name: 'Casey Manager',
          change_request_note: 'Fix regular hours',
          notification_status: 'sent',
          notification_queued: false,
        },
      }}
      companyId={3}
      onDone={onDone}
    />,
  );
  expect(screen.getByRole('status').textContent).toContain('Your Cornerstone account team was notified by email.');

  rerender(
    <ClientPayrollReview
      payPeriod={{
        ...period,
        can_decide_payroll_review: false,
        payroll_review: {
          ...period.payroll_review!,
          status: 'changes_requested',
          changes_requested_by_name: 'Casey Manager',
          change_request_note: 'Fix regular hours',
          notification_status: 'not_sent',
          notification_queued: false,
        },
      }}
      companyId={3}
      onDone={onDone}
    />,
  );
  expect(screen.getByRole('status').textContent).toContain('Recorded. Cornerstone will see it in Client Inbox.');
  expect(screen.getByRole('status').textContent).not.toContain('Notification requested');
});
