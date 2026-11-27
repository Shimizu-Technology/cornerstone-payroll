import { expect, test, type Page } from '@playwright/test';

// The employee app status report on a phone (cards) and a desktop (table),
// for a client viewer. Fictional people only. Set E2E_SCREENSHOT_DIR to save shots.
const screenshotDir = process.env.E2E_SCREENSHOT_DIR;

function row(id: number, name: string, extra: Record<string, unknown> = {}) {
  return {
    id, name, department: null, role: 'Server',
    account: { status: 'not_invited', label: 'Not invited', signed_up: false, invite_sent_at: null, signed_up_at: null, last_opened_at: null },
    terms: { version: null, accepted_at: null, current: false },
    pay_statements: { answer: 'not_answered', answered_at: null },
    w2gu: { answer: 'not_answered', answered_at: null },
    ...extra,
  };
}

const report = {
  enabled: true, delivery_consent_enabled: true, current_terms_version: 'terms-2026-11', opens_recorded_since: '2026-11-25',
  summary: {
    total: 3, signed_up: 1, opened: 1, not_signed_up: 2, signed_up_no_opens: 0,
    invite_expired: 1, terms_not_accepted: 2, no_paperless_answer: 2, kept_paper: 1,
  },
  departments: [{ id: 3, name: 'Kitchen' }], roles: ['Cook', 'Server'],
  employees: [
    row(2, 'Ben Example', { account: { status: 'invite_expired', label: 'Invite expired', signed_up: false, invite_sent_at: '2026-11-01T00:00:00Z', invite_expires_at: '2026-11-20T00:00:00Z', invite_expired: true, signed_up_at: null, last_opened_at: null } }),
    row(3, 'Cy Placeholder-With-A-Very-Long-Family-Name'),
    row(1, 'Ana Sample', {
      department: { id: 3, name: 'Kitchen' }, role: 'Cook',
      account: { status: 'active', label: 'Signed up', signed_up: true, invite_sent_at: '2026-11-01T00:00:00Z', signed_up_at: '2026-11-05T00:00:00Z', last_opened_at: '2026-11-26T03:00:00Z' },
      terms: { version: 'terms-2026-11', accepted_at: '2026-11-05T00:00:00Z', current: true },
      pay_statements: { answer: 'paperless', answered_at: '2026-11-06T00:00:00Z' },
      w2gu: { answer: 'keep_paper', answered_at: '2026-11-07T00:00:00Z' },
    }),
  ],
};

async function mockApi(page: Page): Promise<void> {
  await page.route('**/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path.endsWith('/auth/me')) return route.fulfill({ json: { user: {
      id: 9, role: 'client', client_access_level: 'viewer', name: 'Sample Viewer', company_id: 1, organization_id: 1, assigned_company_ids: [1], capabilities: [],
    } } });
    if (path.endsWith('/companies')) return route.fulfill({ json: { companies: [{ id: 1, name: 'Example Noodle House', active: true, client_view_only: true, workspace_can_write: false }], can_switch_company: false, current_company_id: 1 } });
    if (path.endsWith('/client/employee_app_status/1')) return route.fulfill({ json: { data: report } });
    return route.fulfill({ json: {} });
  });
}

async function expectNoSidewaysScroll(page: Page): Promise<void> {
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
}

test('a client viewer reads the report as cards on a phone', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await mockApi(page);
  await page.goto('/companies/1/employee-app/status');

  await expect(page.getByRole('region', { name: 'Summary' })).toContainText('1 of 3 signed up · 1 has opened the app');
  await expect(page.getByRole('list', { name: 'Employees' }).getByRole('listitem')).toHaveCount(3);
  await expect(page.getByRole('table')).toBeHidden();
  await expect(page.getByLabel('Sort by')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Kept paper (needs paper copies) 1' })).toBeVisible();
  await expectNoSidewaysScroll(page);
  if (screenshotDir) await page.screenshot({ path: `${screenshotDir}/390-app-status.png`, fullPage: true });
});

test('the report is a sortable table on a desktop', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await mockApi(page);
  await page.goto('/companies/1/employee-app/status');

  const table = page.getByRole('table');
  await expect(table.getByRole('row', { name: /Ana Sample/ })).toContainText('Paperless');
  await expect(page.getByRole('list', { name: 'Employees' })).toBeHidden();
  await expectNoSidewaysScroll(page);
  if (screenshotDir) await page.screenshot({ path: `${screenshotDir}/1280-app-status.png`, fullPage: true });
});
