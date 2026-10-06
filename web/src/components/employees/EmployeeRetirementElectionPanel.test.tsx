// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { renderToStaticMarkup } from 'react-dom/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EmployeeRetirementElectionPanel } from './EmployeeRetirementElectionPanel';
import type { Employee, EmployeeRetirementElection } from '@/types';
const mocks = vi.hoisted(() => ({ create: vi.fn() }));
vi.mock('@/services/api', () => ({ employeesApi: { createRetirementElection: mocks.create }, ApiError: class ApiError extends Error { fieldErrors = {}; } }));
vi.mock('@/contexts/AuthContext', () => ({ useAuth: () => ({ hasCapability: () => true }) }));

vi.hoisted(() => {
  vi.stubGlobal('localStorage', {
    getItem: () => null,
    setItem: () => undefined,
    removeItem: () => undefined,
  });
});

function election(overrides: Partial<EmployeeRetirementElection> = {}): EmployeeRetirementElection {
  return {
    id: 91,
    employee_id: 5,
    company_id: 1,
    effective_on: '2026-09-20',
    plan_name: 'MoSa 401(k)',
    eligible: true,
    participating: true,
    traditional_contribution_type: 'fixed',
    traditional_rate: 0,
    traditional_amount: 500,
    roth_contribution_type: 'fixed',
    roth_rate: 0,
    roth_amount: 250,
    eligible_compensation: 'gross_wages',
    catch_up_enabled: true,
    limit_priority: 'proportional',
    employer_match_mode: 'employee_deferral_percentage',
    employer_match_rate: 1,
    employer_match_deferral_cap_rate: 0.04,
    employer_match_ytd_before_system: 900,
    employer_match_destination: 'traditional',
    true_up_policy: 'year_to_date',
    source: 'staff',
    reason: 'Signed election',
    created_at: '2026-09-13T07:00:00+10:00',
    ...overrides,
  };
}

describe('retirement election setup', () => {
  beforeEach(() => { vi.clearAllMocks(); mocks.create.mockResolvedValue({ data: {} }); });
  afterEach(cleanup);
  it('shows a future-only first election as scheduled instead of reopening a blank setup form', () => {
    const upcoming = election();
    const employee = {
      id: 5,
      retirement_rate: 0,
      roth_retirement_rate: 0,
      current_retirement_election: null,
      upcoming_retirement_election: upcoming,
      retirement_elections: [upcoming],
    } as unknown as Employee;

    const html = renderToStaticMarkup(<EmployeeRetirementElectionPanel employee={employee} onSaved={async () => undefined} />);

    expect(html).toContain('Scheduled:');
    expect(html).toContain('takes over automatically');
    expect(html).toContain('Record contribution change');
    expect(html).not.toContain('Save contribution change');
    expect(html).not.toContain('Record a dated election before the next payroll');
  });
  it('uses the positive legacy Roth match instead of a zero Traditional match', async () => {
    const user = userEvent.setup();
    render(<EmployeeRetirementElectionPanel employee={{ id: 5, employer_retirement_match_rate: 0, employer_roth_match_rate: 0.03 } as Employee} onSaved={async () => undefined} />);
    await user.click(screen.getByRole('button', { name: 'Set up retirement' }));
    expect((screen.getByLabelText('Employer match percentage') as HTMLInputElement).value).toBe('3.00');
    expect((screen.getByLabelText('Employer contribution destination') as HTMLSelectElement).value).toBe('roth');
  });
  it('retains an explicit dated-election zero match even when legacy Roth match is positive', async () => {
    const user = userEvent.setup();
    render(<EmployeeRetirementElectionPanel employee={{ id: 5, employer_retirement_match_rate: 0, employer_roth_match_rate: 0.03, current_retirement_election: election({ employer_match_rate: 0 }) } as Employee} onSaved={async () => undefined} />);
    await user.click(screen.getByRole('button', { name: 'Record contribution change' }));
    expect((screen.getByLabelText('Employer match percentage') as HTMLInputElement).value).toBe('0.00');
    expect((screen.getByLabelText('Employer contribution destination') as HTMLSelectElement).value).toBe('traditional');
  });
  it('blocks saving when legacy employer match has two positive destinations', async () => {
    const user = userEvent.setup();
    render(<EmployeeRetirementElectionPanel employee={{ id: 5, employer_retirement_match_rate: 0.02, employer_roth_match_rate: 0.03 } as Employee} onSaved={async () => undefined} />);
    expect(screen.getByRole('alert').textContent).toContain('cannot preserve the split');
    await user.click(screen.getByRole('button', { name: 'Set up retirement' }));
    expect((screen.getByRole('button', { name: 'Save contribution change' }) as HTMLButtonElement).disabled).toBe(true);
  });

  it.each([
    [election(), '$750.00 each payroll'],
    [election({ traditional_contribution_type: 'percentage', traditional_rate: 0.04, roth_contribution_type: 'percentage', roth_rate: 0.06 }), '10.00% of eligible pay'],
    [election({ roth_contribution_type: 'percentage', roth_rate: 0.05 }), '$500.00 + 5.00% of eligible pay'],
  ])('shows a truthful combined contribution summary', (current, summary) => {
    render(<EmployeeRetirementElectionPanel employee={{ id: 5, current_retirement_election: current } as Employee} onSaved={async () => undefined} />);
    expect(screen.getByText(summary)).toBeTruthy();
    expect(screen.getByText('Plan allows catch-up')).toBeTruthy();
    expect(document.getElementById('retirement-plan')).toBeTruthy();
  });
  it('explains catch-up without adding a deduction and preserves the saved payload', async () => {
    const user = userEvent.setup();
    const current = election({ plan_source_reference: 'Verified signed plan', roth_available: true });
    render(<EmployeeRetirementElectionPanel employee={{ id: 5, date_of_birth: '1965-06-01', current_retirement_election: current } as Employee} onSaved={async () => undefined} />);
    await user.click(screen.getByRole('button', { name: 'Record contribution change' }));
    expect(screen.getByText(/Catch-up raises the annual limit; it does not add another deduction/)).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Review yearly retirement checks' }).getAttribute('href')).toBe('#retirement-year-evidence');
    await user.type(screen.getByLabelText('First pay date using this election'), '2026-10-08');
    await user.type(screen.getByLabelText(/Reason for this change/), 'Signed election updated');
    await user.click(screen.getByRole('button', { name: 'Save contribution change' }));
    expect(mocks.create).toHaveBeenCalledWith(5, expect.objectContaining({ traditional_amount: 500, roth_amount: 250, catch_up_enabled: true, plan_source_reference: 'Verified signed plan', limit_priority: 'proportional' }));
  });
  it('reports a saved election separately from a failed refresh', async () => {
    const user = userEvent.setup();
    render(<EmployeeRetirementElectionPanel employee={{ id: 5, current_retirement_election: election({ catch_up_enabled: false, roth_amount: 0 }) } as Employee} onSaved={async () => { throw new Error('Refresh failed'); }} />);
    await user.click(screen.getByRole('button', { name: 'Record contribution change' }));
    await user.type(screen.getByLabelText('First pay date using this election'), '2026-10-08');
    await user.type(screen.getByLabelText(/Reason for this change/), 'Signed election updated');
    await user.click(screen.getByRole('button', { name: 'Save contribution change' }));
    expect((await screen.findByRole('status')).textContent).toContain('Contribution change saved. The employee record could not refresh.');
    expect(mocks.create).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('alert')).toBeNull();
  });

});
