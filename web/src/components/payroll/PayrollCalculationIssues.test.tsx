// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it } from 'vitest';
import { PayrollCalculationIssues } from './PayrollCalculationIssues';

afterEach(cleanup);

it('groups repeated errors while keeping named employee-specific resolution links and payroll context', () => {
  const error = 'Review the applied historical 401(k) classification.';
  render(<MemoryRouter><PayrollCalculationIssues companyId={7} year={2027} returnTo="/companies/7/pay-runs/12/work" names={new Map([[30, 'Ana Cruz']])} failures={[
    { employee_id: 30, error }, { employee_id: 31, name: 'Ben Santos', error }, { employee_id: 32, error: 'An unfamiliar calculation problem' },
  ]} /></MemoryRouter>);
  expect(screen.getAllByText(error)).toHaveLength(1);
  expect(screen.getByText('Ana Cruz')).toBeTruthy();
  expect(screen.getByText('Ben Santos')).toBeTruthy();
  const links = screen.getAllByRole('link', { name: 'Review 2027 retirement checks' });
  expect(links[0].getAttribute('href')).toBe('/companies/7/employees/30/pay-setup?return_to=%2Fcompanies%2F7%2Fpay-runs%2F12%2Fwork&retirement_year=2027#retirement-year-evidence');
  expect(links[0].getAttribute('target')).toBe('_blank');
  expect(screen.getByRole('link', { name: 'Open employee pay setup' }).getAttribute('href')).toContain('/employees/32/pay-setup');
});
