import { useState } from 'react';
import { reportsApi } from '@/services/api';
import { Button } from '@/components/ui/button';

export function W2FilingFileRow({
  companyId,
  year,
  ready,
  canDownloadEfile = false,
}: {
  companyId: number;
  year: number;
  ready: boolean;
  canDownloadEfile?: boolean;
}) {
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function download(pdf: boolean) {
    setBusy(true);
    setError('');
    try {
      const result = await reportsApi.wageFilingFile(
        year,
        companyId,
        ready ? 'final' : 'draft',
        pdf,
      );
      const url = URL.createObjectURL(result.blob);
      const link = document.createElement('a');
      link.href = url;
      link.download =
        result.filename ??
        `${companyId}-${year}-${ready ? 'FINAL' : 'DRAFT'}-${pdf ? 'W3SS.pdf' : 'EFW2.txt'}`;
      link.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Download failed.');
    } finally {
      setBusy(false);
    }
  }
  return (
    <section
      className="space-y-3 rounded-xl border border-neutral-200 bg-white p-4"
      aria-label="W-2 e-file"
    >
      <h3 className="font-semibold">W-2 e-file</h3>
      <p className="text-sm text-neutral-700">
        {ready
          ? 'Mark W-2s ready again if you change client or wage details.'
          : 'Test file — don’t upload as your filing. Mark W-2s ready before downloading a final file.'}
      </p>
      {!ready && (
        <label className="flex min-h-11 items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={confirmed}
            onChange={(e) => setConfirmed(e.target.checked)}
          />
          Test file only — check it in SSA's AccuWage, but don't upload it as your filing.
        </label>
      )}
      {!canDownloadEfile && <p className="text-sm text-neutral-700">Needs client-management access (contains full SSNs).</p>}
      <div className="flex flex-wrap gap-2">
        <Button
          disabled={busy || !canDownloadEfile || (!ready && !confirmed)}
          onClick={() => void download(false)}
        >
          Download {ready ? '' : 'draft '}W-2 e-file
        </Button>
        <Button
          variant="outline"
          disabled={busy || (!ready && !confirmed)}
          onClick={() => void download(true)}
        >
          W-3SS totals (for your records)
        </Button>
      </div>
      <p className="text-xs text-neutral-600">
        One file for both SSA (BSO) and GuamTax. Contains full SSNs — store it securely.
      </p>
      {error && (
        <p role="alert" className="text-sm text-danger-700">
          {error}
        </p>
      )}
    </section>
  );
}
