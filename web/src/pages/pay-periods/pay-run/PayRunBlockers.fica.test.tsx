// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import type { ComponentProps } from 'react';
import { MemoryRouter } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { FicaHistoryReviewNotice, PayRunBlockers } from './PayRunBlockers';
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

const note = "Prior-period void history needs accountant review; this paycheck's Social Security/Medicare is unaffected. Historical tax and filing review remains open.";
const props = {
  payPeriod: {
    annual_fica_review_note: note,
    compliance_warnings: [note],
  },
} as ComponentProps<typeof PayRunBlockers>;

afterEach(cleanup);

describe('FICA history disclosure', () => {
  it('keeps the review note visible at approval without labelling it a workweek problem', () => {
    const sections = {
      processing: { payPeriod: { ...props.payPeriod, id: 1, status: 'approved' } },
      blockers: props,
      results: { payrollItems: [], payrollItemDisplayedHours: () => 0 },
      feedback: { calculationFailures: [] },
      metadata: {},
    } as unknown as ComponentProps<typeof PayRunSteps>['sections'];
    render(<MemoryRouter><PayRunSteps sections={sections} /></MemoryRouter>);
    expect(screen.getByText('Prior-period payroll review remains open')).toBeTruthy();
    expect(screen.getByText(note)).toBeTruthy();
    expect(screen.getByText(note).closest('details')).toBeNull();
    expect(document.querySelector('#payroll-commit')?.hasAttribute('open')).toBe(true);
    expect(screen.queryByText('Review settings')).toBeNull();
  });

  it('does not duplicate the note or attach unrelated settings actions', () => {
    render(<MemoryRouter><FicaHistoryReviewNotice note={note} /><PayRunBlockers {...props} /></MemoryRouter>);
    expect(screen.getAllByText(note)).toHaveLength(1);
    expect(screen.queryByText('Review settings')).toBeNull();
  });
});
