import { expect, test } from '@playwright/test';

test('public product copy uses the current Federal Form 941 terminology', async ({ page }) => {
  await page.goto('/');

  await expect(page.getByRole('heading', { name: /Guam payroll, organized from intake to year-end preparation/i })).toBeVisible();
  await expect(page.getByText('Form 941', { exact: true })).toBeVisible();
  await expect(page.getByText(/Federal Form 941/).first()).toBeVisible();
  await expect(page.getByText(/941-GU/)).toHaveCount(0);
});

test('phone home keeps a product navigation action in the first screen', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 700 });
  await page.goto('/');

  const explore = page.getByRole('link', { name: 'Explore the workspace' });
  await expect(explore).toBeVisible();
  const actionBounds = await explore.boundingBox();
  const heroBounds = await page.locator('#workflow').boundingBox();
  expect(actionBounds).not.toBeNull();
  expect(heroBounds).not.toBeNull();
  expect(actionBounds!.y).toBeLessThan(700);
  expect(heroBounds!.height).toBeLessThan(900);
});
