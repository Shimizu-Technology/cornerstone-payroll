import { PdfPreview, type PdfArtifact } from '@/components/documents/PdfPreview';
import { useState } from 'react';
import { Button } from '@/components/ui/button';
import { clientPayStubsApi } from '@/services/api';

export function ClientPayStubButton({
  itemId,
  compact = false,
  employeeName,
}: {
  itemId: number;
  compact?: boolean;
  employeeName?: string;
}) {
  const [artifact, setArtifact] = useState<PdfArtifact | null>(null);
  const [busyAction, setBusyAction] = useState<'preview' | 'download' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const busy = busyAction !== null;
  const download = async (preview = false) => {
    setBusyAction(preview ? 'preview' : 'download');
    setError(null);
    try {
      const file = await clientPayStubsApi.download(itemId);
      if (preview) {
        setArtifact({ blob: file.blob, filename: file.filename || `paystub_${itemId}.pdf`, title: 'Pay stub' });
        return;
      }
      const url = URL.createObjectURL(file.blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = file.filename || `paystub_${itemId}.pdf`;
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      window.setTimeout(() => URL.revokeObjectURL(url), 100);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Could not download pay stub. Try again.');
    } finally {
      setBusyAction(null);
    }
  };
  const buttonClass = compact
    ? 'min-h-11 sm:min-h-7 sm:px-2.5 sm:py-0.5 sm:text-xs sm:pointer-coarse:min-h-11'
    : 'min-h-11 sm:min-h-9 sm:pointer-coarse:min-h-11';
  const viewText = compact ? 'View stub' : 'View pay stub';
  const downloadText = compact ? 'Download stub' : 'Download pay stub';
  const viewAriaLabel = busyAction === 'preview'
    ? 'Preparing pay stub'
    : employeeName ? `${viewText} for ${employeeName}` : undefined;
  const downloadAriaLabel = busyAction === 'download'
    ? 'Preparing pay stub'
    : employeeName ? `${downloadText} for ${employeeName}` : undefined;
  return <div className={compact ? 'mt-1 flex flex-wrap gap-1.5' : 'flex flex-wrap gap-2'}>
    <span className="sr-only" role="status" aria-live="polite">{busy ? 'Preparing pay stub' : ''}</span>
    <Button variant="outline" size="sm" className={buttonClass} disabled={busy} aria-label={viewAriaLabel} onClick={() => void download(true)}>
      {busyAction === 'preview' ? 'Preparing…' : viewText}
    </Button>
    <Button variant="outline" size="sm" className={buttonClass} disabled={busy} aria-label={downloadAriaLabel} onClick={() => void download()}>
      {busyAction === 'download' ? 'Preparing…' : downloadText}
    </Button>
    <PdfPreview artifact={artifact} onClose={() => setArtifact(null)} />
    {error && <p role="alert" className="w-full text-sm text-red-700">{error}</p>}
  </div>;
}
