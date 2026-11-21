import { useCallback, useEffect, useState } from 'react';
import { useSearchParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { LinkQueue } from '@/components/client-profitability/LinkQueue';
import { ReportView } from '@/components/client-profitability/ReportView';
import { ConnectionSteps, SetupPanel } from '@/components/client-profitability/SetupPanel';
import { cn } from '@/lib/utils';
import { clientProfitabilityApi, type ProfitabilityOverview, type WorkHourImportStatus } from '@/services/clientProfitability';

type Tab = 'report' | 'link' | 'setup';
const POLL_MS = 1500;
const MAX_POLL_FAILURES = 5;

function inProgress(entry: WorkHourImportStatus | null | undefined): boolean {
  return entry !== null && entry !== undefined && (entry.status === 'queued' || entry.status === 'running');
}
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

  // The page, not the Setup section, watches a running refresh, so it keeps
  // going when someone opens another section and the report reloads when it
  // ends. A refresh already running on the server (started earlier, or by the
  // nightly job) is picked up from the overview.
  const [watched, setWatched] = useState<WorkHourImportStatus | null>(null);
  const [pollFailures, setPollFailures] = useState(0);
  const [monitorError, setMonitorError] = useState<string | null>(null);
  const serverActive = overview?.imports.find((entry) => inProgress(entry)) ?? null;
  const activeImport: WorkHourImportStatus | null = watched && inProgress(watched) ? watched : serverActive && serverActive.id !== watched?.id ? serverActive : null;
  const startWatching = useCallback((started: WorkHourImportStatus) => {
    setWatched(started);
    setPollFailures(0);
    setMonitorError(null);
  }, []);
  useEffect(() => {
    if (!activeImport || pollFailures >= MAX_POLL_FAILURES) return undefined;
    let current = true;
    const timer = window.setTimeout(() => {
      void clientProfitabilityApi.importStatus(activeImport.id).then(({ import: next }) => {
        if (!current) return;
        setPollFailures(0);
        setMonitorError(null);
        setWatched(next);
        if (!inProgress(next)) refreshAll();
      }).catch(() => {
        if (!current) return;
        setPollFailures((count) => count + 1);
        setMonitorError(pollFailures + 1 >= MAX_POLL_FAILURES
          ? 'Couldn’t check on the refresh. Reload the page to see how it finished.'
          : 'Couldn’t check on the refresh. Trying again…');
      });
    }, POLL_MS * (pollFailures + 1));
    return () => { current = false; window.clearTimeout(timer); };
  }, [activeImport, pollFailures, refreshAll]);
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
              ? <ReportView reloadKey={reloadKey} onGoTo={goTo} defaults={{
                costPending: overview.settings.default_cost_pending,
                spreadOverhead: overview.settings.default_spread_overhead,
                period: overview.settings.default_period,
                costBasis: overview.settings.cost_basis,
              }} />
              : <p className="rounded-2xl border border-neutral-200 bg-white p-6 text-sm leading-6 text-neutral-700">The report fills in once Cornerstone Tax is connected and hours have been refreshed. Follow the steps above, then open Setup.</p>)}
            {tab === 'link' && <LinkQueue onChanged={refreshAll} reloadKey={reloadKey} />}
            {tab === 'setup' && (
              <SetupPanel overview={overview} onChanged={settingsChanged} activeImport={activeImport} monitorError={monitorError}
                onStarted={startWatching} />
            )}
          </>
        )}
      </main>
    </div>
  );
}
