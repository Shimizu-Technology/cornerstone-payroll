import { expect, test } from '@playwright/test';

const viewports = [
  { name: 'desktop', width: 1280, height: 800 },
  { name: 'narrow', width: 375, height: 812 },
];

for (const { name, width, height } of viewports) {
  test(`an old invitation offers a new invite or sign-in at ${name} width`, async ({ page }) => {
    await page.setViewportSize({ width, height });
    await page.route('**/api/v1/auth/me', route => route.fulfill({ status: 401, json: { error: 'Not authenticated' } }));

    await page.goto('/invite?token=fictional-legacy-invitation');
    await expect(page.getByRole('heading', { name: 'This invitation link has expired' })).toBeVisible();
    await expect(page.getByText(/send a new invitation/)).toBeVisible();
    expect(await page.evaluate(() => localStorage.getItem('cpr_invite_token'))).toBeNull();

    await page.getByRole('link', { name: 'Go to sign in' }).click();
    await expect(page).toHaveURL(/\/login$/);
  });
}
