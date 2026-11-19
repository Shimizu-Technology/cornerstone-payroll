// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MemoryRouter, Route, Routes } from 'react-router';
import { FeedbackProvider } from '@/components/ui/action-feedback';
import { YearEndChecklist } from './YearEndChecklist';
import type { YearEndChecklist as Checklist, YearEndStep } from '@/lib/year-end';

const mocks = vi.hoisted(() => ({
  checklist: vi.fn(), acknowledge: vi.fn(), updateResponsibility: vi.fn(), preflight: vi.fn(), markReady: vi.fn(),
  companyGet: vi.fn(), companyUpdate: vi.fn(), employeeUpdate: vi.fn(),
}));
vi.mock('@/services/api', () => ({
  yearEndApi: { checklist: mocks.checklist, acknowledge: mocks.acknowledge },
  reportsApi: {
    updatePayrollFilingResponsibility: mocks.updateResponsibility, w2GuPreflight: mocks.preflight, w2GuMarkReady: mocks.markReady,
    payrollFilingRecord: vi.fn(async () => ({ filing: null })),
  },
  companiesApi: { get: mocks.companyGet, update: mocks.companyUpdate },
  employeesApi: { update: mocks.employeeUpdate },
  ApiError: class ApiError extends Error {
    data: unknown;
    constructor(message: string, data?: unknown) { super(message); this.data = data; }
  },
}));
vi.mock('@/contexts/CompanyContext', () => ({ useCompany: () => ({ activeCompany: { id: 7, name: 'Tumon Bakery' }, activeCompanyId: 7 }) }));

const permissions = { can_record_decision: true, can_acknowledge: true, can_mark_ready: true };

function step(key: YearEndStep['key'], number: number, title: string, status: YearEndStep['status'], extra: Partial<YearEndStep> = {}): YearEndStep {
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
    data: { w2: null, form_1099: null, w2_employee_count: 4, contractor_count: 0, has_imported_history: false },
  }),
  step('employer', 2, 'Employer details', 'waiting'),
  step('people', 3, 'Employees and payees', 'waiting'),
  step('reconciliation', 4, 'Reconcile W-2s to the 941s and W-1s', 'waiting'),
  step('review_warnings', 5, 'Review warnings', 'waiting'),
  step('prior_provider', 6, 'Prior provider overlap', 'waiting'),
  step('mark_ready', 7, 'Mark W-2s ready', 'waiting'),
];

const decided = step('filing_decision', 1, 'Who files 2026 forms', 'done', {
  data: { w2_employee_count: 4, contractor_count: 0, has_imported_history: false,
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

function working(overrides: { reconciliation?: 'match' | 'mismatch'; warnings?: YearEndStep; people?: YearEndStep; markReady?: YearEndStep } = {}): YearEndStep[] {
  const recon = overrides.reconciliation ?? 'match';
  return [
    decided,
    step('employer', 2, 'Employer details', 'done', { data: { name: 'Tumon Bakery', ein: '98-7654321', address_line1: '1 Marine Dr', city: 'Tamuning', state: 'GU', zip: '96913', phone: '671-555-0100', email: 'office@example.test' } }),
    overrides.people ?? step('people', 3, 'Employees and payees', 'done', { data: { employees: [], contractors: [], w2_employee_count: 4, contractor_count: 0, contractor_error: null } }),
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

function renderPage() {
  render(
    <FeedbackProvider>
      <MemoryRouter initialEntries={['/companies/7/year-end?year=2026']}>
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

  it('records a prior provider for part of the year as a separate W-2 decision', async () => {
    mocks.checklist.mockResolvedValueOnce(checklist(undecided)).mockResolvedValue(checklist(working()));

    renderPage();

    fireEvent.click(await screen.findByRole('radio', { name: /Cornerstone files, after a prior provider/ }));
    fireEvent.change(screen.getByLabelText('The prior provider files wages paid through'), { target: { value: '2026-03-31' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save who files' }));

    await waitFor(() => expect(mocks.updateResponsibility).toHaveBeenCalledTimes(2));
    expect(mocks.updateResponsibility).toHaveBeenNthCalledWith(1, expect.objectContaining({ filing_types: ['w2_gu'], responsible_party: 'cornerstone', prior_provider_through: '2026-03-31', imported_payroll_inclusion: 'included' }));
    expect(mocks.updateResponsibility).toHaveBeenNthCalledWith(2, expect.objectContaining({ filing_types: ['form_1099'], responsible_party: 'no_filing' }));
    expect(await screen.findByText('Saved who files.')).toBeTruthy();
  });

  it('takes a record with no forms off the list in one action', async () => {
    mocks.checklist.mockResolvedValueOnce(checklist(undecided)).mockResolvedValue(checklist(undecided.map((entry) => ({ ...entry, status: entry.key === 'filing_decision' ? 'done' : 'not_needed', issues: [] }) as YearEndStep), { status: 'not_filing', files_w2: false }));

    renderPage();

    fireEvent.click(await screen.findByRole('button', { name: 'This record files no 2026 forms' }));

    await waitFor(() => expect(mocks.updateResponsibility).toHaveBeenCalledWith(expect.objectContaining({ filing_types: ['w2_gu', 'form_1099'], responsible_party: 'no_filing' })));
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

  it('fixes an address inline and links to the employee when the SSN is missing', async () => {
    const people = step('people', 3, 'Employees and payees', 'action_needed', {
      issues: [{ code: 'EMPLOYEE_DETAILS_MISSING', message: 'Ana Cruz is missing an address.', employee_id: 11 }, { code: 'EMPLOYEE_DETAILS_MISSING', message: 'Ben Reyes is missing an SSN.', employee_id: 12 }],
      data: { w2_employee_count: 4, contractor_count: 0, contractor_error: null, contractors: [], employees: [
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

    await waitFor(() => expect(mocks.acknowledge).toHaveBeenCalledWith({ tax_year: 2026, warning_code: 'qualified_overtime_unreviewed', warning_digest: 'abc', note: 'Salaried manager; not qualified overtime.' }));
  });

  it('runs a fresh preflight, then marks ready on that fingerprint', async () => {
    const markedReady = step('mark_ready', 7, 'Mark W-2s ready', 'done', { data: { filing: { status: 'filing_ready', stale: false, marked_ready_at: '2026-11-19T02:00:00Z', notes: 'Checked' }, can_mark_ready: true, remaining_before_ready: 0 } });
    mocks.checklist.mockResolvedValueOnce(checklist(working())).mockResolvedValue(checklist(working({ markReady: markedReady })));
    mocks.preflight.mockResolvedValue({ preflight: { blocking_count: 0, findings: [] }, filing: { preflight_fingerprint: 'fp-1' } });
    mocks.markReady.mockResolvedValue({ filing: {} });

    renderPage();

    fireEvent.change(await screen.findByLabelText('Notes (optional)'), { target: { value: 'Checked' } });
    fireEvent.click(screen.getByRole('button', { name: 'Mark 2026 W-2s ready' }));

    await waitFor(() => expect(mocks.markReady).toHaveBeenCalledWith(2026, 'Checked', 'fp-1'));
    expect(mocks.preflight).toHaveBeenCalledWith(2026);
    expect(await screen.findByText('Ready')).toBeTruthy();
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
