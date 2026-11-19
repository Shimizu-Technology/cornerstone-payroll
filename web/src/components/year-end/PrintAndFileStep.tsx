import { useState, type ReactElement } from 'react';
import { Download, RefreshCw, ShieldAlert } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { yearEndApi } from '@/services/api';
import { saveBlob } from '@/lib/save-blob';
import type { ActiveYearEndStep, YearEndChecklist, YearEndDocument } from '@/lib/year-end';
import { useStillMounted } from './useStillMounted';

/** The year's documents to print, keep or send, one row each. */
export function PrintAndFileStep({ checklist, step }: {
  checklist: YearEndChecklist;
  step: ActiveYearEndStep<'print_and_file'>;
}): ReactElement {
  // The step summary says when these are drafts; each row carries a badge.
  return (
    <ul className="divide-y divide-neutral-200 rounded-xl border border-neutral-200">
      {step.data.documents.map((document) => (
        <DocumentRow key={document.key} document={document} companyId={checklist.company.id} />
      ))}
    </ul>
  );
}

function DocumentRow({ document, companyId }: { document: YearEndDocument; companyId: number }): ReactElement {
  const stillMounted = useStillMounted();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const headingId = `year-end-document-${document.key}`;

  async function download() {
    setLoading(true);
    setError(null);
    try {
      const file = await yearEndApi.downloadDocument(document.download, companyId);
      if (!stillMounted()) return;
      saveBlob(file.blob, file.filename || `${document.key}.${document.format}`);
    } catch (err) {
      if (stillMounted()) setError(err instanceof Error && err.message ? err.message : 'The file could not be downloaded.');
    } finally {
      if (stillMounted()) setLoading(false);
    }
  }

  return (
    <li className="flex flex-col gap-3 p-4 sm:flex-row sm:items-start sm:justify-between sm:gap-6" aria-labelledby={headingId}>
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <h3 id={headingId} className="font-semibold text-neutral-950">{document.title}</h3>
          {document.available && document.draft && <Badge variant="warning">Draft</Badge>}
        </div>
        <p className="mt-1 text-sm text-neutral-800">{document.description}</p>
        <p className="mt-1 text-sm leading-6 text-neutral-600">{document.detail}</p>
        {document.contains_full_ssn && (
          <p className="mt-2 flex gap-1.5 text-sm text-neutral-700">
            <ShieldAlert className="mt-0.5 h-4 w-4 shrink-0 text-warning-700" aria-hidden="true" />
            Full SSNs. Keep the file and the printout somewhere secure.
          </p>
        )}
        {!document.available && document.unavailable_reason && (
          <p className="mt-2 text-sm text-neutral-700">{document.unavailable_reason}</p>
        )}
        {error && (
          <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 p-3 text-sm text-danger-800">
            <p>{error}</p>
            <Button size="sm" variant="outline" className="mt-2 w-full sm:w-auto" onClick={() => void download()} disabled={loading}>
              <RefreshCw className="mr-1.5 h-4 w-4" aria-hidden="true" />Try again
            </Button>
          </div>
        )}
      </div>
      <Button
        className="w-full shrink-0 sm:w-auto"
        variant={document.draft ? 'outline' : 'primary'}
        onClick={() => void download()}
        disabled={!document.available}
        loading={loading}
        loadingLabel="Preparing PDF…"
        aria-describedby={headingId}
      >
        <Download className="mr-1.5 h-4 w-4" aria-hidden="true" />{document.draft ? 'Download draft' : 'Download PDF'}
      </Button>
    </li>
  );
}
