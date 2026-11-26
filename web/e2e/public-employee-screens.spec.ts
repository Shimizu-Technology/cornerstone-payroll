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
    // Masked by default until the person taps Show amounts.
    await expect(latest).toContainText('$•••');
    await expect(latest).not.toContainText('$534.18');
    await expect(year).toContainText('$•••');
    await expect(year).not.toContainText('$23,230.00');
    await latest.getByRole('button', { name: 'Show amounts' }).click();
    await expect(latest).toContainText('$534.18');
    await expect(year).toContainText('$23,230.00');
    const [left, right] = [(await latest.boundingBox())!, (await year.boundingBox())!];
    expect(right.x).toBeGreaterThan(left.x + left.width);
    await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
    await expectNoHorizontalScroll(page);
    await snap(page, '01-home');
  });

  test('Pay shows the list beside the stub, with Older and Newer', async ({ page }) => {
    await signIn(page);
    const log = await mockEmployeeApi(page);
    await page.goto(`/pay?${tenantQuery}`);

    const list = page.getByRole('region', { name: 'Your pay' });
    const stub = page.getByRole('region', { name: 'Pay stub' });
    await expect(stub.getByRole('heading', { name: 'Nov 1 – 14, 2026' })).toBeVisible();
    await expect(stub).toContainText('Paid Nov 20, 2026');
    const [listBox, stubBox] = [(await list.boundingBox())!, (await stub.boundingBox())!];
    expect(Math.round(listBox.width)).toBe(360);
    expect(stubBox.x).toBeGreaterThan(listBox.x + listBox.width);
    // Year to date shows as its own column on a wide screen.
    await expect(stub.getByRole('columnheader', { name: 'This year' }).first()).toBeVisible();
    await expect(list.getByRole('link', { name: /Nov 20/ })).toHaveAttribute('aria-current', 'page');
    await expect(stub.getByText('Newer', { exact: true }).filter({ visible: true })).toHaveAttribute('aria-disabled', 'true');
    await expectNoHorizontalScroll(page);
    await snap(page, '02-pay', true);

    await stub.getByRole('link', { name: /^Older:/ }).click();
    await expect(page).toHaveURL(/\/pay\/905\?year=2026$/);
    await expect(stub.getByRole('heading', { name: 'Oct 18 – 31, 2026' })).toBeVisible();
    await expect(list.getByRole('link', { name: /Nov 6/ })).toHaveAttribute('aria-current', 'page');
    await stub.getByRole('link', { name: /^Newer:/ }).click();
    await expect(stub.getByRole('heading', { name: 'Nov 1 – 14, 2026' })).toBeVisible();

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

test.describe('employee masked pay amounts at 390x844', () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test('masks pay amounts by default across screens, keeps hours/dates visible, and handles blocked storage', async ({ page }) => {
    await signIn(page);
    await mockEmployeeApi(page);
    await page.goto(`/?${tenantQuery}`);

    const latest = page.getByRole('region', { name: 'Latest pay' });
    const showButton = latest.getByRole('button', { name: 'Show amounts' });
    await expect(showButton).toBeVisible();
    await expect(showButton).not.toHaveAttribute('aria-pressed');
    expect((await showButton.boundingBox())!.height).toBeGreaterThanOrEqual(44);
    await expect(latest).toContainText('$•••');
    await expect(latest).toContainText('Paid Nov 20, 2026');
    await expect(latest).toContainText('38.5 hours');
    await expect(latest).not.toContainText('$534.18');
    await expect(latest).not.toContainText('less than');
    await expect(page.getByText('Amounts stay hidden on this device until you tap Show amounts.')).toBeVisible();
    await expectNoHorizontalScroll(page);

    // Keyboard focus on the eye button shows the visible focus outline.
    for (let presses = 0; presses < 12 && !(await showButton.evaluate((node) => node === document.activeElement)); presses += 1) {
      await page.keyboard.press('Tab');
    }
    await expect(showButton).toBeFocused();
    const outline = await showButton.evaluate((node) => {
      const style = getComputedStyle(node);
      return { style: style.outlineStyle, width: parseFloat(style.outlineWidth) };
    });
    expect(outline.style).not.toBe('none');
    expect(outline.width).toBeGreaterThanOrEqual(2);

    // Stub detail: rates are masked, hours/dates stay visible, PDF warns "(shows amounts)".
    await latest.getByRole('link', { name: 'View pay stub' }).click();
    const stub = page.getByRole('article');
    await expect(stub).toContainText('36 hrs × $•••');
    await expect(stub).not.toContainText('$15.00');
    await expect(stub).not.toContainText('$534.18');
    await expect(stub.getByRole('button', { name: 'Download PDF (shows amounts)' })).toBeVisible();
    await expectNoHorizontalScroll(page);

    // Tax forms: W-2GU PDF warns "(shows amounts)".
    await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Tax forms' }).click();
    await expect(page.getByRole('button', { name: 'Download W-2GU PDF (shows amounts)' })).toBeVisible();
    await expectNoHorizontalScroll(page);

    // Reveal amounts, reload, and verify choice persists and explainer does not repeat.
    await page.getByRole('button', { name: 'Show amounts' }).click();
    await expect(page.getByRole('button', { name: 'Download W-2GU (PDF)' })).toBeVisible();
    await page.goto(`/?${tenantQuery}`);
    await expect(page.getByRole('region', { name: 'Latest pay' })).toContainText('$534.18');
    await expect(page.getByText('Amounts stay hidden on this device until you tap Show amounts.')).toHaveCount(0);
  });

  test('fails closed to masked when localStorage throws', async ({ page }) => {
    await signIn(page);
    await page.addInitScript(() => {
      Object.defineProperty(window, 'localStorage', {
        configurable: true,
        get() {
          throw new DOMException('blocked', 'SecurityError');
        },
      });
    });
    await mockEmployeeApi(page);
    await page.goto(`/?${tenantQuery}`);

    const latest = page.getByRole('region', { name: 'Latest pay' });
    await expect(latest.getByRole('button', { name: 'Show amounts' })).toBeVisible();
    await expect(latest).toContainText('$•••');
    await expect(latest).not.toContainText('$534.18');
    await expectNoHorizontalScroll(page);
  });
});
