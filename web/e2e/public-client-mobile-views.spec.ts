import { expect, test, type Page, type Route } from '@playwright/test';

function json(route: Route, body: unknown): Promise<void> {
  return route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
}

async function mockClient(page: Page): Promise<void> {
  await page.route('**/api/v1/auth/me', (route) => json(route, { user: {
    id: 7, email: 'client@example.test', name: 'Client Reviewer', role: 'client',
    organization_id: 1, organization_name: 'Cornerstone', company_id: 1,
    company_name: 'Example Company', home_company_id: 1, assigned_company_ids: [1],
  } }));
  await page.route('**/api/v1/companies', (route) => json(route, {
    companies: [{ id: 1, name: 'Example Company', active: true, payroll_environment: 'live' }],
    can_manage_clients: false, can_view_client_management: false, can_switch_company: false, current_company_id: 1,
  }));
}

test('client change request is selectable and readable at phone width', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 320, height: 700 });
  await mockClient(page);
  const request = {
    id: 31, employee_name: 'Avery Example', status: 'pending', request_kind: 'update',
    requested_by_name: 'Client Reviewer', created_at: '2026-09-10T01:00:00Z',
    request_notes: 'Please update the address.', review_notes: null,
    original_values: { address: 'Old address' }, proposed_changes: { address: 'New address' },
  };
  await page.route('**/api/v1/client/employee_change_requests**', (route) => json(route,
    new URL(route.request().url()).pathname.endsWith('/31') ? { data: request } : { data: [request] }));

  await page.goto('/change-requests');
  await expect(page.getByRole('heading', { name: 'Change Requests' })).toBeVisible();
  await page.getByRole('button', { name: 'View request' }).click();
  await expect(page.getByText('Request #31')).toBeVisible();
  await expect(page.getByText('Please update the address.')).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.screenshot({ path: testInfo.outputPath('client-change-request-320.png'), fullPage: true });
  await page.setViewportSize({ width: 768, height: 844 });
  await expect(page.getByRole('button', { name: 'View request' })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test('client document preview and conversation remain usable on a narrow phone', async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 320, height: 700 });
  await mockClient(page);
  const document = {
    id: 4, title: 'A long payroll source document title for September', category: 'payroll_source',
    file_name: 'september-payroll-notes.txt', content_type: 'text/plain', file_size: 33,
    uploaded_by_id: 7, uploaded_by_name: 'Client Reviewer', visible_to_client: true,
    shared_by_staff: false, created_at: '2026-09-10T01:00:00Z', preview_status: 'not_required', preview_available: true,
  };
  const thread = {
    id: 8, company_id: 1, subject: 'September payroll question', status: 'open',
    created_by_id: 7, created_by_name: 'Client Reviewer', unread: false,
    created_at: '2026-09-10T01:00:00Z', updated_at: '2026-09-10T01:00:00Z',
    messages: [{ id: 9, thread_id: 8, body: 'Please confirm the source file.', author_id: 7,
      author_name: 'Client Reviewer', created_at: '2026-09-10T01:00:00Z' }],
  };
  await page.route('**/api/v1/client/documents**', (route) => {
    if (new URL(route.request().url()).pathname.endsWith('/preview')) {
      return route.fulfill({ contentType: 'text/plain', body: 'Payroll notes for September.' });
    }
    return json(route, { data: [document] });
  });
  await page.route('**/api/v1/client/employees**', (route) => json(route, { data: [], meta: {} }));
  await page.route('**/api/v1/client/portal_threads**', (route) => json(route,
    new URL(route.request().url()).pathname.endsWith('/8') ? { data: thread } : { data: [thread] }));

  await page.goto('/documents');
  await page.getByRole('button', { name: 'Preview' }).click();
  const preview = page.getByRole('dialog');
  await expect(preview.getByText('Payroll notes for September.')).toBeVisible();
  expect(await preview.evaluate((node) => node.scrollWidth <= node.clientWidth)).toBe(true);
  await page.screenshot({ path: testInfo.outputPath('client-preview-320.png') });
  await preview.getByRole('button', { name: 'Close preview' }).click();

  await page.getByRole('button', { name: /September payroll question/ }).click();
  await expect(page.getByText('Please confirm the source file.')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Back to conversations' })).toBeVisible();
  await page.screenshot({ path: testInfo.outputPath('client-conversation-320.png') });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});
