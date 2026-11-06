import { createRoot } from 'react-dom/client';
import { PdfPreview } from '@/components/documents/PdfPreview';

export async function mountPdfPreviewHarness(): Promise<void> {
  const response = await fetch('/synthetic-preview.pdf');
  const blob = await response.blob();
  const container = document.createElement('div');
  document.body.appendChild(container);
  const root = createRoot(container);
  root.render(<PdfPreview artifact={{ blob, filename: 'synthetic-preview.pdf', title: 'Synthetic PDF preview' }} onClose={() => root.unmount()} />);
}
