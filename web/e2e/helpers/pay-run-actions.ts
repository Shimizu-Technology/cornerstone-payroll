import { expect, type Page } from '@playwright/test';

export async function openPayrollActions(page: Page): Promise<void> {
  if (await page.locator('#payroll-hours').isVisible()) await openPayrollStep(page, 'hours');
  const trigger = page.getByLabel('More payroll actions', { exact: true });
  await expect(trigger).toBeVisible();
  if (!await trigger.evaluate(element => (element.parentElement as HTMLDetailsElement).open)) await trigger.click();
}

export async function showPayrollTab(page: Page, name: 'Payroll' | 'Checks & payments' | 'Reports' | 'Activity'): Promise<void> {
  await page.getByRole('navigation', { name: 'Pay-run workspace sections' }).getByRole('link', { name, exact: name !== 'Checks & payments' }).click();
}

export async function openPayrollStep(page: Page, step: 'hours' | 'results' | 'commit'): Promise<void> {
  const section = page.locator(`#payroll-${step}`);
  await expect(section).toBeVisible();
  if (!await section.evaluate(element => (element as HTMLDetailsElement).open)) await section.locator(':scope > summary').click();
}
