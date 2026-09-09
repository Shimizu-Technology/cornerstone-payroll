import { expect, test, type Page, type Route } from '@playwright/test';

async function fulfillJson(route: Route, body: unknown, status = 200): Promise<void> {
  await route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
}

async function mockShell(page: Page, role: 'admin' | 'client'): Promise<void> {
  await page.route('**/api/v1/auth/me', (route) => fulfillJson(route, {
    user: {
      id: 1,
      email: `${role}@example.test`,
      name: role === 'client' ? 'MoSa Client' : 'Payroll Admin',
      role,
      organization_id: 1,
      organization_name: 'Test Organization',
      company_id: 1,
      company_name: 'MoSa',
      home_company_id: 1,
      assigned_company_ids: [1],
    },
  }));
  await page.route('**/api/v1/companies', (route) => fulfillJson(route, {
    companies: [{ id: 1, name: 'MoSa', active: true, active_employees: 1, total_employees: 1, pay_frequency: 'biweekly' }],
    can_manage_clients: role === 'admin',
    can_view_client_management: role === 'admin',
    can_switch_company: false,
    current_company_id: 1,
  }));
}

const capabilities = {
  view: true,
  edit: false,
  delete: false,
  enter_hours: false,
  run: false,
  approve: false,
  commit: false,
};

const importedPeriod = {
  key: 'imported:77', record_type: 'imported', id: 77, company_id: 1,
  start_date: '2024-01-01', end_date: '2024-01-14', pay_date: '2024-01-19',
  status: 'locked', run_purpose: 'regular', includes_base_salary: true, correction_status: null,
  employee_count: 1, total_gross: 1200.5, total_net: 925.25,
  source: { system: 'quickbooks_online', label: 'QuickBooks import', detail: 'MoSa Jan 1–14', locked: true },
  capabilities,
};

test('client reviews imported payroll beside Cornerstone payroll without staff-only provenance', async ({ page }) => {
  await mockShell(page, 'client');
  await page.route('**/api/v1/client/pay_periods**', (route) => fulfillJson(route, {
    pay_periods: [
      {
        key: 'native:88', record_type: 'native', id: 88, company_id: 1,
        start_date: '2024-01-15', end_date: '2024-01-28', pay_date: '2024-02-02',
        status: 'committed', run_purpose: 'regular', includes_base_salary: true, correction_status: null,
        employee_count: 1, total_gross: 1400, total_net: 1050,
        source: { system: 'cornerstone', label: 'Cornerstone', detail: 'Cornerstone', locked: true },
        capabilities,
      },
      importedPeriod,
    ],
    meta: { current_page: 1, per_page: 50, total_count: 2, total_pages: 1, statuses: { committed: 1, locked: 1 }, sources: { cornerstone: 1, quickbooks_online: 1 }, years: [2024] },
  }));
  await page.route('**/api/v1/client/imported_pay_periods/77**', (route) => fulfillJson(route, {
    data: {
      ...importedPeriod,
      paychecks: [{
        id: 901, employee_id: 10, employee_name: 'Avery Example', source_employee_name: 'Example, Avery',
        check_number: null, payment_method: 'Direct deposit', source_status: 'paid', reconciliation_status: 'matched',
        hours_total: '80.0', gross_pay: '1200.5', adjusted_gross: '1200.5', pretax_deductions: '0.0',
        employee_taxes: '200.0', federal_income_tax: '100.0', social_security_tax: '75.0', medicare_tax: '25.0',
        after_tax_deductions: '75.25', net_pay: '925.25', employer_taxes: '100.0', employer_contributions: '0.0',
        total_payroll_cost: '1300.5', hours_breakdown: [], earnings_breakdown: [], pretax_deduction_breakdown: [],
        after_tax_deduction_breakdown: [], employee_tax_breakdown: [], employer_tax_breakdown: [], employer_contribution_breakdown: [],
      }],
    },
    meta: { current_page: 1, per_page: 50, total_count: 1, total_pages: 1 },
  }));

  await page.goto('/companies/1/pay-runs');

  const importedRow = page.getByRole('row').filter({ hasText: 'QuickBooks import' });
  await expect(importedRow).toContainText('Locked');
  await importedRow.getByRole('button', { name: 'View' }).click();

  await expect(page).toHaveURL(/\/companies\/1\/pay-runs\/imported\/77/);
  await expect(page.getByText('This finalized payroll came from QuickBooks')).toBeVisible();
  await expect(page.getByRole('columnheader', { name: 'Payment method' })).toBeVisible();
  await expect(page.getByRole('cell', { name: 'Direct deposit' })).toBeVisible();
  await expect(page.getByText('Import provenance')).toHaveCount(0);
  await expect(page.getByText('QB-401')).toHaveCount(0);
});

test('employee workspace presents native and imported pay as one locked-aware timeline', async ({ page }) => {
  await mockShell(page, 'admin');
  await page.route('**/api/v1/admin/employees/10', (route) => fulfillJson(route, {
    data: {
      id: 10, company_id: 1, first_name: 'Avery', last_name: 'Example', status: 'active',
      employment_type: 'hourly', tax_classification: 'w2', pay_rate: 20, pay_frequency: 'biweekly',
      filing_status: 'single', default_payroll_adjustments: [], wage_rates: [], status_history: [],
    },
  }));
  await page.route('**/api/v1/admin/reports/employee_pay_history**', (route) => fulfillJson(route, {
    report: {
      period: { label: 'Jan 1–Dec 31, 2024', start_date: '2024-01-01', end_date: '2024-12-31', basis: 'pay_date' },
      employee: { id: 10, name: 'Avery Example', employment_type: 'hourly', pay_rate: 20 },
      history: [
        {
          key: 'native:901', record_type: 'native', payroll_item_id: 901, pay_period_id: 88, historical_pay_period_id: null,
          pay_date: '2024-02-02', period_description: 'Jan 15–28, 2024', hours_worked: 80, overtime_hours: 0,
          gross_pay: 1400, total_deductions: 350, net_pay: 1050, check_number: '1601',
          source: { system: 'cornerstone', label: 'Cornerstone', locked: true }, capabilities: { view: true, edit: false },
        },
        {
          key: 'imported:901', record_type: 'imported', payroll_item_id: null, pay_period_id: null, historical_pay_period_id: 77,
          pay_date: '2024-01-19', period_description: 'MoSa Jan 1–14', hours_worked: 80, overtime_hours: null,
          gross_pay: 1200.5, total_deductions: 275.25, net_pay: 925.25, check_number: '1501',
          source: { system: 'quickbooks_online', label: 'QuickBooks import', locked: true }, capabilities: { view: true, edit: false },
        },
      ],
      summary: { payroll_count: 2, gross_pay: 2600.5, net_pay: 1975.25 },
      ytd: { payroll_count: 2, gross_pay: 2600.5, net_pay: 1975.25 },
      source_summary: {
        mode: 'locked_quickbooks_plus_committed_cornerstone', source_statement: 'Imported values were not recalculated.',
        cornerstone: { payroll_count: 1, paycheck_count: 1 }, quickbooks: { payroll_count: 1, paycheck_count: 1, opening_summary_count: 0, excluded_unlinked_paycheck_count: 0, excluded_unlinked_gross_pay: 0, excluded_unlinked_net_pay: 0 },
        historical_ytd_bridge: { applied: false, tax_years: [] },
      },
      payroll_fields: { totals: [], entries: [], treatment_totals: {} },
    },
  }));

  await page.goto('/companies/1/employees/10/pay-history');

  await expect(page.getByRole('heading', { name: 'Pay history' })).toBeVisible();
  await expect(page.getByRole('row').filter({ hasText: 'Cornerstone' })).toBeVisible();
  const importedRow = page.getByRole('row').filter({ hasText: 'QuickBooks import' });
  await expect(importedRow).toBeVisible();
  await expect(importedRow.getByRole('link', { name: 'MoSa Jan 1–14' })).toHaveAttribute('href', /\/companies\/1\/pay-runs\/imported\/77/);
  await expect(importedRow.getByRole('link', { name: /Open imported pay run/ })).toBeVisible();
});

test('payroll summary explains combined sources and any excluded unlinked records', async ({ page }) => {
  await mockShell(page, 'admin');
  await page.route('**/api/v1/admin/reports/ytd_summary**', (route) => fulfillJson(route, {
    report: {
      type: 'ytd_summary', year: 2026,
      period: { label: '2026', start_date: '2026-01-01', end_date: '2026-12-31', basis: 'pay_date' },
      employees: [],
      company_totals: { year: 2026, gross_pay: 1600, withholding_tax: 120, social_security_tax: 90, medicare_tax: 20, retirement: 0, net_pay: 1250, payroll_count: 2 },
      source_summary: {
        mode: 'locked_quickbooks_plus_committed_cornerstone',
        source_statement: 'QuickBooks values are authoritative locked snapshots and were not recalculated by Cornerstone Payroll.',
        cornerstone: { payroll_count: 1, paycheck_count: 1 },
        quickbooks: { payroll_count: 1, paycheck_count: 1, opening_summary_count: 1, excluded_unlinked_paycheck_count: 1, excluded_unlinked_gross_pay: 250, excluded_unlinked_net_pay: 180 },
        historical_ytd_bridge: { applied: false, tax_years: [] },
      },
      payroll_fields: { totals: [], entries: [], treatment_totals: {} },
    },
  }));

  await page.goto('/reports?report=ytd-summary');
  await page.getByRole('button', { name: 'View Report' }).click();

  await expect(page.getByText('Combined payroll history')).toBeVisible();
  await expect(page.getByText(/1 linked QuickBooks paycheck/)).toBeVisible();
  await expect(page.getByText(/1 QuickBooks record was excluded/)).toBeVisible();
  await expect(page.getByText(/Payroll field reconciliation below covers Cornerstone records only/)).toBeVisible();
});
