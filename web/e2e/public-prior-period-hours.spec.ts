import { test, expect, type Page } from '@playwright/test';

// Browser presentation/recovery coverage. The backend import/PDF suites prove
// saved financial outcomes separately; these HTTP fixtures contain no real pay.
async function fixture(page: Page) {
  let sourceReads = 0;
  const writes: string[] = [];
  const label = 'Ground Instruction and Administrative Training Duties';
  const sourceLine = { source_time_entry_id: '1804', line_key: 'admin', source_time_entry_version: 1, source_kind: 'carryover', original_work_date: '2026-09-15', regular_hours: 4.25, overtime_hours: 1, total_hours: 5.25 };
  const item = { id: 3, employee_id: 7, employee_name: 'Casey Example', company_id: 1, employment_type: 'hourly', pay_rate: 10,
    hours_worked: 4.25, overtime_hours: 1, total_hours: 5.25, gross_pay: 57.50, net_pay: 53.10, total_deductions: 4.40,
    import_source: 'time_tracking:aire_services:1:BATCH', check_number: 'TEST-ONLY', check_status: 'delivered', earnings_statement_eligible: true,
    wage_rate_hours: [{ label, rate: 10, regular_hours: 4.25, overtime_hours: 1, source_bucket_key: 'prior', source_lines: [sourceLine] }] };
  const payPeriod = { id: 2, company_id: 1, start_date: '2026-10-16', end_date: '2026-10-31', pay_date: '2026-11-15', status: 'committed', time_tracking: { aire_calendar: { source_id: 1 } }, payroll_items: [item] };
  await page.route('**/api/v1/**', async route => {
    const path = new URL(route.request().url()).pathname;
    if (!['GET', 'OPTIONS'].includes(route.request().method())) writes.push(path);
    let body: unknown = { data: [], meta: { total_pages: 1 } };
    if (path.endsWith('/auth/me')) body = { user: { id: 1, name: 'Review Admin', email: 'review@example.test', role: 'admin', company_id: 1, assigned_company_ids: [1], capabilities: [] } };
    else if (path.endsWith('/companies')) body = { companies: [{ id: 1, name: 'Synthetic Payroll', active: true, payroll_environment: 'live' }], current_company_id: 1, can_switch_company: false };
    else if (path.endsWith('/employees/7')) body = { data: { id: 7, company_id: 1, first_name: 'Casey', last_name: 'Example', employment_type: 'hourly', payment_delivery_method: 'paper_check' } };
    else if (path.endsWith('/payroll_items/3')) body = { payroll_item: item };
    else if (path.endsWith('/pay_periods/2')) body = { pay_period: payPeriod };
    else if (path.endsWith('/time_tracking_sources')) body = { time_tracking_sources: [{ id: 1, company_id: 1, name: 'AIRE', source_type: 'aire_services', active: true, base_url: 'https://example.test', shared_secret_configured: true }] };
    else if (path.endsWith('/preview_time_tracking_import')) body = { import: { id: 1, status: 'previewed', time_tracking_source_id: 1, source_name: 'AIRE', start_date: payPeriod.start_date, end_date: payPeriod.end_date, warnings: [],
      external_batch_id: 'BATCH', external_batch_checksum: 'a'.repeat(64), contract_version: 'payroll_batch_v2', source_cutoff_at: '2026-11-07T07:00:00Z',
      processed_payload: { validation_version: 'payroll_batch_v2', ready: true, exclusions: [], issues: {}, summary: { total_hours: 5.25 }, rows: [{ source_user_id: '37', source_display_name: 'Casey Example', employee_id: 7, employee_name: 'Casey Example', match_method: 'saved_mapping', match_score: 100, ready: true, warnings: [], issues: {}, regular_hours: 4.25, overtime_hours: 1, total_hours: 5.25, source_kind_counts: { carryover: 1 }, categories: [{ name: 'Admin Duties', source_category_id: '4', key: 'admin', regular_hours: 4.25, overtime_hours: 1, total_hours: 5.25, source_kinds: ['carryover'], employee_wage_rate_id: 1, payroll_rate_cents: 1000, original_work_dates: ['2026-09-15'] }] }] } } };
    else if (path.endsWith('/aire_payroll_cockpit/time_entries')) {
      sourceReads += 1;
      if (sourceReads === 1 || sourceReads === 3) {
        await route.fulfill({ status: 503, contentType: 'application/json', body: JSON.stringify({ error: 'Source unavailable for this test' }) });
        return;
      }
      body = { time_entries: [{ id: '1804', version: 1, work_date: '2026-09-15', created_at: '2026-09-23T03:14:22Z',
        capture: { entry_method: 'manual' }, category: { name: 'Admin Duties' }, state: { approval_status: 'approved', overtime_status: 'approved' },
        approval: { actor: { name: 'Review Manager' }, occurred_at: '2026-10-07T03:07:36Z', note: 'Reviewed against original records.' } }],
        pagination: { current_page: 1, total_pages: 1 } };
    }
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  return { reads: () => sourceReads, writes, payPeriod };
}

for (const width of [1280, 390]) {
  test(`prior-period work dates survive reload and source failure at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    const state = await fixture(page);
    await page.goto('/companies/1/pay-runs/2/payroll-items/3');
    const card = page.locator('div').filter({ has: page.getByRole('heading', { name: 'Work dates included in this paycheck', exact: true }) }).last();
    await expect(page.getByText('Prior-period hours · Sep 15, 2026', { exact: true })).toBeVisible();
    await expect(page.getByText(/Paying payroll:/)).toContainText('Nov 15, 2026');
    await expect(page.getByText(/4.25 regular hrs/)).toContainText('1.00 OT hrs');
    expect(state.reads()).toBe(0);
    await page.getByText('Original source entries', { exact: true }).click();
    await page.getByRole('button', { name: 'Review source entry #1804', exact: true }).click();
    await expect(page.getByText(/Saved work dates and hours remain available above/)).toBeVisible();
    await page.getByRole('button', { name: 'Try source again', exact: true }).click();
    await expect(page.getByText('Reviewed against original records.', { exact: true })).toBeVisible();
    await expect(page.getByText(/approved.*Review Manager/)).toBeVisible();
    await page.getByRole('button', { name: 'Review source entry #1804', exact: true }).click();
    await expect(page.getByText(/Saved work dates and hours remain available above/)).toBeVisible();
    await expect(page.getByText('Reviewed against original records.', { exact: true })).not.toBeVisible();
    await page.getByRole('button', { name: 'Try source again', exact: true }).click();
    await expect(page.getByText('Reviewed against original records.', { exact: true })).toBeVisible();
    if (process.env.PRIOR_PERIOD_BROWSER_DIR) await page.screenshot({ path: `${process.env.PRIOR_PERIOD_BROWSER_DIR}/source-history-${width}.png`, fullPage: true });
    await page.reload();
    await expect(page.getByText('Prior-period hours · Sep 15, 2026', { exact: true })).toBeVisible();
    expect(state.reads()).toBe(4);
    expect(state.writes).toEqual([]);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await expect(card).toBeAttached();
  });
}

test('import review shows original work dates next to prior-period hours before applying', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await fixture(page);
  await page.goto('/');
  await page.addScriptTag({ type: 'module', content: "import { mountPriorPeriodImport } from '/e2e/fixtures/prior-period-import-harness.tsx'; mountPriorPeriodImport();" });
  await expect(page.getByText('Prior-period work dates: Sep 15, 2026', { exact: true })).toBeInViewport();
  await expect(page.getByText('Worked: Sep 15, 2026', { exact: true })).toBeVisible();
  await expect(page.getByText('Prior-period hours', { exact: true })).toBeVisible();
  await expect(page.getByText(/Pay date: Nov 15, 2026/)).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  if (process.env.PRIOR_PERIOD_BROWSER_DIR) await page.screenshot({ path: `${process.env.PRIOR_PERIOD_BROWSER_DIR}/import-review-390.png` });
});

test('a supplemental run verifies its origin installation before reading matching entry IDs', async ({ page }) => {
  const state = await fixture(page);
  await page.route(url => url.pathname.endsWith('/pay_periods/2'), route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ pay_period: { ...state.payPeriod, time_tracking: undefined, late_hours_origin_pay_period_id: 99 } }) }));
  await page.route(url => url.pathname.endsWith('/pay_periods/99'), route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ pay_period: { ...state.payPeriod, id: 99, time_tracking: { aire_calendar: { source_id: 2 } } } }) }));
  await page.goto('/companies/1/pay-runs/2/payroll-items/3');
  await page.getByText('Original source entries', { exact: true }).click();
  await page.getByRole('button', { name: 'Review source entry #1804', exact: true }).click();
  await expect(page.getByText(/original source installation could not be verified/)).toBeVisible();
  await expect(page.getByText('Prior-period hours · Sep 15, 2026', { exact: true })).toBeVisible();
  expect(state.reads()).toBe(0);
});

test('saved leave earnings use their display label without borrowing imported work dates', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await fixture(page);
  await page.goto('/');
  await page.addScriptTag({ type: 'module', content: "import { mountSavedLeaveDisclosure } from '/e2e/fixtures/prior-period-import-harness.tsx'; mountSavedLeaveDisclosure();" });
  const disclosure = page.getByTestId('saved-leave-disclosure');
  await disclosure.scrollIntoViewIfNeeded();
  await expect(disclosure.getByText('Admin Duties PTO', { exact: true })).toBeVisible();
  await expect(disclosure).not.toContainText('Sep 15');
  await expect(disclosure.getByText('$20.00', { exact: true })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});
