import { expect, test } from '@playwright/test';
import { twoPagePdf } from './fixtures/synthetic-pdf';

// Visible shapes make a completed canvas paint observable with the real PDF
// engine and worker, rather than a mocked loading task or a blank page.

for (const viewport of [{ width: 1280, height: 900 }, { width: 390, height: 844 }]) {
  test(`real PDF worker paints and navigates both pages at ${viewport.width}px`, async ({ page }) => {
    await page.setViewportSize(viewport);
    let downloads = 0;
    let workers = 0;
    page.on('download', () => { downloads += 1; });
    page.on('worker', () => { workers += 1; });
    await page.route('**/synthetic-preview.pdf', (route) => route.fulfill({ contentType: 'application/pdf', body: twoPagePdf() }));
    await page.goto('/');
    await page.addScriptTag({ type: 'module', content: "import { mountPdfPreviewHarness } from '/e2e/fixtures/pdf-preview-harness.tsx'; await mountPdfPreviewHarness();" });
    const dialog = page.getByRole('dialog', { name: 'Synthetic PDF preview' });
    const painted = async (number: number, color: number[]) => {
      const canvas = dialog.getByLabel(`Page ${number} preview`);
      await expect(canvas).toBeVisible();
      await expect(canvas).toHaveAttribute('aria-hidden', 'false');
      const pixel = await canvas.evaluate((element) => Array.from((element as HTMLCanvasElement).getContext('2d')!.getImageData(175, 175, 1, 1).data));
      expect(pixel).toEqual(color);
      await expect(dialog.getByRole('alert')).toHaveCount(0);
    };
    await expect(dialog.getByText('Page 1 of 2')).toBeVisible();
    await painted(1, [255, 0, 0, 255]);
    expect(workers).toBeGreaterThan(0);
    await dialog.getByRole('button', { name: 'Next' }).click();
    await expect(dialog.getByText('Page 2 of 2')).toBeVisible();
    await painted(2, [0, 0, 255, 255]);
    await dialog.getByRole('button', { name: 'Previous' }).click();
    await painted(1, [255, 0, 0, 255]);
    await dialog.getByRole('button', { name: 'Zoom in' }).click();
    await expect(dialog.getByRole('button', { name: 'Fit page' })).toBeVisible();
    await dialog.getByRole('button', { name: 'Fit page' }).click();
    await dialog.getByRole('button', { name: 'Close PDF preview' }).click();
    await expect(dialog).toHaveCount(0);
    expect(downloads).toBe(0);
  });
}
