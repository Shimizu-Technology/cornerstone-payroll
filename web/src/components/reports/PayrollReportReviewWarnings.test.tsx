// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import { PayrollReportReviewWarnings } from './PayrollReportReviewWarnings';

const warning = { code: 'legacy_employer_benefit_unclassified', message: 'Legacy employer benefit history not yet classified', payroll_item_id: 7, employee_id: 3 };

describe('PayrollReportReviewWarnings', () => {
  afterEach(cleanup);

  it('keeps reports without unresolved history quiet', () => {
    const { container } = render(<PayrollReportReviewWarnings />);
    expect(container.textContent).toBe('');
  });

  it('shows a clear review note once even when several paychecks need review', () => {
    render(<PayrollReportReviewWarnings warnings={[warning, { ...warning, payroll_item_id: 8 }]} />);
    expect(screen.getAllByText(warning.message)).toHaveLength(1);
    expect(screen.getByRole('note', { name: 'Payroll history review required' }).textContent).toContain('before using it for a payroll correction or liability reconciliation');
  });
});
