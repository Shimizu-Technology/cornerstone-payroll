import { expect, test } from '@playwright/test';

test('Tax Summary exports every format after the results card has loaded', async ({ page }, testInfo) => {
  const exported: string[] = [];
  await page.route('**/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    let body: unknown = {};
    if (path.endsWith('/auth/me')) body = { user: { id: 1, role: 'admin', name: 'Review Admin', company_id: 1, organization_id: 1, assigned_company_ids: [1] } };
    else if (path.endsWith('/companies')) body = { companies: [{ id: 1, name: 'Synthetic Review Company', active: true }], can_switch_company: false, current_company_id: 1 };
    else if (path.endsWith('/tax_summary')) body = { report: {
      period: { year: 2026, start_date: '2026-01-01', end_date: '2026-12-31' }, pay_periods_included: 1, employee_count: 1,
      totals: { gross_wages: 1000, withholding_tax: 100, social_security_employee: 62, social_security_employer: 62, medicare_employee: 14.5, medicare_employer: 14.5, total_employment_taxes: 253 },
    } };
    else if (/tax_summary_(pdf|xlsx|csv)$/.test(path)) {
      const format = path.split('_').at(-1)!;
      exported.push(format);
      return route.fulfill({ contentType: 'application/octet-stream', headers: { 'content-disposition': `attachment; filename="review.${format}"` }, body: 'Synthetic export response' });
    }
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  await page.goto('/reports?report=tax-withholding-summary');
  await page.locator('#ts-year').selectOption('2026');
  await page.getByRole('button', { name: 'View Report', exact: true }).click();
  await expect(page.getByRole('heading', { name: /Tax Summary —/ })).toBeVisible();
  for (const [label, format] of [['PDF', 'pdf'], ['Excel workbook', 'xlsx'], ['CSV data', 'csv']]) {
    await page.getByRole('button', { name: /Export Tax Summary/ }).click();
    if (format === 'pdf') await page.screenshot({ path: testInfo.outputPath('export-menu-fixed.png') });
    const download = page.waitForEvent('download');
    await page.getByRole('menuitem', { name: new RegExp(`^${label}`) }).click();
    expect((await download).suggestedFilename()).toMatch(new RegExp(`\\.${format}$`));
  }
  expect(exported).toEqual(['pdf', 'xlsx', 'csv']);
});
