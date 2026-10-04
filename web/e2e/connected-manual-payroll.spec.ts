import { expect, test } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';

const fixture = JSON.parse(readFileSync(process.env.E2E_CONNECTED_FIXTURE_PATH!, 'utf8'));
const aire = JSON.parse(readFileSync(process.env.E2E_AIRE_FIXTURE_PATH!, 'utf8'));
const policy = JSON.parse(readFileSync(process.env.CERTIFICATION_POLICY_FIXTURE_PATH!, 'utf8'));
const periodId = fixture.manual_browser_pay_period_id;
const apiBase = `http://localhost:${process.env.E2E_API_PORT || '44338'}/api/v1`;
const headers = { 'X-E2E-User-Email': fixture.manual_accountant_email, 'X-Company-Id': String(fixture.company_id) };
test.use({ extraHTTPHeaders: headers });

test('assigned accountant enters manual hours, commits an existing check and links exact AIRE hours before recording issuance', async ({ page, request, browser }, testInfo) => {
  const auth = await request.get(`${apiBase}/auth/me`);
  expect(auth.ok()).toBeTruthy();
  const user = (await auth.json()).user;
  expect(user.role).toBe('accountant');
  expect(user.capabilities).toContain('manage_historical_time_reconciliation');
  expect(user.capabilities).not.toContain('manage_client_configuration');
  const path = `/companies/${fixture.company_id}/pay-runs/${periodId}/work`;
  await page.goto(path);
  await expect(page.getByRole('heading', { name: 'Processing Timeline', exact: true })).toBeVisible({ timeout: 30_000 });
  const row = page.getByRole('row').filter({ hasText: fixture.manual_employee_name }).filter({ has: page.getByRole('textbox') });
  await expect(row).toBeVisible();
  const inputs = row.getByRole('textbox');
  await inputs.nth(0).fill('4');
  await inputs.nth(0).press('Tab');
  await inputs.nth(1).fill('0');
  await inputs.nth(1).press('Tab');
  await page.getByRole('button', { name: 'Calculate Payroll', exact: true }).click();
  await page.getByRole('button', { name: 'Approve', exact: true }).click();
  page.once('dialog', dialog => dialog.accept());
  await page.getByRole('button', { name: 'Commit & Finalize', exact: true }).click();
  await expect(page.getByText('Committed', { exact: true }).first()).toBeVisible();
  const before = await (await request.get(`${apiBase}/admin/pay_periods/${periodId}`)).json();
  const item = before.pay_period.payroll_items.find((value: { employee_id: number }) => value.employee_id === fixture.manual_employee_id);
  expect(item).toBeTruthy();
  expect(Number(item.hours_worked)).toBe(4);
  expect(Number(item.overtime_hours)).toBe(0);

  // Generate the saved check package through the real printing controls.
  await page.getByRole('button', { name: 'Print checks', exact: true }).click();
  const printDialog = page.getByRole('dialog');
  const generate = printDialog.getByRole('button', { name: 'Generate and save package', exact: true });
  await expect(generate).toBeEnabled();
  const generationResponse = page.waitForResponse(response => response.url().endsWith('/check_print_generations')
    && response.request().method() === 'POST');
  await generate.click();
  const generationResult = await generationResponse;
  expect(generationResult.ok()).toBeTruthy();
  const generationBody = await generationResult.json();
  execFileSync('bundle', ['exec', 'rails', 'runner', resolve('scripts/connected-browser-generation.rb')], {
    cwd: resolve('../api'), timeout: 60_000,
    env: { ...process.env, RAILS_ENV: 'test', E2E_TEST_MODE: 'true',
      CONNECTED_BROWSER_GENERATION_ID: String(generationBody.check_print_generation.id) },
    stdio: 'pipe',
  });
  await expect(printDialog.getByText('Prepared', { exact: true }).first()).toBeVisible();
  await printDialog.getByRole('button', { name: 'Close', exact: true }).click();

  const reconciliation = page.getByLabel('Manual AIRE payroll reconciliation');
  await expect(reconciliation.getByLabel('Exact AIRE time entry')).toBeVisible();
  const sourceOption = reconciliation.getByRole('option').filter({ hasText: `entry ${aire.manual_browser_entry_id} ·` });
  await expect(sourceOption).toHaveCount(1);
  await reconciliation.getByLabel('Exact AIRE time entry').selectOption((await sourceOption.getAttribute('value'))!);
  await reconciliation.getByLabel('Existing committed payroll item').selectOption(String(item.id));
  await reconciliation.getByLabel('Evidence and reconciliation reason').fill('Synthetic browser QA: exact source hours covered by this existing committed check');
  await reconciliation.getByRole('button', { name: 'Link hours to payroll item', exact: true }).click();
  await expect(reconciliation.getByText('Linked; payment evidence pending').first()).toBeVisible();
  await expect(reconciliation.getByText('Payment recorded in AIRE')).toHaveCount(0);
  const reviewPath = `${apiBase}/admin/pay_periods/${periodId}/aire_payroll_cockpit/manual_review`;
  const pendingReview = await (await request.get(reviewPath)).json();
  const allocation = pendingReview.cornerstone_manual_allocations.find((value: { payroll_item_id: number }) => value.payroll_item_id === item.id);
  expect(allocation.status).toBe('committed');
  expect(allocation.source_user_uuid).toBe(aire.manual_employee_uuid);
  expect(allocation.original_work_date).toBe(aire.manual_browser_work_date);
  expect(Number(allocation.regular_hours)).toBe(4);
  expect(Number(allocation.overtime_hours)).toBe(0);
  expect(allocation.payroll_item_check_status).toBe('prepared');

  await reconciliation.scrollIntoViewIfNeeded();
  await page.screenshot({ path: testInfo.outputPath('manual-prepared-unpaid-desktop.png'), fullPage: false });
  const mobile = await browser.newContext({ viewport: { width: 390, height: 844 }, extraHTTPHeaders: headers,
    timezoneId: 'Pacific/Guam', reducedMotion: 'reduce' });
  try {
    const phone = await mobile.newPage();
    await phone.goto(new URL(path, page.url()).href);
    const mobileReview = phone.getByLabel('Manual AIRE payroll reconciliation');
    await expect(mobileReview.getByText('Linked; payment evidence pending')).toBeVisible();
    await mobileReview.scrollIntoViewIfNeeded();
    expect(await mobileReview.evaluate(node => node.scrollWidth <= node.clientWidth + 1)).toBe(true);
    await phone.screenshot({ path: testInfo.outputPath('manual-prepared-unpaid-mobile.png'), fullPage: false });
  } finally { await mobile.close(); }

  // This is synthetic evidence. Real check handoff remains an operator attestation.
  await page.getByRole('button', { name: 'Record Issued', exact: true }).first().click();
  const delivery = page.getByRole('dialog');
  await delivery.getByLabel('Issue date').fill(policy.delivery_date);
  await delivery.getByLabel('Reference (optional)').fill('Synthetic certification handoff');
  await delivery.getByRole('checkbox').check();
  await delivery.getByRole('button', { name: 'Record Issued', exact: true }).click();
  await expect(delivery).toHaveCount(0);
  // Test queues do not run a hosted worker: exercise the operator's durable retry.
  await reconciliation.getByRole('button', { name: `Retry sync for entry ${aire.manual_browser_entry_id}`, exact: true }).click();
  await expect(reconciliation.getByText('Payment recorded in AIRE').first()).toBeVisible();
  const issuedReview = await (await request.get(reviewPath)).json();
  const issued = issuedReview.cornerstone_manual_allocations.find((value: { id: number }) => value.id === allocation.id);
  expect(issued.status).toBe('issued');
  expect(issued.remote_allocation_id).toBeTruthy();
  expect(issuedReview.employees.flatMap((value: { adjustments: Array<{ source_time_entry_id: string }> }) => value.adjustments)
    .some((value: { source_time_entry_id: string }) => String(value.source_time_entry_id) === String(aire.manual_browser_entry_id))).toBe(false);
  const after = await (await request.get(`${apiBase}/admin/pay_periods/${periodId}`)).json();
  expect(after.pay_period.payroll_items.map((value: { id: number }) => value.id)).toEqual(before.pay_period.payroll_items.map((value: { id: number }) => value.id));
  const finalItem = after.pay_period.payroll_items.find((value: { id: number }) => value.id === item.id);
  for (const field of ['hours_worked', 'overtime_hours', 'gross_pay', 'net_pay']) expect(finalItem[field]).toEqual(item[field]);
  await reconciliation.scrollIntoViewIfNeeded();
  await page.screenshot({ path: testInfo.outputPath('manual-issued-desktop.png'), fullPage: false });
});
