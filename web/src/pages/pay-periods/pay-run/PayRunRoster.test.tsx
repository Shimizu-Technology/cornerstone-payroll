// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import type { ComponentProps } from 'react';
import { PayRunRoster } from './PayRunRoster';

afterEach(cleanup);
function props() {
  return {
    isCalculated: true, canEditPayPeriod: true, additionalEmployeeIds: new Set<number>(),
    employees: [{ id: 7, first_name: 'Manual', last_name: 'Worker', employment_type: 'hourly' }], payrollItems: [],
    payPeriod: { id: 1, status: 'calculated', run_purpose: 'regular', excluded_employee_ids: [7], excluded_employees: [{ employee_id: 7, name: 'Manual Worker', reason: 'No hours received' }] },
    handleRestoreEmployee: vi.fn().mockResolvedValue(undefined), setAdditionalEmployeeIds: vi.fn(), setHoursMap: vi.fn(),
  } as unknown as ComponentProps<typeof PayRunRoster>;
}
it('shows removed names and reasons, then offers Enter pay in the unpaid roster', async () => {
  const data = props();
  const view = render(<PayRunRoster {...data} />);
  expect(screen.getByText('Removed from this run (1)')).toBeTruthy();
  expect(screen.getByText('No hours received')).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Enter pay' })).toBeNull();
  fireEvent.click(screen.getByRole('button', { name: 'Add back Manual Worker' }));
  await waitFor(() => expect(data.handleRestoreEmployee).toHaveBeenCalledWith(7));
  expect(await screen.findByText("Imported hours aren't brought back. Enter hours or import again.")).toBeTruthy();
  view.rerender(<PayRunRoster {...data} payPeriod={{ ...data.payPeriod, excluded_employee_ids: [], excluded_employees: [] }} />);
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
