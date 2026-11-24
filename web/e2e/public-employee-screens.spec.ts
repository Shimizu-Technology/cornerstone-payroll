import { expect, test, type Page } from '@playwright/test';
import { context, employeeBaseUrl, mockEmployeeApi, signIn, tenantQuery } from './employee-fixtures';

// The employee screens on a desktop (1280px): top navigation, a two-column
// Home, and Pay as the list beside the stub with Previous and Next. Phones are
// covered by employee-mobile-screens.spec.ts. Fictional data only.
const screenshotDir = process.env.E2E_SCREENSHOT_DIR;

test.skip(Boolean(process.env.E2E_BASE_URL), 'Needs the local employee dev server');
test.use({ baseURL: employeeBaseUrl, viewport: { width: 1280, height: 800 } });

async function snap(page: Page, name: string, fullPage = false): Promise<void> {
  if (!screenshotDir) return;
  const grow = fullPage ? await page.addStyleTag({ content: '.emp-shell{height:auto!important}.emp-main{overflow:visible!important}' }) : null;
  await page.screenshot({ path: `${screenshotDir}/1280-${name}.png`, fullPage });
  await grow?.evaluate((node) => node.remove());
}

async function expectNoHorizontalScroll(page: Page): Promise<void> {
  expect(await page.evaluate(() => {
    const main = document.getElementById('emp-main');
    return document.documentElement.scrollWidth <= window.innerWidth && (!main || main.scrollWidth <= main.clientWidth);
  })).toBe(true);
}

test.describe('employee screens on a desktop', () => {
  test('Home has two columns: latest and recent pay, then the year so far and questions', async ({ page }) => {
    await signIn(page);
    await mockEmployeeApi(page, { context: { ...context, next_payday: '2026-12-04' } });
    await page.clock.setFixedTime(new Date('2026-11-25T09:00:00+10:00'));
    await page.goto(`/?${tenantQuery}`);

    const latest = page.getByRole('region', { name: 'Latest pay' });
    const year = page.getByRole('region', { name: 'This year so far' });
    await expect(latest).toContainText('$534.18');
    await expect(year).toContainText('$23,230.00');
    const [left, right] = [(await latest.boundingBox())!, (await year.boundingBox())!];
    expect(right.x).toBeGreaterThan(left.x + left.width);
    await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
    await expectNoHorizontalScroll(page);
    await snap(page, '01-home');
  });

  test('Pay shows the list beside the stub, with Previous and Next', async ({ page }) => {
    await signIn(page);
    const log = await mockEmployeeApi(page);
    await page.goto(`/pay?${tenantQuery}`);

    const list = page.getByRole('region', { name: 'Your pay' });
    const stub = page.getByRole('region', { name: 'Pay stub' });
    await expect(stub.getByRole('heading', { name: 'Nov 20, 2026' })).toBeVisible();
    const [listBox, stubBox] = [(await list.boundingBox())!, (await stub.boundingBox())!];
    expect(Math.round(listBox.width)).toBe(360);
    expect(stubBox.x).toBeGreaterThan(listBox.x + listBox.width);
    // Year to date shows as its own column on a wide screen.
    await expect(stub.getByRole('columnheader', { name: 'This year' }).first()).toBeVisible();
    await expect(list.getByRole('link', { name: /Nov 20/ })).toHaveAttribute('aria-current', 'page');
    await expect(stub.getByText('Next', { exact: true }).filter({ visible: true })).toHaveAttribute('aria-disabled', 'true');
    await expectNoHorizontalScroll(page);
    await snap(page, '02-pay', true);

    await stub.getByRole('link', { name: /^Previous/ }).click();
    await expect(page).toHaveURL(/\/pay\/905\?year=2026$/);
    await expect(stub.getByRole('heading', { name: 'Nov 6, 2026' })).toBeVisible();
    await expect(list.getByRole('link', { name: /Nov 6/ })).toHaveAttribute('aria-current', 'page');
    await stub.getByRole('link', { name: /^Next/ }).click();
    await expect(stub.getByRole('heading', { name: 'Nov 20, 2026' })).toBeVisible();

    await list.getByRole('link', { name: /Oct 23/ }).click();
    await expect(stub).toContainText('Check #2187');
    await expect(stub).toContainText('Check delivered');

    await list.getByRole('button', { name: '2025' }).click();
    await expect(list.getByRole('link', { name: /Dec 19/ })).toBeVisible();
    // The year is in the address, so a reload keeps it.
    await expect(page).toHaveURL(/\/pay\?year=2025$/);
    await page.reload();
    await expect(list.getByRole('link', { name: /Dec 19/ })).toHaveAttribute('aria-current', 'page');
    // A stub opened from elsewhere (Home, an email) shows its own year's list.
    await page.goto(`/pay/801?${tenantQuery}`);
    await expect(list.getByRole('link', { name: /Dec 19/ })).toHaveAttribute('aria-current', 'page');
    await expect(list.getByRole('button', { name: '2025' })).toHaveAttribute('aria-pressed', 'true');
    expect(log.requests.some((r) => r.path === '/employee/statements' && r.headers['x-employee-link-id'] === '42')).toBe(true);
  });

  test('Tax forms, My info, Help and sign-up at desktop width', async ({ page }) => {
    await signIn(page);
    await mockEmployeeApi(page, { profile: undefined });
    await page.goto(`/taxes?${tenantQuery}`);
    await expect(page.getByRole('region', { name: '2025 W-2GU' })).toBeVisible();
    await expectNoHorizontalScroll(page);
    await snap(page, '03-tax-forms');

    await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'My info' }).click();
    await expect(page.getByRole('region', { name: 'Contact details' })).toBeVisible();
    await expectNoHorizontalScroll(page);
    await snap(page, '04-my-info', true);

    await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Help' }).click();
    await expect(page.getByRole('region', { name: 'Ask Coral Kitchen' })).toContainText('Rina Calvo');
    await snap(page, '05-help');

    await page.getByRole('banner').getByRole('button', { name: 'Sign out' }).click();
    await page.getByRole('link', { name: 'Set up your account' }).click();
    await expect(page.getByRole('heading', { level: 1, name: 'Set up your account' })).toBeVisible();
    await expectNoHorizontalScroll(page);
    await snap(page, '06-sign-up');
  });
});
