import { expect, test, type Page } from '@playwright/test';

const longEmail = 'alexandra.records.and.payroll@example-long-organization.test';
const longFilename = 'September-2026-corrected-payroll-source-document-with-a-long-filename.pdf';

async function mockStaffSettings(page: Page) {
  await page.route('**/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    let body: unknown = { data: [], meta: { current_page: 1, total_pages: 1, total_count: 0 } };
    if (path.endsWith('/auth/me')) body = { user: { id: 1, email: 'owner@example.test', name: 'Review Owner', role: 'super_admin', organization_id: 1, company_id: 1 } };
    else if (path.endsWith('/companies')) body = { companies: [{ id: 1, name: 'Mobile Review Client', active: true, payroll_environment: 'live' }], current_company_id: 1, can_switch_company: false };
    else if (path.endsWith('/admin/users')) body = { data: [{ id: 2, email: longEmail, name: 'Alexandra Records and Payroll', role: 'admin', organization_id: 1, active: true, created_at: '2026-09-01T00:00:00Z' }] };
    else if (path.endsWith('/admin/organizations')) body = { data: [{ id: 1, name: 'A Long Organization Name for Mobile Review', slug: 'long-organization-for-mobile-review', status: 'active', active: true, client_limit: 3, unlimited_clients: false, companies_count: 1, active_companies_count: 1, users_count: 1, org_admins: [{ id: 2, name: 'Alexandra Records and Payroll', email: longEmail, role: 'org_admin', active: true }], created_at: '2026-09-01T00:00:00Z', updated_at: '2026-09-01T00:00:00Z' }], meta: { current_page: 1, total_pages: 1, total_count: 1 } };
    else if (path.endsWith('/admin/audit_logs')) body = { data: [{ id: 11, action: 'updated', display_action: 'Updated payroll settings', display_subject: 'Corrected September payroll settings for mobile review', summary: 'Settings updated', record_type: 'Company', record_id: 1, user_id: 2, user_name: 'Alexandra Records and Payroll', actor_email: longEmail, actor_role: 'admin', event_category: 'change', subject_name: 'Mobile Review Client', organization_id: 1, organization_name: 'Mobile Review', company_id: 1, company_name: 'Mobile Review Client', metadata: {}, ip_address: null, user_agent: null, request_id: null, created_at: '2026-09-01T00:00:00Z' }], meta: { current_page: 1, total_pages: 1, total_count: 1 } };
    else if (path.endsWith('/admin/client_documents')) body = { data: [{ id: 21, title: 'Corrected payroll source document for September 2026', category: 'payroll_source', file_name: longFilename, content_type: 'application/pdf', file_size: 1024, employee_id: null, employee_name: null, uploaded_by_id: 2, uploaded_by_name: 'Alexandra Records', visible_to_client: true, shared_by_staff: false, created_at: '2026-09-01T00:00:00Z', preview_status: 'ready', preview_available: true }] };
    else if (path.endsWith('/admin/pay_schedule_settings')) body = { pay_schedule_settings: { pay_schedule: { frequency: 'biweekly', period_rule: 'manual', period_start_weekday: 0, period_anchor_date: null, pay_date_rule: 'manual', pay_date_offset_days: 0, payroll_cutoff_days_before: 7, payroll_cutoff_at_minutes: 1020, timezone: 'Pacific/Guam', source: 'operator_confirmed', confirmation_status: 'confirmed', effective_on: '2026-01-01', notes: 'Confirmed by employer' }, workweek: { starts_on_weekday: 0, starts_at_minutes: 0, timezone: 'Pacific/Guam', source: 'operator_confirmed', confirmation_status: 'confirmed', effective_on: '2026-01-01', notes: 'Confirmed by employer' } } };
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
}

async function expectFitsViewport(page: Page, width: number) {
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
}

for (const width of [320, 390]) {
  test(`keeps secondary settings usable on a ${width}px phone`, async ({ page }) => {
    await page.setViewportSize({ width, height: 844 });
    await mockStaffSettings(page);

    await page.goto('/settings/users');
    await expect(page.getByText(longEmail).filter({ visible: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Activity', exact: true }).filter({ visible: true })).toBeVisible();
    await expectFitsViewport(page, width);

    await page.goto('/settings/organizations');
    await expect(page.getByRole('button', { name: 'Rename Alexandra Records and Payroll' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Deactivate Alexandra Records and Payroll' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Delete Alexandra Records and Payroll' })).toBeVisible();
    await expectFitsViewport(page, width);

    await page.goto('/settings/audit-logs');
    await expect(page.getByText('Updated payroll settings', { exact: false }).filter({ visible: true }).first()).toBeVisible();
    await expectFitsViewport(page, width);

    await page.goto('/settings/client-documents');
    await expect(page.getByText(longFilename).filter({ visible: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Preview' }).filter({ visible: true })).toBeVisible();
    await expectFitsViewport(page, width);

    await page.goto('/pay-schedule-settings');
    await expect(page.getByRole('button', { name: 'Confirm & save schedule' })).toBeVisible();
    await expectFitsViewport(page, width);
  });
}
