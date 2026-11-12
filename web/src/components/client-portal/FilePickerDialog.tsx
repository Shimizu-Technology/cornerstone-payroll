import { useEffect, useId, useRef, useState, type ReactElement } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import type { ClientDocument } from '@/services/api';
import { fileTypeLabel, formatFileSize, type PortalDocumentsApi } from './portalFiles';

const PAGE_SIZE = 20;

// Searches the company's whole library on the server, not just loaded pages.
// The server returns only files that can be attached: shared with the
// client, not archived, and not held by a safety check.
export function FilePickerDialog({ open, onOpenChange, api, selectedIds, maxSelectable, onChoose }: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  api: PortalDocumentsApi;
  selectedIds: number[];
  maxSelectable: number;
  onChoose: (documents: ClientDocument[]) => void;
}): ReactElement {
  const listId = useId();
  const [search, setSearch] = useState('');
  const [results, setResults] = useState<ClientDocument[]>([]);
  const [page, setPage] = useState(1);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [picked, setPicked] = useState<Map<number, ClientDocument>>(new Map());
  const [retry, setRetry] = useState(0);
  const version = useRef(0);

  useEffect(() => {
    if (!open) return;
    setPicked(new Map());
  }, [open]);

  // The search the shown results belong to. A changed search hides Load
  // more until its first page arrives, and retires any page in flight.
  const resultsTerm = useRef('');
  useEffect(() => {
    if (!open) return;
    const request = ++version.current;
    setHasMore(false);
    const term = search.trim();
    const timer = setTimeout(() => {
      setLoading(true);
      setError(null);
      api.list({ search: term || undefined, attachable: true, page: 1, per_page: PAGE_SIZE })
        .then(response => {
          if (request !== version.current) return;
          resultsTerm.current = term;
          setResults(response.data);
          setPage(1);
          setHasMore((response.meta?.total_pages ?? 1) > 1);
        })
        .catch(() => { if (request === version.current) setError('Could not search files. Check your connection and try again.'); })
        .finally(() => { if (request === version.current) setLoading(false); });
    }, 250);
    return () => clearTimeout(timer);
  }, [api, open, search, retry]);

  const loadMore = async (): Promise<void> => {
    const request = ++version.current;
    setLoading(true);
    setError(null);
    try {
      const response = await api.list({ search: resultsTerm.current || undefined, attachable: true, page: page + 1, per_page: PAGE_SIZE });
      if (request !== version.current) return;
      setResults(current => [...current, ...response.data.filter(row => !current.some(existing => existing.id === row.id))]);
      setPage(page + 1);
      setHasMore((response.meta?.total_pages ?? page + 1) > page + 1);
    } catch {
      if (request === version.current) setError('Could not load more files. Try again.');
    } finally {
      if (request === version.current) setLoading(false);
    }
  };

  const available = maxSelectable - picked.size;
  const toggle = (document: ClientDocument): void => {
    setPicked(current => {
      const next = new Map(current);
      if (next.has(document.id)) next.delete(document.id);
      else if (next.size < maxSelectable) next.set(document.id, document);
      return next;
    });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[min(90vh,90dvh)] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Choose files to attach</DialogTitle>
          <DialogDescription>Search every shared file by title or file name. Staff-only and archived files are not listed.</DialogDescription>
        </DialogHeader>
        <Input label="Search files" type="search" value={search} onChange={event => setSearch(event.target.value)} placeholder="For example: timesheet" aria-controls={listId} autoFocus />
        {error && <div role="alert" className="mt-3 flex flex-wrap items-center gap-2 text-sm text-danger-700"><span>{error}</span><Button type="button" size="sm" variant="outline" onClick={() => setRetry(value => value + 1)}>Try again</Button></div>}
        <p className="mt-3 text-sm text-neutral-600" aria-live="polite">
          {loading ? 'Searching…' : results.length ? `${results.length} ${results.length === 1 ? 'file' : 'files'} shown` : 'No matching files'}
          {maxSelectable <= 0 ? ' · This message already has the most files it can take.' : ''}
        </p>
        <ul id={listId} className="mt-2 max-h-80 divide-y divide-neutral-100 overflow-y-auto rounded-lg border border-neutral-200">
          {results.map(document => {
            const already = selectedIds.includes(document.id);
            const checked = already || picked.has(document.id);
            const disabled = already || (!picked.has(document.id) && available <= 0);
            return (
              <li key={document.id}>
                <label className={`flex min-h-11 cursor-pointer items-start gap-3 px-3 py-2 text-sm ${disabled ? 'cursor-not-allowed opacity-70' : 'hover:bg-neutral-50'}`}>
                  <input type="checkbox" className="mt-1 h-4 w-4 shrink-0" checked={checked} disabled={disabled} onChange={() => toggle(document)} />
                  <span className="min-w-0">
                    <span className="block break-words font-medium text-neutral-900 [overflow-wrap:anywhere]">{document.title}</span>
                    <span className="block break-words text-xs text-neutral-600 [overflow-wrap:anywhere]">
                      {[document.file_name, fileTypeLabel(document.file_name), formatFileSize(document.file_size), document.employee_name, new Date(document.created_at).toLocaleDateString('en-US', { timeZone: 'Pacific/Guam' })].filter(Boolean).join(' · ')}
                      {already ? ' · Already attached' : ''}
                    </span>
                  </span>
                </label>
              </li>
            );
          })}
        </ul>
        {hasMore && <Button type="button" variant="outline" className="mt-3" disabled={loading} onClick={() => void loadMore()}>Load more files</Button>}
        <DialogFooter className="mt-4">
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button type="button" disabled={!picked.size} onClick={() => { onChoose([...picked.values()]); onOpenChange(false); }}>
            {picked.size ? `Attach ${picked.size} ${picked.size === 1 ? 'file' : 'files'}` : 'Attach files'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
