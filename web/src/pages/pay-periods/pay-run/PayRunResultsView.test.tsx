// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { ComponentProps } from 'react';
import type { PayrollItem } from '@/types';
import { PayRunResultsView } from './PayRunResultsView';

const review = vi.fn();
const props = {
  companyId: 1, currentPath: '/companies/1/pay-runs/2/work', isCalculated: false, isCommitted: true,
  payPeriod: { id: 2, status: 'committed', cycle: 'regular', can_issue_corrective_paycheck: true },
  payrollItems: [{ id: 4 }], sortPayrollItems: [{ id: 4, employee_id: 7, employee_name: 'Maya Manual', employment_type: 'hourly', hours_worked: 40, overtime_hours: 2, gross_pay: 1075, total_deductions: 100, net_pay: 975, check_number: '123' }],
  registerTotals: { hours: 42, gross: 1075, deductions: 100, net: 975 }, payrollItemDisplayedHours: () => 42,
  setReviewingItem: review, setEditingItem: vi.fn(), setCorrectingItem: vi.fn(), setReplacingItem: vi.fn(),
  filters: <input aria-label="Search employees" />, fullDetail: <table><thead><tr><th>FIT</th></tr></thead></table>,
} as unknown as ComponentProps<typeof PayRunResultsView>;
beforeEach(() => { localStorage.clear(); review.mockClear(); });
afterEach(cleanup);
const setup = (): ReturnType<typeof render> => render(<MemoryRouter><PayRunResultsView {...props} /></MemoryRouter>);
it('defaults to employee and net together, opens the existing review and retains guarded corrections', async (): Promise<void> => {
  const user = userEvent.setup(); setup();
  expect(screen.queryByRole('columnheader', { name: 'FIT' })).toBeNull();
  expect(screen.getByRole('columnheader', { name: 'Employee' })).toBeTruthy();
  const row = screen.getByRole('row', { name: /Maya Manual/ });
  expect(within(row).getByText('$975.00')).toBeTruthy();
  await user.click(within(row).getByRole('button', { name: 'Details: open payroll item' }));
  expect(review).toHaveBeenCalledWith(props.sortPayrollItems[0]);
  expect(within(row).getByText('Correct')).toBeTruthy();
  expect(within(row).getByText('Replace check')).toBeTruthy();
});

it.each([
  { baseSalary: true, regular: 0, source: null, expected: 'Not recorded' },
  { baseSalary: undefined, regular: 0, source: null, expected: 'Not recorded' },
  { baseSalary: false, regular: 0, source: null, expected: '—' },
  { baseSalary: true, regular: 0, source: 'schedule' as const, expected: '0.00' },
  { baseSalary: false, regular: 0, source: 'schedule' as const, expected: '0.00' },
  { baseSalary: true, regular: 8, source: null, expected: '8.00' },
])('preserves salary hours meaning on desktop and phone ($baseSalary / $regular / $source)', ({ baseSalary, regular, source, expected }): void => {
  const item: PayrollItem = { ...props.sortPayrollItems[0], employment_type: 'salary', hours_worked: regular, overtime_hours: 0, timekeeping_source: source };
  render(<MemoryRouter><PayRunResultsView {...props} payPeriod={{ ...props.payPeriod, ...(baseSalary === undefined ? {} : { includes_base_salary: baseSalary }) }} sortPayrollItems={[item]} payrollItemDisplayedHours={() => regular} /></MemoryRouter>);
  const row = screen.getByRole('row', { name: /Maya Manual/ });
  const desktopHours = within(row).getAllByRole('cell')[1];
  const phone = screen.getByRole('region', { name: 'Payroll result for Maya Manual' });
  const phoneHours = within(phone).getByText('Hours').nextElementSibling!;
  expect(desktopHours.textContent).toBe(expected);
  expect(phoneHours.textContent).toBe(expected);
  expect(screen.getByRole('row', { name: /Totals \(1\)/ }).textContent).toContain('42.00');
});
it('reveals full tax columns using the keyboard and persists the preference', async (): Promise<void> => {
  const user = userEvent.setup(); const view = setup();
  const toggle = screen.getByRole('checkbox', { name: 'Show tax detail' }); toggle.focus();
  await user.keyboard(' ');
  expect(screen.getByRole('columnheader', { name: 'FIT' })).toBeTruthy();
  view.unmount(); setup();
  expect((screen.getByRole('checkbox', { name: 'Show tax detail' }) as HTMLInputElement).checked).toBe(true);
  expect(screen.getByRole('columnheader', { name: 'FIT' })).toBeTruthy();
});
it('retains every combined flag and the contractor correction guards', (): void => {
  const item: PayrollItem = { ...props.sortPayrollItems[0], voided: true, correction_pay_basis_hold: { reason: 'Fixture source hold' }, withholding_tax_override: 0, employment_type: 'contractor', wage_rate_hours: [{ employee_wage_rate_id: 1, label: 'Base', rate: 25, regular_hours: 1, overtime_hours: 0, holiday_hours: 0, pto_hours: 0 }, { employee_wage_rate_id: 2, label: 'Other', rate: 30, regular_hours: 2, overtime_hours: 0, holiday_hours: 0, pto_hours: 0 }] };
  render(<MemoryRouter><PayRunResultsView {...props} sortPayrollItems={[item]} /></MemoryRouter>);
  const row = screen.getByRole('row', { name: /Maya Manual/ });
  for (const label of ['Voided', 'Pay setup held', 'FIT override', '1099', 'Multiple rates']) expect(row.textContent).toContain(label);
  expect(within(row).queryByText('Correct', { exact: true })).toBeNull();
  expect(within(row).queryByText('Replace check', { exact: true })).toBeNull();
});

it.each([
  { employmentType: 'hourly', regular: 16, overtime: 2, displayed: 18, split: true },
  { employmentType: 'hourly', regular: 16, overtime: 2, displayed: 20, split: false },
  { employmentType: 'salary', regular: 16, overtime: 0, displayed: 0, split: false },
  { employmentType: 'salary', regular: 16, overtime: 0, displayed: 16, split: false },
  { employmentType: 'contractor', regular: 16, overtime: 0, displayed: 0, split: false },
  { employmentType: 'contractor', regular: 0, overtime: 0, displayed: 0, split: false },
])('keeps desktop and phone hours consistent for $employmentType ($regular + $overtime → $displayed)', ({ employmentType, regular, overtime, displayed, split }): void => {
  const item = { ...props.sortPayrollItems[0], employment_type: employmentType as PayrollItem['employment_type'], hours_worked: regular, overtime_hours: overtime };
  render(<MemoryRouter><PayRunResultsView {...props} sortPayrollItems={[item]} payrollItemDisplayedHours={() => displayed} /></MemoryRouter>);
  const row = screen.getByRole('row', { name: /Maya Manual/ });
  const desktopHours = within(row).getAllByRole('cell')[1];
  const phone = screen.getByRole('region', { name: 'Payroll result for Maya Manual' });
  const phoneHours = within(phone).getByText('Hours').nextElementSibling!;
  const expectedSplit = `${regular.toFixed(2)} reg + ${overtime.toFixed(2)} OT`;
  for (const hours of [desktopHours, phoneHours]) {
    expect(hours.textContent).toContain(displayed.toFixed(2));
    expect(within(hours as HTMLElement).queryByText(expectedSplit) !== null).toBe(split);
  }
  // Display rules must not change the saved register totals.
  expect(screen.getByRole('row', { name: /Totals \(1\)/ }).textContent).toContain('42.00');
});

it.each([0, -12345678.90, 12345678.90])('retains exact money and cents in both result projections (%s)', (amount): void => {
  const item = { ...props.sortPayrollItems[0], gross_pay: amount, total_deductions: amount, net_pay: amount };
  render(<MemoryRouter><PayRunResultsView {...props} sortPayrollItems={[item]} /></MemoryRouter>);
  const expected = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(amount);
  const row = screen.getByRole('row', { name: /Maya Manual/ });
  const phone = screen.getByRole('region', { name: 'Payroll result for Maya Manual' });
  expect(within(row).getAllByText(expected)).toHaveLength(3);
  expect(within(phone).getAllByText(expected)).toHaveLength(3);
});
