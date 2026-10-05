// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { MemoryRouter, useLocation } from 'react-router';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeHoursPayroll } from './EmployeeHoursPayroll';
import { SavedHours } from './SavedHours';
import type { EmployeePayHistoryReport, EmployeePayHistoryRecord } from '@/services/api';
const mocks = vi.hoisted(() => ({ evidence: vi.fn() }));
vi.mock('@/services/api', () => ({ employeesApi: { hoursEvidence: mocks.evidence } }));
const totals = { worked_hours: 82, eligible_hours: 82, pending_hours: 0, denied_hours: 0,
  issued_hours: 40, committed_hours: 20, exported_hours: 0, held_hours: 0, needs_reconciliation_hours: 22,
  current_regular_hours: 80, current_overtime_hours: 2, frozen_regular_hours: 40, frozen_overtime_hours: 0, open_case_count: 0 };
const period = { id: '2026-08-01', start_date: '2026-08-01', end_date: '2026-08-15', summary: totals, review_required: true };
const evidence = { status: 'available', source_id: 3, sources: [{ id: 3, name: 'Example business', active: true, employee_identity_verified: true }],
  evidence: { contract_version: '1.0', as_of: '2026-10-05T00:00:00Z', periods: [period], totals,
    pagination: { per_page: 20, total_count: 23, next_cursor: 'signed-next' } } };
const item = { key: 'native:9', record_type: 'native', pay_period_id: 5, payroll_item_id: 9,
  pay_date: '2026-08-30', period_description: 'August 1–15', source: { label: 'Cornerstone' },
  hours_worked: 40.5, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, net_pay: 300,
  payment_evidence: { status: 'issued', label: 'Check delivered', effective_on: '2026-08-30' } } as EmployeePayHistoryRecord;
function Location() { const location = useLocation(); return <output aria-label="Current route">{location.search}</output>; }
function mount(path = '/companies/1/employees/2/hours-payroll?return_to=%2Femployees') {
  render(<MemoryRouter initialEntries={[path]}><EmployeeHoursPayroll employeeId={2} companyId={1} report={{ history: [item] } as EmployeePayHistoryReport} returnTo={path} /><Location /></MemoryRouter>);
}
describe('Employee hours and payroll evidence', () => {
  afterEach(cleanup);
  beforeEach(() => { vi.clearAllMocks(); mocks.evidence.mockResolvedValue(evidence); });
  it('shows all-filter totals and source-only periods beside actual saved REG/OT', async () => {
    mount();
    expect(await screen.findByText('23 original work periods match these dates.')).toBeTruthy();
    expect(screen.getByText('All matching work periods')).toBeTruthy();
    expect(screen.getByText('REG 40.50 · OT 0.00')).toBeTruthy();
    expect(screen.getByText(/40.00 issued coverage/)).toBeTruthy();
    expect(screen.getByText('Check delivered · $300.00 net')).toBeTruthy();
    expect(screen.queryByText(/82.*owed/)).toBeNull();
  });
  it('keeps date filters and cursor when entering and returning from a period', async () => {
    mocks.evidence.mockImplementation((_id, query) => Promise.resolve(query.period_id ? {
      ...evidence, evidence: { ...evidence.evidence, period: { ...period, entries: [], coverage_lines: [] } }, payroll_records: [],
    } : evidence));
    mount('/companies/1/employees/2/hours-payroll?hours_cursor=signed-old&hours_start=2026-08-01&return_to=%2Femployees');
    fireEvent.click(await screen.findByRole('button', { name: 'Review period' }));
    expect(await screen.findByRole('button', { name: 'All work periods' })).toBeTruthy();
    expect(screen.getByLabelText('Current route').textContent).toContain('hours_cursor=signed-old');
    fireEvent.click(screen.getByRole('button', { name: 'All work periods' }));
    await waitFor(() => expect(mocks.evidence).toHaveBeenLastCalledWith(2, expect.objectContaining({ cursor: 'signed-old', start_date: '2026-08-01', period_id: undefined })));
    expect(screen.getByLabelText('Current route').textContent).toContain('return_to=%2Femployees');
  });
  it('keeps saved payroll accessible when source connection is disabled', async () => {
    mocks.evidence.mockResolvedValue({ ...evidence, status: 'unavailable', evidence: undefined, message: 'This connection is disabled. Saved payroll history remains available.' });
    mount();
    expect(await screen.findByText(/This connection is disabled/)).toBeTruthy();
    expect(screen.getByRole('link', { name: /Payroll item/ }).getAttribute('href')).toContain('/pay-runs/5/payroll-items/9');
    expect(screen.getByText('REG 40.50 · OT 0.00')).toBeTruthy();
  });
  it('allows a failed source request to retry without erasing saved payroll', async () => {
    mocks.evidence.mockRejectedValueOnce(new Error('Connection timeout')).mockResolvedValue(evidence);
    mount();
    expect(await screen.findByText('Connection timeout')).toBeTruthy();
    expect(screen.getByText('Check delivered · $300.00 net')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
    expect(await screen.findByText('23 original work periods match these dates.')).toBeTruthy();
  });
  it('explains invalid work dates without contacting the source or offering an outage retry', async () => {
    mount('/companies/1/employees/2/hours-payroll?hours_start=2026-09-01&hours_end=2026-08-01');
    expect(screen.getByRole('alert').textContent).toBe('Work through must be on or after Work from.');
    expect(mocks.evidence).not.toHaveBeenCalled();
    expect(screen.queryByRole('button', { name: 'Try again' })).toBeNull();
    expect(screen.getByText('Check delivered · $300.00 net')).toBeTruthy();
    fireEvent.change(screen.getByLabelText('Work through'), { target: { value: '2026-09-15' } });
    expect(await screen.findByText('23 original work periods match these dates.')).toBeTruthy();
    expect(mocks.evidence).toHaveBeenCalledWith(2, expect.objectContaining({ start_date: '2026-09-01', end_date: '2026-09-15' }));
  });
  it('preserves unknown and signed imported hours instead of silently zeroing them', () => {
    const { rerender } = render(<SavedHours item={{ ...item, record_type: 'imported', overtime_hours: null }} />);
    expect(screen.getByText('Total unavailable')).toBeTruthy();
    expect(screen.getByText('REG 40.50 · OT Unknown')).toBeTruthy();
    rerender(<SavedHours item={{ ...item, record_type: 'adjustment', hours_worked: -0.5 }} />);
    expect(screen.getByText('-0.50 total hours')).toBeTruthy();
    expect(screen.getByText('Signed adjustment')).toBeTruthy();
  });
  it('opens a source entry and exact verified payroll result from period detail', async () => {
    mocks.evidence.mockResolvedValue({ ...evidence, source_workspace_url: 'https://example.com/employee/42',
      evidence: { ...evidence.evidence, period: { ...period, entries: [{ id: '18', work_date: '2026-08-05', regular_hours: 40.5, overtime_hours: 0.5, issued_hours: 41, needs_reconciliation_hours: 0, source_entry_url: 'https://example.com/employee/42?entry=18' }], coverage_lines: [] } },
      payroll_records: [{ payroll_item_id: 9, pay_period_id: 5, check_number: '1003', pay_date: '2026-08-30', period_description: 'August 1–15', pay_period_status: 'draft', regular_hours: 41, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, net_pay: 300, payment_evidence: { label: 'Check delivered' } }] });
    mount('/companies/1/employees/2/hours-payroll?period=2026-08-01');
    expect(await screen.findByRole('link', { name: /Open exact source entry/ })).toHaveProperty('href', 'https://example.com/employee/42?entry=18');
    const actual = screen.getByText('Exact linked payroll results').parentElement!;
    expect(within(actual).getByText('Saved REG 41.00 · OT 0.00 · Holiday 0.00 · PTO 0.00')).toBeTruthy();
    expect(within(actual).getByText(/Pay run status: draft/)).toBeTruthy();
    expect(screen.getByRole('link', { name: /Open exact payroll item/ }).getAttribute('href')).toContain('/pay-runs/5/payroll-items/9');
  });
});
