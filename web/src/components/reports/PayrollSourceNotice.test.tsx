// @vitest-environment jsdom

import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, it } from 'vitest';
import type { PayrollSourceSummary } from '@/services/api';
import { PayrollSourceNotice } from './PayrollSourceNotice';

const summary: PayrollSourceSummary = {
  mode: 'locked_quickbooks_plus_committed_cornerstone',
  source_statement: 'Both sources are included.',
  cornerstone: { payroll_count: 1, paycheck_count: 1 },
  quickbooks: {
    payroll_count: 1, paycheck_count: 1, record_count: 1,
    opening_summary_count: 0, excluded_unlinked_paycheck_count: 0,
    excluded_unlinked_gross_pay: 0, excluded_unlinked_net_pay: 0,
  },
  adjustments: { count: 0, gross_pay_delta: 0, net_pay_delta: 0 },
  historical_ytd_bridge: { applied: false, tax_years: [] },
};

afterEach(cleanup);

it('does not warn when no employee/pay-date pairs overlap', () => {
  render(<PayrollSourceNotice summary={{ ...summary, source_overlap: { employee_pay_date_count: 0 } }} />);
  expect(screen.queryByRole('alert')).toBeNull();
});

it('uses singular wording for one overlap', () => {
  render(<PayrollSourceNotice summary={{ ...summary, source_overlap: { employee_pay_date_count: 1 } }} />);
  expect(screen.getByRole('alert').textContent).toContain('1 matching employee/pay-date pair.');
});

it('uses plural wording for multiple overlaps', () => {
  render(<PayrollSourceNotice summary={{ ...summary, source_overlap: { employee_pay_date_count: 3 } }} />);
  expect(screen.getByRole('alert').textContent).toContain('3 matching employee/pay-date pairs.');
});
