// @vitest-environment jsdom

import { cleanup, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { PayPeriod } from '@/types';
import { TimeTrackingImportModal } from './TimeTrackingImportModal';

const apiMocks = vi.hoisted(() => ({
  listSources: vi.fn(),
  preview: vi.fn(),
}));

vi.mock('@/contexts/AuthContext', () => ({
  useAuth: () => ({ isAdmin: true }),
}));

vi.mock('react-router', async () => {
  const actual = await vi.importActual<typeof import('react-router')>('react-router');
  return { ...actual, useNavigate: () => vi.fn() };
});

vi.mock('@/services/api', () => ({
  ApiError: class ApiError extends Error {
    data?: unknown;
  },
  timeTrackingSourcesApi: { list: apiMocks.listSources },
  payPeriodsApi: { previewTimeTrackingImport: apiMocks.preview },
}));

const payPeriod = {
  id: 17,
  company_id: 3,
  start_date: '2026-10-01',
  end_date: '2026-10-15',
  pay_date: '2026-10-31',
  status: 'draft',
  run_purpose: 'regular',
  includes_base_salary: true,
  includes_recurring_items: true,
} as PayPeriod;

const source = {
  id: 12,
  company_id: 3,
  name: 'AIRE Services',
  source_type: 'aire_services' as const,
  base_url: 'https://aire.example.com',
  active: true,
  shared_secret_configured: true,
  delegation_token_configured: true,
  last_synced_at: null,
};

const otherSource = {
  ...source,
  id: 8,
  name: 'Field Time Clock',
  source_type: 'custom' as const,
};

beforeEach(() => {
  vi.clearAllMocks();
  apiMocks.listSources.mockResolvedValue({ time_tracking_sources: [source] });
  apiMocks.preview.mockResolvedValue({
    import: {
      id: 99,
      status: 'previewed',
      time_tracking_source_id: source.id,
      source_name: source.name,
      start_date: payPeriod.start_date,
      end_date: payPeriod.end_date,
      fetch_start_date: payPeriod.start_date,
      fetch_end_date: payPeriod.end_date,
      warnings: [],
      processed_payload: {
        ready: true,
        rows: [],
        exclusions: [],
        validation_version: 'payroll_batch_v2',
        summary: { total_hours: 72.5 },
        issues: {},
      },
      external_batch_id: 'AIRE-PAY-17',
      external_batch_checksum: 'checksum',
      contract_version: 'payroll_batch_v2',
      source_cutoff_at: '2026-10-23T00:00:00+10:00',
      applied_at: null,
      source_processing_status: null,
      source_processing_synced_at: null,
      source_processing_sync_error: null,
    },
  });
});

afterEach(() => cleanup());

describe('TimeTrackingImportModal guided AIRE review', () => {
  it('opens the configured AIRE batch directly in review', async () => {
    render(
      <TimeTrackingImportModal
        open
        onClose={vi.fn()}
        payPeriod={payPeriod}
        employees={[]}
        onImportComplete={vi.fn()}
        initialSourceId={source.id}
        autoPreview
      />
    );

    await waitFor(() => expect(apiMocks.preview).toHaveBeenCalledWith(payPeriod.id, {
      source_id: source.id,
      start_date: payPeriod.start_date,
      end_date: payPeriod.end_date,
    }));
    expect(await screen.findByText('Review AIRE hours for this payroll')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Retrieve Finalized Batch' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Add AIRE Hours to Payroll' })).toBeTruthy();
  });

  it('keeps the first configured provider for the general import action', async () => {
    apiMocks.listSources.mockResolvedValue({ time_tracking_sources: [otherSource, source] });

    render(
      <TimeTrackingImportModal
        open
        onClose={vi.fn()}
        payPeriod={payPeriod}
        employees={[]}
        onImportComplete={vi.fn()}
      />
    );

    expect(await screen.findByText('Field Time Clock')).toBeTruthy();
    expect(apiMocks.preview).not.toHaveBeenCalled();
    screen.getByRole('button', { name: 'Fetch Hours' }).click();

    await waitFor(() => expect(apiMocks.preview).toHaveBeenCalledWith(payPeriod.id, {
      source_id: otherSource.id,
      start_date: payPeriod.start_date,
      end_date: payPeriod.end_date,
    }));
  });
});
