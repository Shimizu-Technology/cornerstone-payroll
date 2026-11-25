import { useEffect, useState } from 'react';
import { Header } from '@/components/layout/Header';
import { useCompany } from '@/contexts/CompanyContext';
import api from '@/services/api';

interface SupportEvent { id: string; description: string; viewed_at: string }

export function SupportAccessLogs() {
  const { activeCompanyId } = useCompany();
  return (
    <>
      <Header title="Support access" description="When Cornerstone opens your portal to help you, each visit is listed here." />
      {activeCompanyId && <SupportEvents key={activeCompanyId} companyId={activeCompanyId} />}
    </>
  );
}

const date = new Intl.DateTimeFormat('en-US', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'Pacific/Guam' });

function SupportEvents({ companyId }: { companyId: number }) {
  const [events, setEvents] = useState<SupportEvent[] | null>(null);
  const [error, setError] = useState(false);
  useEffect(() => {
    const abort = new AbortController();
    void api.get<{ events: SupportEvent[] }>('/client/support_access_logs', undefined, { companyId, signal: abort.signal })
      .then(({ events }) => { if (!abort.signal.aborted) setEvents(events); })
      .catch(() => { if (!abort.signal.aborted) setError(true); });
    return () => abort.abort();
  }, [companyId]);

  return (
    <section className="max-w-3xl p-4 sm:p-6" aria-label="Recent support sessions">
      {error ? <p role="alert">Could not load support access.</p> :
        events === null ? <p role="status">Loading support access…</p> :
        events.length === 0 ? (
          <div className="space-y-2 text-sm text-neutral-700">
            <p className="font-semibold text-neutral-900">Cornerstone hasn&apos;t opened your portal yet.</p>
            <p>If Cornerstone opens your portal while helping you, the visit appears here with who opened it and when. These visits are view-only, so nothing can be changed.</p>
          </div>
        ) :
        <ul className="divide-y rounded-lg border bg-white">
          {events.map((event) => (
            <li key={event.id} className="break-words px-4 py-3">
              <p className="font-medium">{event.description}</p>
              <time dateTime={event.viewed_at} className="text-sm text-neutral-600">{date.format(new Date(event.viewed_at))} ChST</time>
            </li>
          ))}
        </ul>}
    </section>
  );
}
