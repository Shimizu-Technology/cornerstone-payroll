import { test, expect, type Page } from '@playwright/test';

// The pay-run workspace should only request what its first view shows. These
// HTTP fixtures are synthetic and contain no real pay.
const item = { id: 3, employee_id: 7, employee_name: 'Casey Example', company_id: 1, employment_type: 'hourly', pay_rate: 10,
  hours_worked: 40, overtime_hours: 0, gross_pay: 400, net_pay: 360, total_deductions: 40, withholding_tax: 20,
  check_number: '1001', check_status: 'prepared', effective_payment_delivery_method: 'paper_check' };
const payPeriod = { id: 2, company_id: 1, start_date: '2026-10-16', end_date: '2026-10-31', pay_date: '2026-11-15', status: 'committed',
  cycle: 'regular', run_purpose: 'regular', payroll_items: [item] };

async function fixture(page: Page) {
  const reads: string[] = [];
  page.on('console', message => { if (message.type() === 'error') console.log(`console error: ${message.text()}`); });
  await page.route('**/api/v1/**', async route => {
    const path = new URL(route.request().url()).pathname.replace(/^.*\/api\/v1/, '');
    if (route.request().method() === 'GET') reads.push(path);
    if (path.endsWith('/comparison')) {
      await route.fulfill({ status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'No prior period in this fixture' }) });
      return;
    }
    if (path.endsWith('/cable_ticket')) {
      await route.fulfill({ status: 403, contentType: 'application/json', body: JSON.stringify({ error: 'Live updates unavailable in this fixture' }) });
      return;
    }
    let body: unknown = { data: [], meta: { total_pages: 1 } };
    if (path.endsWith('/auth/me')) body = { user: { id: 1, name: 'Review Admin', email: 'review@example.test', role: 'admin', company_id: 1, assigned_company_ids: [1], capabilities: [] } };
    else if (path.endsWith('/companies')) body = { companies: [{ id: 1, name: 'Synthetic Payroll', active: true, payroll_environment: 'live' }], current_company_id: 1, can_switch_company: false };
    else if (path.endsWith('/companies/1')) body = { company: { id: 1, name: 'Synthetic Payroll' } };
    else if (path === '/admin/pay_periods/2') body = { pay_period: payPeriod };
    else if (path.endsWith('/checks')) body = { checks: [], meta: { total: 0 } };
    else if (path.endsWith('/non_employee_checks')) body = { non_employee_checks: [] };
    else if (path.endsWith('/supplemental_pay_periods')) body = { supplemental_pay_periods: [] };
    else if (path.endsWith('/timecards')) body = [];
    else if (path.endsWith('/payroll_field_inputs')) body = { payroll_field_inputs: { fields: [], assignments: [] } };
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  return reads;
}

const checksTabReads = (path: string) => /\/pay_periods\/2\/checks$|\/check_print_queue$|\/companies\/1$/.test(path);
const activityTabReads = (path: string) => path.endsWith('/timecards');
const reportsTabReads = (path: string) => /\/final_record$|\/check_signoff_preview$|\/transmittal_preview$/.test(path);

test('first open fetches only the Payroll tab, and other tabs load when opened', async ({ page }) => {
  const reads = await fixture(page);
  await page.goto('/companies/1/pay-runs/2/work');
  await expect(page.getByRole('region', { name: 'Payroll workspace' })).toBeVisible();
  const tabs = page.getByRole('navigation', { name: 'Pay-run workspace sections' });
  await page.waitForLoadState('networkidle');
  const firstOpen = [...reads];
  console.log(`first open: ${firstOpen.length} API reads\n  ${firstOpen.join('\n  ')}`);
  expect(firstOpen.filter(checksTabReads)).toEqual([]);
  expect(firstOpen.filter(reportsTabReads)).toEqual([]);
  expect(firstOpen.filter(activityTabReads)).toEqual([]);
  // Results still checks a committed run's FIT deposit for an override.
  expect(firstOpen.filter(path => path.endsWith('/non_employee_checks')).length).toBeLessThanOrEqual(1);

  await tabs.getByRole('link', { name: /Checks/ }).click();
  await expect(page.getByRole('region', { name: 'Checks and payments workspace' })).toBeVisible();
  await expect.poll(() => reads.filter(checksTabReads).length).toBeGreaterThan(0);

  await tabs.getByRole('link', { name: /Reports/ }).click();
  await expect(page.getByRole('region', { name: 'Reports workspace' })).toBeVisible();
  await expect.poll(() => reads.filter(reportsTabReads).length).toBeGreaterThan(0);

  await tabs.getByRole('link', { name: /Activity/ }).click();
  await expect(page.getByRole('region', { name: 'Activity workspace' })).toBeVisible();
  await expect.poll(() => reads.filter(activityTabReads).length).toBeGreaterThan(0);
});
