import { PdfPreview, type PdfArtifact } from '@/components/documents/PdfPreview';
import { useState } from 'react';
import { Button } from '@/components/ui/button';
import { clientPayStubsApi } from '@/services/api';

export function ClientPayStubButton({ itemId, compact = false }: { itemId: number; compact?: boolean }) {
  const [artifact, setArtifact] = useState<PdfArtifact | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const download = async (preview = false) => {
    setBusy(true);
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
      setBusy(false);
    }
  };
  const buttonClass = compact
    ? 'min-h-11 sm:min-h-7 sm:px-2.5 sm:py-0.5 sm:text-xs sm:pointer-coarse:min-h-11'
    : 'min-h-11 sm:min-h-9 sm:pointer-coarse:min-h-11';
  return <div className={compact ? 'mt-1 flex flex-wrap gap-1.5' : 'flex flex-wrap gap-2'}>
    <Button variant="outline" size="sm" className={buttonClass} disabled={busy} aria-label="View pay stub" onClick={() => void download(true)}>
      {compact ? 'View stub' : 'View pay stub'}
    </Button>
    <Button variant="outline" size="sm" className={buttonClass} disabled={busy} aria-label="Download pay stub" onClick={() => void download()}>
      {busy ? 'Preparing…' : compact ? 'Download' : 'Download pay stub'}
    </Button>
    <PdfPreview artifact={artifact} onClose={() => setArtifact(null)} />
    {error && <p role="alert" className="w-full text-sm text-red-700">{error}</p>}
  </div>;
}
