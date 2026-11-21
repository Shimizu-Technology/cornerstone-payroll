import { useCallback, useEffect, useState } from 'react';
import { useSearchParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { LinkQueue } from '@/components/client-profitability/LinkQueue';
import { ReportView } from '@/components/client-profitability/ReportView';
import { ConnectionSteps, SetupPanel } from '@/components/client-profitability/SetupPanel';
import { cn } from '@/lib/utils';
import { clientProfitabilityApi, type ProfitabilityOverview } from '@/services/clientProfitability';

type Tab = 'report' | 'link' | 'setup';
const TABS: Array<{ id: Tab; label: string }> = [
  { id: 'report', label: 'Report' },
  { id: 'link', label: 'Link clients & staff' },
  { id: 'setup', label: 'Setup' },
];

export function ClientProfitability() {
  const [searchParams, setSearchParams] = useSearchParams();
  const requested = searchParams.get('tab');
  const [overview, setOverview] = useState<ProfitabilityOverview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);
  // Chosen once, from the first load: saving settings must not move the
  // person off the section they are working in.
  const [defaultTab, setDefaultTab] = useState<Tab | null>(null);

  const loadOverview = useCallback(() => {
    void clientProfitabilityApi.overview().then((data) => {
      setOverview(data);
      setDefaultTab((current) => current ?? (!data.has_hours || !data.settings.practice_company_id ? 'setup' : 'report'));
    })
      .catch((loadError: unknown) => setError(loadError instanceof Error ? loadError.message : 'Couldn’t load client profitability.'));
  }, []);
  useEffect(loadOverview, [loadOverview]);

  const refreshAll = useCallback(() => { loadOverview(); setReloadKey((key) => key + 1); }, [loadOverview]);
  const settingsChanged = useCallback((updated?: ProfitabilityOverview) => {
    if (updated) setOverview(updated); else loadOverview();
    setReloadKey((key) => key + 1);
  }, [loadOverview]);

  const tab: Tab = requested === 'report' || requested === 'link' || requested === 'setup' ? requested : defaultTab ?? 'report';
  const goTo = useCallback((next: Tab) => setSearchParams((params) => { params.set('tab', next); return params; }), [setSearchParams]);
  const linkCount = overview ? overview.needs_linking.clients + overview.needs_linking.staff : 0;

  return (
    <div className="min-h-screen bg-[#f8f7f4]">
      <Header title="Client profitability" contextLabel="Covers" contextValue="All clients"
        description="What each client paid, what the staff time cost, and the difference. Hours come from Cornerstone Tax." />
      <main className="mx-auto max-w-[1400px] space-y-6 px-4 py-6 sm:px-6 lg:px-8">
        {error && <p role="alert" className="rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-900">{error}</p>}
        {!overview && !error && <p role="status" className="text-sm text-neutral-600">Loading…</p>}
        {overview && (
          <>
            {!overview.connection.connected && <ConnectionSteps overview={overview} />}
            <nav aria-label="Client profitability sections" className="-mx-4 overflow-x-auto px-4">
              <div className="inline-flex min-w-max gap-1 rounded-full border border-neutral-200 bg-white p-1">
                {TABS.map((entry) => (
                  <button key={entry.id} type="button" aria-current={tab === entry.id ? 'page' : undefined} onClick={() => goTo(entry.id)}
                    className={cn('min-h-11 rounded-full px-4 text-sm font-semibold', tab === entry.id ? 'bg-primary-700 text-white' : 'text-neutral-700 hover:bg-neutral-100')}>
                    {entry.label}
                    {entry.id === 'link' && linkCount > 0 && <span className={cn('ml-2 rounded-full px-2 py-0.5 text-xs', tab === entry.id ? 'bg-white/20' : 'bg-amber-100 text-amber-900')}>{linkCount}</span>}
                  </button>
                ))}
              </div>
            </nav>
            {tab === 'report' && (overview.has_hours || overview.connection.connected
              ? <ReportView reloadKey={reloadKey} onGoTo={goTo} />
              : <p className="rounded-2xl border border-neutral-200 bg-white p-6 text-sm leading-6 text-neutral-700">The report fills in once Cornerstone Tax is connected and hours have been refreshed. Follow the steps above, then open Setup.</p>)}
            {tab === 'link' && <LinkQueue onChanged={refreshAll} />}
            {tab === 'setup' && <SetupPanel overview={overview} onChanged={settingsChanged} onRefreshed={refreshAll} />}
          </>
        )}
      </main>
    </div>
  );
}
