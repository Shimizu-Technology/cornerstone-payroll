import { expect, test, type Page, type Route } from '@playwright/test';

const employeeBase = `http://127.0.0.1:${process.env.E2E_EMPLOYEE_WEB_PORT || '4175'}`;
const token = 'v'.repeat(43);
const handoff = `#support-view=${token}`;
const company = 'Juniper Fixture Company';
const client = 'Marigold Example';
const employee = 'Indigo Example';

test.skip(Boolean(process.env.E2E_BASE_URL), 'Needs the local staff and employee builds');

function json(route: Route, body: unknown, status = 200) {
  return route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
}

async function checkBanner(page: Page, name: string) {
  const banner = page.getByRole('region', { name: 'View only' });
  await expect(banner).toContainText(`Viewing as ${name}, view only`);
  const end = banner.getByRole('button', { name: 'End', exact: true });
  await expect(end).toBeInViewport();
  expect((await end.boundingBox())?.height).toBeGreaterThanOrEqual(page.viewportSize()!.width < 600 ? 44 : 40);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  return end;
}

for (const width of [390, 1280]) {
  test.describe(`support views at ${width}px`, () => {
    test.use({ viewport: { width, height: 844 } });

    test('client sees their portal and support history, then End returns to staff', async ({ page }) => {
      let ended = false;
      let readLog = false;
      let endAttempts = 0;
      const expires_at = new Date(Date.now() + 25 * 60_000).toISOString();
      await page.addInitScript(() => localStorage.setItem('activeCompanyId', '75'));
      await page.route('**/api/v1/**', (route) => {
        const request = route.request();
        const path = new URL(request.url()).pathname.replace('/api/v1', '');
        const grant = request.headers()['x-view-as-grant'];
        if (path === '/auth/view_as') {
          expect(grant).toBe(token);
          if (request.method() === 'DELETE') {
            endAttempts += 1;
            if (endAttempts === 1) return json(route, {}, 503);
            ended = true;
            return route.fulfill({ status: 204 });
          }
          return json(route, { name: client, company_id: 9, expires_at, employee_url: null });
        }
        if (path === '/auth/me') {
          expect(grant).toBe(ended ? undefined : token);
          return json(route, { user: {
            id: ended ? 1 : 2, name: ended ? 'Support Example' : client,
            role: ended ? 'super_admin' : 'client', company_id: ended ? 75 : 9, organization_id: 1,
            home_company_id: ended ? 75 : 9, assigned_company_ids: [ended ? 75 : 9],
          } });
        }
        if (path === '/companies') {
          expect(grant).toBe(ended ? undefined : token);
          return json(route, {
            companies: [{ id: ended ? 75 : 9, name: company, organization_id: 1, active: true, workspace_can_write: ended }],
            can_manage_clients: ended, can_switch_company: false, current_company_id: ended ? 75 : 9,
          });
        }
        if (path === '/client/support_access_logs') {
          expect(grant).toBe(token);
          expect(request.headers()['x-company-id']).toBe('9');
          readLog = true;
          return json(route, { events: [{ id: '1', description: `Support Example viewed as ${client}`, viewed_at: '2026-11-25T10:00:00Z' }] });
        }
        if (path === '/client/pay_periods') {
          expect(grant).toBe(token);
          expect(request.headers()['x-company-id']).toBe('9');
          return json(route, {
            pay_periods: [],
            meta: { current_page: 1, per_page: 100, total_count: 0, total_pages: 0, statuses: {}, sources: {}, years: [] },
          });
        }
        if (path === '/client/reports/dashboard') return json(route, { stats: {} });
        if (path === '/client/documents') return json(route, { data: [], meta: { total_count: 0 } });
        return json(route, {});
      });

      await page.goto(`/app${handoff}`);
      await expect(page.getByRole('heading', { name: 'Dashboard', exact: true, level: 1 })).toBeVisible();
      await expect(page.getByRole('heading', { name: 'Needs your attention', exact: true, level: 2 })).toBeVisible();
      await expect(page.getByText('No payroll needs your approval right now.')).toBeVisible();
      await expect(page).toHaveURL(/\/app$/);
      await expect(page.getByRole('button', { name: 'Add Employee' })).toHaveCount(0);
      await checkBanner(page, client);
      if (width < 1024) await page.getByRole('button', { name: 'Open navigation' }).click();
      await page.getByRole('link', { name: 'Support access', exact: true }).click();
      await expect(page.getByText(`Support Example viewed as ${client}`)).toBeVisible();
      expect(readLog).toBe(true);
      const end = await checkBanner(page, client);
      await end.click();
      await expect(page.getByRole('alert').filter({ hasText: 'Could not end this support view.' })).toBeVisible();
      await end.click();
      await expect(page).toHaveURL(/\/app$/);
      await expect(page.getByRole('region', { name: 'View only' })).toHaveCount(0);
      await expect(page.getByText(`Support Example viewed as ${client}`)).toHaveCount(0);
      expect(ended).toBe(true);
      expect(await page.evaluate(() => localStorage.getItem('activeCompanyId'))).toBe('75');
    });

    test('staff sign-in opens the former worker view and End clears the grant', async ({ page }) => {
      let ended = false;
      let inspected = false;
      let normalLinksCalls = 0;
      const expires_at = new Date(Date.now() + 25 * 60_000).toISOString();
      await page.route('**/api/v1/**', (route) => {
        const request = route.request();
        const path = new URL(request.url()).pathname.replace('/api/v1', '');
        if (path === '/public/tenant_branding') return json(route, { name: company });
        if (path === '/employee/links') {
          normalLinksCalls += 1;
          expect(request.headers()['x-view-as-grant']).toBeUndefined();
          return json(route, { links: [] });
        }
        expect(request.headers()['x-view-as-grant']).toBe(token);
        expect(request.headers().authorization).toBe('Bearer dev-preview-token');
        expect(request.headers()['x-employee-link-id']).toBeUndefined();
        if (path === '/auth/view_as') {
          if (request.method() === 'DELETE') {
            ended = true;
            return route.fulfill({ status: 204 });
          }
          inspected = true;
          return json(route, { name: employee, company_id: 9, expires_at, employee_url: employeeBase,
            link: { id: '21', company_name: company, status: 'former', former_access_until: null } });
        }
        if (path === '/employee/context') return json(route, { first_name: 'Indigo', status: 'former', features: { stubs: true } });
        if (path === '/employee/statements') return json(route, { statements: [], years: [], next_page: null });
        return json(route, {});
      });

      await page.goto(`${employeeBase}/?tenantHost=juniper-example.shimizu-technology.com${handoff}`);
      await expect(page.getByText('Sign in with your staff account to open the support view.')).toBeVisible();
      expect(inspected).toBe(false);
      await page.getByRole('button', { name: 'Continue as preview employee' }).click();
      const end = await checkBanner(page, employee);
      await expect(page.getByText(/viewing your past pay/i).first()).toBeVisible();
      expect(normalLinksCalls).toBe(0);
      await end.click();
      await expect(page.getByRole('region', { name: 'View only' })).toHaveCount(0);
      await expect.poll(() => normalLinksCalls).toBeGreaterThan(0);
      expect(ended).toBe(true);
    });
  });
}
