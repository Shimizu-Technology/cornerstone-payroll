// @vitest-environment jsdom

import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CompanySwitcher } from './CompanySwitcher';

const { companyContext } = vi.hoisted(() => ({ companyContext: vi.fn() }));

vi.mock('@/contexts/CompanyContext', () => ({
  useCompany: () => companyContext(),
}));

vi.mock('@/lib/analytics', () => ({
  analytics: { companySwitch: vi.fn() },
}));

vi.mock('@/lib/keyboard-shortcuts', () => ({
  platformShortcut: () => '⌥K',
}));

describe('CompanySwitcher', () => {
  afterEach(cleanup);
  beforeEach(() => {
    companyContext.mockReturnValue({
      companies: [
        {
          id: 1,
          organization_id: 1,
          name: 'Production Alpha',
          active: true,
          active_employees: 12,
          total_employees: 12,
          pay_frequency: 'biweekly',
          historical_payroll_enabled: false,
          payroll_environment: 'live',
          test_workspace: false,
        },
        {
          id: 2,
          organization_id: 1,
          name: 'Alpha Training',
          active: true,
          active_employees: 12,
          total_employees: 12,
          pay_frequency: 'biweekly',
          historical_payroll_enabled: false,
          payroll_environment: 'migration_rehearsal',
          test_workspace: true,
          test_workspace_purpose_label: 'Training replay',
          migration_rehearsal_status: 'ready',
        },
      ],
      activeCompany: {
        id: 1,
        name: 'Production Alpha',
        active_employees: 12,
        payroll_environment: 'live',
      },
      canSwitchCompany: true,
      activeOrganizationId: 1,
      switchCompany: vi.fn(),
    });
  });

  it('separates production clients from test workspaces and labels their purpose', () => {
    render(
      <MemoryRouter>
        <CompanySwitcher />
      </MemoryRouter>,
    );

    fireEvent.click(screen.getByRole('button', { name: /Production Alpha/i }));

    expect(screen.getByText('Production clients')).toBeTruthy();
    expect(screen.getByText('Test workspaces')).toBeTruthy();
    expect(screen.getByText('Training replay · ready')).toBeTruthy();
  });

  it('shows only clients in the selected organization', () => {
    const context = companyContext();
    companyContext.mockReturnValue({
      ...context,
      companies: [...context.companies, {
        id: 3,
        organization_id: 2,
        name: 'Other firm client',
        active_employees: 2,
        payroll_environment: 'live',
      }],
    });

    render(<MemoryRouter><CompanySwitcher /></MemoryRouter>);
    fireEvent.click(screen.getByRole('button', { name: /Production Alpha/i }));
    expect(screen.queryByText('Other firm client')).toBeNull();
  });

  it('distinguishes punctuation and case duplicates without changing company names', async () => {
    const user = userEvent.setup();
    const context = companyContext();
    const companies = [
      { ...context.companies[0], id: 4, name: "MoSa's Hotbox Inc." },
      { ...context.companies[0], id: 6, name: "MOSA’S HOTBOX, INC." },
      { ...context.companies[0], id: 8, name: 'Distinct employer' },
    ];
    companyContext.mockReturnValue({ ...context, companies, activeCompany: companies[1] });
    render(<MemoryRouter><CompanySwitcher /></MemoryRouter>);
    const trigger = screen.getByRole('button', { name: 'Payroll client: MOSA’S HOTBOX, INC. · Client #6' });
    expect(trigger.getAttribute('aria-expanded')).toBe('false');
    await user.click(trigger);
    expect(trigger.getAttribute('aria-expanded')).toBe('true');
    expect(screen.getByRole('button', { name: 'MOSA’S HOTBOX, INC. · Client #6' }).getAttribute('aria-current')).toBe('true');
    expect(screen.getByRole('button', { name: 'Distinct employer' })).toBeTruthy();
    const olderClient = screen.getByRole('button', { name: "MoSa's Hotbox Inc. · Client #4" });
    await user.click(olderClient);
    expect(context.switchCompany).toHaveBeenCalledWith(4);
    expect(screen.queryByRole('group', { name: 'Payroll clients' })).toBeNull();
    expect(companies.map(company => company.name)).toEqual(["MoSa's Hotbox Inc.", 'MOSA’S HOTBOX, INC.', 'Distinct employer']);
  });

  it('updates labels after company context refresh and supports keyboard selection', async () => {
    const user = userEvent.setup();
    const context = companyContext();
    const first = { ...context.companies[0], id: 4, name: "MoSa's Hotbox Inc." };
    const second = { ...context.companies[0], id: 6, name: "MoSa's Hotbox, Inc. — Clean Migration" };
    companyContext.mockReturnValue({ ...context, companies: [first, second], activeCompany: second });
    const rendered = render(<MemoryRouter><CompanySwitcher /></MemoryRouter>);
    expect(screen.queryByText(/Client #/)).toBeNull();
    const renamed = { ...second, name: "MoSa's Hotbox, Inc." };
    companyContext.mockReturnValue({ ...context, companies: [first, renamed], activeCompany: renamed });
    rendered.rerender(<MemoryRouter><CompanySwitcher /></MemoryRouter>);
    const trigger = screen.getByRole('button', { name: "Payroll client: MoSa's Hotbox, Inc. · Client #6" });
    trigger.focus();
    await user.keyboard('{Enter}');
    const firstOption = screen.getByRole('button', { name: "MoSa's Hotbox Inc. · Client #4" });
    await user.tab();
    expect(document.activeElement).toBe(firstOption);
    await user.keyboard('{Escape}');
    expect(document.activeElement).toBe(trigger);
    expect(trigger.getAttribute('aria-expanded')).toBe('false');
    await user.keyboard('{Enter}');
    await user.tab();
    await user.keyboard('{Enter}');
    expect(context.switchCompany).toHaveBeenCalledWith(4);
  });

  it('does not disambiguate unique names using another organization', () => {
    const context = companyContext();
    const company = context.companies[0];
    companyContext.mockReturnValue({ ...context, companies: [company, { ...company, id: 9, organization_id: 2 }], activeCompany: company });
    render(<MemoryRouter><CompanySwitcher /></MemoryRouter>);
    expect(screen.getByText(company.name)).toBeTruthy();
    expect(screen.queryByText(/Client #/)).toBeNull();
  });

  it('distinguishes duplicate names even when switching is unavailable', () => {
    const context = companyContext();
    const company = context.companies[0];
    companyContext.mockReturnValue({ ...context, companies: [company, { ...company, id: 9 }], activeCompany: company, canSwitchCompany: false });
    render(<MemoryRouter><CompanySwitcher /></MemoryRouter>);
    expect(screen.getByText(`${company.name} · Client #${company.id}`)).toBeTruthy();
  });

});
