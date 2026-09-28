import { expect, test, type Page } from '@playwright/test';

async function mockTools(page: Page) {
  await page.route('**/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    const method = route.request().method();
    let body: unknown = { data: [] };
    if (path.endsWith('/auth/me')) body = { user: { id: 1, name: 'Tools Admin', email: 'admin@example.test', role: 'admin', organization_id: 1, company_id: 1 } };
    else if (path.endsWith('/companies')) body = { companies: [{ id: 1, name: 'Review Client', active: true, payroll_environment: 'live' }], current_company_id: 1, can_switch_company: false };
    else if (path.endsWith('/admin/general_transmittals')) body = { general_transmittals: [] };
    else if (path.endsWith('/admin/non_employee_checks')) body = { non_employee_checks: [] };
    else if (path.endsWith('/admin/pay_periods')) body = { pay_periods: [] };
    else if (path.endsWith('/admin/invoices')) body = { invoices: [] };
    else if (path.endsWith('/admin/finance_books')) body = { finance_books: [{ id: 1, organization_id: 1, company_id: null, name: 'Review firm', legal_name: 'Review firm', kind: 'organization', is_default: true, active: true }], effective_finance_book_id: 1 };
    else if (path.endsWith('/admin/invoice_recipients')) body = { invoice_recipients: [] };
    else if (path.endsWith('/admin/invoice_billing_profiles')) body = { invoice_billing_profiles: [] };
    else if (path.endsWith('/admin/invoice_chat_sessions') && method === 'GET') body = { invoice_chat_sessions: [] };
    else if (path.endsWith('/admin/invoice_chat_sessions') && method === 'POST') body = { invoice_chat_session: { id: 7, organization_id: 1, company_id: 1, title: 'Review chat', status: 'active', current_preview: {}, current_preview_version: 0, archived: false, message_count: 0, messages: [], created_at: '2026-09-27T00:00:00Z', updated_at: '2026-09-27T00:00:00Z' } };
    else if (path.endsWith('/admin/invoice_chat_sessions/7/message')) return route.fulfill({ status: 503, contentType: 'application/json', body: JSON.stringify({ error: 'Chat request failed in review' }) });
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
}

function before(headings: string[], first: string, second: string) {
  const labels = headings.map((heading) => heading.trim());
  expect(labels.indexOf(first)).toBeGreaterThanOrEqual(0);
  expect(labels.indexOf(second)).toBeGreaterThanOrEqual(0);
  expect(labels.indexOf(first)).toBeLessThan(labels.indexOf(second));
}

test('mobile tools follow visual focus order and show chat errors beside the chat', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await mockTools(page);

  await page.goto('/tools/transmittals');
  await expect(page.getByRole('heading', { name: 'New standalone transmittal' })).toBeVisible();
  before(await page.locator('h2').allTextContents(), 'New standalone transmittal', 'Transmittal history');

  await page.goto('/tools/invoices/assistant');
  await expect(page.getByRole('heading', { name: 'New Invoice' })).toBeVisible();
  before(await page.locator('h2').allTextContents(), 'New Invoice', 'Invoice History');

  await page.getByRole('button', { name: 'AI Assistant' }).click();
  await expect(page.getByRole('heading', { name: 'Invoice Assistant', level: 2 })).toBeVisible();
  const aiHeadings = await page.locator('h2').allTextContents();
  before(aiHeadings, 'Invoice Assistant', 'AI Draft Preview');
  before(aiHeadings, 'AI Draft Preview', 'Assistant Sessions');

  await page.getByPlaceholder('Type the invoice request...').fill('Create a test invoice');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(page.getByRole('alert').filter({ hasText: 'Chat request failed in review' })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
});
