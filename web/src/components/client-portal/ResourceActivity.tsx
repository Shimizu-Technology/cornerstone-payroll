import { useEffect, useRef, useState, type ReactElement } from 'react';
import { Button } from '@/components/ui/button';
import { appendUniqueById, hasMorePages } from '@/lib/paged-list';
import type { BoundedListMeta, PortalActivityEvent } from '@/services/api';

export type ResourceActivityApi = {
  activity: (id: number, page?: number) => Promise<{ data: PortalActivityEvent[]; meta: BoundedListMeta }>;
};

export function ResourceActivity({ id, api, revision }: { id: number; api: ResourceActivityApi; revision?: string | number }): ReactElement {
  const generation = useRef(0);
  const [expanded, setExpanded] = useState(false);
  const [events, setEvents] = useState<PortalActivityEvent[]>([]);
  const [meta, setMeta] = useState<BoundedListMeta | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    const requestGeneration = ++generation.current;
    if (!expanded) return;
    const active = () => requestGeneration === generation.current;
    setLoading(true);
    setError(null);
    api.activity(id).then(response => {
      if (active()) { setEvents(response.data); setMeta(response.meta); }
    }).catch(() => { if (active()) setError('Activity could not be loaded. Try again.'); })
      .finally(() => { if (active()) setLoading(false); });
    return () => { generation.current += 1; };
  }, [api, id, expanded, revision, attempt]);
  const loadMore = async (): Promise<void> => {
    const requestGeneration = generation.current;
    setLoading(true);
    setError(null);
    try {
      const response = await api.activity(id, (meta?.current_page ?? 1) + 1);
      if (requestGeneration !== generation.current) return;
      setEvents(current => appendUniqueById(current, response.data));
      setMeta(response.meta);
    } catch { if (requestGeneration === generation.current) setError('Activity could not be loaded. Try again.'); }
    finally { if (requestGeneration === generation.current) setLoading(false); }
  };
  return <section className="border-t border-neutral-200 p-4" aria-label="Resource activity">
    <Button type="button" variant="outline" size="sm" aria-expanded={expanded} onClick={() => setExpanded(value => !value)}>Activity</Button>
    {expanded && <div className="mt-3 space-y-3 text-sm">
      <p className="text-xs text-neutral-500">Times in Pacific/Guam. Opened records access, not acknowledgment.</p>
      {error && <p role="alert">{error} <button type="button" className="underline" onClick={() => setAttempt(value => value + 1)}>Retry</button></p>}
      {!loading && !error && events.length === 0 && <p className="text-neutral-500">No activity recorded yet.</p>}
      <ol className="space-y-3">{events.map(event => <li key={event.id} className="break-words">
        <p className="text-neutral-800">{event.headline}</p>
        <time className="text-xs text-neutral-500" dateTime={event.created_at}>{new Date(event.created_at).toLocaleString('en-US', { timeZone: 'Pacific/Guam', dateStyle: 'medium', timeStyle: 'short' })}</time>
      </li>)}</ol>
      {loading && <p role="status">Loading activity…</p>}
      {hasMorePages(meta) && <Button type="button" variant="outline" size="sm" disabled={loading} onClick={() => void loadMore()}>Load more activity</Button>}
    </div>}
  </section>;
}
