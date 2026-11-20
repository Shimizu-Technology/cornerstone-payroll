import { expect, test } from '@playwright/test';
for (const width of [390, 1440]) {
  test(`agency lifecycle at ${width}px (fictional transport)`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await page.goto('/');
    await page.addScriptTag({ type: 'module', content: "import { mountFilingEvidenceHarness } from '/e2e/fixtures/filing-evidence-harness.tsx'; mountFilingEvidenceHarness();" });
    async function record(agency: string, action: string) {
      const panel = page.locator(`[data-agency=${agency}]`);
      await panel.getByRole('button', { name: action, exact: true }).click();
      if (action.includes('submission')) {
        await expect(panel.getByLabel('Final file uploaded')).toHaveValue('91');
        await expect(panel.getByLabel('Receipt or agency response (optional)')).not.toHaveAttribute('required');
        if (agency === 'ssa') {
          await expect(panel.getByRole('option', { name: /out of date/ })).toHaveCount(1);
          await panel.getByLabel('Final file uploaded').selectOption('90');
          await panel.getByRole('button', { name: 'Refresh files' }).click();
          await expect(panel.getByLabel('Final file uploaded')).toHaveValue('94');
          await page.locator('main').last().screenshot({ path: `../docs/evidence/filing-record/r1-select-${width}.png` });
        }
      }
      await panel.getByLabel('Agency reference number').fill(`CONF-${agency}`);
      await panel.getByLabel('Prepared / recorded by').fill('Dana Example');
      await panel.getByRole('textbox', { name: /Notes/ }).fill('Fictional QA outcome');
      await panel.getByRole('button', { name: 'Save evidence', exact: true }).click();
      await expect(panel.getByRole('button', { name: 'Saving evidence…' })).toBeDisabled();
      await expect(panel.locator('form')).toHaveCount(0);
    }
    await record('ssa', 'Record submission');
    await record('drt', 'Record submission');
    await record('ssa', 'Record acceptance');
    await record('drt', 'Record rejection');
    await record('drt', 'Record resubmission');
    await expect(page.locator('[data-agency=ssa]')).toContainText('Agency acceptance recorded');
    await expect(page.locator('[data-agency=drt]')).toContainText('Submitted; waiting');
    await expect(page.locator('[data-agency=drt] ol li')).toHaveCount(3);
    await page.locator('main').last().screenshot({ path: `../docs/evidence/filing-record/lifecycle-${width}.png` });
    expect(await page.locator('main').last().evaluate((el) => el.scrollWidth <= el.clientWidth)).toBe(true);
  });
}
