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
  test(`client report catalog and PDF download at ${viewport.width}px`, async ({ page }) => {
    await page.setViewportSize(viewport);
    await mockPracticeClient(page);
    await page.route('**/api/v1/client/reports/**', route => {
      if (route.request().url().includes('_pdf')) return route.fulfill({ contentType: 'application/pdf', headers: { 'Content-Disposition': 'attachment; filename="report.pdf"' }, body: '%PDF-1.4 test' });
      return json(route, { report: null });
    });
    await page.goto('/reports');
    await expect(page.getByRole('region', { name: 'Report catalog' })).toBeVisible();
    await expect(page.getByText('Deductions & Contributions', { exact: true })).toBeVisible();
    await page.getByRole('button', { name: 'Export Payroll Summary by Employee' }).click();
    const download = page.waitForEvent('download');
    await page.getByRole('menuitem', { name: /PDF/ }).click();
    await download;
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  });
}
