import { expect, test } from '@playwright/test';

for (const width of [390, 1440]) {
  for (const scenario of ['approved', 'foreign', 'malformed'] as const) {
    test(`protects custom account authorization (${scenario}, ${width}px)`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 });
      const source = { id: 4, company_id: 7, name: 'Neutral time', source_type: 'custom', active: true,
        supported_operations: ['account_linking'], authorization_origin: scenario === 'malformed' ? 'invalid origin' : 'https://neutral.example.test' };
      const authorizationUrl = scenario === 'foreign' ? 'https://foreign.example.test/consent?token=synthetic'
        : 'https://neutral.example.test/consent?token=synthetic';
      const externalRequests: string[] = [];
      await page.route('https://*.example.test/**', async route => {
        externalRequests.push(route.request().url());
        await route.fulfill({ contentType: 'text/html', body: '<h1>Producer consent</h1>' });
      });
      await page.route('**/api/v1/**', async route => {
        const path = new URL(route.request().url()).pathname;
        let body: unknown = { data: [] };
        if (path.endsWith('/auth/me')) body = { user: { id: 1, company_id: 7, organization_id: 1,
          name: 'Assigned accountant', email: 'operator@example.test', role: 'accountant', assigned_company_ids: [7],
          capabilities: ['manage_own_aire_account_link'] } };
        else if (path.endsWith('/companies')) body = { companies: [{ id: 7, name: 'Review Client', active: true }], current_company_id: 7 };
        else if (path.endsWith('/time_tracking_sources')) body = { time_tracking_sources: [source] };
        else if (path.endsWith('/aire_account_link')) body = route.request().method() === 'POST'
          ? { authorization_url: authorizationUrl } : { account_link: { connected: false } };
        await route.fulfill({ contentType: 'application/json', body: JSON.stringify(body) });
      });
      await page.goto('/app/time-account-connection?source_id=4');
      await page.getByRole('button', { name: 'Connect my time tracking account', exact: true }).click();
      if (scenario === 'approved') {
        await expect(page.getByRole('heading', { name: 'Producer consent' })).toBeVisible();
        expect(externalRequests).toEqual([authorizationUrl]);
      } else {
        await expect(page.getByRole('alert')).toContainText('Time tracking returned an invalid connection link');
        expect(externalRequests).toEqual([]);
        expect(await page.evaluate(() => sessionStorage.getItem('aire-own-link-return:4'))).toBeNull();
        expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
      }
    });
  }
}
