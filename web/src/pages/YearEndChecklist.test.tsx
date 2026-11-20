// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MemoryRouter, Route, Routes, useNavigate } from 'react-router';
import { FeedbackProvider } from '@/components/ui/action-feedback';
import { YearEndChecklist } from './YearEndChecklist';
import { ApiError } from '@/services/api';
import type { ActiveYearEndStep, YearEndChecklist as Checklist, YearEndIssue, YearEndStep } from '@/lib/year-end';

const mocks = vi.hoisted(() => ({
  checklist: vi.fn(), acknowledge: vi.fn(), downloadDocument: vi.fn(), updateResponsibility: vi.fn(), preflight: vi.fn(), markReady: vi.fn(),
  companyGet: vi.fn(), companyUpdate: vi.fn(), employeeUpdate: vi.fn(),
}));
vi.mock('@/services/api', () => ({
  yearEndApi: { checklist: mocks.checklist, acknowledge: mocks.acknowledge, downloadDocument: mocks.downloadDocument },
  reportsApi: {
    updatePayrollFilingResponsibility: mocks.updateResponsibility, w2GuPreflight: mocks.preflight, w2GuMarkReady: mocks.markReady,
    payrollFilingRecord: vi.fn(async () => ({ filing: null })),
  },
  companiesApi: { get: mocks.companyGet, update: mocks.companyUpdate },
  employeesApi: { update: mocks.employeeUpdate },
  ApiError: class ApiError extends Error {
    status: number;
    details?: unknown;
    data: unknown;
    constructor(message: string, status = 500, details?: unknown, data?: unknown) { super(message); this.status = status; this.details = details; this.data = data; }
  },
}));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompany: { id: 7, name: 'Tumon Bakery' }, activeCompanyId: 7 }) }));

const permissions = { can_record_decision: true, can_acknowledge: true, can_mark_ready: true };

// A step that ran must carry its full data, typed by key.
function step<K extends YearEndStep['key']>(key: K, number: number, title: string, status: YearEndStep['status'],
  extra: { issues?: YearEndIssue[]; data?: ActiveYearEndStep<K>['data'] } = {}): YearEndStep {
  return { key, number, title, status, summary: `${title} summary`, issues: [], data: {}, ...extra } as YearEndStep;
}

function checklist(steps: YearEndStep[], overrides: Partial<Checklist> = {}): { data: Checklist } {
  const next = steps.find((entry) => entry.status === 'action_needed');
  return {
    data: {
      company: { id: 7, name: 'Tumon Bakery', active: true, test_workspace: false },
      tax_year: 2026, status: next ? 'needs_action' : 'ready', issue_count: steps.reduce((sum, entry) => sum + entry.issues.length, 0),
      next_step: next?.key ?? null, files_w2: true, files_1099: false, permissions, steps, ...overrides,
    },
  };
}

const undecided = [
  step('filing_decision', 1, 'Who files 2026 forms', 'action_needed', {
    issues: [{ code: 'W2_FILER_NOT_CHOSEN', message: 'Choose who files 2026 W-2s.' }],
    data: { w2: null, form_1099: null, w2_employee_count: 4, contractor_count: 0, one_off_payee_count: 0, has_imported_history: false },
  }),
  step('employer', 2, 'Employer details', 'waiting'),
  step('people', 3, 'Employees and payees', 'waiting'),
  step('reconciliation', 4, 'Reconcile W-2s to the 941s and W-1s', 'waiting'),
  step('review_warnings', 5, 'Review warnings', 'waiting'),
  step('prior_provider', 6, 'Prior provider overlap', 'waiting'),
  step('mark_ready', 7, 'Mark W-2s ready', 'waiting'),
];

const decided = step('filing_decision', 1, 'Who files 2026 forms', 'done', {
  data: { w2_employee_count: 4, contractor_count: 0, one_off_payee_count: 0, has_imported_history: false,
    w2: { id: 1, filing_type: 'w2_gu', responsible_party: 'cornerstone', prior_provider_through: null, notes: null, label: 'Cornerstone files', reviewed_at: null, reviewed_by: { id: 1, name: 'Dafne', email: 'd@example.test', role: 'admin' } },
    form_1099: { id: 2, filing_type: 'form_1099', responsible_party: 'no_filing', prior_provider_through: null, notes: null, label: 'No forms this year', reviewed_at: null, reviewed_by: { id: 1, name: 'Dafne', email: 'd@example.test', role: 'admin' } } },
});

function reconciliationLine(status: 'match' | 'mismatch') {
  return {
    key: 'social_security_wages', label: 'Social Security wages', w2_box: 'Box 3', source: 'form_941' as const, source_label: 'Form 941 line 5a',
    w2_total: 3800, quarterly_total: status === 'match' ? 3800 : 4000, opening_balances: 0, difference: status === 'match' ? 0 : -200, status,
    quarters: [1, 2, 3, 4].map((quarter) => ({ quarter, amount: quarter === 2 && status === 'mismatch' ? 2000 : quarter === 1 ? 2000 : 0, payroll_records: quarter <= 2 ? (quarter === 2 ? 1800 : 2000) : 0, difference: quarter === 2 && status === 'mismatch' ? 200 : 0 })),
    look_at: status === 'match' ? [] : [{ kind: 'quarter' as const, quarter: 2, label: 'Q2 941', detail: 'The Q2 941 shows $2,000.00, but Q2 payroll records total $1,800.00.' }],
    message: status === 'match' ? null : 'W-2 Box 3 (Social Security wages) is $200.00 less than the 941s and opening balances. Look at the Q2 941.',
  };
}

function printAndFile(final: boolean): YearEndStep {
  return step('print_and_file', 8, 'Print and file', 'available', {
    data: {
      final,
      documents: [{
        key: 'w2_employee_copies', title: 'Employee copies (B and C)', description: 'Print and give to each employee by Feb 1, 2027.',
        detail: '4 employees, one sheet each.', format: 'pdf', contains_full_ssn: false, draft: !final, available: true, unavailable_reason: null,
        download: { path: '/admin/reports/w2_gu_employee_copies', params: { year: 2026 } },
      }],
    },
  });
}

function working(overrides: { reconciliation?: 'match' | 'mismatch'; warnings?: YearEndStep; people?: YearEndStep; markReady?: YearEndStep } = {}): YearEndStep[] {
  const recon = overrides.reconciliation ?? 'match';
  return [
    decided,
    step('employer', 2, 'Employer details', 'done', { data: { name: 'Tumon Bakery', ein: '98-7654321', address_line1: '1 Marine Dr', address_line2: null, city: 'Tamuning', state: 'GU', zip: '96913', phone: '671-555-0100', email: 'office@example.test' } }),
    overrides.people ?? step('people', 3, 'Employees and payees', 'done', { data: { employees: [], contractors: [], one_off_payees: [], w2_employee_count: 4, contractor_count: 0, contractor_error: null } }),
    step('reconciliation', 4, 'Reconcile W-2s to the 941s and W-1s', recon === 'match' ? 'done' : 'action_needed', {
      issues: recon === 'match' ? [] : [{ code: 'RECONCILIATION_MISMATCH', line: 'social_security_wages', message: reconciliationLine('mismatch').message! }],
      data: { status: recon, tolerance: 0.01, quarters: [], opening_balances: { present: false, first_pay_date: null, last_pay_date: null }, lines: [reconciliationLine(recon)] },
    }),
    overrides.warnings ?? step('review_warnings', 5, 'Review warnings', 'done', { data: { warnings: [] } }),
    step('prior_provider', 6, 'Prior provider overlap', 'done', { data: { prior_provider_through: null, overlaps: [] } }),
    overrides.markReady ?? step('mark_ready', 7, 'Mark W-2s ready', 'action_needed', {
      issues: [{ code: 'W2_NOT_MARKED_READY', message: 'Mark the 2026 W-2s ready once everything above is done.' }],
      data: { filing: null, can_mark_ready: recon === 'match', remaining_before_ready: recon === 'match' ? 0 : 1 },
    }),
  ];
}

function OpenOtherClient() {
  const navigate = useNavigate();
  return <button type="button" onClick={() => navigate('/companies/8/year-end?year=2026')}>Open Agana Auto</button>;
}

function renderPage() {
  render(
    <FeedbackProvider>
      <MemoryRouter initialEntries={['/companies/7/year-end?year=2026']}>
        <OpenOtherClient />
        <Routes><Route path="/companies/:companyId/year-end" element={<YearEndChecklist />} /></Routes>
      </MemoryRouter>
    </FeedbackProvider>,
  );
}

describe('Year-end checklist', () => {
  afterEach(cleanup);
  beforeEach(() => {
    vi.clearAllMocks();
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-11-19T12:00:00+10:00'));
    mocks.updateResponsibility.mockResolvedValue({ data: [] });
  });
  afterEach(() => vi.useRealTimers());

  it('asks who files first and locks the later steps', async () => {
    mocks.checklist.mockResolvedValue(checklist(undecided));

    renderPage();

    expect(await screen.findByText('1 thing to fix')).toBeTruthy();
    expect(screen.getByText('Next: step 1, who files 2026 forms.')).toBeTruthy();
    expect(screen.getAllByText('After step 1')).toHaveLength(6);
    expect(mocks.checklist).toHaveBeenCalledWith(2026, 7);
    // No contractor payments, so the 1099 answer starts at "no 1099s"; W-2s must be chosen.
    expect((screen.getByRole('radio', { name: /No 1099s for 2026/ }) as HTMLInputElement).checked).toBe(true);
    expect(screen.getByRole('button', { name: 'Save who files' })).toHaveProperty('disabled', true);
  });

  it('saves the W-2 decision with its prior provider and the 1099 decision in one request', async () => {
    mocks.checklist.mockResolvedValueOnce(checklist(undecided)).mockResolvedValue(checklist(working()));

    renderPage();

    fireEvent.click(await screen.findByRole('radio', { name: /Cornerstone files, after a prior provider/ }));
    fireEvent.change(screen.getByLabelText('The prior provider files wages paid through'), { target: { value: '2026-03-31' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save who files' }));

    await waitFor(() => expect(mocks.updateResponsibility).toHaveBeenCalledTimes(1));
    expect(mocks.updateResponsibility).toHaveBeenCalledWith({
      tax_year: 2026, imported_payroll_inclusion: 'included', notes: undefined,
      decisions: [
        { filing_type: 'w2_gu', responsible_party: 'cornerstone', prior_provider_through: '2026-03-31' },
        { filing_type: 'form_1099', responsible_party: 'no_filing', prior_provider_through: null },
      ],
    }, 7);
    expect(await screen.findByText('Saved who files.')).toBeTruthy();
  });

  it('keeps both answers on screen and saves nothing else when the combined save is refused', async () => {
    mocks.checklist.mockResolvedValue(checklist(undecided));
    mocks.updateResponsibility.mockRejectedValueOnce(new ApiError('Prior provider through must be in 2026', 422));

    renderPage();

    const radio = (group: string, value: string) => document.querySelector<HTMLInputElement>(`input[name="${group}"][value="${value}"]`)!;
    await screen.findByRole('button', { name: 'Save who files' });
    fireEvent.click(radio('w2-party', 'cornerstone'));
    fireEvent.click(radio('form-1099-party', 'client'));
    fireEvent.click(screen.getByRole('button', { name: 'Save who files' }));

    expect(await screen.findByText('Prior provider through must be in 2026')).toBeTruthy();
    expect(mocks.updateResponsibility).toHaveBeenCalledTimes(1);
    expect(mocks.checklist).toHaveBeenCalledTimes(1);
    expect(radio('w2-party', 'cornerstone').checked).toBe(true);
    expect(radio('form-1099-party', 'client').checked).toBe(true);
    expect(screen.getByRole('button', { name: 'Save who files' })).toHaveProperty('disabled', false);
  });

  it('does not default the 1099 answer to "no 1099s" when the only 1099 activity is one-off checks', async () => {
    mocks.checklist.mockResolvedValue(checklist(undecided.map((entry) => entry.key === 'filing_decision'
      ? step('filing_decision', 1, 'Who files 2026 forms', 'action_needed', {
        issues: entry.issues,
        data: { w2: null, form_1099: null, w2_employee_count: 0, contractor_count: 0, one_off_payee_count: 1, has_imported_history: false },
      })
      : entry)));

    renderPage();

    expect(await screen.findByText('Paid here in 2026: 1 payee paid by one-off contractor checks.')).toBeTruthy();
    expect(screen.getAllByRole('radio', { checked: true }).map((radio) => radio.getAttribute('name'))).toEqual(['w2-party']);
    expect((screen.getByRole('radio', { name: /No 1099s for 2026/ }) as HTMLInputElement).checked).toBe(false);
    expect(screen.getByRole('button', { name: 'Save who files' })).toHaveProperty('disabled', true);
  });

  it('keeps both decisions on the client it started with and stops when the user opens another client mid-save', async () => {
    mocks.checklist.mockImplementation(async (_year: number, companyId: number) => checklist(undecided, {
      company: { id: companyId, name: companyId === 8 ? 'Agana Auto' : 'Tumon Bakery', active: true, test_workspace: false },
    }));
    let finishFirst: (value: { data: unknown[] }) => void = () => undefined;
    mocks.updateResponsibility.mockImplementationOnce(() => new Promise((resolve) => { finishFirst = resolve; }));

    renderPage();

    fireEvent.click(await screen.findByRole('radio', { name: /Cornerstone files, after a prior provider/ }));
    fireEvent.change(screen.getByLabelText('The prior provider files wages paid through'), { target: { value: '2026-03-31' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save who files' }));
    await waitFor(() => expect(mocks.updateResponsibility).toHaveBeenCalledTimes(1));
    expect(mocks.updateResponsibility).toHaveBeenCalledWith(expect.objectContaining({
      decisions: [expect.objectContaining({ filing_type: 'w2_gu' }), expect.objectContaining({ filing_type: 'form_1099' })],
    }), 7);

    fireEvent.click(screen.getByRole('button', { name: 'Open Agana Auto' }));
    await waitFor(() => expect(mocks.checklist).toHaveBeenCalledWith(2026, 8));
    finishFirst({ data: [] });
    await new Promise((resolve) => setTimeout(resolve, 0));

    // Both answers went to the first client in one request, and no success shows on the new page.
    expect(mocks.updateResponsibility).toHaveBeenCalledTimes(1);
    expect(screen.queryByText('Saved who files.')).toBeNull();
    expect(mocks.checklist).toHaveBeenLastCalledWith(2026, 8);
    expect(await screen.findByText('1 thing to fix')).toBeTruthy();
  });

  it('takes a record with no forms off the list in one action', async () => {
    mocks.checklist.mockResolvedValueOnce(checklist(undecided)).mockResolvedValue(checklist(undecided.map((entry) => ({ ...entry, status: entry.key === 'filing_decision' ? 'done' : 'not_needed', issues: [] }) as YearEndStep), { status: 'not_filing', files_w2: false }));

    renderPage();

    fireEvent.click(await screen.findByRole('button', { name: 'This record files no 2026 forms' }));

    await waitFor(() => expect(mocks.updateResponsibility).toHaveBeenCalledWith(expect.objectContaining({ decisions: [
      { filing_type: 'w2_gu', responsible_party: 'no_filing', prior_provider_through: null },
      { filing_type: 'form_1099', responsible_party: 'no_filing', prior_provider_through: null },
    ] }), 7));
    expect(await screen.findByText('No forms by Cornerstone')).toBeTruthy();
    expect(screen.getByText(/It is off the to-do list; nothing was deleted/)).toBeTruthy();
  });

  it('shows a reconciliation mismatch, names the quarter, and keeps mark ready closed', async () => {
    mocks.checklist.mockResolvedValue(checklist(working({ reconciliation: 'mismatch' })));

    renderPage();

    const recon = await screen.findByRole('region', { name: /Reconcile W-2s/ });
    expect(within(recon).getAllByText('Off by $200.00').length).toBeGreaterThan(0);
    expect(within(recon).getAllByText(/The Q2 941 shows \$2,000.00/).length).toBeGreaterThan(0);
    const ready = screen.getByRole('region', { name: /Mark W-2s ready/ });
    expect(within(ready).getByText('Finish the 1 item above first. This step opens when they are done.')).toBeTruthy();
    expect(within(ready).queryByRole('button', { name: /Mark 2026 W-2s ready/ })).toBeNull();
  });

  it('links each mismatch to the report for the checklist year and quarter, and W-1 lines to the W-1', async () => {
    const steps = working({ reconciliation: 'mismatch' });
    const w1Line = {
      ...reconciliationLine('mismatch'), key: 'guam_income_tax', label: 'Guam income tax withheld', w2_box: 'Box 2', source: 'w1' as const, source_label: 'W-1 Guam withholding',
      look_at: [{ kind: 'quarter' as const, quarter: 3, label: 'Q3 W-1', detail: 'The Q3 W-1 shows $100.00, but Q3 payroll records total $150.00.' }],
    };
    const recon = steps[3] as ActiveYearEndStep<'reconciliation'>;
    steps[3] = { ...recon, data: { ...recon.data, lines: [...recon.data.lines, w1Line] } };
    mocks.checklist.mockResolvedValue(checklist(steps));

    renderPage();

    const region = await screen.findByRole('region', { name: /Reconcile W-2s/ });
    const form941 = within(region).getAllByRole('link', { name: 'Open the Q2 Form 941' });
    expect(form941.length).toBeGreaterThan(0);
    form941.forEach((link) => expect(link.getAttribute('href')).toBe('/reports?report=941-gu&year=2026&quarter=2'));
    const w1 = within(region).getAllByRole('link', { name: 'Open the Q3 W-1' });
    expect(w1.length).toBeGreaterThan(0);
    w1.forEach((link) => expect(link.getAttribute('href')).toBe('/reports?report=quarterly-compliance-packet&year=2026&quarter=3'));
  });

  it('says the quarters differ when the year totals agree', async () => {
    const steps = working({ reconciliation: 'mismatch' });
    const recon = steps[3] as ActiveYearEndStep<'reconciliation'>;
    const line = { ...reconciliationLine('mismatch'), w2_total: 4000, quarterly_total: 4000, difference: 0,
      look_at: [1, 2].map((quarter) => ({ kind: 'quarter' as const, quarter, label: `Q${quarter} 941`, detail: `The Q${quarter} 941 differs.` })) };
    steps[3] = { ...recon, data: { ...recon.data, lines: [line] } };
    mocks.checklist.mockResolvedValue(checklist(steps));

    renderPage();

    const region = await screen.findByRole('region', { name: /Reconcile W-2s/ });
    expect(within(region).getAllByText('Quarters differ').length).toBeGreaterThan(0);
    expect(within(region).queryByText('Off by $0.00')).toBeNull();
    expect(within(region).getAllByRole('link', { name: 'Open the Q1 Form 941' }).length).toBeGreaterThan(0);
  });

  it('shows a wage-base split as matching in total and names a quarter whose 941 withholding is off', async () => {
    const base = working({ reconciliation: 'match' });
    const explained = { ...reconciliationLine('match'), w2_total: 184500, quarterly_total: 179500, difference: 5000, status: 'explained' as const,
      note: 'Box 3 and Box 7 split Social Security wages and tips differently from lines 5a and 5b by $5,000.00, because the W-2 applies the wage base to wages first. Box 3 + Box 7 equals lines 5a + 5b.' };
    const recon = step('reconciliation', 4, 'Reconcile W-2s to the 941s and W-1s', 'action_needed', {
      issues: [{ code: 'FORM_941_WITHHOLDING_MISMATCH', line: null, quarter: 2, message: 'The Q2 941: employee Social Security and Medicare withheld is $124.00 less than the employee share of the quarter\'s wages.' }],
      data: { status: 'mismatch', tolerance: 0.01, quarters: [], opening_balances: { present: false, first_pay_date: null, last_pay_date: null }, lines: [explained],
        form_941_reviews: [{ quarter: 2, status: 'unexplained', employee_difference: -124, expected_employee_total: 153, recorded_employee_total: 29, recorded_liability_residual: 0, message: 'The Q2 941: employee Social Security and Medicare withheld is $124.00 less than the employee share of the quarter\'s wages.' }] },
    });
    mocks.checklist.mockResolvedValue(checklist(base.map((entry) => (entry.key === 'reconciliation' ? recon : entry))));

    renderPage();

    const region = await screen.findByRole('region', { name: /Reconcile W-2s/ });
    expect(within(region).getAllByText('Matches in total').length).toBeGreaterThan(0);
    expect(within(region).getAllByText(/Box 3 \+ Box 7 equals lines 5a \+ 5b/).length).toBeGreaterThan(0);
    expect(within(within(region).getByRole('list', { name: '941 withholding problems' })).getByText(/The Q2 941: employee Social Security/)).toBeTruthy();
  });

  it('fixes an address inline and links to the employee when the SSN is missing', async () => {
    const people = step('people', 3, 'Employees and payees', 'action_needed', {
      issues: [{ code: 'EMPLOYEE_DETAILS_MISSING', message: 'Ana Cruz is missing an address.', employee_id: 11 }, { code: 'EMPLOYEE_DETAILS_MISSING', message: 'Ben Reyes is missing an SSN.', employee_id: 12 }],
      data: { w2_employee_count: 4, contractor_count: 0, contractor_error: null, contractors: [], one_off_payees: [], employees: [
        { employee_id: 11, name: 'Ana Cruz', kind: 'employee', missing_fields: ['address'], address_line1: null, address_line2: null, city: null, state: null, zip: null, edit_path: '' },
        { employee_id: 12, name: 'Ben Reyes', kind: 'employee', missing_fields: ['ssn'], address_line1: '1 Main', address_line2: null, city: 'Hagatna', state: 'GU', zip: '96910', edit_path: '' },
      ] },
    });
    mocks.checklist.mockResolvedValueOnce(checklist(working({ people }))).mockResolvedValue(checklist(working()));
    mocks.employeeUpdate.mockResolvedValue({ data: {} });

    renderPage();

    expect(await screen.findByRole('link', { name: 'Open Ben Reyes' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Add address for Ben Reyes' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Add address for Ana Cruz' }));
    fireEvent.change(screen.getByLabelText('Street address'), { target: { value: '12 Chalan Santo Papa' } });
    fireEvent.change(screen.getByLabelText('City'), { target: { value: 'Hagatna' } });
    fireEvent.change(screen.getByLabelText('ZIP'), { target: { value: '96910' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save address' }));

    await waitFor(() => expect(mocks.employeeUpdate).toHaveBeenCalledWith(11, { address_line1: '12 Chalan Santo Papa', address_line2: '', city: 'Hagatna', state: 'GU', zip: '96910' }, 7));
    expect(await screen.findByText("Saved Ana Cruz's address.")).toBeTruthy();
  });

  it('keeps the address form usable and shows the error when the refresh after a save fails', async () => {
    const people = step('people', 3, 'Employees and payees', 'action_needed', {
      issues: [{ code: 'EMPLOYEE_DETAILS_MISSING', message: 'Ana Cruz is missing an address.', employee_id: 11 }],
      data: { w2_employee_count: 1, contractor_count: 0, contractor_error: null, contractors: [], one_off_payees: [], employees: [
        { employee_id: 11, name: 'Ana Cruz', kind: 'employee', missing_fields: ['address'], address_line1: null, address_line2: null, city: null, state: null, zip: null, edit_path: '' },
      ] },
    });
    mocks.checklist.mockResolvedValueOnce(checklist(working({ people }))).mockRejectedValue(new Error('The checklist could not be refreshed.'));
    mocks.employeeUpdate.mockResolvedValue({ data: {} });

    renderPage();

    fireEvent.click(await screen.findByRole('button', { name: 'Add address for Ana Cruz' }));
    fireEvent.change(screen.getByLabelText('Street address'), { target: { value: '12 Chalan Santo Papa' } });
    fireEvent.change(screen.getByLabelText('City'), { target: { value: 'Hagatna' } });
    fireEvent.change(screen.getByLabelText('ZIP'), { target: { value: '96910' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save address' }));

    await waitFor(() => expect(mocks.employeeUpdate).toHaveBeenCalledTimes(1));
    expect(await screen.findByText('The checklist could not be refreshed.')).toBeTruthy();
    await waitFor(() => expect((screen.getByRole('button', { name: 'Save address' }) as HTMLButtonElement).disabled).toBe(false));
    expect((screen.getByRole('button', { name: 'Cancel' }) as HTMLButtonElement).disabled).toBe(false);
  });

  it('asks who a one-off 1099 payee is, links to the checks, and records the answer on this client', async () => {
    const payee = {
      code: 'one_off_payee:non_employee_check:41', payee_key: 'non_employee_check:41', name: 'Synthetic Roofing', total_compensation: 2500, payment_count: 2,
      checks: [{ id: 41, check_number: '9001', payment_date: '2026-05-02', amount: 1500 }, { id: 42, check_number: '9002', payment_date: '2026-06-05', amount: 1000 }],
      checks_path: '/checks-payments', digest: 'payee-digest', status: 'needs_identity' as const, acknowledgement: null, acknowledgement_stale: false,
    };
    const people = step('people', 3, 'Employees and payees', 'action_needed', {
      issues: [{ code: 'PAYEE_IDENTITY_UNRESOLVED', message: 'Synthetic Roofing was paid $2,500.00 by checks 9001 and 9002 with no contractor record or TIN. Record who this payee is.', warning_code: payee.code }],
      data: { w2_employee_count: 4, contractor_count: 0, contractor_error: null, employees: [], contractors: [], one_off_payees: [payee] },
    });
    mocks.checklist.mockResolvedValueOnce(checklist(working({ people }), { files_1099: true })).mockResolvedValue(checklist(working(), { files_1099: true }));
    mocks.acknowledge.mockResolvedValue({ data: {} });

    renderPage();

    const region = await screen.findByRole('region', { name: /Employees and payees/ });
    expect(within(region).getByText('Identify this payee')).toBeTruthy();
    expect(within(region).getByText(/#9001 on May 2, 2026 \(\$1,500\.00\), #9002 on Jun 5, 2026 \(\$1,000\.00\)/)).toBeTruthy();
    expect(within(region).getByRole('link', { name: 'Open checks for Synthetic Roofing' }).getAttribute('href')).toBe('/checks-payments');
    fireEvent.change(within(region).getByLabelText('Who is this payee, and where is their W-9 and TIN?'), { target: { value: 'Synthetic Roofing LLC; W-9 in the client folder.' } });
    fireEvent.click(within(region).getByRole('button', { name: 'Record payee' }));

    await waitFor(() => expect(mocks.acknowledge).toHaveBeenCalledWith({ tax_year: 2026, warning_code: payee.code, warning_digest: 'payee-digest', note: 'Synthetic Roofing LLC; W-9 in the client folder.' }, 7));
    expect(await screen.findByText('Recorded who Synthetic Roofing is.')).toBeTruthy();
  });

  it('records a reviewed acknowledgement with a note, and shows a blocker as fix-first', async () => {
    const warnings = step('review_warnings', 5, 'Review warnings', 'action_needed', {
      issues: [{ code: 'JUDGMENT_WARNING_BLOCKING', message: 'x', warning_code: 'tipped_occupation_code_missing' }, { code: 'JUDGMENT_WARNING_UNREVIEWED', message: 'y', warning_code: 'qualified_overtime_unreviewed' }],
      data: { warnings: [
        { code: 'qualified_overtime_unreviewed', kind: 'acknowledge', title: 'Overtime without qualified-overtime amounts', explanation: 'Review the overtime.', status: 'needs_review', digest: 'abc', period: null, employees: [{ employee_id: 11, name: 'Ana Cruz', edit_path: '/companies/7/employees/11' }], acknowledgement: null, acknowledgement_stale: false },
        { code: 'tipped_occupation_code_missing', kind: 'blocker', title: 'Tipped employees without an occupation code', explanation: 'Add the code.', status: 'blocked', digest: 'def', period: null, employees: [{ employee_id: 12, name: 'Ben Reyes', edit_path: '/companies/7/employees/12' }], acknowledgement: null, acknowledgement_stale: false },
      ] },
    });
    mocks.checklist.mockResolvedValueOnce(checklist(working({ warnings }))).mockResolvedValue(checklist(working()));
    mocks.acknowledge.mockResolvedValue({ data: {} });

    renderPage();

    const region = await screen.findByRole('region', { name: /Review warnings/ });
    expect(within(region).getByText('Fix before filing')).toBeTruthy();
    expect(within(region).getAllByRole('button', { name: 'Mark reviewed' })).toHaveLength(1);
    expect(within(region).getByRole('button', { name: 'Mark reviewed' })).toHaveProperty('disabled', true);
    fireEvent.change(within(region).getByLabelText('What did you check and confirm?'), { target: { value: 'Salaried manager; not qualified overtime.' } });
    fireEvent.click(within(region).getByRole('button', { name: 'Mark reviewed' }));

    await waitFor(() => expect(mocks.acknowledge).toHaveBeenCalledWith({ tax_year: 2026, warning_code: 'qualified_overtime_unreviewed', warning_digest: 'abc', note: 'Salaried manager; not qualified overtime.' }, 7));
  });

  it('lets the reviewer save again when the reloaded warning still needs review', async () => {
    const warnings = step('review_warnings', 5, 'Review warnings', 'action_needed', {
      issues: [{ code: 'JUDGMENT_WARNING_UNREVIEWED', message: 'y', warning_code: 'qualified_overtime_unreviewed' }],
      data: { warnings: [
        { code: 'qualified_overtime_unreviewed', kind: 'acknowledge', title: 'Overtime without qualified-overtime amounts', explanation: 'Review the overtime.', status: 'needs_review', digest: 'abc', period: null, employees: [], acknowledgement: null, acknowledgement_stale: false },
      ] },
    });
    mocks.checklist.mockResolvedValue(checklist(working({ warnings })));
    mocks.acknowledge.mockResolvedValue({ data: {} });

    renderPage();

    const region = await screen.findByRole('region', { name: /Review warnings/ });
    fireEvent.change(within(region).getByLabelText('What did you check and confirm?'), { target: { value: 'Checked the timesheets.' } });
    fireEvent.click(within(region).getByRole('button', { name: 'Mark reviewed' }));
    await waitFor(() => expect(mocks.checklist).toHaveBeenCalledTimes(2));

    await waitFor(() => expect(within(screen.getByRole('region', { name: /Review warnings/ })).getByRole('button', { name: 'Mark reviewed' })).toHaveProperty('disabled', false));
    expect(within(screen.getByRole('region', { name: /Review warnings/ })).getByLabelText('What did you check and confirm?')).toHaveProperty('disabled', false);
  });

  it('adds print and file after the sign-off: folded while it holds drafts, open once the copies are final', async () => {
    const printStep = (final: boolean) => step('print_and_file', 8, 'Print and file', 'available', {
      data: {
        final,
        documents: [{
          key: 'w2_employee_copies', title: 'Employee copies (B and C)', description: 'Print and give to each employee by Feb 1, 2027.',
          detail: '4 employees, one sheet each.', format: 'pdf', contains_full_ssn: false, draft: !final, available: true, unavailable_reason: null,
          download: { path: '/admin/reports/w2_gu_employee_copies', params: { year: 2026 } },
        }],
      },
    });
    const markedReady = step('mark_ready', 7, 'Mark W-2s ready', 'done', { data: { filing: { status: 'filing_ready', stale: false, marked_ready_at: '2026-11-19T02:00:00Z', notes: null }, can_mark_ready: true, remaining_before_ready: 0 } });
    mocks.checklist.mockResolvedValueOnce(checklist([...working(), printStep(false)], { status: 'needs_action', issue_count: 1, next_step: 'mark_ready' }));

    renderPage();

    const drafts = await screen.findByRole('region', { name: /Print and file/ });
    expect(within(drafts).getByText('Downloads')).toBeTruthy();
    expect(within(drafts).queryByRole('heading', { name: 'Employee copies (B and C)' })).toBeNull();
    fireEvent.click(within(drafts).getByRole('button', { name: 'Show Print and file' }));
    expect(within(drafts).getByRole('button', { name: 'Download draft' })).toBeTruthy();
    expect(screen.getByText('Next: step 7, mark w-2s ready.')).toBeTruthy();

    cleanup();
    mocks.checklist.mockResolvedValue(checklist([...working({ markReady: markedReady }), printStep(true)], { status: 'ready', issue_count: 0, next_step: null }));
    renderPage();

    const final = await screen.findByRole('region', { name: /Print and file/ });
    expect(within(final).getByRole('button', { name: 'Download PDF' })).toBeTruthy();
    expect(screen.getByText('Ready')).toBeTruthy();
  });

  it('opens print and file when marking ready on this page makes the copies final, and keeps a later collapse', async () => {
    const markedReady = step('mark_ready', 7, 'Mark W-2s ready', 'done', { data: { filing: { status: 'filing_ready', stale: false, marked_ready_at: '2026-11-19T02:00:00Z', notes: null }, can_mark_ready: true, remaining_before_ready: 0 } });
    mocks.checklist
      .mockResolvedValueOnce(checklist([...working(), printAndFile(false)]))
      .mockResolvedValue(checklist([...working({ markReady: markedReady }), printAndFile(true)], { status: 'ready', issue_count: 0, next_step: null }));
    mocks.preflight.mockResolvedValue({ preflight: { blocking_count: 0, findings: [] }, filing: { preflight_fingerprint: 'fp-1' } });
    mocks.markReady.mockResolvedValue({ filing: {} });

    renderPage();

    const region = await screen.findByRole('region', { name: /Print and file/ });
    expect(within(region).getByRole('button', { name: 'Show Print and file' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Mark 2026 W-2s ready' }));

    // Same step, not remounted: it opens because the copies became final.
    expect(await within(region).findByRole('button', { name: 'Download PDF' })).toBeTruthy();
    expect(screen.getByRole('region', { name: /Print and file/ })).toBe(region);

    fireEvent.click(within(region).getByRole('button', { name: 'Hide Print and file' }));
    expect(within(region).getByRole('button', { name: 'Show Print and file' })).toBeTruthy();
    expect(within(region).queryByRole('button', { name: 'Download PDF' })).toBeNull();
  });

  it('still saves a download when print and file is collapsed while it runs', async () => {
    const createObjectURL = vi.fn(() => 'blob:w2');
    Object.assign(URL, { createObjectURL, revokeObjectURL: vi.fn() });
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
    let finish: (value: { blob: Blob; filename: string }) => void = () => {};
    mocks.downloadDocument.mockReturnValue(new Promise((resolve) => { finish = resolve; }));
    mocks.checklist.mockResolvedValue(checklist([...working(), printAndFile(true)], { status: 'ready', issue_count: 0, next_step: null }));

    renderPage();

    const region = await screen.findByRole('region', { name: /Print and file/ });
    fireEvent.click(within(region).getByRole('button', { name: 'Download PDF' }));
    fireEvent.click(within(region).getByRole('button', { name: 'Hide Print and file' }));
    expect(within(region).queryByRole('button', { name: /Preparing PDF/ })).toBeNull();

    finish({ blob: new Blob(['%PDF'], { type: 'application/pdf' }), filename: 'W-2GU_2026_Tumon_Bakery_Employee_Copies_B_C.pdf' });

    await waitFor(() => expect(createObjectURL).toHaveBeenCalledTimes(1));
    expect(click).toHaveBeenCalledTimes(1);
    click.mockRestore();
  });

  it.each([
    { change: 'client', outcome: 'finishes' },
    { change: 'client', outcome: 'fails' },
    { change: 'tax year', outcome: 'finishes' },
    { change: 'tax year', outcome: 'fails' },
  ])('drops a download that $outcome after the user switches $change, even when the new checklist loads at once', async ({ change, outcome }) => {
    // January, so both 2026 and 2027 can be chosen.
    vi.setSystemTime(new Date('2027-01-15T12:00:00+10:00'));
    const createObjectURL = vi.fn(() => 'blob:w2');
    Object.assign(URL, { createObjectURL, revokeObjectURL: vi.fn() });
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
    let finish: () => void = () => {};
    mocks.downloadDocument.mockReturnValueOnce(new Promise((resolve, reject) => {
      finish = () => (outcome === 'finishes'
        ? resolve({ blob: new Blob(['%PDF'], { type: 'application/pdf' }), filename: 'W-2GU_2026_Tumon_Bakery_Employee_Copies_B_C.pdf' })
        : reject(new ApiError("This client's W-2 data changed while the file was being made. Download again.", 409)));
    }));
    const next = change === 'client'
      ? { company: { id: 8, name: 'Agana Auto', active: true, test_workspace: false } }
      : { tax_year: 2027 };
    // Resolved at once, so the new checklist can arrive in the same render
    // that clears the old one.
    mocks.checklist
      .mockResolvedValueOnce(checklist([...working(), printAndFile(true)], { status: 'ready', issue_count: 0, next_step: null }))
      .mockResolvedValue(checklist([...working(), printAndFile(true)], { status: 'ready', issue_count: 0, next_step: null, ...next }));

    renderPage();

    const before = await screen.findByRole('region', { name: /Print and file/ });
    fireEvent.click(within(before).getByRole('button', { name: 'Download PDF' }));
    expect(mocks.downloadDocument).toHaveBeenCalledWith(expect.objectContaining({ params: { year: 2026 } }), 7);
    if (change === 'client') fireEvent.click(screen.getByRole('button', { name: 'Open Agana Auto' }));
    else fireEvent.change(screen.getByLabelText('Tax year'), { target: { value: '2027' } });
    await waitFor(() => expect(mocks.checklist).toHaveBeenCalledTimes(2));
    expect(mocks.checklist).toHaveBeenLastCalledWith(change === 'client' ? 2026 : 2027, change === 'client' ? 8 : 7);

    // The new client's or year's step: its own row, not the old one still loading.
    const after = await screen.findByRole('region', { name: /Print and file/ });
    expect(after).not.toBe(before);
    expect(before.isConnected).toBe(false);
    await waitFor(() => expect(within(after).queryByRole('button', { name: /Preparing PDF/ })).toBeNull());
    expect(within(after).getByRole('button', { name: 'Download PDF' })).toHaveProperty('disabled', false);

    finish();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(createObjectURL).not.toHaveBeenCalled();
    expect(click).not.toHaveBeenCalled();
    expect(screen.queryByRole('alert')).toBeNull();
    expect(screen.queryByText(/data changed while the file was being made/)).toBeNull();
    click.mockRestore();
  });

  it('remounts print and file on a tax-year change, so a 2026 download still running is never saved or shown on 2027', async () => {
    vi.setSystemTime(new Date('2027-01-15T12:00:00+10:00'));
    const createObjectURL = vi.fn(() => 'blob:w2');
    Object.assign(URL, { createObjectURL, revokeObjectURL: vi.fn() });
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
    const settle: Array<() => void> = [];
    const pending = (outcome: 'finishes' | 'fails') => new Promise((resolve, reject) => {
      settle.push(() => (outcome === 'finishes'
        ? resolve({ blob: new Blob(['%PDF'], { type: 'application/pdf' }), filename: 'W-2GU_2026_Tumon_Bakery_Employee_Copies_B_C.pdf' })
        : reject(new ApiError('The download could not be recorded in the activity log, so the file was not sent. Try again.', 503))));
    });
    const printStep = (year: number) => {
      const base = printAndFile(true) as ActiveYearEndStep<'print_and_file'>;
      const document = base.data.documents[0];
      return { ...base, data: { ...base.data, documents: [document, { ...document, key: 'w2_drt_copy_1', title: 'Copy 1 for Guam DRT', download: { path: '/admin/reports/w2_gu_copy_1_drt', params: { year } } }]
        .map((entry) => ({ ...entry, download: { ...entry.download, params: { year } } })) } };
    };
    // Every load resolves at once, the case where the clear and the next
    // checklist could be batched into one render.
    mocks.checklist.mockImplementation(async (year: number) => checklist([...working(), printStep(year)], { status: 'ready', issue_count: 0, next_step: null, tax_year: year }));
    mocks.downloadDocument.mockReturnValueOnce(pending('finishes')).mockReturnValueOnce(pending('fails'));

    renderPage();

    const before = await screen.findByRole('region', { name: /Print and file/ });
    for (const button of within(before).getAllByRole('button', { name: 'Download PDF' })) fireEvent.click(button);
    expect(mocks.downloadDocument.mock.calls.map(([download]) => download.params)).toEqual([{ year: 2026 }, { year: 2026 }]);

    fireEvent.change(screen.getByLabelText('Tax year'), { target: { value: '2027' } });
    // The 2026 rows are gone as soon as the year changes.
    expect(before.isConnected).toBe(false);
    expect(await screen.findByText('2027 year-end checklist')).toBeTruthy();

    const after = await screen.findByRole('region', { name: /Print and file/ });
    expect(within(after).getAllByRole('button', { name: 'Download PDF' }).map((button) => button.hasAttribute('disabled'))).toEqual([false, false]);

    settle.forEach((done) => done());
    await new Promise((resolve) => setTimeout(resolve, 0));

    // Neither the 2026 file nor its failure reaches the 2027 page.
    expect(createObjectURL).not.toHaveBeenCalled();
    expect(click).not.toHaveBeenCalled();
    expect(screen.queryByRole('alert')).toBeNull();
    expect(screen.queryByText(/could not be recorded|W-2GU_2026/)).toBeNull();

    // A download started on 2027 asks for 2027.
    mocks.downloadDocument.mockReturnValueOnce(pending('finishes'));
    fireEvent.click(within(after).getAllByRole('button', { name: 'Download PDF' })[0]);
    expect(mocks.downloadDocument).toHaveBeenLastCalledWith(expect.objectContaining({ params: { year: 2027 } }), 7);
    click.mockRestore();
  });

  it('runs a fresh preflight, then marks ready on that fingerprint', async () => {
    const markedReady = step('mark_ready', 7, 'Mark W-2s ready', 'done', { data: { filing: { status: 'filing_ready', stale: false, marked_ready_at: '2026-11-19T02:00:00Z', notes: 'Checked' }, can_mark_ready: true, remaining_before_ready: 0 } });
    mocks.checklist.mockResolvedValueOnce(checklist(working())).mockResolvedValue(checklist(working({ markReady: markedReady })));
    mocks.preflight.mockResolvedValue({ preflight: { blocking_count: 0, findings: [] }, filing: { preflight_fingerprint: 'fp-1' } });
    mocks.markReady.mockResolvedValue({ filing: {} });

    renderPage();

    fireEvent.change(await screen.findByLabelText('Notes (optional)'), { target: { value: 'Checked' } });
    fireEvent.click(screen.getByRole('button', { name: 'Mark 2026 W-2s ready' }));

    await waitFor(() => expect(mocks.markReady).toHaveBeenCalledWith(2026, 'Checked', 'fp-1', 7));
    expect(mocks.preflight).toHaveBeenCalledWith(2026, 7);
    expect(await screen.findByText('Ready')).toBeTruthy();
  });

  it('keeps the note after a stale 409, refreshes on request, and needs the new numbers reviewed before resubmitting', async () => {
    const overtime = (digest: string, employees: number) => step('review_warnings', 5, 'Review warnings', 'action_needed', {
      issues: [{ code: 'JUDGMENT_WARNING_UNREVIEWED', message: 'y', warning_code: 'qualified_overtime_unreviewed' }],
      data: { warnings: [
        { code: 'qualified_overtime_unreviewed', kind: 'acknowledge', title: 'Overtime without qualified-overtime amounts', explanation: 'Review the overtime.', status: 'needs_review', digest, period: null,
          employees: [{ employee_id: 11, name: 'Ana Cruz', edit_path: '/companies/7/employees/11' }, { employee_id: 12, name: 'Ben Reyes', edit_path: '/companies/7/employees/12' }].slice(0, employees),
          acknowledgement: null, acknowledgement_stale: false },
      ] },
    });
    mocks.checklist.mockResolvedValueOnce(checklist(working({ warnings: overtime('old', 1) }))).mockResolvedValue(checklist(working({ warnings: overtime('new', 2) })));
    mocks.acknowledge
      .mockRejectedValueOnce(new ApiError('The data behind this warning changed. Reload the checklist and review it again.', 409))
      .mockResolvedValue({ data: {} });

    renderPage();

    const region = () => screen.getByRole('region', { name: /Review warnings/ });
    await screen.findByRole('region', { name: /Review warnings/ });
    fireEvent.change(within(region()).getByLabelText('What did you check and confirm?'), { target: { value: 'Salaried manager.' } });
    fireEvent.click(within(region()).getByRole('button', { name: 'Mark reviewed' }));

    expect(await within(region()).findByText(/changed after this page loaded, so nothing was saved/)).toBeTruthy();
    expect(within(region()).getByLabelText('What did you check and confirm?')).toHaveProperty('value', 'Salaried manager.');
    expect(within(region()).getByRole('button', { name: 'Mark reviewed' })).toHaveProperty('disabled', true);
    expect(mocks.checklist).toHaveBeenCalledTimes(1);

    fireEvent.click(within(region()).getByRole('button', { name: 'Refresh checklist' }));
    expect(await within(region()).findByRole('link', { name: 'Ben Reyes' })).toBeTruthy();
    expect(within(region()).getByLabelText('What did you check and confirm?')).toHaveProperty('value', 'Salaried manager.');
    // Nothing is resubmitted with the new digest until the reviewer confirms and submits.
    expect(mocks.acknowledge).toHaveBeenCalledTimes(1);
    expect(within(region()).getByRole('button', { name: 'Mark reviewed' })).toHaveProperty('disabled', true);
    fireEvent.click(within(region()).getByLabelText('I reviewed the updated numbers'));
    fireEvent.click(within(region()).getByRole('button', { name: 'Mark reviewed' }));

    await waitFor(() => expect(mocks.acknowledge).toHaveBeenCalledTimes(2));
    expect(mocks.acknowledge).toHaveBeenLastCalledWith({ tax_year: 2026, warning_code: 'qualified_overtime_unreviewed', warning_digest: 'new', note: 'Salaried manager.' }, 7);
  });

  it('offers the same stale-check recovery when identifying a one-off payee', async () => {
    const payee = (digest: string, amount: number) => ({
      code: 'one_off_payee:non_employee_check:41', payee_key: 'non_employee_check:41', name: 'Synthetic Roofing', total_compensation: 2500, payment_count: 2,
      checks: [{ id: 41, check_number: '9001', payment_date: '2026-05-02', amount }, { id: 42, check_number: '9002', payment_date: '2026-06-05', amount: 2500 - amount }],
      checks_path: '/checks-payments', digest, status: 'needs_identity' as const, acknowledgement: null, acknowledgement_stale: false,
    });
    const people = (digest: string, amount: number) => step('people', 3, 'Employees and payees', 'action_needed', {
      issues: [{ code: 'PAYEE_IDENTITY_UNRESOLVED', message: 'Identify Synthetic Roofing.', warning_code: 'one_off_payee:non_employee_check:41' }],
      data: { w2_employee_count: 4, contractor_count: 0, contractor_error: null, employees: [], contractors: [], one_off_payees: [payee(digest, amount)] },
    });
    mocks.checklist.mockResolvedValueOnce(checklist(working({ people: people('old', 1500) }), { files_1099: true }))
      .mockResolvedValue(checklist(working({ people: people('new', 1200) }), { files_1099: true }));
    mocks.acknowledge.mockRejectedValueOnce(new ApiError('The data behind this warning changed.', 409));

    renderPage();

    const region = await screen.findByRole('region', { name: /Employees and payees/ });
    fireEvent.change(within(region).getByLabelText('Who is this payee, and where is their W-9 and TIN?'), { target: { value: 'Synthetic Roofing LLC.' } });
    fireEvent.click(within(region).getByRole('button', { name: 'Record payee' }));
    fireEvent.click(await within(region).findByRole('button', { name: 'Refresh checklist' }));

    expect(await within(screen.getByRole('region', { name: /Employees and payees/ })).findByLabelText('I reviewed the updated checks')).toBeTruthy();
    expect(screen.getByText(/\(\$1,200\.00\), #9002 on Jun 5, 2026 \(\$1,300\.00\)/)).toBeTruthy();
    expect(screen.getByLabelText('Who is this payee, and where is their W-9 and TIN?')).toHaveProperty('value', 'Synthetic Roofing LLC.');
    expect(screen.getByRole('button', { name: 'Record payee' })).toHaveProperty('disabled', true);
    expect(mocks.acknowledge).toHaveBeenCalledTimes(1);
  });

  it('drops a save started under one tax year after the user switches years', async () => {
    // January, so both 2026 and 2027 can be chosen.
    vi.setSystemTime(new Date('2027-01-15T12:00:00+10:00'));
    const warnings = step('review_warnings', 5, 'Review warnings', 'action_needed', {
      issues: [{ code: 'JUDGMENT_WARNING_UNREVIEWED', message: 'y', warning_code: 'qualified_overtime_unreviewed' }],
      data: { warnings: [
        { code: 'qualified_overtime_unreviewed', kind: 'acknowledge', title: 'Overtime without qualified-overtime amounts', explanation: 'Review the overtime.', status: 'needs_review', digest: 'abc', period: null, employees: [], acknowledgement: null, acknowledgement_stale: false },
      ] },
    });
    mocks.checklist.mockImplementation(async (year: number) => checklist(working({ warnings }), { tax_year: year }));
    let finish: (value: { data: unknown }) => void = () => undefined;
    mocks.acknowledge.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));

    renderPage();

    const region = await screen.findByRole('region', { name: /Review warnings/ });
    fireEvent.change(within(region).getByLabelText('What did you check and confirm?'), { target: { value: 'Checked.' } });
    fireEvent.click(within(region).getByRole('button', { name: 'Mark reviewed' }));
    await waitFor(() => expect(mocks.acknowledge).toHaveBeenCalledWith(expect.objectContaining({ tax_year: 2026 }), 7));

    fireEvent.change(screen.getByLabelText('Tax year'), { target: { value: '2027' } });
    await waitFor(() => expect(mocks.checklist).toHaveBeenLastCalledWith(2027, 7));
    expect(await screen.findByText('2027 year-end checklist')).toBeTruthy();
    const calls = mocks.checklist.mock.calls.length;
    finish({ data: {} });
    await new Promise((resolve) => setTimeout(resolve, 0));

    // The 2026 save did not reload 2026 over the 2027 page or report success on it.
    expect(mocks.checklist).toHaveBeenCalledTimes(calls);
    expect(mocks.checklist).not.toHaveBeenLastCalledWith(2026, 7);
    expect(screen.queryByText(/Recorded your review/)).toBeNull();
  });

  it('says the permission check failed, with a retry, instead of sending the user to a manager', async () => {
    const employer = step('employer', 2, 'Employer details', 'action_needed', {
      issues: [{ code: 'EMPLOYER_PHONE_MISSING', message: 'Add the employer phone number for the W-3SS contact.', field: 'phone' }, { code: 'EMPLOYER_EIN_MISSING', message: 'Add the employer EIN.', field: 'ein' }],
      data: { name: 'Tumon Bakery', ein: null, address_line1: '1 Marine Dr', address_line2: null, city: 'Tamuning', state: 'GU', zip: '96913', phone: null, email: 'office@example.test' },
    });
    mocks.checklist.mockResolvedValue(checklist(working().map((entry) => (entry.key === 'employer' ? employer : entry))));
    mocks.companyGet.mockRejectedValueOnce(new Error('Network error')).mockResolvedValue({ company: { editable_fields: ['phone'] } });

    renderPage();

    const region = await screen.findByRole('region', { name: /Employer details/ });
    expect(await within(region).findByText(/Could not check which employer details you can edit/)).toBeTruthy();
    expect(within(region).queryByText(/manager or admin/)).toBeNull();
    expect(within(region).queryByLabelText('Phone')).toBeNull();

    fireEvent.click(within(region).getByRole('button', { name: 'Try again' }));

    expect(await within(region).findByLabelText('Phone')).toBeTruthy();
    // EIN is confirmed read-only for this user, so it stays locked.
    expect(within(region).queryByLabelText('EIN')).toBeNull();
    expect(within(region).getByText(/A manager or admin adds the EIN/)).toBeTruthy();
    expect(mocks.companyGet).toHaveBeenCalledTimes(2);
  });

  it('shows the load error with a retry', async () => {
    mocks.checklist.mockRejectedValueOnce(new Error('Choose a tax year from 2026 to 2027')).mockResolvedValue(checklist(working()));

    renderPage();

    const alert = await screen.findByRole('alert');
    expect(within(alert).getByText('Choose a tax year from 2026 to 2027')).toBeTruthy();
    fireEvent.click(within(alert).getByRole('button', { name: 'Try again' }));
    expect(await screen.findByText('1 thing to fix')).toBeTruthy();
  });
});
