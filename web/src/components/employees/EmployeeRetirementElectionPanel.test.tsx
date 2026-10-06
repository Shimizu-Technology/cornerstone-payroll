// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { renderToStaticMarkup } from 'react-dom/server';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { EmployeeRetirementElectionPanel } from './EmployeeRetirementElectionPanel';
import type { Employee, EmployeeRetirementElection } from '@/types';
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
    expect(html).toContain('New election');
    expect(html).not.toContain('Save retirement election');
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
    await user.click(screen.getByRole('button', { name: 'New election' }));
    expect((screen.getByLabelText('Employer match percentage') as HTMLInputElement).value).toBe('0.00');
    expect((screen.getByLabelText('Employer contribution destination') as HTMLSelectElement).value).toBe('traditional');
  });
  it('blocks saving when legacy employer match has two positive destinations', async () => {
    const user = userEvent.setup();
    render(<EmployeeRetirementElectionPanel employee={{ id: 5, employer_retirement_match_rate: 0.02, employer_roth_match_rate: 0.03 } as Employee} onSaved={async () => undefined} />);
    expect(screen.getByRole('alert').textContent).toContain('cannot preserve the split');
    await user.click(screen.getByRole('button', { name: 'Set up retirement' }));
    expect((screen.getByRole('button', { name: 'Save retirement election' }) as HTMLButtonElement).disabled).toBe(true);
  });

});
