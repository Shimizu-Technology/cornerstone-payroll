import { useState } from 'react';
import { checksApi } from '@/services/api';
import { ReportDownloadMenu } from '@/components/reports/ReportDownloadMenu';
import { ActionFeedback, useFeedbackState } from '@/components/ui/action-feedback';
import type { PayPeriod } from '@/types';

type Part = 'combined' | 'checks' | 'stubs' | 'all_stubs';

export function PayrollPreviewCard({ payPeriod, compact = false, onDownloaded }: {
  payPeriod: PayPeriod; compact?: boolean; onDownloaded?: (revision: number) => void | Promise<void>;
}) {
  const [busy, setBusy] = useState<Part | null>(null);
  const [error, setError, attempt] = useFeedbackState<string | null>(null);
  const [download, setDownload] = useState<{ runId: number; revision: number } | null>(null);
  const localRevision = download?.runId === payPeriod.id ? download.revision : undefined;
  const savedRevision = payPeriod.last_preview_download?.revision;
  const lastRevision = localRevision == null ? savedRevision : Math.max(localRevision, savedRevision ?? 0);
  const currentRevision = payPeriod.payroll_review?.revision ?? 0;
  const stale = lastRevision != null && lastRevision !== currentRevision;
  if (!['calculated', 'approved'].includes(payPeriod.status) || payPeriod.correction_status === 'voided') return null;

  const save = async (part: Part) => {
    if (busy) return;
    setBusy(part);
    setError(null);
    try {
      const result = await checksApi.previewPdf(payPeriod.id, payPeriod.company_id, part === 'combined' ? undefined : part);
      const url = URL.createObjectURL(result.blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = result.filename || `Payroll_PREVIEW_${payPeriod.pay_date}_rev${currentRevision}.pdf`;
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      window.setTimeout(() => URL.revokeObjectURL(url), 1000);
      const revision = Number(result.filename?.match(/_rev(\d+)/)?.[1] ?? currentRevision);
      setDownload({ runId: payPeriod.id, revision });
      try { await onDownloaded?.(revision); } catch {
        setError('Preview downloaded. Reopen this run to refresh its download history.');
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not download the preview. Try again.');
    } finally {
      setBusy(null);
    }
  };

  const menu = <ReportDownloadMenu className="[&_button]:min-h-11" disabled={busy !== null} buttonLabel={busy ? 'Preparing preview…' : 'Download preview'}
    formats={([
      ['combined', 'Checks and pay stubs', 'Paper checks, plus separate stubs for direct deposit and statement-only employees.'],
      ['checks', 'Checks only', 'Positive-net paper checks.'],
      ['stubs', 'Pay stubs only', 'Direct deposit and statement-only employees. Paper-check employees are excluded.'],
      ['all_stubs', 'All pay stubs (including paper-check employees)', 'A separate statement for every employee with payroll activity.'],
    ] as const).map(([part, label, description]) => ({ key: part, label, description, kind: 'pdf', loading: busy === part, onSelect: () => save(part) }))} />;
  const feedback = <>
    {stale && <p role="status" className="text-sm text-warning-900">The last preview was revision {lastRevision}; download a new one.</p>}
    {download?.runId === payPeriod.id && !stale && <p role="status" className="text-sm text-neutral-600">Downloaded preview revision {download.revision}.</p>}
    {error && <ActionFeedback tone="error" retryKey={attempt} message={error} />}
  </>;
  if (compact) return <div className="w-[10.5rem] max-w-full shrink-0 space-y-2">{menu}{feedback}</div>;
  return <section aria-label="Payroll preview" className="rounded-xl border border-primary-200 bg-primary-50 p-4 sm:p-6">
    <div className="flex flex-col items-start gap-3 sm:flex-row sm:items-center sm:justify-between">
      <div className="min-w-0">
        <h3 className="font-semibold text-neutral-950">Download preview</h3>
        <p className="mt-1 text-sm text-neutral-700">Watermarked PREVIEW, no check numbers. Send it to the client to review before you commit.</p>
      </div>
      <div className="shrink-0">{menu}</div>
    </div>
    <div className="mt-2 space-y-2">{feedback}</div>
  </section>;
}
