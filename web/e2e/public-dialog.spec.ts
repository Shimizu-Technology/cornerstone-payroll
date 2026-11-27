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

test('Clerk step-up modal opened over a Dialog remains interactive while background stays inert', async ({ page }): Promise<void> => {
  await page.goto('/');
  await page.addScriptTag({
    type: 'module',
    content: `import { mountStepUpDialogHarness } from '${harnessModule}'; mountStepUpDialogHarness();`,
  });

  const appDialog = page.getByRole('dialog', { name: 'Step-up inside dialog test' });
  await expect(appDialog).toBeVisible();

  // The page behind the dialog is marked inert.
  const backgroundIsInert = await page.getByTestId('background-page-btn').evaluate(
    (el) => Boolean(el.closest('[inert]')),
  );
  expect(backgroundIsInert).toBe(true);

  await appDialog.getByRole('button', { name: 'Turn on' }).click();

  const clerkModal = page.getByRole('dialog', { name: 'Verification required' });
  await expect(clerkModal).toBeVisible();
  const clerkIsInert = await clerkModal.evaluate((el) => Boolean(el.closest('[inert]')));
  expect(clerkIsInert).toBe(false);

  const passwordInput = clerkModal.getByLabel('Clerk password');
  await passwordInput.click();
  await passwordInput.fill('test-password-123');
  await expect(passwordInput).toHaveValue('test-password-123');

  // Escape while focused in the Clerk modal must not dismiss the underlying dialog.
  await page.keyboard.press('Escape');
  await expect(appDialog).toBeVisible();

  await clerkModal.getByRole('button', { name: 'Continue' }).click();
  await expect(clerkModal).toHaveCount(0);
  await expect(appDialog.getByTestId('stepup-status')).toHaveText('Verified: test-password-123');
});
