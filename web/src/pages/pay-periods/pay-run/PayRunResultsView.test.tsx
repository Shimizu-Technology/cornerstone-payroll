// @vitest-environment jsdom
import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { ComponentProps } from 'react';
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
const setup = () => render(<MemoryRouter><PayRunResultsView {...props} /></MemoryRouter>);
it('defaults to employee and net together, opens the existing review and retains guarded corrections', async () => {
  const user = userEvent.setup(); setup();
  expect(screen.queryByRole('columnheader', { name: 'FIT' })).toBeNull();
  expect(screen.getByRole('columnheader', { name: 'Employee' })).toBeTruthy();
  const row = screen.getByRole('row', { name: /Maya Manual/ });
  expect(within(row).getByText('$975.00')).toBeTruthy();
  await user.click(within(row).getByRole('button', { name: 'Open payroll item' }));
  expect(review).toHaveBeenCalledWith(props.sortPayrollItems[0]);
  expect(within(row).getByText('Correct')).toBeTruthy();
  expect(within(row).getByText('Replace check')).toBeTruthy();
});
it('reveals full tax columns using the keyboard and persists the preference', async () => {
  const user = userEvent.setup(); const view = setup();
  const toggle = screen.getByRole('checkbox', { name: 'Show tax detail' }); toggle.focus();
  await user.keyboard(' ');
  expect(screen.getByRole('columnheader', { name: 'FIT' })).toBeTruthy();
  view.unmount(); setup();
  expect((screen.getByRole('checkbox', { name: 'Show tax detail' }) as HTMLInputElement).checked).toBe(true);
  expect(screen.getByRole('columnheader', { name: 'FIT' })).toBeTruthy();
});
