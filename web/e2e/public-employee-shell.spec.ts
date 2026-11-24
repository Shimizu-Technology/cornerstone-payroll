import { expect, test, type Page, type Route } from '@playwright/test';

// The employee surface runs on its own dev server (playwright.config.ts) with
// no Clerk key, so the dev-only preview sign-in stands in for Clerk. Branding
// and the employee API are mocked. Set E2E_SCREENSHOT_DIR to save screenshots.
const employeeBaseUrl = `http://127.0.0.1:${process.env.E2E_EMPLOYEE_WEB_PORT || '4175'}`;
const tenant = 'tenantHost=mosas.shimizu-technology.com';
const screenshotDir = process.env.E2E_SCREENSHOT_DIR;

test.skip(Boolean(process.env.E2E_BASE_URL), 'Needs the local employee dev server');
test.use({ baseURL: employeeBaseUrl });

function json(route: Route, body: unknown, status = 200): Promise<void> {
  return route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
}

interface ApiMock {
  branding?: (route: Route) => Promise<void>;
  links?: (route: Route) => Promise<void>;
  context?: (route: Route) => Promise<void>;
}

const activeLinks = (route: Route) => json(route, { links: [{ id: 42, company_name: "MoSa's", subdomain_slug: 'mosas', status: 'active', former_access_until: null }] });
const contextOk = (route: Route) => route.fulfill({ status: 204 });

async function mockApi(page: Page, mock: ApiMock = {}): Promise<{ contextHeaders: Record<string, string>[]; linksHeaders: Record<string, string>[] }> {
  const seen = { contextHeaders: [] as Record<string, string>[], linksHeaders: [] as Record<string, string>[] };
  await page.route('**/api/v1/public/tenant_branding**', mock.branding ?? ((route) => json(route, {
    // MoSa's logo blue and yellow (UX audit). White text on the blue fails 4.5:1, so buttons use a darker shade.
    name: "MoSa's", logo_url: null, primary_color: '#1898CF', accent_color: '#FADF06',
  })));
  await page.route('**/api/v1/employee/links', (route) => {
    seen.linksHeaders.push(route.request().headers());
    return (mock.links ?? activeLinks)(route);
  });
  await page.route('**/api/v1/employee/context', (route) => {
    seen.contextHeaders.push(route.request().headers());
    return (mock.context ?? contextOk)(route);
  });
  return seen;
}

async function signIn(page: Page): Promise<void> {
  await page.addInitScript(() => sessionStorage.setItem('employee-dev-preview-signed-in', 'true'));
}

async function expectNoHorizontalScroll(page: Page): Promise<void> {
  expect(await page.evaluate(() => {
    const main = document.getElementById('emp-main');
    return document.documentElement.scrollWidth <= window.innerWidth && (!main || main.scrollWidth <= main.clientWidth);
  })).toBe(true);
}

async function snap(page: Page, name: string): Promise<void> {
  if (screenshotDir) await page.screenshot({ path: `${screenshotDir}/${name}.png` });
}

for (const viewport of [{ width: 390, height: 844 }, { width: 1280, height: 800 }]) {
  test.describe(`employee shell at ${viewport.width}px`, () => {
    // Phone screenshots at 2x so they stay sharp in a PR.
    test.use({ viewport, ...(screenshotDir && viewport.width < 600 ? { deviceScaleFactor: 2 } : {}) });
    const tag = `${viewport.width}`;

    test('a signed-out visitor sees the client brand, signs in, and lands where they were going', async ({ page }) => {
      await mockApi(page);
      await page.goto(`/?${tenant}`);

      await expect(page.getByRole('heading', { level: 1, name: 'Your pay, on your phone' })).toBeVisible();
      await expect(page).toHaveTitle("Welcome · MoSa's employee app");
      await expect(page.getByText("See your pay stubs and tax forms from MoSa's any time.")).toBeVisible();
      await expect(page.getByText("First time here? Your manager at MoSa's will send you a link")).toBeVisible();
      await expectNoHorizontalScroll(page);
      await snap(page, `${tag}-01-welcome`);

      const signInLink = page.getByRole('link', { name: 'Sign in' });
      expect((await signInLink.boundingBox())!.height).toBeGreaterThanOrEqual(44);
      // The logo blue is decoration only; the button uses the darker shade derived from it.
      expect(await signInLink.evaluate((node) => getComputedStyle(node).backgroundColor)).toBe('rgb(19, 122, 167)');
      await signInLink.click();
      await expect(page).toHaveURL(/\/sign-in$/);
      await expect(page.getByTestId('dev-preview-sign-in')).toBeVisible();
      await expect(page).toHaveTitle("Sign in · MoSa's employee app");
      await expect(page.getByRole('link', { name: 'Back' })).toBeVisible();
      await snap(page, `${tag}-02-sign-in`);

      // A deep link (like the "pay stub ready" email) goes through sign-in and back.
      await page.goto('/pay');
      await expect(page).toHaveURL(/\/sign-in$/);
      await page.getByRole('button', { name: 'Continue as preview employee' }).click();
      await expect(page).toHaveURL(/\/pay$/);
      await expect(page.getByRole('heading', { level: 1, name: 'Pay stubs' })).toBeVisible();
    });

    test('the five tabs open, survive a refresh, and send the link header', async ({ page }) => {
      await signIn(page);
      const seen = await mockApi(page);
      await page.goto(`/?${tenant}`);

      await expect(page.getByRole('heading', { level: 1, name: 'Welcome' })).toBeVisible();
      await expect(page.getByRole('banner').getByText("MoSa's")).toBeVisible();
      expect(seen.linksHeaders[0].authorization).toBe('Bearer dev-preview-token');
      expect(seen.linksHeaders[0]['x-employee-link-id']).toBeUndefined();
      expect(seen.contextHeaders[0]['x-employee-link-id']).toBe('42');
      expect(seen.contextHeaders[0].authorization).toBe('Bearer dev-preview-token');
      await snap(page, `${tag}-03-home`);

      const nav = page.getByRole('navigation', { name: 'Main' });
      const wide = viewport.width >= 600;
      const tabs = [
        { label: 'Home', path: '/', heading: 'Welcome', text: 'Your latest pay will show here' },
        { label: 'Pay', path: '/pay', heading: 'Pay stubs', text: 'Your pay stubs will show here' },
        { label: wide ? 'Tax forms' : 'Taxes', path: '/taxes', heading: 'Tax forms', text: 'Your tax forms will show here' },
        { label: 'My info', path: '/my-info', heading: 'My info', text: 'Your contact details will show here' },
        { label: 'Help', path: '/help', heading: 'Help', text: 'Questions about your pay or this app?' },
      ];
      for (const [index, tab] of tabs.entries()) {
        const link = nav.getByRole('link', { name: tab.label });
        expect((await link.boundingBox())!.height).toBeGreaterThanOrEqual(44);
        await link.click();
        await expect(page).toHaveURL(new RegExp(`${tab.path === '/' ? '/$' : `${tab.path}$`}`));
        await expect(page.getByRole('heading', { level: 1, name: tab.heading })).toBeVisible();
        await expect(page.getByText(tab.text)).toBeVisible();
        await expect(link).toHaveAttribute('aria-current', 'page');
        await expect(page).toHaveTitle(`${tab.heading} · MoSa's employee app`);
        await expectNoHorizontalScroll(page);
        if (index > 0) await snap(page, `${tag}-04-tab-${tab.path.slice(1)}`);
      }

      await expect(page.getByRole('main')).not.toContainText('Cornerstone');
      await nav.getByRole('link', { name: wide ? 'Tax forms' : 'Taxes' }).click();
      await page.reload();
      await expect(page).toHaveURL(/\/taxes$/);
      await expect(page.getByRole('heading', { level: 1, name: 'Tax forms' })).toBeVisible();

      await page.goto('/not-a-real-page');
      await expect(page).toHaveURL(/\/$/);
      await expect(page.getByRole('heading', { level: 1, name: 'Welcome' })).toBeVisible();
    });

    test('keyboard focus is visible on the tabs', async ({ page }) => {
      await signIn(page);
      await mockApi(page);
      await page.goto(`/?${tenant}`);
      await expect(page.getByRole('heading', { level: 1, name: 'Welcome' })).toBeVisible();

      const payTab = page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Pay' });
      for (let presses = 0; presses < 10 && !(await payTab.evaluate((node) => node === document.activeElement)); presses += 1) {
        await page.keyboard.press('Tab');
      }
      await expect(payTab).toBeFocused();
      const outline = await payTab.evaluate((node) => {
        const style = getComputedStyle(node);
        return { style: style.outlineStyle, width: parseFloat(style.outlineWidth), color: style.outlineColor };
      });
      expect(outline.style).not.toBe('none');
      expect(outline.width).toBeGreaterThanOrEqual(2);
      expect(outline.color).toBe('rgb(47, 127, 247)');
      await snap(page, `${tag}-05-focus`);
      await page.keyboard.press('Enter');
      await expect(page.getByRole('heading', { level: 1, name: 'Pay stubs' })).toBeFocused();
    });

    test('a switched-off app or an unknown person sees "isn\'t available", never why', async ({ page }) => {
      await signIn(page);
      await mockApi(page, { links: (route) => route.fulfill({ status: 404 }) });
      await page.goto(`/?${tenant}`);

      await expect(page.getByRole('heading', { level: 1, name: "The employee app isn't available right now" })).toBeVisible();
      await expect(page.getByText('Your pay stubs still come the usual way.')).toBeVisible();
      await expect(page.getByText("Questions about your pay? Ask your manager at MoSa's.")).toBeVisible();
      await expect(page.getByRole('button', { name: 'Try again' })).toBeVisible();
      await expect(page.getByRole('navigation', { name: 'Main' })).toHaveCount(0);
      await expectNoHorizontalScroll(page);
      await snap(page, `${tag}-06-unavailable`);
    });

    test('a former employee past their access date sees "access ended" and can sign out', async ({ page }) => {
      await signIn(page);
      await mockApi(page, { links: (route) => json(route, [{ id: 9, company_name: "MoSa's", subdomain_slug: 'mosas', status: 'former', former_access_until: '2020-01-01' }]) });
      await page.goto(`/?${tenant}`);

      await expect(page.getByRole('heading', { level: 1, name: 'Your access has ended' })).toBeVisible();
      await expect(page.getByText("Need a copy of an old pay stub or tax form? Ask MoSa's.")).toBeVisible();
      await expectNoHorizontalScroll(page);
      await snap(page, `${tag}-07-access-ended`);
      await page.getByRole('button', { name: 'Sign out' }).click();
      await expect(page.getByRole('heading', { level: 1, name: 'Your pay, on your phone' })).toBeVisible();
    });

    test('server errors, rate limits and going offline each get their own screen', async ({ page, context }) => {
      await signIn(page);
      let linksStatus = 500;
      await mockApi(page, { links: (route) => (linksStatus === 200 ? activeLinks(route) : route.fulfill({ status: linksStatus })) });
      await page.goto(`/?${tenant}`);

      await expect(page.getByRole('heading', { level: 1, name: 'Something went wrong' })).toBeVisible();
      await expect(page.getByText("Still not working? Ask your manager at MoSa's.")).toBeVisible();
      // No tabs that change the address without changing the screen, and a way out on a phone.
      await expect(page.getByRole('navigation', { name: 'Main' })).toHaveCount(0);
      await expect(page.getByRole('main').getByRole('button', { name: 'Sign out' })).toBeVisible();
      await expectNoHorizontalScroll(page);
      await snap(page, `${tag}-08-error`);

      linksStatus = 429;
      await page.getByRole('button', { name: 'Try again' }).click();
      await expect(page.getByRole('heading', { level: 1, name: 'Too many tries, wait a minute' })).toBeVisible();
      await expect(page.getByRole('main').getByRole('button', { name: 'Sign out' })).toBeVisible();
      await snap(page, `${tag}-09-too-many-tries`);

      await context.setOffline(true);
      await expect(page.getByRole('status').filter({ hasText: "You're offline" })).toBeVisible();
      await page.getByRole('button', { name: 'Try again' }).click();
      await expect(page.getByRole('heading', { level: 1, name: 'No internet connection' })).toBeVisible();
      await expect(page.getByText("For your privacy, your pay isn't saved on this phone.")).toBeVisible();
      await expectNoHorizontalScroll(page);
      await snap(page, `${tag}-10-offline`);

      // Coming back online retries on its own.
      linksStatus = 200;
      await context.setOffline(false);
      await expect(page.getByRole('heading', { level: 1, name: 'Welcome' })).toBeVisible();
      await expect(page.getByRole('status').filter({ hasText: "You're offline" })).toHaveCount(0);
      await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
    });

    test('on a client subdomain, another company\'s link is never opened', async ({ page }) => {
      await signIn(page);
      await mockApi(page, { links: (route) => json(route, { links: [{ id: 77, company_name: 'Pelican Row Bakery (demo)', subdomain_slug: 'pelican', status: 'active', former_access_until: null }] }) });
      await page.goto(`/?${tenant}`);

      await expect(page.getByRole('heading', { level: 1, name: "The employee app isn't available right now" })).toBeVisible();
      await expect(page.getByText('Pelican Row Bakery')).toHaveCount(0);
    });

    test('signing out from My info lands on Welcome, not sign-in', async ({ page }) => {
      await signIn(page);
      await mockApi(page);
      await page.goto(`/my-info?${tenant}`);
      await expect(page.getByRole('heading', { level: 1, name: 'My info' })).toBeVisible();

      await page.getByRole('main').getByRole('button', { name: 'Sign out' }).click();
      await expect(page.getByRole('heading', { level: 1, name: 'Your pay, on your phone' })).toBeVisible();
      await expect(page).toHaveURL(/\/$/);
      // Signing back in opens Home, not the page signed out from.
      await page.getByRole('link', { name: 'Sign in' }).click();
      await page.getByRole('button', { name: 'Continue as preview employee' }).click();
      await expect(page.getByRole('heading', { level: 1, name: 'Welcome' })).toBeVisible();
    });

    test('the loading skeleton shows while the link is checked', async ({ page }) => {
      await signIn(page);
      let release: () => void = () => undefined;
      const held = new Promise<void>((resolve) => { release = resolve; });
      await mockApi(page, { context: async (route) => { await held; await route.fulfill({ status: 204 }); } });
      await page.goto(`/?${tenant}`);

      await expect(page.getByText('Loading your pay…')).toBeAttached();
      await expect(page.locator('[aria-busy="true"]')).toBeVisible();
      await snap(page, `${tag}-11-loading`);
      release();
      await expect(page.getByRole('heading', { level: 1, name: 'Welcome' })).toBeVisible();
    });

    test('without branding the app uses a neutral Cornerstone Payroll brand', async ({ page }) => {
      await mockApi(page, { branding: (route) => route.fulfill({ status: 500 }) });
      await page.goto(`/?${tenant}`);

      await expect(page.getByRole('heading', { level: 1, name: 'Your pay, on your phone' })).toBeVisible();
      await expect(page.getByText('See your pay stubs and tax forms any time.')).toBeVisible();
      await expect(page.getByText("First time here? Your manager will send you a link to set up your account.")).toBeVisible();
      expect(await page.getByRole('link', { name: 'Sign in' }).evaluate((node) => getComputedStyle(node).backgroundColor)).toBe('rgb(25, 75, 170)');
      await snap(page, `${tag}-12-fallback-brand`);
    });

    test('a too-light brand color is darkened so white text stays readable', async ({ page }) => {
      await mockApi(page, { branding: (route) => json(route, { name: 'Pelican Row Bakery (demo)', logo_url: null, primary_color: '#ffd54f', accent_color: null }) });
      await page.goto(`/?${tenant}`);

      const background = await page.getByRole('link', { name: 'Sign in' }).evaluate((node) => getComputedStyle(node).backgroundColor);
      const [r, g, b] = background.match(/\d+/g)!.map(Number);
      const channel = (v: number) => { const s = v / 255; return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4; };
      const contrast = 1.05 / (0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b) + 0.05);
      expect(contrast).toBeGreaterThanOrEqual(4.5);
    });

    test('phones get bottom tabs; wider screens get a top bar and side-by-side columns', async ({ page }) => {
      await signIn(page);
      await mockApi(page);
      await page.goto(`/?${tenant}`);
      await expect(page.getByRole('heading', { level: 1, name: 'Welcome' })).toBeVisible();

      const nav = page.getByRole('navigation', { name: 'Main' });
      const navBox = (await nav.boundingBox())!;
      const latest = page.getByRole('region', { name: 'Latest pay' });
      const year = page.getByRole('region', { name: 'This year so far' });
      const signOut = page.getByRole('banner').getByRole('button', { name: 'Sign out' });
      if (viewport.width < 600) {
        expect(Math.round(navBox.y + navBox.height)).toBe(viewport.height);
        const home = nav.getByRole('link', { name: 'Home' });
        await home.hover();
        expect(await home.evaluate((node) => getComputedStyle(node).color)).toBe('rgb(19, 122, 167)');
        await expect(year).toBeHidden();
        await expect(signOut).toBeHidden();
      } else {
        expect(navBox.y).toBeLessThan(80);
        await expect(signOut).toBeVisible();
        const [left, right] = [(await latest.boundingBox())!, (await year.boundingBox())!];
        expect(right.x).toBeGreaterThan(left.x + left.width);
        expect(Math.abs(right.y - left.y)).toBeLessThan(2);
        // The current tab is underlined in the logo blue, which passes 3:1 against white,
        // and keeps its color under the mouse.
        await nav.getByRole('link', { name: 'Home' }).hover();
        expect(await nav.getByRole('link', { name: 'Home' }).evaluate((node) => getComputedStyle(node).borderBottomColor)).toBe('rgb(24, 152, 207)');

        await nav.getByRole('link', { name: 'Pay' }).click();
        await expect(page.getByRole('heading', { level: 1, name: 'Pay stubs' })).toBeVisible();
        const list = (await page.getByRole('region', { name: 'Your pay' }).boundingBox())!;
        const detail = (await page.getByRole('region', { name: 'Pay stub' }).boundingBox())!;
        expect(Math.round(list.width)).toBe(360);
        expect(detail.x).toBeGreaterThan(list.x + list.width);
        await snap(page, `${tag}-14-pay-desktop`);
      }
    });

    test('"Hide amounts" is remembered on this device', async ({ page }) => {
      await signIn(page);
      await mockApi(page);
      await page.goto(`/?${tenant}`);

      await page.getByRole('button', { name: 'Hide amounts' }).click();
      await expect(page.getByRole('button', { name: 'Show amounts' })).toBeVisible();
      expect(await page.evaluate(() => localStorage.getItem('employee-app:hide-amounts'))).toBe('true');
      await page.reload();
      await expect(page.getByRole('button', { name: 'Show amounts' })).toBeVisible();
      await page.getByRole('button', { name: 'Show amounts' }).click();
      await expect(page.getByRole('button', { name: 'Hide amounts' })).toBeVisible();
    });

    test('the view-only banner names the person and has an End button', async ({ page }) => {
      await signIn(page);
      await mockApi(page);
      await page.goto(`/?${tenant}&previewViewAs=${encodeURIComponent('Milo Tarrant')}`);

      const banner = page.getByRole('region', { name: 'View only' });
      await expect(banner).toContainText('Viewing as Milo Tarrant');
      await expect(banner).toContainText('View only · 27 min left');
      expect((await banner.getByRole('button', { name: 'End' }).boundingBox())!.height).toBeGreaterThanOrEqual(44);
      await expect(page.getByRole('heading', { level: 1, name: 'Welcome' })).toBeVisible();
      await expectNoHorizontalScroll(page);
      await snap(page, `${tag}-13-view-only`);
    });
  });
}
