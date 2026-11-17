// @vitest-environment jsdom
import { render } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { PayPeriod } from '@/types';
import type { PayRunSections } from './usePayRunController';
import { PayRunSteps } from './PayRunWorkflowSteps';

const panel = vi.hoisted(() => ({ onSaved: undefined as undefined | (() => unknown) }));
vi.mock('./ExpectedEntriesPanel', () => ({
  ExpectedEntriesPanel: (props: { onSaved: () => unknown }) => { panel.onSaved = props.onSaved; return null; },
}));

vi.mock('./PayRunProcessingActions', () => ({ PayRunStepAction: () => null }));
vi.mock('./PayRunSourceCheckpoint', () => ({ PayRunSourceCheckpoint: () => null }));
vi.mock('./PayRunBlockers', () => ({ FicaHistoryReviewNotice: () => null, PayRunBlockers: () => null, PayRunClientFiles: () => null }));
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

describe('PayRunSteps', () => {
  it('keeps staged worksheet inputs when an expected-entry resolution reloads the run', () => {
    const loadPayPeriod = vi.fn().mockResolvedValue('loaded');
    const payPeriod = { id: 132, status: 'approved', run_purpose: 'regular', cycle: 'regular' } as unknown as PayPeriod;
    const sections = {
      processing: { payPeriod, handleUnapprove: vi.fn() },
      results: { payrollItems: [], payrollItemDisplayedHours: () => 0 },
      feedback: { calculationFailures: [] },
      metadata: { processedBy: null },
      roster: { loadPayPeriod, processing: false, financialActionsHeld: false, canEditPayPeriod: true, hasStagedWorksheetChanges: true,
        handleRestoreEmployee: vi.fn(), onCalculateExpectedEntry: vi.fn(), setAdditionalEmployeeIds: vi.fn(), setHoursMap: vi.fn() },
    } as unknown as PayRunSections;

    render(<PayRunSteps sections={sections} />);
    panel.onSaved?.();

    expect(loadPayPeriod).toHaveBeenCalledWith(132, true, true);
  });
});
