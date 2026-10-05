import { expect, test, type Page } from '@playwright/test';

const delivery = { recorded_count: 3, pending_count: 2, failed_count: 1, last_success_at: '2026-10-05T00:00:00Z', failure_record_updated_at: '2026-10-05T01:00:00Z', oldest_pending_at: '2026-10-04T00:00:00Z', oldest_pending_age_seconds: 86400, pay_period_ids: [21] };
const health = { source_id: 4, company_id: 1, active: true, as_of: '2026-10-06T00:00:00Z', last_source_activity_at: null, evidence_scope: 'local_records', receipts: { batch: delivery, entry: delivery }, calendar: { supported: true, recorded_period_count: 1, unacknowledged_revision_count: 1, failed_revision_count: 0, last_success_at: null, oldest_pending_at: '2026-10-04T00:00:00Z', oldest_pending_age_seconds: 86400, pay_period_ids: [21] }, latest_import_mapping_review: { status: 'recorded', missing_count: 2, as_of: '2026-10-05T00:00:00Z', pay_period_id: 21 }, reconciliation: { pending_classification_count: 1, manual_pending_commit_count: 0, manual_sync_failed_count: 1, pay_period_ids: [21] }, source_settlement_holds: { status: 'not_fetched', count: null }, source_roster_missing_mappings: { status: 'not_fetched', count: null } };
async function fixture(page: Page, firstFailure = false) {
  let healthReads = 0;
  await page.route('**/api/v1/**', async route => {
    const path = new URL(route.request().url()).pathname;
    let body: unknown = { data: [], meta: { total_pages: 1 } };
    if (path.endsWith('/auth/me')) body = { user: { id: 1, role: 'accountant', capabilities: ['manage_own_aire_account_link', 'payroll_operations'], email: 'review@example.test', name: 'Reviewer', organization_id: 1, company_id: 1, assigned_company_ids: [1] } };
    else if (path.endsWith('/companies')) body = { companies: [{ id: 1, name: 'Example Business', active: true, payroll_environment: 'live', pay_frequency: 'semimonthly' }], can_manage_clients: false, can_switch_company: false, current_company_id: 1 };
    else if (path.endsWith('/time_tracking_sources')) body = { time_tracking_sources: [{ id: 4, company_id: 1, name: 'Example Time', active: true, source_type: 'custom', supported_operations: ['account_linking'], identity_verified: true }] };
    else if (path.endsWith('/aire_account_link')) body = { account_link: { connected: true, source_user_name: 'Reviewer' } };
    else if (path.endsWith('/4/health')) {
      healthReads++;
      expect(route.request().headers()['x-company-id']).toBe('1');
      if (firstFailure && healthReads === 1) { await route.fulfill({ status: 503, contentType: 'application/json', body: JSON.stringify({ error: 'Stored delivery review unavailable.' }) }); return; }
      body = health;
    }
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  return () => healthReads;
}
for (const width of [1440, 390]) {
  test(`connector review is lazy, keyboard accessible and retains exact repair context at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 960 }); const reads = await fixture(page);
    await page.goto('/app/time-account-connection?source_id=4&return_to=%2Fcompanies%2F1%2Fpay-runs%2F21%2Fwork');
    const button = page.getByRole('button', { name: 'Review connection deliveries' });
    await expect(button).toBeVisible(); expect(reads()).toBe(0);
    await button.focus(); await page.keyboard.press('Enter');
    await expect(page.getByText('Batch receipts', { exact: true })).toBeVisible();
    await expect(page).toHaveURL(/source_id=4.*connection_health=open/);
    await expect(page.getByText('2 pending · 1 failed deliveries').first()).toBeVisible();
    await expect(page.getByText(/Current source settlement holds/)).toContainText('not fetched');
    const link = page.getByRole('link', { name: 'Review pay run #21', exact: true }).first();
    await expect(link).toHaveAttribute('href', /\/companies\/1\/pay-runs\/21\/work\?return_to=.*source_id%3D4.*connection_health%3Dopen/);
    await expect.poll(() => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.reload(); await expect(page.getByText('Entry receipts', { exact: true })).toBeVisible();
    await page.getByRole('button', { name: 'Hide connection review' }).click();
    await expect(page).not.toHaveURL(/connection_health=/);
    await expect(page.getByRole('link', { name: 'Return to payroll', exact: true })).toHaveAttribute('href', '/companies/1/pay-runs/21/work');
  });
}
test('failed local summary never becomes a successful zero and can be retried', async ({ page }) => {
  await fixture(page, true);
  await page.goto('/app/time-account-connection?source_id=4&connection_health=open');
  await expect(page.getByRole('alert')).toContainText('Stored delivery review unavailable.');
  await expect(page.getByText('No receipt deliveries recorded.')).toHaveCount(0);
  await page.getByRole('button', { name: 'Retry connection review' }).click();
  await expect(page.getByText('Batch receipts', { exact: true })).toBeVisible();
});
