import { expect, test } from '@playwright/test';

// Visible shapes make a completed canvas paint observable with the real PDF
// engine and worker, rather than a mocked loading task or a blank page.
function twoPagePdf(): Buffer {
  const shapes = ['1 0 0 rg 20 20 160 160 re f', '0 0 1 rg 20 20 160 160 re f'];
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R >>',
    `<< /Length ${shapes[0].length} >>\nstream\n${shapes[0]}\nendstream`,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 6 0 R >>',
    `<< /Length ${shapes[1].length} >>\nstream\n${shapes[1]}\nendstream`,
  ];
  let contents = '%PDF-1.4\n';
  const offsets = [0];
  objects.forEach((object, index) => {
    offsets.push(Buffer.byteLength(contents));
    contents += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const xref = Buffer.byteLength(contents);
  contents += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  offsets.slice(1).forEach((offset) => { contents += `${String(offset).padStart(10, '0')} 00000 n \n`; });
  contents += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(contents);
}

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
