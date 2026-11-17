// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { afterEach, expect, it, vi } from 'vitest';
import type { ComponentProps } from 'react';
import { PayRunProcessingActions, PayRunStepAction } from './PayRunProcessingActions';

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

it.each([true, false])('blocks Commit over client changes with setting %s', required => {
  const commit = vi.fn();
  const props = { step: 'commit', companyId: 1, payPeriod: { id: 2, status: 'approved', run_purpose: 'regular', client_payroll_approval_required: required,
    payroll_review: { status: 'changes_requested', changes_requested_by_name: 'MoSa Approver', change_request_note: 'Add two hours' } }, isApproved: true,
    calculationFailures: [], payrollItems: [{ id: 1 }], standaloneLoanConflicts: [], setCommitPeriodId: commit } as unknown as ComponentProps<typeof PayRunStepAction>;
  render(<MemoryRouter><PayRunStepAction {...props} /></MemoryRouter>);
  expect(screen.getByRole('button', { name: 'Commit' })).toHaveProperty('disabled', true);
  expect(screen.getByText('MoSa Approver requested changes: Add two hours. Unapprove to make changes.')).toBeTruthy();
  expect(commit).not.toHaveBeenCalled();
});

it('tells staff to unapprove an approved regular run with removed employees', () => {
  const props = { companyId: 1, payRunId: 2, payPeriod: { id: 2, status: 'approved', run_purpose: 'regular', excluded_employee_ids: [7] }, isApproved: true,
    calculationFailures: [], payrollItems: [{ id: 1 }], standaloneLoanConflicts: [], handleUnapprove: vi.fn() } as unknown as ComponentProps<typeof PayRunProcessingActions>;
  render(<MemoryRouter><PayRunProcessingActions {...props} /></MemoryRouter>);
  expect(screen.getByText('1 removed from this run. Unapprove to add someone back.')).toBeTruthy();
});

it.each(['approved', 'calculated'] as const)('shows the %s header blocker with a direct link to expected entries', status => {
  const props = { companyId: 1, payRunId: 2, payPeriod: { id: 2, status, run_purpose: 'regular', expected_entries: { outstanding: ['Regular Worker'] } }, isApproved: status === 'approved', isCalculated: status === 'calculated',
    calculationFailures: [], payrollItems: [{ id: 1 }], standaloneLoanConflicts: [] } as unknown as ComponentProps<typeof PayRunProcessingActions>;
  render(<MemoryRouter><PayRunProcessingActions {...props} /></MemoryRouter>);
  expect(screen.getByText('Resolve expected entries: Regular Worker', { exact: false })).toBeTruthy();
  expect(screen.getByRole('link', { name: 'Resolve expected entries' }).getAttribute('href')).toContain('#expected-payroll-entries');
  expect(screen.getByRole('button', { name: status === 'approved' ? 'Commit' : 'Approve' })).toHaveProperty('disabled', true);
});

it('links the unapproved commit reason directly to results and opens collapsed approval controls', async () => {
  const props = { step: 'commit', companyId: 1, payPeriod: { id: 2, status: 'calculated', run_purpose: 'regular' }, isCalculated: true, calculationFailures: [], payrollItems: [{ id: 1 }], standaloneLoanConflicts: [] } as unknown as ComponentProps<typeof PayRunStepAction>;
  render(<MemoryRouter><details id="payroll-results"><summary>Results</summary><button>Approve reviewed payroll</button></details><PayRunStepAction {...props} /></MemoryRouter>);
  const link = screen.getByRole('link', { name: 'Review and approve payroll' });
  expect(link.getAttribute('href')).toContain('#payroll-results');
  await userEvent.click(link);
  expect(document.querySelector<HTMLDetailsElement>('#payroll-results')?.open).toBe(true);
  expect(screen.getByRole('button', { name: 'Approve reviewed payroll' })).toBeTruthy();
});

it.each([
  ['draft', 'hours', 'calculate', 'Calculating…', 'Calculating payroll for 1 employee…'],
  ['calculated', 'hours', 'calculate', 'Recalculating…', 'Recalculating payroll for 1 employee…'],
  ['calculated', 'results', 'approve', 'Approving…', 'Approving payroll…'],
  ['approved', 'commit', 'commit', 'Committing…', 'Committing payroll…'],
] as const)('announces %s %s work only on the action actually in progress', (status, step, processingAction, label, message) => {
  const props = { step, companyId: 1, payPeriod: { id: 2, status, run_purpose: 'regular' }, isDraft: status === 'draft', isCalculated: status === 'calculated', isApproved: status === 'approved', processing: true, processingAction,
    hasManualHours: true, calculationFailures: [], payrollItems: [{ id: 1 }], standaloneLoanConflicts: [] } as unknown as ComponentProps<typeof PayRunStepAction>;
  render(<MemoryRouter><PayRunStepAction {...props} /></MemoryRouter>);
  const button = screen.getByRole('button', { name: label });
  expect(button).toHaveProperty('disabled', true);
  expect(button.getAttribute('aria-busy')).toBe('true');
  expect(button.querySelector('svg[aria-hidden="true"]')).toBeTruthy();
  const statusLine = screen.getByRole('status');
  expect(statusLine.getAttribute('aria-live')).toBe('polite');
  expect(statusLine.lastElementChild?.textContent).toContain(message);
});

it('does not label approval as busy while a calculation is running', () => {
  const props = { step: 'results', companyId: 1, payPeriod: { id: 2, status: 'calculated' }, isCalculated: true, processing: true, processingAction: 'calculate', calculationFailures: [], payrollItems: [{ id: 1 }], standaloneLoanConflicts: [] } as unknown as ComponentProps<typeof PayRunStepAction>;
  render(<MemoryRouter><PayRunStepAction {...props} /></MemoryRouter>);
  expect(screen.getByRole('button', { name: 'Approve' })).toHaveProperty('disabled', true);
  expect(screen.getByRole('button', { name: 'Approve' }).getAttribute('aria-busy')).toBeNull();
});

it('shows unapproval feedback without marking Commit as busy', () => {
  const props = { companyId: 1, payRunId: 2, payPeriod: { id: 2, status: 'approved', run_purpose: 'regular', excluded_employee_ids: [7] }, isApproved: true, processing: true, processingAction: 'unapprove',
    calculationFailures: [], payrollItems: [{ id: 1 }], standaloneLoanConflicts: [], handleUnapprove: vi.fn() } as unknown as ComponentProps<typeof PayRunProcessingActions>;
  render(<MemoryRouter><PayRunProcessingActions {...props} /></MemoryRouter>);
  expect(screen.getAllByRole('button', { name: 'Unapproving…' }).every(button => button.getAttribute('aria-busy') === 'true' && (button as HTMLButtonElement).disabled)).toBe(true);
  expect(screen.getAllByRole('status').some(status => status.lastElementChild?.textContent === 'Unapproving payroll…')).toBe(true);
  expect(screen.getByRole('button', { name: 'Commit' }).getAttribute('aria-busy')).toBeNull();
});
