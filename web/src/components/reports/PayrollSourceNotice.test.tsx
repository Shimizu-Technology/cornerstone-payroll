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


it('names prior-provider payments separately from QuickBooks', () => {
  render(<PayrollSourceNotice summary={{ ...summary,
    quickbooks: { ...summary.quickbooks, payroll_count: 0, paycheck_count: 0, record_count: 0 },
    prior_provider: { ...summary.quickbooks, paycheck_count: 3, record_count: 3 },
  }} />);
  expect(screen.getByText(/3 linked prior-provider paychecks/)).toBeTruthy();
  expect(screen.queryByText(/linked QuickBooks/)).toBeNull();
});

it('says when imported totals come from the opening balance and when they are shown as imported', () => {
  const bridged = { applied: true, tax_years: [ 2026 ], totals_basis: 'historical_ytd_bridge' as const };
  const { unmount } = render(<PayrollSourceNotice summary={{ ...summary, historical_ytd_bridge: bridged }} />);
  expect(screen.getByText(/the same figures as pay stubs and W-2GU/).textContent).toContain('Hours, 401(k), employer costs and other categories are shown as imported.');
  unmount();
  render(<PayrollSourceNotice summary={{ ...summary, historical_ytd_bridge: { ...bridged, totals_basis: 'as_imported' } }} />);
  expect(screen.getByText(/Imported figures are shown as imported/)).toBeTruthy();
});

it('warns when Cornerstone paychecks are dated inside the opening balance', () => {
  render(<PayrollSourceNotice summary={{ ...summary, source_overlap: { employee_pay_date_count: 0, bridge_window_paycheck_count: 1 } }} />);
  expect(screen.getByRole('alert').textContent).toContain('1 Cornerstone paycheck is dated inside the imported opening year-to-date balance');
});

it('says nothing about the basis when no opening balance applies', () => {
  render(<PayrollSourceNotice summary={{ ...summary, historical_ytd_bridge: { applied: false, tax_years: [], totals_basis: 'as_imported' } }} />);
  expect(screen.queryByText(/as imported/)).toBeNull();
});
