import { expect, test, type Page } from '@playwright/test';
import { branding, context, employeeBaseUrl, json, mockEmployeeApi, signIn, tenantQuery } from './employee-fixtures';

// The employee screens on a phone: the employee-mobile projects (Pixel 7 on
// Chromium locally; iPhone 14 on WebKit in CI). No Clerk key, so the dev-only
// preview stands in for Clerk's sign-in, sign-up and "confirm it's you"
// prompt. All data is fictional (employee-fixtures.ts). Set E2E_SCREENSHOT_DIR
// to save 390px screenshots.
const screenshotDir = process.env.E2E_SCREENSHOT_DIR;

test.skip(Boolean(process.env.E2E_BASE_URL), 'Needs the local employee dev server');
test.use({ baseURL: employeeBaseUrl, ...(screenshotDir ? { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 } : {}) });

// The signed-in shell scrolls inside <main>; a full-page shot lets the page grow for the picture only.
async function snap(page: Page, name: string, fullPage = false): Promise<void> {
  if (!screenshotDir) return;
  const grow = fullPage ? await page.addStyleTag({ content: '.emp-shell{height:auto!important}.emp-main{overflow:visible!important}.emp-shell{position:relative!important}.emp-nav{position:absolute!important}' }) : null;
  await page.screenshot({ path: `${screenshotDir}/390-${name}.png`, fullPage });
  await grow?.evaluate((node) => node.remove());
}

async function expectPhoneBasics(page: Page): Promise<void> {
  const result = await page.evaluate(() => {
    const main = document.getElementById('emp-main');
    const noScroll = document.documentElement.scrollWidth <= window.innerWidth && (!main || main.scrollWidth <= main.clientWidth);
    const small = [...document.querySelectorAll<HTMLElement>('button, a.emp-btn, .emp-row, summary, input:not([type=checkbox]):not([type=radio]), select')]
      .filter((node) => node.offsetParent !== null && node.getBoundingClientRect().height < 43.5)
      .map((node) => node.textContent?.trim() || node.getAttribute('aria-label') || node.id);
    const zoomy = [...document.querySelectorAll<HTMLElement>('input, select, textarea')]
      .filter((node) => parseFloat(getComputedStyle(node).fontSize) < 16).map((node) => node.id);
    return { noScroll, small, zoomy };
  });
  expect(result.noScroll).toBe(true);
  expect(result.small, 'tap targets under 44px').toEqual([]);
  expect(result.zoomy, 'inputs under 16px zoom on iOS').toEqual([]);
}

test.describe('employee app on a phone', () => {
  test('Home shows the latest check, and a stub opens with its lines, YTD and PDF', async ({ page }) => {
    await signIn(page);
    const log = await mockEmployeeApi(page, { context: { ...context, next_payday: '2026-12-04' } });
    await page.clock.setFixedTime(new Date('2026-11-25T09:00:00+10:00'));
    await page.goto(`/?${tenantQuery}`);

    await expect(page.getByRole('heading', { level: 1, name: 'Hi, Tala' })).toBeVisible();
    const latest = page.getByRole('region', { name: 'Latest pay' });
    await expect(latest).toContainText('$534.18');
    await expect(latest).toContainText('Paid Nov 20, 2026');
    await expect(latest).toContainText('38.5 hours');
    await expect(latest).toContainText('$36.45 less than Nov 6. You worked 3.5 fewer hours.');
    await expect(page.getByText('Next payday')).toBeVisible();
    await expect(page.getByText('In 9 days')).toBeVisible();
    await expect(page.getByRole('region', { name: 'Recent pay' }).getByRole('listitem')).toHaveCount(3);
    await expectPhoneBasics(page);
    await snap(page, '01-home');

    await latest.getByRole('link', { name: 'View pay stub' }).click();
    await expect(page).toHaveURL(/\/pay\/906$/);
    await expect(page.getByRole('heading', { level: 1, name: 'Pay stub' })).toBeFocused();
    const stub = page.getByRole('article');
    await expect(stub.getByRole('heading', { name: 'Nov 20, 2026' })).toBeVisible();
    await expect(stub).toContainText('Pay period Nov 1 – 14');
    await expect(stub).toContainText('36 hrs × $15.00');
    await expect(stub).toContainText('2.5 hrs × $22.50');
    await expect(stub.getByRole('row', { name: /Tips/ })).toContainText('$16.25');
    // Guam income tax, never "Federal".
    await expect(stub).toContainText('Guam income tax');
    await expect(stub).not.toContainText('Federal');
    await expect(stub.getByRole('region', { name: 'This year so far' })).toContainText('$23,230.00');
    await expectPhoneBasics(page);
    await snap(page, '02-stub', true);

    const download = page.waitForEvent('download');
    await stub.getByRole('button', { name: 'Download PDF' }).click();
    expect((await download).suggestedFilename()).toBe('pay-stub-2026-11-20.pdf');
    const pdfRequest = log.requests.find((r) => r.path === '/employee/statements/906/pdf');
    expect(pdfRequest?.headers['x-employee-link-id']).toBe('42');
    expect(pdfRequest?.headers.accept).toBe('application/pdf');

    // Previous walks to the older check.
    await stub.getByRole('link', { name: /^Previous/ }).click();
    await expect(page).toHaveURL(/\/pay\/905$/);
    await page.getByRole('link', { name: 'Pay', exact: true }).first().click();
    await expect(page.getByRole('heading', { level: 1, name: 'Pay stubs' })).toBeVisible();
  });

  test('Pay shows the latest, the three before it, then all by year with QuickBooks checks', async ({ page }) => {
    await signIn(page);
    await mockEmployeeApi(page);
    await page.goto(`/pay?${tenantQuery}`);

    await expect(page.getByRole('region', { name: 'Latest pay' })).toContainText('$534.18');
    await expect(page.getByRole('region', { name: 'Recent pay' }).getByRole('listitem')).toHaveCount(3);
    await snap(page, '03-pay');
    await page.getByRole('link', { name: 'View all pay stubs' }).click();
    await expect(page.getByRole('heading', { level: 1, name: 'All pay stubs' })).toBeVisible();
    const paychecks = page.getByRole('list', { name: 'Paychecks' });
    await expect(paychecks.getByRole('listitem')).toHaveCount(5);
    await expect(paychecks.getByRole('listitem').first()).toContainText('38.5 hours');
    await expect(paychecks).toContainText('Corrected');
    const quickbooks = page.getByRole('list', { name: 'From QuickBooks records' });
    await expect(quickbooks.getByRole('listitem')).toHaveCount(2);
    await expectPhoneBasics(page);
    await snap(page, '04-pay-all', true);

    // A QuickBooks check with its original PDF offers it; one without says nothing about it.
    await quickbooks.getByRole('link', { name: /Aug 28/ }).click();
    await expect(page.getByRole('button', { name: 'View original stub (PDF)' })).toBeVisible();
    await expect(page.getByText('From QuickBooks records')).toBeVisible();
    await page.getByRole('link', { name: 'All pay stubs' }).click();
    await page.getByRole('list', { name: 'From QuickBooks records' }).getByRole('link', { name: /Aug 14/ }).click();
    await expect(page.getByRole('heading', { name: 'Aug 14, 2026' })).toBeVisible();
    await expect(page.getByRole('button', { name: /PDF|original/i })).toHaveCount(0);
    await expect(page.getByRole('main')).not.toContainText(/no original|not available|missing/i);

    await page.getByRole('link', { name: 'All pay stubs' }).click();
    await page.getByRole('button', { name: '2025' }).click();
    await expect(page.getByRole('list', { name: 'Paychecks' }).getByRole('listitem')).toHaveCount(1);
    await expect(page).toHaveURL(/year=2025/);
  });

  test('Hide amounts hides every amount and the comparison line', async ({ page }) => {
    await signIn(page);
    await mockEmployeeApi(page);
    await page.goto(`/?${tenantQuery}`);
    const latest = page.getByRole('region', { name: 'Latest pay' });
    await expect(latest).toContainText('$534.18');
    await page.getByRole('button', { name: 'Hide amounts' }).click();
    await expect(latest).not.toContainText('$534.18');
    await expect(latest).not.toContainText('less than');
    await expect(latest.getByText('Amount hidden')).toBeAttached();
    await expect(page.getByText('Amounts stay hidden on this device until you tap Show amounts.')).toBeVisible();
    await snap(page, '05-hidden-amounts');
  });

  test('a contact change asks to confirm it\'s you first, then saves', async ({ page }) => {
    await signIn(page);
    const log = await mockEmployeeApi(page);
    await page.goto(`/my-info?${tenantQuery}`);

    const contact = page.getByRole('region', { name: 'Contact details' });
    await expect(contact).toContainText('(671) 555-0142');
    await expect(contact.getByText('Verified')).toBeVisible();
    await expectPhoneBasics(page);
    await snap(page, '06-my-info', true);

    await contact.getByRole('button', { name: 'Change mobile phone' }).click();
    await page.getByLabel('Mobile phone').fill('671-555-0177');
    await snap(page, '07-phone-edit');
    await page.getByRole('button', { name: 'Save phone' }).click();

    // The API asked for step-up; the prompt shows, and Cancel saves nothing.
    const prompt = page.getByRole('dialog', { name: "Confirm it's you" });
    await expect(prompt).toBeVisible();
    await snap(page, '08-step-up');
    await prompt.getByRole('button', { name: 'Cancel' }).click();
    await expect(page.getByText("Not saved. To save your phone number, confirm it's you.")).toBeVisible();

    await page.getByRole('button', { name: 'Save phone' }).click();
    await page.getByRole('dialog', { name: "Confirm it's you" }).getByLabel('Code').fill('424242');
    await page.getByRole('dialog', { name: "Confirm it's you" }).getByRole('button', { name: 'Confirm' }).click();
    await expect(page.getByText('Phone number saved.')).toBeVisible();
    await expect(contact).toContainText('(671) 555-0177');
    const saves = log.requests.filter((r) => r.path === '/employee/profile/phone');
    expect(saves.map((r) => r.headers.authorization)).toEqual(['Bearer dev-preview-token', 'Bearer dev-preview-token', 'Bearer dev-preview-token-verified']);

    // A new email is confirmed with a code before it's saved.
    await contact.getByRole('button', { name: 'Change personal email' }).click();
    await page.getByLabel('Personal email').fill('tala.new@example.com');
    await page.getByRole('button', { name: 'Send code' }).click();
    await expect(page.getByText('We sent a code to')).toBeVisible();
    await page.getByLabel('Code from the email').fill('123456');
    await page.getByRole('button', { name: 'Confirm email' }).click();
    await expect(page.getByText('Email verified and saved.')).toBeVisible();
    await expect(contact).toContainText('tala.new@example.com');
  });

  test('an address change is a request: current and requested side by side, then Edit or Cancel', async ({ page }) => {
    await signIn(page);
    const log = await mockEmployeeApi(page);
    await page.goto(`/my-info?${tenantQuery}`);

    const address = page.getByRole('region', { name: 'Home address' });
    await expect(address).toContainText('Used for paychecks, W-2s and other tax and work documents.');
    await address.getByRole('button', { name: 'Request a change' }).click();
    await page.getByLabel('Street address').fill('200 Sample Ave');
    await page.getByLabel('Apartment, unit or PO box (optional)').fill('');
    await page.getByLabel('Village or city').fill('Hagåtña');
    await page.getByLabel('ZIP code').fill('9691');
    await page.getByRole('button', { name: 'Send request' }).click();
    await expect(page.getByText('Enter a 5-digit ZIP code.')).toBeVisible();
    await page.getByLabel('ZIP code').fill('96910');
    await snap(page, '09-address-form', true);
    await page.getByRole('button', { name: 'Send request' }).click();
    await page.getByRole('dialog', { name: "Confirm it's you" }).getByRole('button', { name: 'Confirm' }).click();

    await expect(page.getByText('Request sent to Coral Kitchen.')).toBeVisible();
    await expect(address.getByText('Waiting for approval')).toBeVisible();
    await expect(address).toContainText('Current');
    await expect(address).toContainText('100 Example Rd');
    await expect(address).toContainText('Requested');
    await expect(address).toContainText('200 Sample Ave');
    expect(log.requests.find((r) => r.path === '/employee/address_requests')?.body).toEqual({
      address: { address_line1: '200 Sample Ave', address_line2: '', city: 'Hagåtña', state: 'GU', zip: '96910' },
    });
    await snap(page, '10-address-pending');

    await address.getByRole('button', { name: 'Edit request' }).click();
    await expect(page.getByLabel('Street address')).toHaveValue('200 Sample Ave');
    await page.getByRole('button', { name: 'Cancel', exact: true }).click();
    await address.getByRole('button', { name: 'Cancel request' }).click();
    await expect(page.getByText('Request cancelled.')).toBeVisible();
    await expect(address.getByRole('button', { name: 'Request a change' })).toBeVisible();
  });

  test('emergency contacts have "Save & add another"', async ({ page }) => {
    await signIn(page);
    await mockEmployeeApi(page);
    await page.goto(`/my-info?${tenantQuery}`);
    await page.getByRole('dialog').waitFor({ state: 'detached' }).catch(() => undefined);

    const card = page.getByRole('region', { name: 'Emergency contacts' });
    await card.getByRole('button', { name: 'Add a contact' }).click();
    await card.getByLabel('Name').fill('Leo Cruz');
    await card.getByLabel('Relationship (optional)').fill('Friend');
    await card.getByLabel('Phone').fill('671 555 0123');
    await card.getByRole('button', { name: 'Save & add another' }).click();
    await page.getByRole('dialog', { name: "Confirm it's you" }).getByRole('button', { name: 'Confirm' }).click();
    await expect(page.getByText('Leo Cruz saved. Add another contact.')).toBeVisible();
    await expect(card.getByLabel('Name')).toHaveValue('');
    await expect(card.getByRole('list', { name: 'Emergency contacts' })).toContainText('Leo Cruz');
    await snap(page, '11-emergency-add-another', true);
  });

  test('legal name and SSN point to Cornerstone, with what to bring', async ({ page }) => {
    await signIn(page);
    await mockEmployeeApi(page);
    await page.goto(`/my-info?${tenantQuery}`);
    const legal = page.getByRole('region', { name: 'Name and Social Security number' });
    await expect(legal).toContainText('Tala Mendiola Reyes');
    await expect(legal).toContainText('To change these, contact Cornerstone');
    await expect(legal).toContainText('Your Social Security card');
    await expect(legal.getByRole('button')).toHaveCount(0);
  });

  test('former employees see their pay read-only, with no next payday and no changes', async ({ page }) => {
    await signIn(page);
    await mockEmployeeApi(page, {
      links: { links: [{ ...profileLinkFormer }] },
      context: { ...context, status: 'former', former_access_until: '2028-03-01', next_payday: '2026-12-04' },
    });
    await page.goto(`/?${tenantQuery}`);
    await expect(page.getByText("You're viewing your past pay")).toBeVisible();
    await expect(page.getByText('until Mar 1, 2028')).toBeVisible();
    await expect(page.getByText('Next payday')).toHaveCount(0);
    await snap(page, '12-former-home');

    await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'My info' }).click();
    await expect(page.getByText("Your details can't be changed here after your job ends.")).toBeVisible();
    await expect(page.getByRole('button', { name: /Change|Request a change|Add a contact/ })).toHaveCount(0);
    await snap(page, '13-former-my-info', true);

    await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Taxes' }).click();
    await expect(page.getByText('Your paper copy is mailed to your last address on file.')).toBeVisible();
  });

  test('Tax forms: download, how the paper copy comes, and a corrected form being prepared', async ({ page }) => {
    await signIn(page);
    await mockEmployeeApi(page, { taxForms: [
      { id: 13, tax_year: 2026, kind: 'w2gu', status: 'withdrawn', corrected: false },
      { id: 12, tax_year: 2025, kind: 'w2gu', status: 'posted', corrected: false },
    ] });
    await page.goto(`/taxes?${tenantQuery}`);
    const current = page.getByRole('region', { name: '2026 W-2GU' });
    await expect(current).toContainText('A corrected form is being prepared');
    await expect(current.getByRole('button')).toHaveCount(0);
    const earlier = page.getByRole('region', { name: '2025 W-2GU' });
    await expect(earlier).toContainText('Your paper copy is mailed to your home address.');
    await expectPhoneBasics(page);
    await snap(page, '14-tax-forms', true);
    const download = page.waitForEvent('download');
    await earlier.getByRole('button', { name: 'Download W-2GU (PDF)' }).click();
    expect((await download).suggestedFilename()).toBe('w-2gu-2025.pdf');
  });

  test('Help lists the company\'s own contacts, or says to ask a manager', async ({ page }) => {
    await signIn(page);
    await mockEmployeeApi(page);
    await page.goto(`/help?${tenantQuery}`);
    const ask = page.getByRole('region', { name: 'Ask Coral Kitchen' });
    await expect(ask).toContainText('Rina Calvo');
    await expect(ask.getByRole('link', { name: 'Call Rina Calvo, (671) 555-0110' })).toHaveAttribute('href', 'tel:6715550110');
    await expect(ask.getByRole('link', { name: 'Text Rina Calvo' })).toBeVisible();
    await expect(ask.getByRole('link', { name: 'Text Joe Santos' })).toHaveCount(0);
    await expectPhoneBasics(page);
    await snap(page, '15-help', true);
  });

  test('Help with no contacts set up: ask your manager, and the main line', async ({ page }) => {
    await signIn(page);
    await mockEmployeeApi(page, { helpContacts: [] });
    await page.goto(`/help?${tenantQuery}`);
    await expect(page.getByText('Ask your manager at Coral Kitchen.', { exact: true })).toBeVisible();
    await expect(page.getByRole('link', { name: "Call Coral Kitchen's main line" })).toHaveAttribute('href', 'tel:6715550100');
    await expect(page.getByRole('main')).not.toContainText('Cornerstone');
    await snap(page, '16-help-blank');
  });
});

const profileLinkFormer = { id: 42, company_name: 'Coral Kitchen', subdomain_slug: 'coral', status: 'former', former_access_until: '2028-03-01' };

test.describe('signing up on a phone', () => {
  test('a printed code, date of birth and SSN-4, then email, then Clerk sign-up, then Home', async ({ page }) => {
    const log = await mockEmployeeApi(page);
    await page.goto(`/?${tenantQuery}`);
    await expect(page.getByText("Can't sign in?")).toBeVisible();
    await page.getByRole('link', { name: 'Set up your account' }).click();

    await expect(page.getByRole('heading', { level: 1, name: 'Set up your account' })).toBeVisible();
    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.getByText('Enter the 10-letter code from your printed sheet.')).toBeVisible();
    await expect(page.getByText('Enter your full date of birth.')).toBeVisible();
    await expectPhoneBasics(page);
    await snap(page, '20-sign-up-step-1', true);

    await page.getByLabel('Sign-up code').fill('abcde-fghjk');
    await page.getByLabel('Month').selectOption('April');
    await page.getByLabel('Day').fill('7');
    await page.getByLabel('Year').fill('1990');
    await page.getByLabel('Last 4 of your Social Security number').fill('1234');
    await page.getByRole('button', { name: 'Continue' }).click();

    await expect(page.getByRole('heading', { level: 1, name: 'Your email' })).toBeVisible();
    expect(log.requests.find((r) => r.path === '/employee/activation')?.body).toEqual({ code: 'ABCDEFGHJK', date_of_birth: '1990-04-07', ssn_last4: '1234' });
    expect(log.requests.find((r) => r.path === '/employee/activation')?.headers.authorization).toBeUndefined();
    // The record has another email, so the person picks where notices go.
    await expect(page.getByText('t•••@example.com')).toBeVisible();
    await page.getByLabel('Your email').fill('tala.reyes@example.com');
    await expectPhoneBasics(page);
    await snap(page, '21-sign-up-step-2', true);
    await page.getByRole('button', { name: 'Create account' }).click();

    await expect(page.getByTestId('dev-preview-sign-up')).toBeVisible();
    const second = log.requests.filter((r) => r.path === '/employee/activation')[1];
    expect(second?.body).toMatchObject({ email: 'tala.reyes@example.com', notice_email: 'sign_in', code: 'ABCDEFGHJK' });
    expect(second?.body).not.toHaveProperty('terms_version');
    await page.getByRole('button', { name: 'Finish preview sign-up' }).click();
    await expect(page.getByRole('heading', { level: 1, name: 'Hi, Tala' })).toBeVisible();
  });

  test('an invite link fills in the token, and takes it out of the address bar', async ({ page }) => {
    const log = await mockEmployeeApi(page);
    await page.goto(`/sign-up?${tenantQuery}#token=${'t'.repeat(40)}`);
    await expect(page.getByText('Your invite link is ready.')).toBeVisible();
    await expect(page.getByLabel('Sign-up code')).toHaveCount(0);
    expect(page.url()).not.toContain('token');
    await page.getByLabel('Month').selectOption('April');
    await page.getByLabel('Day').fill('7');
    await page.getByLabel('Year').fill('1990');
    await page.getByLabel('Last 4 of your Social Security number').fill('1234');
    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.getByRole('heading', { level: 1, name: 'Your email' })).toBeVisible();
    expect(log.requests[0].body).toMatchObject({ token: 't'.repeat(40) });
  });

  test('every failed check shows the same message, and too many tries shows the lockout', async ({ page }) => {
    let calls = 0;
    await mockEmployeeApi(page, { activation: () => (++calls < 3 ? { status: 422, body: { error: 'whatever the API says' } } : { status: 423 }) });
    await page.goto(`/sign-up?${tenantQuery}`);
    const fill = async (): Promise<void> => {
      await page.getByLabel('Sign-up code').fill('ABCDEFGHJK');
      await page.getByLabel('Month').selectOption('April');
      await page.getByLabel('Day').fill('7');
      await page.getByLabel('Year').fill('1990');
      await page.getByLabel('Last 4 of your Social Security number').fill('9999');
      await page.getByRole('button', { name: 'Continue' }).click();
    };
    await fill();
    await expect(page.getByText("We couldn't match those details")).toBeVisible();
    await expect(page.getByText('whatever the API says')).toHaveCount(0);
    await snap(page, '22-sign-up-no-match', true);
    await fill();
    await expect(page.getByText("We couldn't match those details")).toBeVisible();
    await fill();
    await expect(page.getByRole('heading', { level: 1, name: 'Sign-up is paused' })).toBeVisible();
    await expect(page.getByText('we pause sign-up for 24 hours')).toBeVisible();
    await expect(page.getByText('Ask your manager at Coral Kitchen.')).toBeVisible();
    await snap(page, '23-sign-up-locked');
  });

  test('"Already have an account?" signs in, then adds access with step-up', async ({ page }) => {
    const log = await mockEmployeeApi(page);
    await page.goto(`/sign-up?${tenantQuery}`);
    await page.getByRole('link', { name: 'Sign in' }).click();
    await page.getByRole('button', { name: 'Continue as preview employee' }).click();

    await expect(page.getByRole('heading', { level: 1, name: 'Add your employee access' })).toBeVisible();
    await page.getByLabel('Sign-up code').fill('ABCDEFGHJK');
    await page.getByLabel('Month').selectOption('April');
    await page.getByLabel('Day').fill('7');
    await page.getByLabel('Year').fill('1990');
    await page.getByLabel('Last 4 of your Social Security number').fill('1234');
    await expectPhoneBasics(page);
    await snap(page, '24-add-access', true);
    await page.getByRole('button', { name: 'Add access' }).click();
    await page.getByRole('dialog', { name: "Confirm it's you" }).getByRole('button', { name: 'Confirm' }).click();
    await expect(page.getByRole('heading', { level: 1, name: 'Hi, Tala' })).toBeVisible();
    const claims = log.requests.filter((r) => r.path === '/employee/links/claim');
    expect(claims.at(-1)?.headers.authorization).toBe('Bearer dev-preview-token-verified');
    expect(claims.at(-1)?.body).toEqual({ code: 'ABCDEFGHJK', date_of_birth: '1990-04-07', ssn_last4: '1234' });
  });

  test('"Can\'t sign in?" is generic before sign-in, with only the company\'s main phone', async ({ page }) => {
    await mockEmployeeApi(page);
    await page.goto(`/sign-in?${tenantQuery}`);
    await page.getByText("Can't sign in?").click();
    await expect(page.getByText('Still stuck? Ask your manager at Coral Kitchen.')).toBeVisible();
    await expect(page.getByRole('link', { name: 'Call (671) 555-0100' })).toBeVisible();
    await expect(page.getByRole('main')).not.toContainText('Rina');
    await snap(page, '25-cant-sign-in', true);
  });

  test('without a main phone, "Can\'t sign in?" names no number', async ({ page }) => {
    await mockEmployeeApi(page, { branding: { ...branding, main_phone: null } });
    await page.goto(`/sign-in?${tenantQuery}`);
    await page.getByText("Can't sign in?").click();
    await expect(page.getByRole('link', { name: /Call/ })).toHaveCount(0);
  });
});

test.describe('several employers on the shared host', () => {
  test('the picker opens the chosen employer and My info can switch back', async ({ page }) => {
    await signIn(page);
    const log = await mockEmployeeApi(page, { links: { links: [
      { id: 42, company_name: 'Coral Kitchen', subdomain_slug: 'coral', status: 'active', former_access_until: null },
      { id: 77, company_name: 'Pelican Row Bakery (demo)', subdomain_slug: 'pelican', status: 'former', former_access_until: '2027-06-30' },
    ] } });
    await page.route('**/api/v1/public/tenant_branding**', (route) => json(route, {}, 404));
    await page.goto('/');
    await expect(page.getByRole('heading', { level: 1, name: 'Which job do you want to see?' })).toBeVisible();
    await expect(page.getByText('Former job · view until Jun 30, 2027')).toBeVisible();
    await expectPhoneBasics(page);
    await snap(page, '26-employer-picker');
    await page.getByRole('button', { name: /Pelican Row Bakery/ }).click();
    await expect(page.getByRole('heading', { level: 1, name: 'Hi, Tala' })).toBeVisible();
    expect(log.requests.filter((r) => r.path === '/employee/context').at(-1)?.headers['x-employee-link-id']).toBe('77');
    await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'My info' }).click();
    await page.getByRole('button', { name: 'Switch employer' }).click();
    await expect(page.getByRole('heading', { level: 1, name: 'Which job do you want to see?' })).toBeVisible();
  });
});

