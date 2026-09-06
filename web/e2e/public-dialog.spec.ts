import { expect, test } from '@playwright/test';

const harnessModule = '/e2e/fixtures/dialog-harness.tsx';

test('shared Dialog applies the latest Escape policy and handler while open', async ({ page }): Promise<void> => {
  await page.goto('/');
  await page.addScriptTag({
    type: 'module',
    content: `import { mountLivePropDialogHarness } from '${harnessModule}'; mountLivePropDialogHarness();`,
  });

  const liveDialog = page.getByRole('dialog', { name: 'Shared dialog live-prop test' });
  await expect(liveDialog).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(liveDialog.getByTestId('dialog-result')).toHaveText('No close requested');

  await liveDialog.getByRole('button', { name: 'Allow Escape' }).click();
  await page.keyboard.press('Escape');
  await expect(liveDialog.getByTestId('dialog-result')).toHaveText('Latest handler called');

  await page.addScriptTag({
    type: 'module',
    content: `import { mountDefaultDialogHarness } from '${harnessModule}'; mountDefaultDialogHarness();`,
  });
  const defaultDialog = page.getByRole('dialog', { name: 'Shared dialog default test' });
  await expect(defaultDialog).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(defaultDialog.getByTestId('dialog-result')).toHaveText('Default handler called');
});
