import { expect, test } from '@playwright/test';

const payPeriodId = process.env.E2E_PAY_PERIOD_ID;
const storageState = process.env.E2E_AUTH_STORAGE_STATE;

test.describe('authenticated payroll workflow smoke test', () => {
  test.skip(!payPeriodId || !storageState, 'Set E2E_PAY_PERIOD_ID and E2E_AUTH_STORAGE_STATE for a staging payroll smoke test.');
  test.use({ storageState: storageState || { cookies: [], origins: [] } });

  test('opens a pay period and exposes review and report controls', async ({ page }) => {
    await page.goto(`/pay-periods/${payPeriodId}`);

    await expect(page.getByRole('heading', { name: /Pay Period:/i })).toBeVisible();
    await expect(page.getByText(/Reports & Documents/i)).toBeVisible();
    await expect(page.getByRole('button', { name: /View/i }).first()).toBeVisible();
  });
});
