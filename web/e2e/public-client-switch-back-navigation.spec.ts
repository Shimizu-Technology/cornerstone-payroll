import { expect, test, type Page } from '@playwright/test';

async function fixture(page: Page) {
  const seen = { historyCompanyId: '' };
  await page.route('**/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path.endsWith('/payroll_history')) seen.historyCompanyId = route.request().headers()['x-company-id'] ?? '';
    let body: unknown = { data: [], meta: { current_page: 1, total_pages: 0, total_count: 0, per_page: 50, statuses: {}, sources: {}, years: [] } };
    if (path.endsWith('/tax_year_readiness')) body = { verified_years: [2026], warnings: [] };
    else if (path.endsWith('/auth/me')) body = { user: { id: 1, role: 'admin', capabilities: ['payroll_operations'], email: 'review@example.test', name: 'Reviewer', organization_id: 1, company_id: 1, assigned_company_ids: [1, 2] } };
    else if (path.endsWith('/companies')) {
      body = {
        companies: [
          { id: 1, organization_id: 1, name: 'First client', active: true, payroll_environment: 'live', pay_frequency: 'biweekly' },
          { id: 2, organization_id: 1, name: 'Second client', active: true, payroll_environment: 'live', pay_frequency: 'biweekly' },
        ],
        can_manage_clients: true, can_switch_company: true, current_company_id: 1,
      };
    }
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
  });
  return seen;
}

async function switchToSecondClient(page: Page, width: number) {
  if (width < 1024) await page.getByRole('button', { name: 'Open navigation' }).click();
  await page.getByRole('button', { name: /First client/ }).first().click();
  await page.getByRole('button', { name: 'Second client' }).click();
}

for (const width of [1280, 390]) {
  test(`Back and Forward after switching clients open the client in the URL at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    const seen = await fixture(page);
    const expectOpen = async (companyId: number) => {
      await expect(page).toHaveURL(new RegExp(`/companies/${companyId}/pay-runs`));
      await expect(page.getByRole('heading', { name: 'Pay Periods' }).first()).toBeVisible();
      await expect(page.getByText('Opening client workspace')).toHaveCount(0);
      // The page loads the client in the URL, and the sidebar agrees with it.
      await expect.poll(() => seen.historyCompanyId).toBe(String(companyId));
      if (width >= 1024) await expect(page.getByRole('button', { name: new RegExp(companyId === 1 ? 'First client' : 'Second client') }).first()).toBeVisible();
    };
    await page.goto('/companies/1/pay-runs');
    await expectOpen(1);
    await switchToSecondClient(page, width);
    await expectOpen(2);
    await page.goBack();
    await expectOpen(1);
    await page.goForward();
    await expectOpen(2);
    await page.goBack();
    await expectOpen(1);
  });

  test(`Back straight after switching clients, before the redirect finishes, still recovers at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    const seen = await fixture(page);
    await page.goto('/companies/1/pay-runs');
    await expect(page.getByRole('heading', { name: 'Pay Periods' }).first()).toBeVisible();
    await switchToSecondClient(page, width);
    await page.goBack();
    await expect(page).toHaveURL(/\/companies\/1\/pay-runs/);
    await expect(page.getByRole('heading', { name: 'Pay Periods' }).first()).toBeVisible();
    await expect(page.getByText('Opening client workspace')).toHaveCount(0);
    await expect.poll(() => seen.historyCompanyId).toBe('1');
  });
}
