// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { PdfPreviewProvider } from '@/components/documents/PdfPreview';
import { W2GuPanel } from './Reports';

const mocks = vi.hoisted(() => ({
  readiness: vi.fn(), preflight: vi.fn(), markReady: vi.fn(), report: vi.fn(),
}));
const gate = {
  scope: 'annual', tax_year: new Date().getFullYear() - 1, blockers: [],
  source_coverage: { has_historical_payroll: false },
  filings: { w2_gu: { filing_type: 'w2_gu', status: 'responsibility_not_required', blockers: [], source_coverage: { has_historical_payroll: false }, capabilities: { can_mark_filing_ready: true } } },
};
vi.mock('@/services/api', () => ({
  reportsApi: {
    w2GuFilingReadiness: mocks.readiness, w2GuPreflight: mocks.preflight,
    w2GuMarkReady: mocks.markReady, w2Gu: mocks.report,
    payrollFilingResponsibilities: vi.fn(async () => ({ data: gate, permissions: { can_record: false } })),
    payrollFilingRecord: vi.fn(async () => ({ filing: null })),
  },
  ApiError: class ApiError extends Error {},
}));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 42 }) }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { id: 1, company_id: 42 } }) }));

function readiness(status = 'stale') {
  return {
    year: new Date().getFullYear() - 1, status,
    stale: status === 'stale', preflight_current: status !== 'stale',
    preflight_fingerprint: 'current-preflight', blocking_count: 0, warning_count: 0,
    attestation_history: [{ source_fingerprint: 'previous', marked_ready_at: '2025-12-31T08:00:00Z', marked_ready_by_id: 1, notes: 'Previous review preserved' }],
  };
}
function renderPanel() {
  render(<MemoryRouter><PdfPreviewProvider><W2GuPanel /></PdfPreviewProvider></MemoryRouter>);
}

describe('W-2 readiness recovery', () => {
  afterEach(cleanup);
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.readiness.mockResolvedValue({ filing: readiness(), filing_gate: gate });
    mocks.preflight.mockResolvedValue({ filing: readiness('preflight_passed'), preflight: { findings: [], blocking_count: 0, warning_count: 0 }, filing_gate: gate });
    mocks.markReady.mockResolvedValue({ filing: readiness('filing_ready'), filing_gate: gate });
  });

  it('keeps previous reviews visible and requires preflight before a new explicit attestation', async () => {
    renderPanel();
    expect(await screen.findByText('Review needed — inputs changed')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Mark Filing Ready' })).toHaveProperty('disabled', true);
    expect(screen.getByText('Previous review preserved')).toBeTruthy();
    fireEvent.change(screen.getByLabelText('Filing Notes (optional)'), { target: { value: 'Reviewed updated wages' } });
    fireEvent.click(screen.getByRole('button', { name: 'Run Preflight' }));
    await waitFor(() => expect(screen.getByRole('button', { name: 'Mark Filing Ready' })).toHaveProperty('disabled', false));
    expect(screen.getByLabelText('Filing Notes (optional)')).toHaveProperty('value', 'Reviewed updated wages');
    fireEvent.click(screen.getByRole('button', { name: 'Mark Filing Ready' }));
    await waitFor(() => expect(mocks.markReady).toHaveBeenCalledWith(new Date().getFullYear() - 1, 'Reviewed updated wages', 'current-preflight'));
    expect(await screen.findByText('filing ready')).toBeTruthy();
  });

  it('refreshes readiness when the current report reveals changed inputs', async () => {
    mocks.readiness.mockResolvedValue({ filing: readiness('filing_ready'), filing_gate: gate });
    mocks.report.mockResolvedValue({ report: {
      meta: { year: new Date().getFullYear() - 1, employee_count: 0, caveats: [] },
      employer: {}, employees: [], totals: {}, compliance_issues: [],
      filing_gate: gate, filing_readiness: readiness(),
    } });
    renderPanel();
    expect(await screen.findByText('filing ready')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'View W-2GU Report' }));
    expect(await screen.findByText('Review needed — inputs changed')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Mark Filing Ready' })).toHaveProperty('disabled', true);
    expect(mocks.markReady).not.toHaveBeenCalled();
  });
});
