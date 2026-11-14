import { PdfPreview, type PdfArtifact } from '@/components/documents/PdfPreview';
import { useState } from 'react';
import { Button } from '@/components/ui/button';
import { clientPayStubsApi } from '@/services/api';

export function ClientPayStubButton({ itemId }: { itemId: number }) {
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
  return <div className="space-y-2">
    <Button variant="outline" size="sm" disabled={busy} onClick={() => void download(true)}>View pay stub</Button>
    <Button variant="outline" size="sm" disabled={busy} onClick={() => void download()}>{busy ? 'Preparing…' : 'Download pay stub'}</Button>
    <PdfPreview artifact={artifact} onClose={() => setArtifact(null)} />
    {error && <p role="alert" className="text-sm text-red-700">{error}</p>}
  </div>;
}
