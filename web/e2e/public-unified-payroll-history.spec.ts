import { expect, test, type Page, type Route } from '@playwright/test';

async function fulfillJson(route: Route, body: unknown, status = 200): Promise<void> {
  await route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
}

async function mockShell(page: Page): Promise<void> {
  await page.route('**/api/v1/auth/me', (route) => fulfillJson(route, {
    user: {
      id: 1,
      email: 'admin@example.test',
      name: 'Payroll Admin',
      role: 'admin',
      organization_id: 1,
      organization_name: 'Test Organization',
      company_id: 1,
      company_name: 'MoSa',
      home_company_id: 1,
      assigned_company_ids: [1],
    },
  }));
  await page.route('**/api/v1/companies', (route) => fulfillJson(route, {
    companies: [{
      id: 1,
      name: 'MoSa',
      active: true,
      active_employees: 2,
      total_employees: 2,
      pay_frequency: 'biweekly',
      historical_payroll_enabled: true,
    }],
    can_manage_clients: true,
    can_view_client_management: true,
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

test('shows locked QuickBooks payroll beside native payroll and keeps the imported detail read-only', async ({ page }) => {
  await mockShell(page);
  let listRequestUrl = '';
  await page.route('**/api/v1/admin/payroll_history**', async (route) => {
    listRequestUrl = route.request().url();
    await fulfillJson(route, {
      data: [
        {
          key: 'imported:77', record_type: 'imported', id: 77, company_id: 1,
          start_date: '2024-01-01', end_date: '2024-01-14', pay_date: '2024-01-19',
          status: 'locked', run_purpose: 'regular', includes_base_salary: true, correction_status: null,
          employee_count: 1, total_gross: 1200.5, total_net: 925.25,
          processed_at: '2024-01-20T00:00:00Z', processed_by_name: 'Payroll Admin',
          source: { system: 'quickbooks_online', label: 'QuickBooks import', detail: 'MoSa Jan 1–14', locked: true },
          capabilities,
        },
        {
          key: 'native:88', record_type: 'native', id: 88, company_id: 1,
          start_date: '2024-01-15', end_date: '2024-01-28', pay_date: '2024-02-02',
          status: 'committed', run_purpose: 'regular', includes_base_salary: true, correction_status: null,
          employee_count: 1, total_gross: 1400, total_net: 1050,
          processed_at: '2024-02-03T00:00:00Z', processed_by_name: 'Payroll Admin',
          source: { system: 'cornerstone', label: 'Cornerstone', detail: 'Cornerstone', locked: true },
          capabilities,
        },
      ],
      meta: {
        current_page: 1, per_page: 50, total_count: 2, total_pages: 1,
        statuses: { locked: 1, committed: 1 }, sources: { quickbooks_online: 1, cornerstone: 1 }, years: [2024],
      },
    });
  });
  await page.route('**/api/v1/admin/imported_pay_periods/77**', (route) => fulfillJson(route, {
    data: {
      key: 'imported:77', record_type: 'imported', id: 77, company_id: 1,
      start_date: '2024-01-01', end_date: '2024-01-14', pay_date: '2024-01-19',
      status: 'locked', run_purpose: 'regular', includes_base_salary: true, correction_status: null,
      employee_count: 1, total_gross: 1200.5, total_net: 925.25,
      source: {
        system: 'quickbooks_online', label: 'QuickBooks import', detail: 'MoSa Jan 1–14', locked: true,
        import_batch_id: 12, importer_version: 'quickbooks-online-payroll-v5', locked_by_name: 'Payroll Admin',
      },
      capabilities,
      paychecks: [{
        id: 901, employee_id: 10, employee_name: 'Avery Example', source_employee_name: 'Example, Avery',
        check_number: '1501', payment_method: 'check', source_status: 'paid', reconciliation_status: 'matched',
        hours_total: '80.0', gross_pay: '1200.5', adjusted_gross: '1200.5', pretax_deductions: '0.0',
        employee_taxes: '200.0', federal_income_tax: '100.0', social_security_tax: '75.0', medicare_tax: '25.0',
        after_tax_deductions: '75.25', net_pay: '925.25', employer_taxes: '100.0', employer_contributions: '0.0',
        total_payroll_cost: '1300.5', hours_breakdown: [], earnings_breakdown: [], pretax_deduction_breakdown: [],
        after_tax_deduction_breakdown: [], employee_tax_breakdown: [], employer_tax_breakdown: [], employer_contribution_breakdown: [],
      }],
    },
    meta: { current_page: 1, per_page: 50, total_count: 1, total_pages: 1 },
  }));

  await page.goto('/companies/1/pay-runs?source=quickbooks&year=2024');

  await expect(page.getByRole('heading', { name: 'Pay Periods' })).toBeVisible();
  await expect(page.getByText('Data Migration', { exact: true })).toBeVisible();
  const importedRow = page.getByRole('row').filter({ hasText: 'QuickBooks import' });
  await expect(importedRow).toContainText('Locked');
  await expect(importedRow.getByRole('button', { name: 'View' })).toBeVisible();
  await expect(importedRow.getByRole('button', { name: 'Edit' })).toHaveCount(0);
  expect(listRequestUrl).toContain('source=quickbooks');
  expect(listRequestUrl).toContain('year=2024');

  await importedRow.getByRole('button', { name: 'View' }).click();
  await expect(page).toHaveURL(/\/companies\/1\/pay-runs\/imported\/77/);
  await expect(page.getByText('Locked source record')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Payroll records' })).toBeVisible();
  await expect(page.getByRole('table').getByText('Avery Example')).toBeVisible();
  await expect(page.getByText('quickbooks-online-payroll-v5')).toBeVisible();
  await expect(page.getByRole('button', { name: /edit|delete|approve|commit|recalculate/i })).toHaveCount(0);

  await page.getByRole('button', { name: 'Back to Payroll' }).click();
  await expect(page).toHaveURL('/companies/1/pay-runs?source=quickbooks&year=2024');
});

test('shows an explicit error instead of an empty imported payroll when detail loading fails', async ({ page }) => {
  await mockShell(page);
  await page.route('**/api/v1/admin/imported_pay_periods/77**', (route) => fulfillJson(route, {
    error: 'Synthetic imported payroll failure',
  }, 500));

  await page.goto('/companies/1/pay-runs/imported/77');

  await expect(page.getByText('Synthetic imported payroll failure')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Payroll records' })).toHaveCount(0);
  await expect(page.getByText('Locked source record')).toHaveCount(0);
});

test('keeps an imported run visible when a native run with the same numeric id is deleted', async ({ page }): Promise<void> => {
  await mockShell(page);
  let nativeDeleted = false;
  await page.route('**/api/v1/admin/payroll_history**', async (route): Promise<void> => {
    if (nativeDeleted) {
      await fulfillJson(route, { error: 'Synthetic refresh failure' }, 500);
      return;
    }

    await fulfillJson(route, {
      data: [
        {
          key: 'imported:77', record_type: 'imported', id: 77, company_id: 1,
          start_date: '2024-01-01', end_date: '2024-01-14', pay_date: '2024-01-19',
          status: 'locked', run_purpose: 'regular', includes_base_salary: true, correction_status: null,
          employee_count: 1, total_gross: 1200.5, total_net: 925.25,
          processed_at: '2024-01-20T00:00:00Z', processed_by_name: 'Payroll Admin',
          source: { system: 'quickbooks_online', label: 'QuickBooks import', detail: 'MoSa Jan 1–14', locked: true },
          capabilities,
        },
        {
          key: 'native:77', record_type: 'native', id: 77, company_id: 1,
          start_date: '2024-01-15', end_date: '2024-01-28', pay_date: '2024-02-02',
          status: 'draft', run_purpose: 'regular', includes_base_salary: true, correction_status: null,
          employee_count: 0, total_gross: 0, total_net: 0,
          processed_at: null, processed_by_name: null,
          source: { system: 'cornerstone', label: 'Cornerstone', detail: 'Cornerstone', locked: false },
          capabilities: { ...capabilities, edit: true, delete: true, enter_hours: true, run: true },
        },
      ],
      meta: {
        current_page: 1, per_page: 50, total_count: 2, total_pages: 1,
        statuses: { locked: 1, draft: 1 }, sources: { quickbooks_online: 1, cornerstone: 1 }, years: [2024],
      },
    });
  });
  await page.route('**/api/v1/admin/pay_periods/77', (route): Promise<void> => {
    nativeDeleted = true;
    return fulfillJson(route, {});
  });
  page.on('dialog', (dialog): Promise<void> => dialog.accept());

  await page.goto('/companies/1/pay-runs');

  const nativeRow = page.getByRole('row').filter({ hasText: 'Cornerstone' });
  await nativeRow.getByRole('button', { name: 'Delete' }).click();

  await expect(page.getByRole('row').filter({ hasText: 'QuickBooks import' })).toBeVisible();
  await expect(page.getByText('Synthetic refresh failure')).toBeVisible();
});
