import { expect, type Page } from '@playwright/test';

export async function openPayrollActions(page: Page): Promise<void> {
  const trigger = page.getByLabel('More payroll actions', { exact: true });
  await expect(trigger).toBeVisible();
  if (!await trigger.evaluate(element => (element.parentElement as HTMLDetailsElement).open)) await trigger.click();
}

export async function showPayrollTab(page: Page, name: 'Payroll' | 'Checks & payments' | 'Reports' | 'Activity'): Promise<void> {
  await page.getByRole('navigation', { name: 'Pay-run workspace sections' }).getByRole('link', { name, exact: name !== 'Checks & payments' }).click();
}
