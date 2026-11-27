// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { TimecardImportModal } from './TimecardImportModal';

const mocks = vi.hoisted(() => ({
  previewTimecardImport: vi.fn(),
  applyTimecardImport: vi.fn(),
}));

vi.mock('@/services/api', () => ({
  payPeriodsApi: {
    previewTimecardImport: mocks.previewTimecardImport,
    applyTimecardImport: mocks.applyTimecardImport,
  },
}));

describe('TimecardImportModal skipped-hours notice', () => {
  beforeEach(() => {
    vi.resetAllMocks();
  });

  afterEach(cleanup);

  it('displays skipped Incomplete hires and their exact reason so hours are never dropped silently', async () => {
    mocks.previewTimecardImport.mockResolvedValue({
      preview: [
        { csv_name: 'Morgan Example', employee_id: 42, regular_hours: '32', overtime_hours: '0', total_hours: '32', match_score: 1 },
        { csv_name: 'Jordan Sample', employee_id: 43, regular_hours: '40', overtime_hours: '0', total_hours: '40', match_score: 1 },
      ],
      all_employees: [
        { id: 42, name: 'Morgan Example' },
        { id: 43, name: 'Jordan Sample' },
      ],
      total_rows: 2,
      matched: 2,
      unmatched: 0,
    });
    mocks.applyTimecardImport.mockResolvedValue({
      applied: [{ employee_id: 43, employee_name: 'Jordan Sample', hours_worked: 40, overtime_hours: 0 }],
      skipped: [{
        employee_id: 42,
        employee_name: 'Morgan Example',
        name: 'Morgan Example',
        reason: "Skipped — Can't be paid yet: W-4 missing. Hours were not imported.",
        code: 'employee_readiness_incomplete',
      }],
      errors: [],
    });

    const onImportComplete = vi.fn();
    const { container } = render(
      <TimecardImportModal open onClose={vi.fn()} payPeriodId={12} onImportComplete={onImportComplete} />
    );

    const fileInput = container.querySelector('input[type="file"]') as HTMLInputElement;
    const csvFile = new File(['Employee Name,Regular Hours\nMorgan Example,32\n'], 'timecards.csv', { type: 'text/csv' });
    fireEvent.change(fileInput, { target: { files: [csvFile] } });

    await screen.findByText('Apply Import (2 employees)');
    fireEvent.click(screen.getByRole('button', { name: 'Apply Import (2 employees)' }));

    await waitFor(() => expect(screen.getByText('Import Complete')).toBeTruthy());
    expect(screen.getByText(/1 skipped\./)).toBeTruthy();
    expect(screen.getByText('Skipped employees (hours not imported):')).toBeTruthy();
    expect(screen.getByText(/Morgan Example:/)).toBeTruthy();
    expect(screen.getByText(/W-4 missing\. Hours were not imported\./)).toBeTruthy();
    expect(onImportComplete).toHaveBeenCalledOnce();
  });
});
