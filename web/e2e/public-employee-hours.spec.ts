import { expect, test, type Page } from '@playwright/test';

const totals = { worked_hours: 41, eligible_hours: 41, pending_hours: 0, denied_hours: 0,
  issued_hours: 41, committed_hours: 0, exported_hours: 0, held_hours: 0, needs_reconciliation_hours: 0,
  current_regular_hours: 40.5, current_overtime_hours: 0.5, frozen_regular_hours: 40.5, frozen_overtime_hours: 0.5, open_case_count: 0 };
const period = { id: '2026-08-01', start_date: '2026-08-01', end_date: '2026-08-15', summary: totals, review_required: false };
async function fixture(page: Page, unavailable = false) {
  await page.route('**/api/v1/**', async (route) => {
    const url = new URL(route.request().url()); const path = url.pathname;
    let body: unknown = { data: [], meta: { total_pages: 1 } };
    if (path.endsWith('/auth/me')) body = { user: { id: 1, role: 'admin', email: 'hours@example.test', name: 'Hours Reviewer', organization_id: 1, company_id: 1, assigned_company_ids: [1] } };
    else if (path.endsWith('/companies')) body = { companies: [{ id: 1, name: 'Example Business', active: true, payroll_environment: 'live', pay_frequency: 'semimonthly' }], can_manage_clients: true, can_switch_company: false, current_company_id: 1 };
    else if (path.endsWith('/employees/31')) body = { data: { id: 31, company_id: 1, first_name: 'Casey', last_name: 'Example', status: 'active', employment_type: 'hourly', pay_rate: 9.25, payment_delivery_method: 'paper_check', pay_frequency: 'semimonthly' } };
    else if (path.endsWith('/employee_pay_history')) body = { report: { summary: {}, history: [{ key: 'native:9', record_type: 'native', payroll_item_id: 9, pay_period_id: 5, pay_date: '2026-08-30', period_description: 'August 1–15 payroll', hours_worked: 41, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, gross_pay: 379.25, net_pay: 350, total_deductions: 29.25, source: { label: 'Cornerstone' }, payment_evidence: { status: 'issued', label: 'Check delivered', effective_on: '2026-08-30' } }] } };
    else if (path.endsWith('/hours_evidence')) body = { status: unavailable ? 'unavailable' : 'available', source_id: 3, sources: [{ id: 3, name: 'Example time app', active: !unavailable, employee_identity_verified: true }], message: unavailable ? 'This connection is disabled. Saved payroll history remains available.' : undefined,
      evidence: unavailable ? undefined : { as_of: '2026-10-05T00:00:00Z', contract_version: '1.0', totals, periods: [period], pagination: { total_count: 1, per_page: 20, next_cursor: null }, period: url.searchParams.has('period_id') ? { ...period, entries: [{ id: '18', work_date: '2026-08-05', description: 'Maintenance shift', regular_hours: 40.5, overtime_hours: 0.5, issued_hours: 41, needs_reconciliation_hours: 0, approval_status: 'approved', overtime_status: 'approved' }], coverage_lines: [], settlement_cases: [], detail_pagination: { per_page: 25, offset: 0, counts: { entries: 1, coverage_lines: 0, settlement_cases: 0 }, next_cursor: null } } : undefined } };
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
}
for (const viewport of [{ width: 1440, height: 960 }, { width: 390, height: 844 }]) {
  test(`employee work evidence keeps actual payroll classification distinct at ${viewport.width}px`, async ({ page }) => {
    await page.setViewportSize(viewport); await fixture(page);
    await page.goto('/companies/1/employees/31/hours-payroll?hours_start=2026-08-01&hours_end=2026-08-15&return_to=%2Fcompanies%2F1%2Femployees');
    await expect(page.getByText('REG 41.00 · OT 0.00', { exact: true })).toBeVisible();
    await expect(page.getByText('Current classification:', { exact: false })).toContainText('OT 0.50');
    await page.getByRole('button', { name: 'Review period' }).click();
    await expect(page).toHaveURL(/period=2026-08-01/);
    await expect(page.getByText('Maintenance shift')).toBeVisible();
    await expect(page.getByRole('link', { name: 'Payroll item', exact: true })).toHaveAttribute('href', /return_to=.*period%3D2026-08-01/);
    await page.getByRole('link', { name: /^Pay history/ }).click();
    await expect(page).toHaveURL(/hours_start=2026-08-01/);
    await page.getByRole('link', { name: 'Hours & payroll', exact: true }).click();
    await expect(page.getByText('Maintenance shift')).toBeVisible();
    await page.getByRole('button', { name: 'All work periods' }).click();
    await expect(page).not.toHaveURL(/period=/);
    await expect(page.getByLabel('Work from')).toHaveValue('2026-08-01');
    await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.getByRole('button', { name: 'Review period' }).focus();
    await page.keyboard.press('Enter');
    await expect(page.getByText('Maintenance shift')).toBeVisible();
  });
}
test('a disabled source leaves saved payroll and exact record navigation available', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 }); await fixture(page, true);
  await page.goto('/companies/1/employees/31/hours-payroll');
  await expect(page.getByText('This connection is disabled. Saved payroll history remains available.')).toBeVisible();
  await expect(page.getByText('Check delivered · $350.00 net')).toBeVisible();
  await expect(page.getByRole('link', { name: 'Payroll item', exact: true })).toHaveAttribute('href', /pay-runs\/5\/payroll-items\/9/);
  await expect(page.getByRole('button', { name: 'Try again', exact: true })).toBeVisible();
});
