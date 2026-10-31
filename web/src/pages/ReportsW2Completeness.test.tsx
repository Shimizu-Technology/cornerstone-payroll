// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { MemoryRouter } from 'react-router';
import { PdfPreviewProvider } from '@/components/documents/PdfPreview';
import { W2GuPanel } from './Reports';

const mocks = vi.hoisted(() => ({ readiness: vi.fn(), preflight: vi.fn() }));
vi.mock('@/services/api', () => ({ reportsApi: {
  w2GuFilingReadiness: mocks.readiness,
  w2GuPreflight: mocks.preflight,
  payrollFilingRecord: vi.fn().mockResolvedValue({ filing: null }),
  payrollFilingResponsibilities: vi.fn().mockRejectedValue(new Error('No responsibility fixture')),
}, ApiError: class extends Error {} }));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompanyId: 42 }) }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ user: { id: 1 } }) }));
afterEach(() => { cleanup(); vi.clearAllMocks(); });
const incomplete = { message: 'Add missing employee details. Drafts can still be generated.', missing_ssn_count: 1, missing_address_count: 1,
  employees: [{ employee_id: 7, name: 'Synthetic Worker', missing_fields: ['ssn', 'address'], edit_path: '/companies/42/employees/7/edit' }] };
function mount() { render(<MemoryRouter><PdfPreviewProvider><W2GuPanel /></PdfPreviewProvider></MemoryRouter>); }

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
