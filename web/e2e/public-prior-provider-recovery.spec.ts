import { expect, test, type Page } from '@playwright/test';

async function fixture(page: Page, active = false) {
  let writes = 0;
  let draft: Record<string, unknown> | null = null;
  const record = {
    id: 7, status: 'active', provider_name: 'Example previous provider', tax_year: 2026,
    takeover_on: '2026-11-05', converted_at: '', activated_at: '2026-11-05T00:00:00Z', reversed_at: null,
    reversal_reason: null, batch_id: 1, source_run_ids: [2], can_reverse: true,
    periods: [{ id: 1, pay_date: '2026-11-04', start_date: '2026-10-08', end_date: '2026-10-28', paycheck_count: 1, totals: { gross_pay: '1000', net_pay: '800' } }],
    totals: { gross_pay: '1000', net_pay: '800' }, employee_balances: [], employee_totals: [],
    source_files: [], filing_responsibilities: [],
    payment_references: [{ employee_id: 1, pay_date: '2026-11-04', reference: '007060' }],
  };
  await page.route('**/api/v1/**', async route => {
    const path = new URL(route.request().url()).pathname;
    let body: unknown = { data: [], meta: { total_pages: 1 } };
    if (path.endsWith('/auth/me')) body = { user: { id: 1, role: 'accountant', capabilities: ['payroll_operations'], email: 'review@example.test', name: 'Reviewer', organization_id: 1, company_id: 1, assigned_company_ids: [1] } };
    else if (path.endsWith('/companies')) body = { companies: [{ id: 1, name: 'Example payroll client', active: true, payroll_environment: 'live', pay_frequency: 'semimonthly' }], can_manage_clients: false, can_switch_company: false, current_company_id: 1 };
    else if (path.endsWith('/prior_provider_histories/draft')) {
      writes++;
      if (writes === 1) {
        await route.fulfill({ status: 422, contentType: 'application/json', body: JSON.stringify({ error: 'Register notes are too long. Shorten them and retry.' }) });
        return;
      }
      const input = route.request().postDataJSON();
      draft = { ...input, lock_version: 0, updated_at: '2026-11-05T00:00:00Z', updated_by_name: 'Reviewer' };
      body = { draft };
    } else if (path.endsWith('/prior_provider_histories')) body = {
      company_id: 1, enabled: active, can_manage: true, candidates: [], eligible_run_count: 0,
      candidates_overflow: false, employees: [], draft, onboardings: active ? [record] : [],
      readiness_gaps: active ? [{ employee_id: 1, employee_name: 'Employee 1', label: 'Signed withholding election', status: 'missing' }] : [],
    };
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  return () => writes;
}

for (const width of [1280, 390]) {
  test(`prior-provider save failure pauses and retry survives reload at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    const writes = await fixture(page);
    await page.goto('/companies/1/prior-provider-history');
    const provider = page.getByLabel('Previous payroll provider');
    await provider.fill('Example previous provider');
    await expect(page.getByText('Register notes are too long. Shorten them and retry.')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Reload', exact: true })).toHaveCount(0);
    await expect(provider).toHaveValue('Example previous provider');
    await page.clock.install();
    await page.clock.fastForward(6000);
    expect(writes()).toBe(1);
    await page.getByRole('button', { name: /Retry/ }).click();
    await expect(page.getByText(/^Saved/)).toBeVisible();
    expect(writes()).toBe(2);
    await expect(page.getByText('Register notes are too long. Shorten them and retry.')).toHaveCount(0);
    await page.reload();
    await expect(provider).toHaveValue('Example previous provider');
    await expect(page.getByText(/^Saved/)).toBeVisible();
    expect(writes()).toBe(2);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  });

  test(`first-live suggestion follows period end with a later historical payday at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await fixture(page, true);
    await page.goto('/companies/1/prior-provider-history');
    await expect(page.getByText('Year-to-date on', { exact: true })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Create the first live pay period' })).toHaveAttribute('href', '/companies/1/pay-runs?new_after=2026-10-28');
    await expect(page.getByRole('link', { name: /Set the next live check number/ })).toHaveAttribute('href', '/check-settings?company_id=1&suggested_next=7061#next-check-number');
    await expect(page.getByRole('link', { name: /Employee 1: Signed withholding election/ })).toHaveAttribute('href', /employees\/1\/edit\?/);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    if (process.env.PR407_SCREENSHOT_DIR) {
      await page.getByText('Before the first live payroll', { exact: true }).locator('..').screenshot({ path: `${process.env.PR407_SCREENSHOT_DIR}/next-steps-${width}.png` });
    }
  });
}
