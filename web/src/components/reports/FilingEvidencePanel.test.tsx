// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { PayrollFilingRecord } from '@/services/api';
import { FilingEvidencePanel } from './FilingEvidencePanel';

const apiMocks = vi.hoisted(() => ({
  payrollFilingRecord: vi.fn(),
  recordPayrollFilingEvent: vi.fn(),
  download: vi.fn(),
}));

vi.mock('@/services/api', () => ({
  reportsApi: {
    payrollFilingRecord: apiMocks.payrollFilingRecord,
    recordPayrollFilingEvent: apiMocks.recordPayrollFilingEvent,
  },
  adminClientDocumentsApi: { download: apiMocks.download },
}));

const submitted: PayrollFilingRecord = {
  id: 14,
  filing_type: 'w1',
  display_name: 'Guam W-1',
  tax_year: 2026,
  quarter: 2,
  status: 'submitted',
  submitted_at: '2026-07-20T02:00:00Z',
  resolved_at: null,
  confirmation_number: 'W1-SUBMIT-1',
  source_fingerprint: 'a'.repeat(64),
  current_source_fingerprint: 'a'.repeat(64),
  source_changed: false,
  events: [{
    id: 21,
    event_type: 'submitted',
    from_status: null,
    to_status: 'submitted',
    occurred_at: '2026-07-20T02:00:00Z',
    reference_number: 'W1-SUBMIT-1',
    preparer_name: 'Dana Accountant',
    signer_name: 'Client Owner',
    signer_title: 'President',
    notes: null,
    source_fingerprint: 'a'.repeat(64),
    recorded_by: 'Dana Accountant',
    evidence_document: {
      id: 31,
      file_name: 'w1-receipt.pdf',
      content_type: 'application/pdf',
      preview_available: true,
    },
  }],
};

describe('FilingEvidencePanel', () => {
  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  beforeEach(() => {
    vi.clearAllMocks();
    vi.stubGlobal('crypto', { randomUUID: () => 'filing-event-key-1' });
  });

  it('uses the receipt path for prior years without an agency selector or final file', async () => {
    apiMocks.payrollFilingRecord.mockResolvedValue({ filing: null });
    render(<FilingEvidencePanel filingType="w2_gu_w3_ss" taxYear={2025} preparationReady readinessMessage="Ready" />);
    fireEvent.click(await screen.findByRole('button', { name: 'Record submission' }));
    expect(screen.queryByLabelText('Agency')).toBeNull();
    expect(screen.queryByLabelText('Final file uploaded')).toBeNull();
    expect((screen.getByLabelText('Receipt or agency response') as HTMLInputElement).required).toBe(true);
  });

  it('refreshes to the newest current file and labels stale downloads', async () => {
    const file = { created_at: '2026-11-20T01:00:00Z', actor_name: 'Dana', sha256: 'b'.repeat(64) };
    apiMocks.payrollFilingRecord.mockResolvedValueOnce({ filing: null, downloads: [{ ...file, id: 93, current: false }, { ...file, id: 91, current: true }] })
      .mockResolvedValue({ filing: null, downloads: [{ ...file, id: 94, current: true }] });
    render(<FilingEvidencePanel filingType="w2_gu_w3_ss" taxYear={2026} agency="ssa" preparationReady readinessMessage="Ready" />);
    fireEvent.click(await screen.findByRole('button', { name: 'Record submission' }));
    expect((screen.getByLabelText('Final file uploaded') as HTMLSelectElement).value).toBe('91');
    expect(screen.getByRole('option', { name: /out of date/ })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Refresh files' }));
    await waitFor(() => expect((screen.getByLabelText('Final file uploaded') as HTMLSelectElement).value).toBe('94'));
  });

  it('explains how to get a final file and makes receipts optional for current years', async () => {
    apiMocks.payrollFilingRecord.mockResolvedValue({ filing: null, downloads: [] });
    render(<FilingEvidencePanel filingType="w2_gu_w3_ss" taxYear={2026} agency="ssa" preparationReady readinessMessage="Ready" />);
    fireEvent.click(await screen.findByRole('button', { name: 'Record submission' }));
    expect(screen.getByText(/Download the final W-2 e-file in Print and file first/)).toBeTruthy();
    expect((screen.getByLabelText('Receipt or agency response (optional)') as HTMLInputElement).required).toBe(false);
  });

  it('shows earlier W-2 history once across the two agency panels', async () => {
    apiMocks.payrollFilingRecord.mockResolvedValue({ filing: null, legacy_filing: { ...submitted, filing_type: 'w2_gu_w3_ss', quarter: null } });
    render(<>{['ssa', 'drt'].map((agency) => <FilingEvidencePanel key={agency} filingType="w2_gu_w3_ss" taxYear={2026} agency={agency} preparationReady readinessMessage="Ready" />)}</>);
    await waitFor(() => expect(screen.getAllByText('Earlier W-2 history — agency not recorded')).toHaveLength(1));
  });

  it('does not claim retained proof for receipt-free annual acceptance', async () => {
    apiMocks.payrollFilingRecord.mockResolvedValue({ filing: { ...submitted, status: 'accepted', filing_type: 'w2_gu_w3_ss', quarter: null, events: [] } });
    render(<FilingEvidencePanel filingType="w2_gu_w3_ss" taxYear={2026} agency="ssa" preparationReady readinessMessage="Ready" />);
    expect(await screen.findByText('Agency acceptance recorded.')).toBeTruthy();
    expect(screen.queryByText(/retained proof/)).toBeNull();
  });

  it('keeps submission disabled until the preparation workflow is ready', async () => {
    apiMocks.payrollFilingRecord.mockResolvedValue({ filing: null });

    render(
      <FilingEvidencePanel
        filingType="w1"
        taxYear={2026}
        quarter={2}
        preparationReady={false}
        readinessMessage="Mark Guam W-1 ready first."
      />,
    );

    expect(await screen.findByText('No agency submission recorded.')).toBeTruthy();
    expect(screen.getByText('Mark Guam W-1 ready first.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Record submission' }).hasAttribute('disabled')).toBe(true);
  });

  it('records an agency rejection with its required evidence and updates the timeline', async () => {
    const rejected: PayrollFilingRecord = {
      ...submitted,
      status: 'rejected',
      resolved_at: '2026-07-21T02:00:00Z',
      confirmation_number: 'W1-REJECT-2',
      events: [...submitted.events, {
        ...submitted.events[0],
        id: 22,
        event_type: 'rejected',
        from_status: 'submitted',
        to_status: 'rejected',
        occurred_at: '2026-07-21T02:00:00Z',
        reference_number: 'W1-REJECT-2',
        signer_name: null,
        signer_title: null,
        notes: 'TIN mismatch; correct and resubmit.',
        evidence_document: {
          id: 32,
          file_name: 'w1-rejection.pdf',
          content_type: 'application/pdf',
          preview_available: true,
        },
      }],
    };
    apiMocks.payrollFilingRecord.mockResolvedValue({ filing: submitted });
    apiMocks.recordPayrollFilingEvent
      .mockRejectedValueOnce(new Error('Temporary failure'))
      .mockResolvedValueOnce({ filing: rejected });

    render(
      <FilingEvidencePanel
        filingType="w1"
        taxYear={2026}
        quarter={2}
        preparationReady
        readinessMessage="Ready"
      />,
    );

    fireEvent.click(await screen.findByRole('button', { name: 'Record rejection' }));
    fireEvent.change(screen.getByLabelText('Agency reference number'), { target: { value: 'W1-REJECT-2' } });
    fireEvent.change(screen.getByLabelText('Prepared / recorded by'), { target: { value: 'Dana Accountant' } });
    fireEvent.change(screen.getByLabelText('Notes (required)'), { target: { value: 'TIN mismatch; correct and resubmit.' } });
    fireEvent.change(screen.getByLabelText('Receipt or agency response'), {
      target: { files: [new File(['proof'], 'w1-rejection.pdf', { type: 'application/pdf' })] },
    });
    const saveButton = screen.getByRole('button', { name: 'Save evidence' });
    fireEvent.submit(saveButton.closest('form')!);

    await waitFor(() => expect(apiMocks.recordPayrollFilingEvent).toHaveBeenCalledOnce());
    expect((await screen.findByRole('alert')).textContent).toContain('Temporary failure');
    fireEvent.submit(saveButton.closest('form')!);
    await waitFor(() => expect(apiMocks.recordPayrollFilingEvent).toHaveBeenCalledTimes(2));

    const firstBody = apiMocks.recordPayrollFilingEvent.mock.calls[0][0] as FormData;
    const retryBody = apiMocks.recordPayrollFilingEvent.mock.calls[1][0] as FormData;
    expect(firstBody.get('filing_type')).toBe('w1');
    expect(firstBody.get('tax_year')).toBe('2026');
    expect(firstBody.get('quarter')).toBe('2');
    expect(firstBody.get('event_type')).toBe('rejected');
    expect(firstBody.get('idempotency_key')).toBe('filing-event-key-1');
    expect(retryBody.get('idempotency_key')).toBe(firstBody.get('idempotency_key'));
    expect(firstBody.get('occurred_at')).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00\+10:00$/);
    expect(firstBody.has('file')).toBe(true);

    expect(await screen.findByText('Rejected; correct the filing and record the resubmission.')).toBeTruthy();
    expect(screen.getByText('TIN mismatch; correct and resubmit.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Record resubmission' })).toBeTruthy();
  });

  it('preselects the latest final download and records the selected agency without a receipt', async () => {
    apiMocks.payrollFilingRecord.mockResolvedValue({ filing: null, downloads: [
      { id: 91, created_at: '2026-11-20T01:00:00Z', actor_name: 'Dana', sha256: 'b'.repeat(64), current: true },
      { id: 90, created_at: '2026-11-19T01:00:00Z', actor_name: 'Dana', sha256: 'a'.repeat(64), current: false },
    ] });
    apiMocks.recordPayrollFilingEvent.mockResolvedValue({ filing: { ...submitted, filing_type: 'w2_gu_w3_ss', agency: 'ssa' } });
    render(<FilingEvidencePanel filingType="w2_gu_w3_ss" taxYear={2026} companyId={3} agency="ssa" preparationReady readinessMessage="Ready" />);
    fireEvent.click(await screen.findByRole('button', { name: 'Record submission' }));
    expect((screen.getByLabelText('Final file uploaded') as HTMLSelectElement).value).toBe('91');
    expect(screen.getByLabelText('Receipt or agency response (optional)').hasAttribute('required')).toBe(false);
    fireEvent.change(screen.getByLabelText('Agency reference number'), { target: { value: 'WFID-1' } });
    fireEvent.change(screen.getByLabelText('Prepared / recorded by'), { target: { value: 'Dana' } });
    fireEvent.submit(screen.getByRole('button', { name: 'Save evidence' }).closest('form')!);
    await waitFor(() => expect(apiMocks.recordPayrollFilingEvent).toHaveBeenCalledOnce());
    const data = apiMocks.recordPayrollFilingEvent.mock.calls[0][0] as FormData;
    expect(data.get('agency')).toBe('ssa');
    expect(data.get('download_audit_id')).toBe('91');
    expect(apiMocks.recordPayrollFilingEvent.mock.calls[0][1]).toBe(3);
  });

  it('surfaces loading failures through an accessible alert', async () => {
    apiMocks.payrollFilingRecord.mockRejectedValue(new Error('Evidence service unavailable'));

    render(
      <FilingEvidencePanel
        filingType="w1"
        taxYear={2026}
        quarter={2}
        preparationReady
        readinessMessage="Ready"
      />,
    );

    await waitFor(() => expect(screen.getByRole('alert').textContent).toContain('Evidence service unavailable'));
  });
});
