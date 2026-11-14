import { expect, test, type Page, type Route } from '@playwright/test';

function json(route: Route, body: unknown): Promise<void> {
  return route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
}

const practiceCopy = {
  payroll_intake_source_types: ['mosa_revel'],
  id: 12, name: 'MoSa Practice', active: true, payroll_environment: 'migration_rehearsal',
  test_workspace: true, practice_portal: true, workspace_can_write: false, test_workspace_purpose: 'sandbox',
  migration_source_company_name: 'MoSa',
};

async function mockPracticeClient(page: Page): Promise<void> {
  await page.route('**/api/v1/auth/me', (route) => json(route, { user: {
    id: 14, email: 'practice@example.test', name: 'Practice Client', role: 'client',
    organization_id: 1, organization_name: 'Cornerstone', company_id: 12,
    company_name: practiceCopy.name, home_company_id: 12, assigned_company_ids: [12],
  } }));
  await page.route('**/api/v1/companies', (route) => json(route, {
    companies: [practiceCopy], can_manage_clients: false, can_view_client_management: false,
    can_switch_company: false, current_company_id: 12,
  }));
  await page.route('**/api/v1/client/pay_periods**', (route) => json(route, {
    pay_periods: [{
      key: 'native:91', record_type: 'native', id: 91, company_id: 12,
      start_date: '2026-10-05', end_date: '2026-10-18', pay_date: '2026-10-22', status: 'approved',
      run_purpose: 'regular', includes_base_salary: true, includes_recurring_items: true,
      test_workspace_role: 'baseline', employee_count: 52, total_gross: 65047.21, total_net: 47441.02,
      source: { system: 'cornerstone', label: 'Cornerstone', detail: 'Cornerstone', locked: false },
      capabilities: { view: true },
    }],
    meta: { current_page: 1, per_page: 25, total_count: 1, total_pages: 1, statuses: { approved: 1 }, sources: {}, years: [2026] },
  }));
  await page.route('**/api/v1/client/employees**', (route) => json(route, { data: [], meta: { current_page: 1, total_pages: 1, total_count: 0, per_page: 500 } }));
  await page.route('**/api/v1/client/departments**', (route) => json(route, { data: [] }));
}

for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
  test(`practice client sees the Client Portal label, copied history and Add Employee at ${viewport.width}px`, async ({ page }, testInfo) => {
    await page.setViewportSize(viewport);
    await mockPracticeClient(page);

    await page.goto('/companies/12/pay-runs');
    await expect(page.getByText('Paid (copied history)').filter({ visible: true }).first()).toBeVisible();
    if (viewport.width >= 1024) {
      await expect(page.getByText('Client Portal', { exact: true })).toBeVisible();
      await expect(page.getByRole('link', { name: 'Pay Period Files' })).toBeVisible();
    } else {
      await expect(page.getByText('Cornerstone Payroll · Client Portal')).toBeVisible();
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.screenshot({ path: testInfo.outputPath(`practice-pay-periods-${viewport.width}.png`), fullPage: true });

    await page.goto('/companies/12/employees');
    await expect(page.getByRole('button', { name: 'Add Employee' }).filter({ visible: true }).first()).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath(`practice-employees-${viewport.width}.png`), fullPage: true });
  });
}
