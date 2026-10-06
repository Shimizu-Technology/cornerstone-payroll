// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeRetirementYearPanel } from './EmployeeRetirementYearPanel';
import type { Employee, HistoricalRetirementReview, HistoricalRetirementSource } from '@/types';

const mocks = vi.hoisted(() => ({ list: vi.fn(), inputs: vi.fn(), create: vi.fn(), canManage: true }));
vi.mock('@/services/api', () => ({
  annualRetirementLimitsApi: { list: mocks.list },
  employeesApi: { retirementYearInputs: mocks.inputs, createRetirementYearInput: mocks.create },
  ApiError: class ApiError extends Error { fieldErrors = {}; },
}));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ hasCapability: () => mocks.canManage }) }));
const year = new Date().getFullYear();
const employee = { id: 5, date_of_birth: `${year - 61}-12-31`, retirement_elections: [{ effective_on: `${year}-01-01`, catch_up_enabled: true }] } as unknown as Employee;
const limit = { tax_year: year, elective_deferral_limit: 24500, catch_up_limit: 8000, enhanced_catch_up_limit: 11250, roth_catch_up_wage_threshold: 150000 };

const historicalSource: HistoricalRetirementSource = {
  tax_year: year, balance_digest: 'retained-digest', historical_balance_id: 7,
  classifications: [
    { source_bucket: 'pretax_deduction_breakdown', source_label: '401(k) After Tax', amount: '1234.56' },
    { source_bucket: 'after_tax_deduction_breakdown', source_label: '401(k) Voluntary', amount: '50.00' },
  ],
};
const reviewed: HistoricalRetirementReview = {
  balance_digest: historicalSource.balance_digest,
  classifications: historicalSource.classifications.map((source, index) => ({ ...source, reporting_group: index === 0 ? '401k_after_tax' : '401k_non_roth_after_tax' })),
};
async function enterReviewNote(user: ReturnType<typeof userEvent.setup>): Promise<void> {
  await user.type(screen.getByLabelText('Evidence reference'), 'Retained payroll / signed election');
  await user.type(screen.getByLabelText('Review note'), 'Verified retained retirement types');
}

describe('annual retirement evidence', () => {
  beforeEach(() => { vi.clearAllMocks(); mocks.canManage = true; mocks.list.mockResolvedValue({ data: [limit] }); mocks.inputs.mockResolvedValue({ data: [] }); });
  afterEach(cleanup);
  it('shows year-end eligibility and missing evidence without pretending wages are zero', async () => {
    render(<EmployeeRetirementYearPanel employee={employee} />);
    expect(await screen.findByText('$35,750.00')).toBeTruthy();
    expect(screen.getByText(/employer wages need verification before catch-up/)).toBeTruthy();
    expect(screen.getByText(/Missing history is not treated as zero/)).toBeTruthy();
  });
  it('shows zero catch-up when verified high wages require unavailable Roth support', async () => {
    mocks.inputs.mockResolvedValue({ data: [{ id: 1, tax_year: year, prior_year_wage_status: 'verified', prior_year_fica_wages: '175000.0', prior_year_wage_source: 'Verified wage statement', source_reference: 'Review 1', reason: 'Confirmed' }] });
    render(<EmployeeRetirementYearPanel employee={employee} />);
    expect(await screen.findByText(/Catch-up is unavailable until designated Roth support is verified/)).toBeTruthy();
    expect(screen.queryByText('$35,750.00')).toBeNull();
    expect(screen.getAllByText('$24,500.00').length).toBeGreaterThan(0);
  });
  it('lets staff read evidence while reserving changes for configuration administrators', async () => {
    mocks.canManage = false;
    render(<EmployeeRetirementYearPanel employee={employee} />);
    await screen.findByText(/employer wages need verification before catch-up/);
    expect(screen.queryByRole('button', { name: 'Review yearly records' })).toBeNull();
  });
  it('saves verified no-prior-employer wages with zero and retained provenance', async () => {
    const user = userEvent.setup();
    mocks.create.mockImplementation(async (_id, draft) => ({ data: { ...draft, id: 9 } }));
    render(<EmployeeRetirementYearPanel employee={employee} />);
    await user.click(await screen.findByRole('button', { name: 'Review yearly records' }));
    await user.selectOptions(screen.getByLabelText(`${year - 1} wages from this employer`), 'no_prior_employer_wages');
    await user.type(screen.getByLabelText('Employer wage evidence reference'), 'New hire verification');
    await user.type(screen.getByLabelText('Evidence reference'), 'Administrator review 12');
    await user.type(screen.getByLabelText('Review note'), 'Verified employee joined this year');
    await user.click(screen.getByRole('button', { name: 'Save verified records' }));
    await waitFor(() => expect(mocks.create).toHaveBeenCalledWith(5, expect.objectContaining({
      tax_year: year, prior_year_wage_status: 'no_prior_employer_wages', prior_year_fica_wages: 0,
      prior_year_wage_source: 'New hire verification', source_reference: 'Administrator review 12',
    })));
    expect(await screen.findByText(/retirement records saved/)).toBeTruthy();
  });
  it('keeps unknown wages null when recording other evidence', async () => {
    const user = userEvent.setup();
    mocks.create.mockImplementation(async (_id, draft) => ({ data: { ...draft, id: 10 } }));
    render(<EmployeeRetirementYearPanel employee={employee} />);
    await user.click(await screen.findByRole('button', { name: 'Review yearly records' }));
    await user.type(screen.getByLabelText('Evidence reference'), 'Outside plan statement');
    await user.type(screen.getByLabelText('Review note'), 'Employer wages pending');
    await user.click(screen.getByRole('button', { name: 'Save verified records' }));
    await waitFor(() => expect(mocks.create).toHaveBeenCalledWith(5, expect.objectContaining({ prior_year_wage_status: 'unknown', prior_year_fica_wages: null })));
  });
  it('allows replacing the year with keyboard entry and avoids current-election historical assumptions', async () => {
    const user = userEvent.setup();
    mocks.list.mockResolvedValue({ data: [{ ...limit, tax_year: year - 1 }] });
    render(<EmployeeRetirementYearPanel employee={employee} />);
    await screen.findByRole('button', { name: 'Review yearly records' });
    const input = screen.getByLabelText('Retirement evidence payroll year');
    await user.clear(input);
    await user.type(input, String(year - 1));
    await user.tab();
    expect((input as HTMLInputElement).value).toBe(String(year - 1));
    expect(screen.getAllByText('$24,500.00').length).toBeGreaterThan(0);
    expect(screen.queryByText('$35,750.00')).toBeNull();
  });
  it('recovers failed loading without showing invented evidence', async () => {
    const user = userEvent.setup();
    mocks.inputs.mockRejectedValueOnce(new Error('Evidence service unavailable')).mockResolvedValueOnce({ data: [] });
    render(<EmployeeRetirementYearPanel employee={employee} />);
    expect(await screen.findByRole('alert')).toHaveProperty('textContent', expect.stringContaining('Evidence service unavailable'));
    await user.click(screen.getByRole('button', { name: 'Retry loading evidence' }));
    expect(await screen.findByRole('button', { name: 'Review yearly records' })).toBeTruthy();
  });
  it('requires explicit types for every retained amount and a separate confirmation', async () => {
    const user = userEvent.setup();
    mocks.inputs.mockResolvedValue({ data: [], historical_retirement_sources: [historicalSource] });
    mocks.create.mockImplementation(async (_id, draft) => ({ data: { ...draft, id: 11 } }));
    render(<EmployeeRetirementYearPanel employee={employee} />);
    expect(await screen.findByText('Confirm imported contribution types')).toBeTruthy();
    expect(screen.getByText('Original payroll category: Pre-tax deductions')).toBeTruthy();
    expect(screen.getByText('$1,234.56')).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Review yearly records' }));
    const first = screen.getByLabelText('Contribution type for 401(k) After Tax (Pre-tax deductions)');
    const second = screen.getByLabelText('Contribution type for 401(k) Voluntary (After-tax deductions)');
    expect((first as HTMLSelectElement).value).toBe('');
    await enterReviewNote(user);
    await user.click(screen.getByLabelText(/I verified these opening balances/));
    await user.click(screen.getByRole('button', { name: 'Save verified records' }));
    expect(screen.getByRole('alert').textContent).toContain('Choose the contribution type for every retained');
    await user.selectOptions(first, '401k_after_tax');
    await user.click(screen.getByRole('button', { name: 'Save verified records' }));
    expect(mocks.create).not.toHaveBeenCalled();
    await user.selectOptions(second, '401k_non_roth_after_tax');
    await user.click(screen.getByRole('button', { name: 'Save verified records' }));
    expect(screen.getByRole('alert').textContent).toContain('Confirm the retained historical');
    await user.click(screen.getByLabelText(/I confirmed each retained historical contribution type/));
    await user.click(screen.getByRole('button', { name: 'Save verified records' }));
    await waitFor(() => expect(mocks.create).toHaveBeenCalledWith(5, expect.objectContaining({
      historical_retirement_review: reviewed, external_roth_deferrals: 0, external_traditional_deferrals: 0,
    })));
    expect(await screen.findByText('Imported contribution types verified')).toBeTruthy();
    expect(screen.getByText('Reviewed as: Roth 401(k)')).toBeTruthy();
  });
  it('preserves a current retained classification when saving another wage review', async () => {
    const user = userEvent.setup();
    mocks.inputs.mockResolvedValue({ data: [{ id: 1, tax_year: year, prior_year_wage_status: 'unknown', historical_retirement_review: reviewed, source_reference: 'Prior review', reason: 'Confirmed' }], historical_retirement_sources: [historicalSource] });
    mocks.create.mockImplementation(async (_id, draft) => ({ data: { ...draft, id: 12 } }));
    render(<EmployeeRetirementYearPanel employee={employee} />);
    await user.click(await screen.findByRole('button', { name: 'Record updated yearly records' }));
    expect(screen.queryByLabelText(/I confirmed each retained historical contribution type/)).toBeNull();
    await user.type(screen.getByLabelText('Review note'), 'Wage review only');
    await user.click(screen.getByRole('button', { name: 'Save verified records' }));
    await waitFor(() => expect(mocks.create).toHaveBeenCalledWith(5, expect.objectContaining({ historical_retirement_review: reviewed })));
  });
  it.each([
    { ...reviewed, balance_digest: 'stale-digest' },
    { ...reviewed, classifications: reviewed.classifications!.map((entry) => ({ ...entry, amount: '1.00' })) },
  ])('requires a new review for stale digest or changed retained amounts', async (staleReview) => {
    const user = userEvent.setup();
    mocks.inputs.mockResolvedValue({ data: [{ id: 1, tax_year: year, prior_year_wage_status: 'unknown', historical_retirement_review: staleReview }], historical_retirement_sources: [historicalSource] });
    render(<EmployeeRetirementYearPanel employee={employee} />);
    expect(await screen.findByText('Confirm imported contribution types')).toBeTruthy();
    await user.click(screen.getByRole('button', { name: 'Review yearly records' }));
    expect((screen.getByLabelText('Contribution type for 401(k) After Tax (Pre-tax deductions)') as HTMLSelectElement).value).toBe('');
  });
  it('uses only the selected payroll year retained source and resets confirmation when a type changes', async () => {
    const user = userEvent.setup();
    mocks.inputs.mockResolvedValue({ data: [], historical_retirement_sources: [historicalSource, { ...historicalSource, tax_year: year - 1, balance_digest: 'prior-year', classifications: [{ ...historicalSource.classifications[0], source_label: 'Prior year only', amount: '300.00' }] }] });
    render(<EmployeeRetirementYearPanel employee={employee} />);
    await user.click(await screen.findByRole('button', { name: 'Review yearly records' }));
    expect(screen.queryByText('Prior year only')).toBeNull();
    const confirmation = screen.getByLabelText(/I confirmed each retained historical contribution type/) as HTMLInputElement;
    await user.click(confirmation);
    await user.selectOptions(screen.getByLabelText('Contribution type for 401(k) After Tax (Pre-tax deductions)'), '401k_pre_tax');
    expect(confirmation.checked).toBe(false);
    const input = screen.getByLabelText('Retirement evidence payroll year');
    await user.clear(input);
    await user.type(input, String(year - 1));
    await user.tab();
    expect(await screen.findByText('Prior year only')).toBeTruthy();
    expect(screen.queryByText('401(k) After Tax')).toBeNull();
  });

  it('opens the requested payroll year and preserves it in saved evidence', async () => {
    const user = userEvent.setup();
    mocks.list.mockResolvedValue({ data: [{ ...limit, tax_year: year - 1 }] });
    mocks.create.mockImplementation(async (_id, draft) => ({ data: { ...draft, id: 15 } }));
    render(<EmployeeRetirementYearPanel employee={employee} initialYear={year - 1} />);
    await user.click(await screen.findByRole('button', { name: 'Review yearly records' }));
    expect((screen.getByLabelText('Retirement evidence payroll year') as HTMLInputElement).value).toBe(String(year - 1));
    expect(document.getElementById('retirement-year-evidence')).toBeTruthy();
    await enterReviewNote(user);
    await user.click(screen.getByRole('button', { name: 'Save verified records' }));
    await waitFor(() => expect(mocks.create).toHaveBeenCalledWith(5, expect.objectContaining({ tax_year: year - 1, prior_year_fica_wages: null, prior_year_wage_status: 'unknown' })));
  });
  it.each([NaN, 1999, 2201, 2026.5])('ignores invalid requested payroll years', async (initialYear) => {
    render(<EmployeeRetirementYearPanel employee={employee} initialYear={initialYear} />);
    await screen.findByRole('button', { name: 'Review yearly records' });
    expect((screen.getByLabelText('Retirement evidence payroll year') as HTMLInputElement).value).toBe(String(year));
  });

});
