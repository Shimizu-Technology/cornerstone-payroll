// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { FicaHistoryReviewNotice } from '@/components/payroll/FicaHistoryReviewNotice';
import type { ComponentProps } from 'react';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { PayRunBlockers, PayRunClientFiles } from './PayRunBlockers';
import { PayRunSteps } from './PayRunWorkflowSteps';

vi.mock('./PayRunProcessingActions', () => ({ PayRunStepAction: () => null }));
vi.mock('./PayRunSourceCheckpoint', () => ({ PayRunSourceCheckpoint: () => null }));
vi.mock('./PayRunFeedback', () => ({ PayRunFeedback: () => null }));
vi.mock('./PayRunLoanInputs', () => ({ PayRunLoanInputs: () => null }));
vi.mock('./PayRunRoster', () => ({ PayRunRoster: () => null }));
vi.mock('./PayRunHoursWorksheet', () => ({ PayRunHoursWorksheet: () => null }));
vi.mock('./PayRunSavedRecords', () => ({ PayRunSavedRecords: () => null }));
vi.mock('./PayRunEmployeeResults', () => ({ PayRunEmployeeResults: () => null }));
vi.mock('./PayRunComparison', () => ({ PayRunComparison: () => null }));
vi.mock('./PayRunEmployerTaxes', () => ({ PayRunEmployerTaxes: () => null }));
vi.mock('./PayRunEmptyState', () => ({ PayRunEmptyState: () => null }));
vi.mock('./PayRunTimecardOcr', () => ({ PayRunTimecardOcr: () => null }));

const entries = [
  { employee_name: 'Maya Cruz', note: 'Prior-period payroll history needs accountant review: voided pay period #75.' },
  { employee_name: 'Noah Reyes', note: 'Prior-period payroll history needs accountant review: reversed paycheck #412.' },
];
const note = entries.map(entry => `${entry.employee_name}: ${entry.note}`).join('\n');
const summary = "2 payroll history items awaiting accountant review. This payroll isn't affected.";
const props = {
  payPeriod: {
    annual_fica_review_note: note,
    annual_fica_review: { employee_count: 2, entries },
    compliance_warnings: [note],
  },
} as ComponentProps<typeof PayRunBlockers>;

afterEach(cleanup);

describe('FICA history disclosure', () => {
  it('shows the quiet summary at approval without labelling it a workweek problem', () => {
    const sections = {
      processing: { payPeriod: { ...props.payPeriod, id: 1, status: 'approved' } },
      blockers: props,
      results: { payrollItems: [], payrollItemDisplayedHours: () => 0 },
      feedback: { calculationFailures: [] },
      metadata: {},
      roster: { processing: false, financialActionsHeld: false, canEditPayPeriod: true, hasStagedWorksheetChanges: false, loadPayPeriod: () => undefined },
    } as unknown as ComponentProps<typeof PayRunSteps>['sections'];
    render(<MemoryRouter><PayRunSteps sections={sections} /></MemoryRouter>);
    expect(screen.getByText(summary).closest('details')).toBeNull();
    expect(screen.getByRole('button', { name: 'Show details' }).getAttribute('aria-expanded')).toBe('false');
    expect(document.querySelector('#payroll-commit')?.hasAttribute('open')).toBe(true);
    expect(screen.queryByText('Review settings')).toBeNull();
  });

  it('discloses the affected workers and actual reasons with a keyboard-operable button', async () => {
    const user = userEvent.setup();
    render(<FicaHistoryReviewNotice payPeriod={props.payPeriod} showDisclosure />);
    const button = screen.getByRole('button', { name: 'Show details' });
    expect(button.getAttribute('aria-expanded')).toBe('false');
    expect(screen.queryByRole('list')).toBeNull();
    await user.tab();
    expect(document.activeElement).toBe(button);
    await user.keyboard('{Enter}');
    expect(screen.getByRole('button', { name: 'Hide details' }).getAttribute('aria-expanded')).toBe('true');
    expect(screen.getByRole('list').id).toBe(button.getAttribute('aria-controls'));
    expect(screen.getAllByRole('listitem').map(item => item.textContent)).toEqual(note.split('\n'));
    await user.keyboard(' ');
    expect(screen.queryByRole('list')).toBeNull();
  });

  it('summarizes and discloses a legacy note when the API lacks the structured field', async () => {
    const legacyNote = "Prior-period void history or imported paycheck history needs accountant review.";
    render(<FicaHistoryReviewNotice payPeriod={{ annual_fica_review_note: legacyNote }} showDisclosure />);
    expect(screen.getByText("1 payroll history item awaiting accountant review. This payroll isn't affected.")).toBeTruthy();
    await userEvent.click(screen.getByRole('button', { name: 'Show details' }));
    expect(screen.getByRole('listitem').textContent).toBe(legacyNote);
  });

  it('does not duplicate the note or attach unrelated settings actions', () => {
    render(<MemoryRouter><FicaHistoryReviewNotice payPeriod={props.payPeriod} /><PayRunBlockers {...props} /></MemoryRouter>);
    expect(screen.getAllByText(summary)).toHaveLength(1);
    expect(screen.queryByText(/voided pay period/)).toBeNull();
    expect(screen.queryByText('Review settings')).toBeNull();
  });

  it('links staff to payroll history for the company and pay year', () => {
    const url = '/companies/7/year-end?year=2026#payroll-history-review';
    render(<MemoryRouter><FicaHistoryReviewNotice payPeriod={{ ...props.payPeriod, annual_fica_review_path: url }} /></MemoryRouter>);
    expect(screen.getByRole('link', { name: 'Payroll history review' }).getAttribute('href')).toBe(url);
  });
});

it('links a waiting client revision directly and hides the panel without a submission', () => {
  const files = { period_id: 9, revision: 2, submission_id: 22, submitted_at: '2026-11-01T00:00:00Z', status: 'waiting', blocks_calculation: true };
  const view = render(<MemoryRouter><PayRunClientFiles payPeriod={{ ...props.payPeriod, company_id: 2, client_files: files }} /><PayRunBlockers {...props} payPeriod={{ ...props.payPeriod, company_id: 2, client_files: files }} /></MemoryRouter>);
  expect(screen.getByRole('region', { name: 'Files from the client' })).toBeTruthy();
  expect(screen.getByRole('link', { name: 'review this revision' }).getAttribute('href')).toBe('/companies/2/payroll-submissions/9#revision-22');
  view.rerender(<MemoryRouter><PayRunClientFiles payPeriod={props.payPeriod} /><PayRunBlockers {...props} /></MemoryRouter>);
  expect(screen.queryByRole('region', { name: 'Files from the client' })).toBeNull();
});
