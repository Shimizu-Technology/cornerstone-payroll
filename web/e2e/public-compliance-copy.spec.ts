import { expect, test } from '@playwright/test';

test('public product copy uses the current Federal Form 941 terminology', async ({ page }) => {
  await page.goto('/');

  await expect(page.getByRole('heading', { name: /Guam payroll, organized from pay run to filing/i })).toBeVisible();
  await expect(page.getByText('Form 941', { exact: true })).toBeVisible();
  await expect(page.getByText(/Federal Form 941/).first()).toBeVisible();
  await expect(page.getByText(/941-GU/)).toHaveCount(0);
});
