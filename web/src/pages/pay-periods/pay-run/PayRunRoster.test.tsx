// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import type { ComponentProps } from 'react';
import { MemoryRouter } from 'react-router';
import { PayRunRoster } from './PayRunRoster';

afterEach(cleanup);
function props() {
  return {
    isCalculated: true, canEditPayPeriod: true, additionalEmployeeIds: new Set<number>(),
    employees: [{ id: 7, first_name: 'Manual', last_name: 'Worker', employment_type: 'hourly' }], payrollItems: [],
    payPeriod: { id: 1, status: 'calculated', run_purpose: 'regular', excluded_employee_ids: [7], excluded_employees: [{ employee_id: 7, name: 'Manual Worker', reason: 'No hours received' }] },
    handleRestoreEmployee: vi.fn().mockResolvedValue(undefined), addBackNotice: null, setAdditionalEmployeeIds: vi.fn(), setHoursMap: vi.fn(),
  } as unknown as ComponentProps<typeof PayRunRoster>;
}
it('shows removed names and reasons, then offers Enter pay in the unpaid roster', async () => {
  const data = props();
  const view = render(<PayRunRoster {...data} />);
  expect(screen.getByText('Removed from this run (1)')).toBeTruthy();
  expect(screen.getByText('No hours received')).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Enter pay' })).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: 'Add back Manual Worker' }));
  await waitFor(() => expect(data.handleRestoreEmployee).toHaveBeenCalledWith(7, 'roster'));
  // The controller keeps the result, so it survives the Hours step remounting as the run returns to draft.
  const result = { employee_id: 7, employee_name: 'Manual Worker', restored: [{ kind: 'loan' as const, label: 'Loan', amount: '150.0' }], not_restored: [] };
  const notice = { source: 'roster' as const, result, hoursEntered: false };
  view.rerender(<PayRunRoster {...data} isCalculated={false} isDraft addBackNotice={notice} payPeriod={{ ...data.payPeriod, status: 'draft', excluded_employee_ids: [], excluded_employees: [] }} />);
  const message = "Manual Worker is back. Restored from the import: Loan $150.00. Hours aren't brought back. Enter hours, then calculate.";
  expect(screen.getAllByText(message)).toHaveLength(2);
  expect(screen.getByTestId('add-back-announcement').textContent).toBe(message);
  view.rerender(<PayRunRoster {...data} addBackNotice={notice} payPeriod={{ ...data.payPeriod, excluded_employee_ids: [], excluded_employees: [] }} />);
  expect(screen.getByRole('button', { name: 'Enter pay' })).toBeTruthy();
  expect(screen.queryByRole('region', { name: 'Removed from this run' })).toBeNull();
});
it('shows an error and allows retry when a restore fails', async () => {
  const data = props();
  data.handleRestoreEmployee = vi.fn().mockRejectedValueOnce(new Error('Employee is ineligible')).mockResolvedValue(undefined);
  render(<PayRunRoster {...data} />);
  fireEvent.click(screen.getByRole('button', { name: 'Add back Manual Worker' }));
  await waitFor(() => expect(screen.getByRole('alert').textContent).toBe('Employee is ineligible'));
  fireEvent.click(screen.getByRole('button', { name: 'Add back Manual Worker' }));
  await waitFor(() => expect(data.handleRestoreEmployee).toHaveBeenCalledTimes(2));
});
it.each(['processing', 'financialActionsHeld', 'hasStagedWorksheetChanges'] as const)('disables restore while %s', key => {
  render(<PayRunRoster {...props()} {...{ [key]: true }} />);
  expect(screen.getByRole('button', { name: 'Add back Manual Worker' })).toHaveProperty('disabled', true);
});
it.each(['regular', 'bonus'] as const)('shows removed employees on draft %s runs and hides them on approved runs', purpose => {
  const data = props();
  const view = render(<PayRunRoster {...data} isCalculated={false} isDraft payPeriod={{ ...data.payPeriod, status: 'draft', run_purpose: purpose }} />);
  expect(within(screen.getByRole('region', { name: 'Removed from this run' })).getByRole('button')).toBeTruthy();
  view.rerender(<PayRunRoster {...data} isCalculated={false} payPeriod={{ ...data.payPeriod, status: 'approved' }} />);
  expect(screen.queryByRole('region', { name: 'Removed from this run' })).toBeNull();
});

it('announces the selected add-back action while preventing repeated writes', () => {
  const data = props();
  data.handleRestoreEmployee = vi.fn().mockReturnValue(new Promise(() => {}));
  render(<PayRunRoster {...data} />);
  fireEvent.click(screen.getByRole('button', { name: 'Add back Manual Worker' }));
  const busy = screen.getByRole('button', { name: 'Adding back Manual Worker…' });
  expect(busy.getAttribute('aria-busy')).toBe('true');
  expect(busy).toHaveProperty('disabled', true);
  expect(screen.getByRole('status').getAttribute('aria-live')).toBe('polite');
  expect(screen.getByRole('status').lastElementChild?.textContent).toBe('Adding employee back to this run…');
  fireEvent.click(busy);
  expect(data.handleRestoreEmployee).toHaveBeenCalledOnce();
});
it('keeps an empty live region mounted, leaves a saved add-back to Expected entries, and says when hours are in', () => {
  const data = props();
  const result = { employee_id: 7, employee_name: 'Manual Worker', restored: [{ kind: 'loan' as const, label: 'Loan', amount: '150.0' }], not_restored: [] };
  const view = render(<PayRunRoster {...data} />);
  expect(screen.getByTestId('add-back-announcement').textContent).toBe('');
  const listed = { ...data.payPeriod, expected_entries: { fields: [], missing_regulars: [], outstanding: [], added_back: [{ ...result, hours_entered: false }] } };
  view.rerender(<PayRunRoster {...data} payPeriod={listed} addBackNotice={{ source: 'roster', result, hoursEntered: false }} />);
  // Expected entries shows it; the roster still announces the add-back it made.
  expect(screen.queryAllByText(/Manual Worker is back/).filter(element => element.dataset.testid !== 'add-back-announcement')).toHaveLength(0);
  expect(screen.getByTestId('add-back-announcement').textContent).toBe("Manual Worker is back. Restored from the import: Loan $150.00. Hours aren't brought back. Enter hours, then calculate.");
  view.rerender(<PayRunRoster {...data} addBackNotice={{ source: 'roster', result, hoursEntered: true }} />);
  expect(screen.getByTestId('add-back-announcement').textContent).toBe('Manual Worker is back. Restored from the import: Loan $150.00. Hours are entered.');
});

it('renders the collapsible Not included — incomplete setup panel with reasons separate from Removed from this run', () => {
  const data = props();
  render(
    <MemoryRouter>
      <PayRunRoster
        {...data}
        companyId={7}
        payPeriod={{
          ...data.payPeriod,
          company_id: 7,
          readiness_excluded_employees: [
            {
              employee_id: 88,
              name: 'Morgan Example',
              employment_type: 'hourly',
              reason: "Can't be paid yet: W-4 missing and payment method not chosen.",
              missing_keys: ['tax_form', 'payment_method'],
            },
          ],
        }}
      />
    </MemoryRouter>
  );

  expect(screen.getByText('Removed from this run (1)')).toBeTruthy();
  expect(screen.getByText('Not included — incomplete setup (1)')).toBeTruthy();
  expect(screen.getByText('Morgan Example')).toBeTruthy();
  expect(screen.getByText(/Can't be paid yet: W-4 missing and payment method not chosen\./)).toBeTruthy();
});
