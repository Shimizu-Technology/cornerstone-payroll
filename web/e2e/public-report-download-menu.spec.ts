import { expect, test, type Page } from '@playwright/test';

async function mount(page: Page, modal = false, count = 3): Promise<void> {
  await page.goto('/');
  await page.addScriptTag({
    type: 'module',
    content: `import { mountReportDownloadMenuHarness } from '/e2e/fixtures/report-download-menu-harness.tsx'; mountReportDownloadMenuHarness(${modal}, ${count});`,
  });
  await expect(page.getByRole('button', { name: 'Download report', exact: true })).toBeVisible();
}

for (const modal of [false, true]) {
  test(`all formats remain clickable above clipping cards${modal ? ' in a modal preview' : ''}`, async ({ page }) => {
    await mount(page, modal);
    for (const format of ['PDF', 'Excel', 'CSV']) {
      await page.getByRole('button', { name: 'Download report', exact: true }).click();
      // A real pointer click detects the original occlusion and overflow regression.
      await page.getByRole('menuitem', { name: new RegExp(`^${format}`) }).click();
      await expect(page.getByTestId('export-result')).toHaveText(format);
      await expect(page.getByRole('menu')).toHaveCount(0);
      await expect(page.getByRole('button', { name: 'Download report', exact: true })).toBeFocused();
    }
  });
}

test('keyboard navigation, selection, Escape, outside click and Tab preserve focus', async ({ page }) => {
  await mount(page);
  const trigger = page.getByRole('button', { name: 'Download report', exact: true });
  const pdf = page.getByRole('menuitem', { name: /^PDF/ });
  const csv = page.getByRole('menuitem', { name: /^CSV/ });
  await trigger.focus();
  await page.keyboard.press('ArrowUp');
  await expect(csv).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(pdf).toBeFocused();
  await page.keyboard.press('End');
  await expect(csv).toBeFocused();
  await page.keyboard.press('Home');
  await expect(pdf).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('Enter');
  await expect(page.getByTestId('export-result')).toHaveText('Excel');
  await expect(trigger).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('Escape');
  await expect(page.getByRole('menu')).toHaveCount(0);
  await expect(trigger).toBeFocused();
  await page.keyboard.press('Enter');
  await page.keyboard.press('Tab');
  await expect(page.getByRole('textbox', { name: 'After export', exact: true })).toBeFocused();
  await trigger.click();
  await page.keyboard.press('Shift+Tab');
  await expect(page.getByRole('textbox', { name: 'Before export', exact: true })).toBeFocused();
  await trigger.click();
  await page.getByRole('textbox', { name: 'Outside menu', exact: true }).click();
  await expect(page.getByRole('menu')).toHaveCount(0);
  await expect(page.getByRole('textbox', { name: 'Outside menu', exact: true })).toBeFocused();
});

test('Escape dismisses the export menu before its containing dialog', async ({ page }) => {
  await mount(page, true);
  await page.getByRole('button', { name: 'Download report', exact: true }).click();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('menu')).toHaveCount(0);
  await expect(page.getByRole('dialog', { name: 'Report preview' })).toBeVisible();
  await page.getByRole('button', { name: 'Download report', exact: true }).click();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('textbox', { name: 'After export', exact: true })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog')).toHaveCount(0);
});

test('menu flips and clamps in a narrow viewport, scrolls every format into reach, and follows nested scrolling', async ({ page }) => {
  await page.setViewportSize({ width: 240, height: 260 });
  await mount(page);
  await page.getByTestId('anchor-space').evaluate((element) => { element.style.height = '100px'; });
  const trigger = page.getByRole('button', { name: 'Download report', exact: true });
  await trigger.click();
  const menu = page.getByRole('menu');
  const bounds = await menu.boundingBox();
  const anchor = await trigger.boundingBox();
  expect(bounds).not.toBeNull();
  expect(anchor).not.toBeNull();
  expect(bounds!.x).toBeGreaterThanOrEqual(8);
  expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(232);
  expect(bounds!.y).toBeGreaterThanOrEqual(8);
  expect(bounds!.y + bounds!.height).toBeLessThan(anchor!.y);
  expect(await menu.evaluate((element) => element.scrollHeight > element.clientHeight)).toBe(true);
  await page.keyboard.press('End');
  await expect(page.getByRole('menuitem', { name: /^CSV/ })).toBeFocused();
  await page.getByRole('menuitem', { name: /^CSV/ }).click();
  await expect(page.getByTestId('export-result')).toHaveText('CSV');

  await page.setViewportSize({ width: 600, height: 700 });
  await page.getByTestId('scroll-area').evaluate((element) => { element.scrollTop = 0; });
  await trigger.click();
  await expect.poll(async () => {
    const box = await menu.boundingBox();
    const button = await trigger.boundingBox();
    return Math.abs(box!.y - button!.y - button!.height - 8);
  }).toBeLessThan(2);
  const before = await menu.boundingBox();
  const scrollDelta = await page.getByTestId('scroll-area').evaluate((element) => {
    const previous = element.scrollTop;
    element.scrollTop = previous >= 35 ? previous - 35 : previous + 35;
    return element.scrollTop - previous;
  });
  expect(Math.abs(scrollDelta)).toBe(35);
  await expect.poll(async () => Math.abs((await menu.boundingBox())!.y - before!.y + scrollDelta)).toBeLessThan(3);
  await page.setViewportSize({ width: 240, height: 400 });
  await expect.poll(async () => { const box = await menu.boundingBox(); return box!.x + box!.width; }).toBeLessThanOrEqual(232);
  await page.getByRole('menuitem', { name: /^Excel/ }).click();
  await expect(page.getByTestId('export-result')).toHaveText('Excel');
});

test('single-format exports run directly and disabled/loading states prevent downloads', async ({ page }) => {
  await mount(page, false, 1);
  const trigger = page.getByRole('button', { name: 'Download report', exact: true });
  await trigger.click();
  await expect(page.getByTestId('export-result')).toHaveText('PDF');
  await expect(page.getByRole('menu')).toHaveCount(0);
  await page.getByRole('button', { name: 'Toggle disabled', exact: true }).click();
  await expect(trigger).toBeDisabled();
  await page.getByRole('button', { name: 'Toggle disabled', exact: true }).click();
  await page.getByRole('button', { name: 'Toggle loading', exact: true }).click();
  await expect(trigger).toBeDisabled();
  await page.getByRole('button', { name: 'Toggle loading', exact: true }).click();
  await expect(trigger).toBeEnabled();
});

test('multiple-format menu cannot open while disabled or loading', async ({ page }) => {
  await mount(page);
  const trigger = page.getByRole('button', { name: 'Download report', exact: true });
  for (const name of ['Toggle disabled', 'Toggle loading']) {
    await page.getByRole('button', { name, exact: true }).click();
    await expect(trigger).toBeDisabled();
    await expect(page.getByRole('menu')).toHaveCount(0);
    await page.getByRole('button', { name, exact: true }).click();
    await expect(trigger).toBeEnabled();
  }
});
