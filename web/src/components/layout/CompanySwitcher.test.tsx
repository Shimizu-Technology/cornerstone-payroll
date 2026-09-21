// @vitest-environment jsdom

import { fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { beforeEach, describe, expect, it, vi } from 'vitest';
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
  beforeEach(() => {
    companyContext.mockReturnValue({
      companies: [
        {
          id: 1,
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
});
