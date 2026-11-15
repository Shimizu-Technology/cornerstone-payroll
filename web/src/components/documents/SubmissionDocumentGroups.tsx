import type { ClientDocument } from '@/services/api';
import { Button } from '@/components/ui/button';

export function SubmissionDocumentGroups({ documents, onPreview, onDownload, allowArchived = false }: {
  allowArchived?: boolean;
  documents: ClientDocument[];
  onPreview: (document: ClientDocument) => Promise<void>;
  onDownload: (document: ClientDocument) => Promise<void>;
}) {
  const groups = new Map<number, { label: string; files: ClientDocument[] }>();
  for (const document of documents) {
    for (const group of document.submission_groups || []) {
      if (!groups.has(group.id)) groups.set(group.id, { label: group.label, files: [] });
      groups.get(group.id)!.files.push(document);
    }
  }
  return <div className="space-y-3">{[...groups].map(([id, group]) => <details key={id} className="rounded-lg border border-neutral-200 p-3">
    <summary className="min-h-11 cursor-pointer break-words font-semibold">{group.label}</summary>
    <ul className="divide-y divide-neutral-100">{group.files.map(file => <li key={file.id} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center sm:justify-between">
      <span className="min-w-0 break-all text-sm">{file.file_name}</span>
      <div className="flex shrink-0 gap-2">
        {file.preview_available && <Button disabled={Boolean(file.archived_at) && !allowArchived} size="sm" variant="outline" onClick={() => void onPreview(file)} aria-label={`Preview ${file.file_name}`}>Preview</Button>}
        <Button disabled={Boolean(file.archived_at) && !allowArchived} size="sm" variant="outline" onClick={() => void onDownload(file)} aria-label={`Download ${file.file_name}`}>Download</Button>
      </div>
    </li>)}</ul>
  </details>)}</div>;
}
