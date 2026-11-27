import { expect, test, type Page, type Route } from '@playwright/test';
import { context, employeeBaseUrl, json, mockEmployeeApi, signIn, tenantQuery } from './employee-fixtures';

// "Go paperless?" on the smallest phones we support (360px), by keyboard,
// with reduced motion. All data is fictional (employee-fixtures.ts). Set
// E2E_SCREENSHOT_DIR to save 360px screenshots.
const screenshotDir = process.env.E2E_SCREENSHOT_DIR;

test.skip(Boolean(process.env.E2E_BASE_URL), 'Needs the local employee dev server');
test.use({ baseURL: employeeBaseUrl, viewport: { width: 360, height: 780 }, reducedMotion: 'reduce' });

type Answer = 'paperless' | 'keep_paper' | 'not_answered';

function consents(pay: Answer, w2: Answer = 'not_answered') {
  const item = (kind: 'pay_statements' | 'w2gu', answer: Answer) => ({
    kind,
    status: answer === 'paperless' ? 'consented' : 'not_consented',
    answer,
    paper_chosen_at: null,
    active_consent: answer === 'paperless'
      ? { id: 7, disclosure_version: 'draft-1', disclosure_digest: 'c'.repeat(64), given_at: '2026-11-27T00:00:00Z', method: 'employee_portal_checkbox', matches_current_disclosure: true }
      : null,
    last_withdrawn_at: null,
    disclosure: {
      version: 'draft-1',
      title: kind === 'w2gu' ? 'Electronic Form W-2GU Delivery Consent' : 'Electronic Pay Statement Delivery Consent',
      text: 'Purpose and scope\nThis is sample disclosure text for the test.\n\nRight to withdraw consent\nYou can switch back to paper any time.',
      digest: 'c'.repeat(64),
      published_at: '2026-11-25T00:00:00Z',
      draft_marker: false,
    },
    requires_access_proof: kind === 'w2gu',
    email_notice_locked_on: false,
    paper_continues: true,
    electronic_only_ready: false,
  });
  return { paper_delivery_continues: true, consents: [item('pay_statements', pay), item('w2gu', w2)] };
}

/** Registered after mockEmployeeApi, so these routes win. Consent needs the preview's verified token. */
async function mockConsents(page: Page, initial: Answer = 'not_answered'): Promise<{ posts: string[] }> {
  let pay = initial;
  const posts: string[] = [];
  await page.route('**/api/v1/employee/delivery_consents**', (route: Route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname.replace(/^.*\/api\/v1/, '');
    if (request.method() === 'GET') return json(route, consents(pay));
    posts.push(path);
    if (path === '/employee/delivery_consents/keep_paper') {
      pay = 'keep_paper';
      return json(route, consents(pay));
    }
    if (request.headers().authorization !== 'Bearer dev-preview-token-verified') {
      return json(route, { clerk_error: { type: 'forbidden', reason: 'reverification-error', metadata: { reverification: { level: 'second_factor', afterMinutes: 10 } } } }, 403);
    }
    pay = 'paperless';
    return json(route, consents(pay), 201);
  });
  return { posts };
}

async function expectPhoneBasics(page: Page): Promise<void> {
  const result = await page.evaluate(() => {
    const main = document.getElementById('emp-main');
    const noScroll = document.documentElement.scrollWidth <= window.innerWidth && (!main || main.scrollWidth <= main.clientWidth);
    const small = [...document.querySelectorAll<HTMLElement>('button, a:not(.emp-link-inline), a.emp-link-standalone')]
      .filter((node) => node.offsetParent !== null && node.getBoundingClientRect().height < 43.5)
      .map((node) => node.textContent?.trim() || node.getAttribute('aria-label') || node.id);
    return { noScroll, small };
  });
  expect(result.noScroll).toBe(true);
  expect(result.small, 'tap targets under 44px').toEqual([]);
}

async function snap(page: Page, name: string): Promise<void> {
  if (screenshotDir) await page.screenshot({ path: `${screenshotDir}/360-${name}.png` });
}

const deliveryContext = { ...context, features: { ...context.features, delivery_consent: true } };

test.describe('"Go paperless?" on a phone', () => {
  test('Yes, by keyboard: the disclosure opens from its expander, step-up confirms, then Home', async ({ page, browserName }) => {
    // Safari's Tab skips buttons unless "Press Tab to highlight each item" is on; Option+Tab always reaches them.
    const tab = browserName === 'webkit' ? 'Alt+Tab' : 'Tab';
    await signIn(page);
    await mockEmployeeApi(page, { context: deliveryContext });
    const { posts } = await mockConsents(page);
    await page.goto(`/go-paperless?${tenantQuery}`);

    await expect(page.getByRole('heading', { level: 1, name: 'Go paperless?' })).toBeVisible();
    await expect(page.getByRole('navigation', { name: 'Main' })).toHaveCount(0);
    await expectPhoneBasics(page);
    await snap(page, '01-go-paperless');

    const yes = page.getByRole('button', { name: 'Yes, go paperless' });
    await yes.focus();
    await page.keyboard.press('Enter');
    const form = page.getByRole('form', { name: 'Go paperless' });
    await expect(form.getByRole('heading', { name: 'Go paperless' })).toBeFocused();

    // Heading → disclosure toggle → checkbox → (disabled submit skipped) → Back.
    await page.keyboard.press(tab);
    await expect(form.getByRole('button', { name: 'Read the full disclosure' })).toBeFocused();
    await page.keyboard.press('Enter');
    await expect(form.getByText('This is sample disclosure text for the test.')).toBeVisible();
    await expect(form.getByRole('button', { name: 'Hide the full disclosure' })).toHaveAttribute('aria-expanded', 'true');
    await page.keyboard.press(tab);
    await page.keyboard.press('Space');
    await expect(form.getByRole('checkbox')).toBeChecked();
    await expectPhoneBasics(page);
    await snap(page, '02-yes-form');

    await page.keyboard.press(tab);
    await expect(form.getByRole('button', { name: 'Go paperless' })).toBeFocused();
    await page.keyboard.press('Enter');
    await page.getByTestId('dev-preview-step-up').getByRole('button', { name: 'Confirm' }).click();

    await expect(page.getByRole('heading', { level: 1, name: 'Hi, Tala' })).toBeVisible();
    await expect(page.getByText("You're set to go paperless. Paper pay stubs still come for now.")).toBeVisible();
    await expect(page.getByRole('region', { name: 'Choose how you get pay stubs' })).toHaveCount(0);
    expect(posts.filter((path) => path === '/employee/delivery_consents')).toHaveLength(2);
  });

  test('Keep paper is one tap and needs no step-up', async ({ page }) => {
    await signIn(page);
    await mockEmployeeApi(page, { context: deliveryContext });
    const { posts } = await mockConsents(page);
    await page.goto(`/go-paperless?${tenantQuery}`);

    await page.getByRole('button', { name: 'Keep paper' }).click();
    await expect(page.getByText("Saved. You'll keep getting paper pay stubs.")).toBeVisible();
    await expect(page.getByTestId('dev-preview-step-up')).toHaveCount(0);
    expect(posts).toEqual(['/employee/delivery_consents/keep_paper']);
  });

  test('Home asks until answered, with the W-2GU card in December, and Not now hides each for the visit', async ({ page }) => {
    await signIn(page);
    await page.clock.setFixedTime(new Date('2026-12-02T09:00:00+10:00'));
    await mockEmployeeApi(page, { context: deliveryContext });
    await mockConsents(page);
    await page.goto(`/?${tenantQuery}`);

    await expect(page.getByRole('heading', { level: 1, name: 'Hi, Tala' })).toBeVisible();
    const pay = page.getByRole('region', { name: 'Choose how you get pay stubs' });
    const w2 = page.getByRole('region', { name: 'Get your W-2GU online?' });
    await expect(pay).toBeVisible();
    await expect(w2).toContainText('Your 2026 Form W-2GU comes by January 31.');
    await expectPhoneBasics(page);
    await snap(page, '03-home-cards');

    await w2.getByRole('button', { name: 'Not now: Get your W-2GU online?' }).focus();
    await page.keyboard.press('Enter');
    await expect(w2).toHaveCount(0);
    await page.reload();
    await expect(pay).toBeVisible();
    await expect(w2).toHaveCount(0);
  });
});
