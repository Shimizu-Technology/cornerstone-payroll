// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { PdfPreviewProvider } from '@/components/documents/PdfPreview';
import { ApiError } from '@/services/api';
import { W2GuPanel } from './Reports';

const mocks = vi.hoisted(() => ({ readiness: vi.fn(), preflight: vi.fn(), report: vi.fn(), markReady: vi.fn(), responsibilities: vi.fn().mockRejectedValue(new Error('No responsibility fixture')), companyId: 42 }));
vi.mock('@/services/api', () => ({ reportsApi: {
  w2GuFilingReadiness: mocks.readiness,
  w2GuPreflight: mocks.preflight,
  w2Gu: mocks.report,
  w2GuMarkReady: mocks.markReady,
  payrollFilingRecord: vi.fn().mockResolvedValue({ filing: null }),
  payrollFilingResponsibilities: mocks.responsibilities,
}, ApiError: class extends Error { data: unknown; constructor(message: string, _status: number, _details?: unknown, data?: unknown) { super(message); this.data = data; } } }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: mocks.companyId, activeCompany: {
  id: mocks.companyId, client_capabilities: ['manage_client_administration'],
} }) }));
vi.mock('@/components/reports/FilingResponsibilityPanel', () => ({ FilingResponsibilityPanel: ({ canRecord }: { canRecord: boolean }) => <button disabled={!canRecord}>Record responsibility</button> }));
vi.mock('@/lib/company-write-access', () => ({ canWriteCompany: () => true, companyReadOnlyMessage: () => '' }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { id: 1 } }) }));
afterEach(() => { cleanup(); vi.clearAllMocks(); mocks.companyId = 42; });
const incomplete = { message: 'Add missing employee details. Drafts can still be generated.', missing_ssn_count: 1, missing_address_count: 1,
  employees: [{ employee_id: 7, name: 'Synthetic Worker', missing_fields: ['ssn', 'address'], edit_path: '/companies/42/employees/7/edit' }] };
function mount() { return render(<MemoryRouter><PdfPreviewProvider><W2GuPanel /></PdfPreviewProvider></MemoryRouter>); }

it('shows live employee warnings before any explicit preflight and clears them for another year', async () => {
  mocks.readiness.mockResolvedValueOnce({ filing: null, filing_gate: null, employee_completeness: incomplete })
    .mockResolvedValueOnce({ filing: null, filing_gate: null, employee_completeness: { ...incomplete, employees: [], message: null } });
  mount();
  expect(await screen.findByText('Synthetic Worker — missing 9-digit SSN and complete address')).toBeTruthy();
  expect(screen.getByRole('link', { name: /Edit profile for Synthetic Worker/ }).getAttribute('href')).toBe('/companies/42/employees/7/edit');
  expect(mocks.preflight).not.toHaveBeenCalled();
  fireEvent.change(screen.getByLabelText('Tax Year'), { target: { value: String(new Date().getFullYear()) } });
  expect(screen.queryByText('Synthetic Worker — missing 9-digit SSN and complete address')).toBeNull();
});
it('ignores a late readiness response after the selected year changes', async () => {
  let resolveOld: (value: unknown) => void = () => {};
  mocks.readiness.mockImplementationOnce(() => new Promise((resolve) => { resolveOld = resolve; }))
    .mockResolvedValueOnce({ filing: null, filing_gate: null, employee_completeness: { ...incomplete, employees: [], message: null } });
  mount();
  fireEvent.change(screen.getByLabelText('Tax Year'), { target: { value: String(new Date().getFullYear()) } });
  await act(async () => { resolveOld({ filing: null, filing_gate: null, employee_completeness: incomplete }); });
  expect(screen.queryByText('Synthetic Worker — missing 9-digit SSN and complete address')).toBeNull();
});

const complete = { ...incomplete, employees: [], message: null };
const ready = { status: 'preflight_passed', blocking_count: 0, warning_count: 0, preflight_current: true };
const gate = { filings: { w2_gu: { capabilities: { can_mark_filing_ready: true } } }, blockers: [], source_coverage: {} };
const preflight = { findings: [], blocking_count: 0, warning_count: 0 };
const emptyReport = { employees: [], compliance_issues: [], totals: {}, meta: { year: 2026, company_name: 'Synthetic', caveats: [] }, filing_gate: null };
function deferred() {
  let resolve!: (value: unknown) => void;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

it.each(['report', 'preflight'] as const)('ignores readiness that finishes after a newer %s request', async (flow) => {
  const old = deferred();
  mocks.readiness.mockReturnValueOnce(old.promise);
  mocks.report.mockResolvedValue({ report: { ...emptyReport, employee_completeness: complete } });
  mocks.preflight.mockResolvedValue({ preflight: { ...preflight, employee_completeness: complete }, filing: null, filing_gate: null });
  mount();
  fireEvent.click(screen.getByRole('button', { name: flow === 'report' ? 'View W-2GU Report' : 'Run Preflight' }));
  await act(async () => {});
  await act(async () => { old.resolve({ filing: null, filing_gate: null, employee_completeness: incomplete }); });
  expect(screen.queryByText(/Synthetic Worker —/)).toBeNull();
});

it.each(['report', 'preflight'] as const)('ignores a late %s response from a previous company', async (flow) => {
  const old = deferred();
  mocks.readiness.mockResolvedValue({ filing: null, filing_gate: null, employee_completeness: complete });
  mocks.report.mockReturnValue(old.promise);
  mocks.preflight.mockReturnValue(old.promise);
  const view = mount();
  await act(async () => {});
  fireEvent.click(screen.getByRole('button', { name: flow === 'report' ? 'View W-2GU Report' : 'Run Preflight' }));
  mocks.companyId = 43;
  view.rerender(<MemoryRouter><PdfPreviewProvider><W2GuPanel /></PdfPreviewProvider></MemoryRouter>);
  await act(async () => { old.resolve({ report: { ...emptyReport, employee_completeness: incomplete }, preflight: { ...preflight, employee_completeness: incomplete }, filing: null, filing_gate: null }); });
  expect(screen.queryByText(/Synthetic Worker —/)).toBeNull();
});

it('clears stale details on readiness failure and lets the accountant retry', async () => {
  mocks.readiness.mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce({ filing: null, filing_gate: null, employee_completeness: incomplete });
  mount();
  expect(await screen.findByRole('alert')).toHaveProperty('textContent', expect.stringContaining('could not be refreshed'));
  expect(screen.queryByText(/Synthetic Worker —/)).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: 'Retry employee readiness' }));
  expect(await screen.findByText(/Synthetic Worker —/)).toBeTruthy();
  expect(screen.queryByRole('alert')).toBeNull();
});

it('refreshes employee details after mark-ready revalidation blocks and clears old details on reload failure', async () => {
  mocks.readiness.mockResolvedValueOnce({ filing: ready, filing_gate: gate, employee_completeness: incomplete })
    .mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce({ filing: ready, filing_gate: gate, employee_completeness: complete });
  mocks.markReady.mockRejectedValue(new ApiError('Cannot mark filing ready', 422, undefined, { filing: ready, revalidation: { ...preflight, blocking_count: 1,
    findings: [{ severity: 'blocking', code: 'EMPLOYEE_ADDRESS_INCOMPLETE', message: 'Address required' }] } }));
  mount();
  await screen.findByText(/Synthetic Worker —/);
  await waitFor(() => expect(screen.getByRole('button', { name: 'Mark Filing Ready' })).toHaveProperty('disabled', false));
  fireEvent.click(screen.getByRole('button', { name: 'Mark Filing Ready' }));
  await screen.findByRole('button', { name: 'Retry employee readiness' });
  expect(mocks.readiness).toHaveBeenCalledTimes(2);
  expect(screen.queryByText(/Synthetic Worker —/)).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: 'Retry employee readiness' }));
  await waitFor(() => expect(mocks.readiness).toHaveBeenCalledTimes(3));
  expect(screen.queryByText(/could not be refreshed/)).toBeNull();
});

it('retains responsibility permissions when a newer preflight supersedes the initial readiness request', async () => {
  const old = deferred();
  const permissions = deferred();
  mocks.readiness.mockReturnValueOnce(old.promise);
  mocks.responsibilities.mockReturnValueOnce(permissions.promise);
  mocks.preflight.mockResolvedValue({ preflight: { ...preflight, employee_completeness: complete }, filing: ready, filing_gate: gate });
  mount();
  fireEvent.click(screen.getByRole('button', { name: 'Run Preflight' }));
  await screen.findByRole('button', { name: 'Record responsibility' });
  await act(async () => {
    old.resolve({ filing: null, filing_gate: null, employee_completeness: incomplete });
    permissions.resolve({ data: gate, permissions: { can_record: true } });
  });
  expect(screen.getByRole('button', { name: 'Record responsibility' })).toHaveProperty('disabled', false);
  expect(screen.queryByText(/Synthetic Worker —/)).toBeNull();
});
