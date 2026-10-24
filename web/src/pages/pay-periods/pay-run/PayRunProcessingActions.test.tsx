// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import type { ComponentProps } from 'react';
import { PayRunStepAction } from './PayRunProcessingActions';

afterEach(cleanup);
it.each([
  ['draft', 'hours', 'Calculate Payroll'],
  ['calculated', 'results', 'Approve'],
  ['approved', 'commit', 'Commit'],
  ['committed', 'results', 'Checks & payments'],
] as const)('keeps only the header action filled for %s while the step stays usable', async (status, step, label) => {
  const run = vi.fn(), approve = vi.fn(), commit = vi.fn();
  const props = { step, companyId: 1, payPeriod: { id: 2, status, run_purpose: 'regular' }, isDraft: status === 'draft', isCalculated: status === 'calculated', isApproved: status === 'approved', isCommitted: status === 'committed', hasManualHours: true, calculationFailures: [], payrollItems: [{ id: 1 }], standaloneLoanConflicts: [], handleRunPayroll: run, handleApprove: approve, setCommitPeriodId: commit } as unknown as ComponentProps<typeof PayRunStepAction>;
  render(<MemoryRouter><PayRunStepAction {...props} header /><PayRunStepAction {...props} /></MemoryRouter>);
  const actions = screen.getAllByRole(status === 'committed' ? 'link' : 'button', { name: label });
  expect(actions).toHaveLength(2);
  expect(actions.filter(action => action.classList.contains('bg-primary-700'))).toHaveLength(1);
  const secondary = actions.find(action => !action.classList.contains('bg-primary-700'))!;
  if (status === 'committed') expect(secondary.getAttribute('href')).toContain('/checks');
  else {
    await userEvent.click(secondary);
    if (status === 'draft') expect(run).toHaveBeenCalledOnce();
    if (status === 'calculated') expect(approve).toHaveBeenCalledOnce();
    if (status === 'approved') expect(commit).toHaveBeenCalledWith(2);
  }
});

it('explains a loan conflict beside disabled approval and links to its inputs', () => {
  const props = { step: 'results', companyId: 1, payPeriod: { id: 2, status: 'calculated', run_purpose: 'regular' }, isCalculated: true, calculationFailures: [], payrollItems: [{ id: 1 }], standaloneLoanConflicts: [{ employee_id: 1 }] } as unknown as ComponentProps<typeof PayRunStepAction>;
  render(<MemoryRouter><PayRunStepAction {...props} /></MemoryRouter>);
  const approve = screen.getByRole('button', { name: 'Approve' }) as HTMLButtonElement;
  expect(approve.disabled).toBe(true);
  expect(screen.getByText(/Clear the standalone one-time deduction/)).toBeTruthy();
  expect(screen.getByRole('link', { name: 'Review loan inputs' }).getAttribute('href')).toContain('#payroll-loan-inputs');
});
