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
  test(`client downloads employee stub from pay period and history at ${viewport.width}px`, async ({ page }) => {
    await page.setViewportSize(viewport);
    await mockPracticeClient(page);
    await page.route('**/api/v1/client/pay_periods/91', route => json(route, { pay_period: {
      id: 91, company_id: 12, start_date: '2026-10-05', end_date: '2026-10-18', pay_date: '2026-10-22',
      status: 'approved', test_workspace_role: 'baseline', employee_count: 1, total_gross: 100, total_net: 90,
      payroll_items: [{ id: 701, employee_id: 7, employee_name: 'Synthetic Worker', employment_type: 'hourly',
        gross_pay: 100, net_pay: 90, pay_rate: 10, hours_worked: 10, pay_stub_available: true }],
    } }));
    await page.route('**/api/v1/client/employees/7', route => json(route, { data: {
      id: 7, company_id: 12, first_name: 'Synthetic', last_name: 'Worker', status: 'active',
      employment_type: 'hourly', pay_rate: 10, pay_frequency: 'biweekly',
    } }));
    await page.route('**/api/v1/client/pay_stubs/employee/7', route => json(route, { pay_stubs: [{
      id: 701, pay_period_id: 91, period_description: 'Oct 5 – 18, 2026', pay_date: '2026-10-22', net_pay: 90,
    }] }));
    await page.route('**/api/v1/client/pay_stubs/701/download', route => route.fulfill({
      contentType: 'application/pdf', headers: { 'Content-Disposition': 'attachment; filename="stub.pdf"' }, body: Buffer.from('JVBERi0xLjMKJf////8KMSAwIG9iago8PCAvQ3JlYXRvciA8ZmVmZjAwNTAwMDcyMDA2MTAwNzcwMDZlPgovUHJvZHVjZXIgPGZlZmYwMDUwMDA3MjAwNjEwMDc3MDA2ZT4KPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL0NhdGFsb2cKL1BhZ2VzIDMgMCBSCj4+CmVuZG9iagozIDAgb2JqCjw8IC9UeXBlIC9QYWdlcwovQ291bnQgMQovS2lkcyBbNSAwIFJdCj4+CmVuZG9iago0IDAgb2JqCjw8IC9MZW5ndGggOTAKPj4Kc3RyZWFtCnEKCkJUCjM2LjAgNzQ3LjM4NCBUZAovRjEuMCAxMiBUZgpbPDUzNzk2ZTc0Njg2NTc0Njk2MzIwNzA2MT4gMzAgPDc5MjA3Mzc0NzU2Mj5dIFRKCkVUCgpRCgplbmRzdHJlYW0KZW5kb2JqCjUgMCBvYmoKPDwgL1R5cGUgL1BhZ2UKL1BhcmVudCAzIDAgUgovTWVkaWFCb3ggWzAgMCA2MTIgNzkyXQovQ3JvcEJveCBbMCAwIDYxMiA3OTJdCi9CbGVlZEJveCBbMCAwIDYxMiA3OTJdCi9UcmltQm94IFswIDAgNjEyIDc5Ml0KL0FydEJveCBbMCAwIDYxMiA3OTJdCi9Db250ZW50cyA0IDAgUgovUmVzb3VyY2VzIDw8IC9Qcm9jU2V0IFsvUERGIC9UZXh0IC9JbWFnZUIgL0ltYWdlQyAvSW1hZ2VJXQovRm9udCA8PCAvRjEuMCA2IDAgUgo+Pgo+Pgo+PgplbmRvYmoKNiAwIG9iago8PCAvVHlwZSAvRm9udAovU3VidHlwZSAvVHlwZTEKL0Jhc2VGb250IC9IZWx2ZXRpY2EKL0VuY29kaW5nIC9XaW5BbnNpRW5jb2RpbmcKPj4KZW5kb2JqCnhyZWYKMCA3CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAxNSAwMDAwMCBuIAowMDAwMDAwMTA5IDAwMDAwIG4gCjAwMDAwMDAxNTggMDAwMDAgbiAKMDAwMDAwMDIxNSAwMDAwMCBuIAowMDAwMDAwMzU1IDAwMDAwIG4gCjAwMDAwMDA2MjEgMDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA3Ci9Sb290IDIgMCBSCi9JbmZvIDEgMCBSCj4+CnN0YXJ0eHJlZgo3MTgKJSVFT0YK', 'base64'),
    }));
    await page.goto('/companies/12/pay-runs/91');
    await page.getByRole('button', { name: 'View pay stub' }).filter({ visible: true }).click();
    await expect(page.getByRole('dialog')).toBeVisible();
    await expect(page.getByLabel('Page 1 preview')).toBeVisible();
    await page.getByRole('button', { name: 'Close PDF preview' }).click();
    let download = page.waitForEvent('download');
    await page.getByRole('button', { name: 'Download pay stub' }).filter({ visible: true }).click();
    await download;
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.goto('/companies/12/employees/7/overview');
    await expect(page.getByRole('region', { name: 'Pay history' })).toBeVisible();
    download = page.waitForEvent('download');
    await page.getByRole('button', { name: 'Download pay stub' }).click();
    await download;
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  });
}
