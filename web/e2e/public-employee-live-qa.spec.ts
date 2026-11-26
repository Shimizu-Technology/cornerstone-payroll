import { expect, test } from '@playwright/test';
import { branding, detailFor, employeeBaseUrl, json, mockEmployeeApi, signIn, statements2026, tenantQuery } from './employee-fixtures';

test.skip(Boolean(process.env.E2E_BASE_URL), 'Needs both local dev servers');
test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });

for (const fixture of [
  { name: 'without a logo', logoSize: null, iconSize: 180 },
  { name: 'with a square logo', logoSize: { width: 256, height: 256 }, iconSize: 256 },
  { name: 'with a wordmark', logoSize: { width: 256, height: 96 }, iconSize: 180 },
]) {
  test(`the browser reads the tenant manifest and square Home Screen icon ${fixture.name}`, async ({ page }) => {
    const logoUrl = fixture.logoSize ? 'https://assets.example.test/employee-icon.png' : null;
    await mockEmployeeApi(page, {
      branding: { ...branding, app_name: 'Coral Pay', logo_url: logoUrl },
    });
    if (logoUrl && fixture.logoSize) {
      const png = await page.evaluate(({ width, height }) => {
        const canvas = document.createElement('canvas');
        canvas.width = width;
        canvas.height = height;
        return canvas.toDataURL('image/png').split(',')[1];
      }, fixture.logoSize);
      await page.route(logoUrl, route => route.fulfill({ contentType: 'image/png', body: Buffer.from(png, 'base64') }));
    }
    await page.goto(`${employeeBaseUrl}/sign-in?${tenantQuery}`);

    const manifestLink = page.locator('link[rel="manifest"]');
    await expect(manifestLink).toHaveAttribute('href', /^blob:/);
    await expect(page.locator('meta[name="theme-color"]')).toHaveAttribute('content', branding.primary_color);
    await expect(page.locator('meta[name="apple-mobile-web-app-capable"]')).toHaveAttribute('content', 'yes');
    await expect(page.locator('meta[name="apple-mobile-web-app-title"]')).toHaveAttribute('content', 'Coral Pay');
    const generatedIcon = /^data:image\/png;base64,/;
    const favicon = page.locator('link[rel="icon"]');
    await expect(favicon).toHaveAttribute('href', logoUrl ?? generatedIcon);
    if (logoUrl) await favicon.evaluate(async (link: HTMLLinkElement) => {
      const img = new Image();
      img.src = link.href;
      await img.decode();
      await new Promise(requestAnimationFrame);
    });
    const touchIcon = page.locator('link[rel="apple-touch-icon"]');
    await expect(touchIcon).toHaveAttribute('href', fixture.logoSize?.width === fixture.logoSize?.height && logoUrl ? logoUrl : generatedIcon);
    await expect(touchIcon).toHaveAttribute('sizes', `${fixture.iconSize}x${fixture.iconSize}`);
    const iconSize = await touchIcon.evaluate(async (link: HTMLLinkElement) => {
      const img = new Image();
      img.src = link.href;
      await img.decode();
      return [img.naturalWidth, img.naturalHeight];
    });
    expect(iconSize).toEqual([fixture.iconSize, fixture.iconSize]);

    const cdp = await page.context().newCDPSession(page);
    const { data, errors, parsed } = await cdp.send('Page.getAppManifest');
    expect(errors).toEqual([]);
    expect(JSON.parse(data)).toMatchObject({
      name: 'Coral Kitchen', short_name: 'Coral Pay', display: 'standalone',
      start_url: `${employeeBaseUrl}/`, theme_color: branding.primary_color,
      icons: [
        { src: expect.stringMatching(/^data:image\/png;base64,/), sizes: '192x192', type: 'image/png' },
        { src: expect.stringMatching(/^data:image\/png;base64,/), sizes: '512x512', type: 'image/png' },
      ],
    });
    expect(parsed?.scope).toBe(`${employeeBaseUrl}/`);
  });
}

test('an unavailable stub stays in Pay and returns to the selected year', async ({ page }) => {
  await signIn(page);
  await mockEmployeeApi(page);
  await page.goto(`${employeeBaseUrl}/pay/999999?year=2025&${tenantQuery}`);

  await expect(page.getByRole('status').filter({ hasText: "We couldn't find that pay stub." })).toBeVisible();
  await page.getByRole('link', { name: 'Back to pay stubs' }).click();
  await expect(page).toHaveURL(/\/pay\?year=2025$/);
  await expect(page.getByRole('button', { name: '2025' })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByRole('link', { name: /Dec 19/ })).toBeVisible();
});

test('hides YTD-only earnings on a phone and restores their YTD column on desktop', async ({ page }) => {
  await signIn(page);
  await mockEmployeeApi(page);
  const detail = detailFor(statements2026[0]);
  detail.earnings.push({ label: 'Earlier regular pay', hours: null, rate: null, pay_basis: null, amount: '0.00', ytd: '125.00', kind: 'regular' });
  await page.route('**/api/v1/employee/statements/906', route => json(route, detail));
  await page.goto(`${employeeBaseUrl}/pay/906?${tenantQuery}`);

  // Amounts start masked by default ($•••), then reveal to check exact YTD values.
  await expect(page.getByRole('row', { name: /Regular/ })).toContainText('$•••');
  await page.getByRole('button', { name: 'Show amounts' }).click();

  const earlierPay = page.getByRole('row', { name: /Earlier regular pay/, includeHidden: true });
  await expect(page.getByRole('row', { name: /Regular.*540\.00/ })).toBeVisible();
  await expect(earlierPay).toBeAttached();
  await expect(earlierPay).toBeHidden();
  await page.setViewportSize({ width: 1280, height: 800 });
  await expect(page.getByRole('row', { name: /Earlier regular pay/ })).toContainText('$125.00');
});

test('shows a phone message when every earning is YTD-only', async ({ page }) => {
  await signIn(page);
  await mockEmployeeApi(page);
  const detail = {
    ...detailFor(statements2026[0]),
    earnings: [{ label: 'Earlier regular pay', hours: null, rate: null, amount: '0.00', ytd: '125.00' }],
  };
  await page.route('**/api/v1/employee/statements/906', route => json(route, detail));
  await page.goto(`${employeeBaseUrl}/pay/906?${tenantQuery}`);

  const notice = page.getByText('No earnings this pay period.');
  const earnings = page.getByRole('table', { name: /Pay before taxes/ });
  await expect(notice).toBeVisible();
  await expect(earnings).toBeHidden();
  await page.setViewportSize({ width: 1280, height: 800 });
  await expect(earnings.getByRole('row', { name: /Earlier regular pay/ })).toContainText('$•••');
  await page.getByRole('button', { name: 'Show amounts' }).click();
  await expect(earnings.getByRole('row', { name: /Earlier regular pay/ })).toContainText('$125.00');
  await expect(notice).toBeHidden();
});

test('switching the account on a claim keeps the invite through a failed sign-out and retry', async ({ page }) => {
  await signIn(page);
  const log = await mockEmployeeApi(page);
  const token = 'fictional-employee-invite-123';
  await page.goto(`${employeeBaseUrl}/claim?${tenantQuery}&previewSignOutFails=1#token=${token}`);

  await expect(page.getByText('preview.employee@example.test')).toBeVisible();
  await page.getByRole('button', { name: 'Sign out and use your invite again' }).click();
  const alert = page.getByRole('alert').filter({ hasText: "Couldn't sign you out" });
  await expect(alert).toBeVisible();
  await alert.getByRole('button', { name: 'Try again' }).click();
  await expect(page).toHaveURL(/\/sign-in$/);
  await page.getByRole('button', { name: 'Continue as preview employee' }).click();
  await expect(page).toHaveURL(/\/claim$/);
  await expect(page.getByText('Your invite link is ready.')).toBeVisible();
  expect(await page.evaluate(() => sessionStorage.getItem('employee-invite-token'))).toBe(token);
  expect(log.requests.some(request => request.path === '/employee/links/claim')).toBe(false);
});

for (const employeeAppUrl of [null, 'https://coral.example.test']) {
  test(`an employee on the staff host sees ${employeeAppUrl ? 'their app link' : 'directions for their employer’s app'} before any admin requests`, async ({ page }) => {
    const adminRequests: string[] = [];
    await page.route('**/api/v1/auth/me', route => json(route, { user: {
      id: 10, role: 'portal_employee', name: 'Example Employee', email: 'employee@example.test', employee_app_url: employeeAppUrl,
    } }));
    await page.route('**/api/v1/admin/**', route => {
      adminRequests.push(route.request().url());
      return json(route, { error: 'Staff access required' }, 403);
    });
    await page.goto('/app');

    await expect(page.getByRole('heading', { name: 'This sign-in is for your employee app.' })).toBeVisible();
    if (employeeAppUrl) {
      await expect(page.getByRole('link', { name: 'Go to your employee app' })).toHaveAttribute('href', employeeAppUrl);
    } else {
      await expect(page.getByText('Open the employee app link from your employer to see your pay.')).toBeVisible();
      await expect(page.getByRole('link', { name: 'Go to your employee app' })).toHaveCount(0);
    }
    await expect(page.getByRole('button', { name: 'Sign out' })).toBeVisible();
    await expect(page.getByText('Create the next pay period')).toHaveCount(0);
    expect(adminRequests).toEqual([]);
    await page.getByRole('button', { name: 'Sign out' }).click();
    await expect(page).toHaveURL(/\/login$/);
  });
}
