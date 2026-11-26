import { formatGuamDate } from '@/lib/utils';
import type { ReactNode } from 'react';
import type { ClientDocument } from '@/services/api';
import { Button } from '@/components/ui/button';

// Pass openGroups/onToggleGroup when the page reloads its list after an action,
// so a group the user expanded stays open across the reload.
export function SubmissionDocumentGroups({ documents, onPreview, onDownload, allowArchived = false, extraActions, openGroups, onToggleGroup }: {
  openGroups?: ReadonlySet<number>;
  onToggleGroup?: (id: number, open: boolean) => void;
  allowArchived?: boolean;
  documents: ClientDocument[];
  onPreview: (document: ClientDocument) => Promise<void>;
  onDownload: (document: ClientDocument) => Promise<void>;
  extraActions?: (document: ClientDocument) => ReactNode;
}) {
  const groups = new Map<number, { label: string; sentAt?: string | null; files: ClientDocument[] }>();
  for (const document of documents) {
    for (const group of document.submission_groups || []) {
      if (!groups.has(group.id)) groups.set(group.id, { label: group.label, sentAt: group.submitted_at, files: [] });
      groups.get(group.id)!.files.push(document);
    }
  }
  return <div className="space-y-3">{[...groups].map(([id, group]) => <details key={id} open={openGroups?.has(id)} onToggle={event => onToggleGroup?.(id, event.currentTarget.open)} className="rounded-lg border border-neutral-200 p-3">
    <summary className="min-h-11 cursor-pointer break-words font-semibold">{group.label}
      <span className="ml-2 text-sm font-normal text-neutral-600">{group.files.length} {group.files.length === 1 ? 'file' : 'files'} · sent {formatGuamDate(group.sentAt || group.files[0].created_at)}</span>
    </summary>
    <ul className="divide-y divide-neutral-100">{group.files.map(file => <li key={file.id} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center sm:justify-between">
      <span className="min-w-0 text-sm">
        <span className="block break-all">{file.file_name}</span>
        <span className="block text-neutral-600">{file.uploaded_by_name || '—'} · {formatGuamDate(file.created_at)}</span>
        {file.archived_at && <span className="block font-medium text-neutral-600">File archived · kept as evidence</span>}
      </span>
      <div className="flex shrink-0 flex-wrap gap-2">
        <Button disabled={Boolean(file.archived_at) && !allowArchived} size="sm" variant="outline" className="min-h-11 sm:min-h-0 sm:pointer-coarse:min-h-11" onClick={() => void onPreview(file)} aria-label={`Preview ${file.file_name}`}>Preview</Button>
        <Button disabled={Boolean(file.archived_at) && !allowArchived} size="sm" variant="outline" className="min-h-11 sm:min-h-0 sm:pointer-coarse:min-h-11" onClick={() => void onDownload(file)} aria-label={`Download ${file.file_name}`}>Download</Button>
        {extraActions?.(file)}
      </div>
    </li>)}</ul>
  </details>)}</div>;
}
