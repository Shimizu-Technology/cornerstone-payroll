import { readFileSync } from 'node:fs';
import { expect, test, type Page, type Route } from '@playwright/test';

// A plain round badge. Set E2E_LOGO_PATH to a PNG to take screenshots with a
// real client logo.
const SAMPLE_LOGO = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><circle cx="32" cy="32" r="30" fill="#FADF06"/><circle cx="32" cy="32" r="22" fill="#1898CF"/><text x="32" y="38" font-size="16" text-anchor="middle" font-family="sans-serif" fill="#040707">EG</text></svg>`;

function json(route: Route, body: unknown, status = 200): Promise<void> {
  return route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
}

type Settings = Record<string, unknown> & { branding: Record<string, unknown>; help_contacts: unknown[] };

async function mockClientWithSettings(page: Page): Promise<{ saved: () => Settings }> {
  await page.route('**/api/v1/auth/me', (route) => json(route, { user: {
    id: 7, email: 'client@example.test', name: 'Client Reviewer', role: 'client',
    organization_id: 1, organization_name: 'Cornerstone', company_id: 6,
    company_name: "MoSa's Joint", home_company_id: 6, assigned_company_ids: [6],
  } }));
  await page.route('**/api/v1/companies', (route) => json(route, {
    companies: [{ id: 6, name: "MoSa's Joint", active: true, payroll_environment: 'live' }],
    can_manage_clients: false, can_view_client_management: false, can_switch_company: false, current_company_id: 6,
  }));

  let settings: Settings = {
    company_id: 6,
    company_name: "MoSa's Joint",
    branding: {
      display_name: null, app_name: null, primary_color: null, accent_color: null, show_main_phone: true,
      logo: { content_type: 'image/svg+xml', byte_size: 400, digest: '0123456789abcdef' }, external_logo_url: null,
    },
    main_phone: '6715550100',
    subdomain: { slug: 'mosas', host: 'mosas.shimizu-technology.com' },
    help_contacts: [],
    max_help_contacts: 5,
    logo_limits: { max_bytes: 1048576, content_types: ['image/png', 'image/webp', 'image/svg+xml'] },
  };
  const logoPath = process.env.E2E_LOGO_PATH;
  const logo = logoPath
    ? { contentType: 'image/png', body: readFileSync(logoPath) }
    : { contentType: 'image/svg+xml', body: SAMPLE_LOGO };

  await page.route('**/api/v1/client/employee_app_settings**', async (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    if (path.endsWith('/logo') && request.method() === 'GET') return route.fulfill(logo);
    if (path.endsWith('/branding') && request.method() === 'PATCH') {
      const { branding } = request.postDataJSON() as { branding: Record<string, unknown> };
      const cleaned = Object.fromEntries(Object.entries(branding).map(([key, value]) => [key, value === '' ? null : value]));
      settings = { ...settings, branding: { ...settings.branding, ...cleaned } };
      return json(route, { data: settings });
    }
    if (path.endsWith('/help_contacts') && request.method() === 'PUT') {
      settings = { ...settings, help_contacts: (request.postDataJSON() as { help_contacts: unknown[] }).help_contacts };
      return json(route, { data: settings });
    }
    return json(route, { data: settings });
  });
  return { saved: () => settings };
}

async function noSideScroll(page: Page): Promise<void> {
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
}

for (const width of [390, 1280]) {
  test(`client sets brand and Help contacts at ${width}px`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width, height: width === 390 ? 844 : 900 });
    const api = await mockClientWithSettings(page);

    await page.goto('/companies/6/employee-app');
    await expect(page.getByRole('heading', { name: 'Employee app' })).toBeVisible();
    await expect(page.getByText('Help contacts not set up')).toBeVisible();
    await noSideScroll(page);
    await page.screenshot({ path: testInfo.outputPath(`employee-app-settings-${width}-empty.png`) });

    await page.getByLabel('Name employees see').fill("MoSa's");
    await page.getByLabel('Home Screen name').fill("MoSa's Pay");
    await page.getByLabel('Brand color', { exact: true }).fill('#1898CF');
    await page.getByLabel('Accent color (optional)', { exact: true }).fill('#FADF06');
    await expect(page.getByText('Buttons will use this darker shade so text is readable.')).toBeVisible();
    await expect(page.getByText('Highlights use this color with dark text.')).toBeVisible();
    await page.getByRole('button', { name: 'Save name and colors' }).click();
    await expect(page.getByText(/Employees see the new look/)).toBeVisible();
    expect(api.saved().branding).toMatchObject({ display_name: "MoSa's", app_name: "MoSa's Pay", primary_color: '#1898CF', accent_color: '#FADF06' });

    await page.getByRole('button', { name: 'Set up Help contacts' }).click();
    const list = page.getByRole('list', { name: /Help contacts/ });
    await list.getByLabel('Name', { exact: true }).fill('Avery Example');
    await list.getByLabel('Role (optional)').fill('General manager');
    await list.getByLabel('Phone', { exact: true }).fill('671-555-0111');
    await list.getByRole('checkbox', { name: /Employees can text this number/ }).check();
    await page.getByRole('button', { name: 'Add another contact' }).click();
    await list.getByLabel('Name', { exact: true }).nth(1).fill('Riley Example');
    await list.getByLabel('Role (optional)').nth(1).fill('Owner');
    await list.getByLabel('Email', { exact: true }).nth(1).fill('riley@example.test');
    await page.getByRole('button', { name: 'Save Help contacts' }).click();
    await expect(page.getByText('Help contacts saved.')).toBeVisible();
    await expect(page.getByText('Help contacts not set up')).toHaveCount(0);
    expect(api.saved().help_contacts).toHaveLength(2);

    // Every tap target in the editor is at least 40px tall, 44px on touch.
    const buttons = page.getByRole('button', { name: /Move|Remove|Save Help contacts|Add another contact/ });
    for (const box of await buttons.evaluateAll((nodes) => nodes.map((node) => node.getBoundingClientRect().height))) {
      expect(box).toBeGreaterThanOrEqual(36);
    }

    await noSideScroll(page);
    const dismiss = page.getByRole('button', { name: /^Dismiss notification/ });
    while (await dismiss.count()) await dismiss.first().click({ force: true });
    await expect(page.getByRole('button', { name: /^Dismiss notification/ })).toHaveCount(0);
    // The app scrolls inside its own container, so a tall viewport captures the whole page.
    await page.setViewportSize({ width, height: width === 390 ? 3000 : 1700 });
    await page.evaluate(() => document.querySelectorAll('*').forEach((node) => { if (node.scrollTop) node.scrollTop = 0; }));
    await page.screenshot({ path: testInfo.outputPath(`employee-app-settings-${width}-saved.png`) });
    await page.setViewportSize({ width, height: width === 390 ? 844 : 900 });
    for (const [screen, device] of [['Sign-in', 'Phone'], ['Home', 'Phone'], ['Help', 'Phone'], ['Home', 'Desktop'], ['Help', 'Desktop']] as const) {
      await page.getByRole('radio', { name: screen, exact: true }).click();
      await page.getByRole('radio', { name: device }).click();
      await expect(page.getByRole('img', { name: new RegExp(`${screen} screen on a ${device.toLowerCase()}`) })).toBeVisible();
      await noSideScroll(page);
      await page.getByRole('img', { name: /Preview of the/ }).screenshot({
        path: testInfo.outputPath(`employee-app-preview-${width}-${screen.toLowerCase()}-${device.toLowerCase()}.png`),
      });
    }
  });
}
