import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactElement } from 'react';
import { useLocation, useNavigate, useSearchParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Select } from '@/components/ui/select';
import { Card, CardContent } from '@/components/ui/card';
import { useCompany } from '@/contexts/CompanyContext';
import { useAuth } from '@/contexts/AuthContext';
import { clientInboxApi, mergeInboxRows, type InboxCounts, type InboxRow } from '@/services/clientInbox';

const labels = { message: 'Message', document: 'Client upload', employee_change: 'Employee change', payroll_submission: 'Pay period files', file_request: 'File request' };
const scrollPositions = new Map<string, number>();
export function ClientInbox(): ReactElement {
  const [params, setParams] = useSearchParams();
  const location = useLocation();
  const navigate = useNavigate();
  const { user } = useAuth();
  const { companies, switchCompany, activeOrganizationId } = useCompany();
  const [rows, setRows] = useState<InboxRow[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [counts, setCounts] = useState<InboxCounts | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [restoring, setRestoring] = useState(true);
  const version = useRef(0);
  const loadedPages = useRef(1);
  const invalidateRequests = useCallback(() => { ++version.current; }, []);
  const container = useRef<HTMLDivElement>(null);
  const scrollKey = `${user?.id}:${activeOrganizationId}:${location.pathname}${location.search}`;
  const filterKey = params.toString();
  const getScroll = () => container.current?.closest('main');
  const load = useCallback(async (next?: string, preserveWindow = false): Promise<void> => {
    const request = ++version.current;
    const filters = { company_id: Number(new URLSearchParams(filterKey).get('client')) || undefined, kind: new URLSearchParams(filterKey).get('kind') || undefined, status: new URLSearchParams(filterKey).get('status') || 'waiting' };
    const pageLimit = preserveWindow ? loadedPages.current : 1;
    setBusy(true);
    setError(null);
    try {
      let response = await clientInboxApi.list({ ...filters, cursor: next });
      let incoming = response.data;
      let pages = 1;
      while (!next && pages < pageLimit && response.meta.next_cursor) {
        if (version.current !== request) return;
        response = await clientInboxApi.list({ ...filters, cursor: response.meta.next_cursor });
        incoming = mergeInboxRows(incoming, response.data);
        pages += 1;
      }
      const summary = await clientInboxApi.counts({ ...filters, status: 'all' });
      if (version.current !== request) return;
      if (preserveWindow) {
        scrollPositions.set(scrollKey, container.current?.closest('main')?.scrollTop || 0);
        setRestoring(true);
      }
      setRows(current => mergeInboxRows(next ? current : [], incoming));
      loadedPages.current = next ? loadedPages.current + 1 : pages;
      setCursor(response.meta.next_cursor);
      setCounts(summary.data);
    } catch (err) {
      if (version.current === request) {
        setError(err instanceof Error ? err.message : 'Could not load inbox');
        setRestoring(false);
        if (!next) { setRows([]); setCounts(null); setCursor(null); loadedPages.current = 1; }
      }
    } finally { if (version.current === request) setBusy(false); }
  }, [filterKey, scrollKey]);
  useEffect(() => {
    setRows([]); setCursor(null); setRestoring(true); loadedPages.current = 1;
    void load();
    return invalidateRequests;
  }, [load, invalidateRequests]);
  useLayoutEffect(() => {
    if (busy || !restoring || !rows.length) return;
    const top = scrollPositions.get(scrollKey) || 0;
    const main = getScroll();
    if (main && main.scrollHeight - main.clientHeight < top && cursor) { void load(cursor); return; }
    main?.scrollTo({ top, behavior: 'instant' });
    setRestoring(false);
  }, [rows, busy, cursor, load, restoring, scrollKey]);
  useEffect(() => {
    const main = getScroll();
    const save = () => { if (!restoring) scrollPositions.set(scrollKey, main?.scrollTop || 0); };
    main?.addEventListener('scroll', save);
    return () => main?.removeEventListener('scroll', save);
  }, [scrollKey, restoring]);
  useEffect(() => {
    let pending: ReturnType<typeof setTimeout> | undefined;
    const refresh = () => {
      if (document.visibilityState === 'hidden') return;
      clearTimeout(pending);
      pending = setTimeout(() => void load(undefined, true), 100);
    };
    const timer = setInterval(refresh, 60_000);
    window.addEventListener('focus', refresh);
    window.addEventListener('portal-work-changed', refresh);
    document.addEventListener('visibilitychange', refresh);
    return () => { clearInterval(timer); clearTimeout(pending); window.removeEventListener('focus', refresh); window.removeEventListener('portal-work-changed', refresh); document.removeEventListener('visibilitychange', refresh); };
  }, [load]);
  const filter = (key: string, value: string): void => {
    const next = new URLSearchParams(params);
    if (value) next.set(key, value); else next.delete(key);
    setParams(next);
  };
  const open = (row: InboxRow): void => {
    if (!switchCompany(row.company_id)) return;
    scrollPositions.set(scrollKey, getScroll()?.scrollTop || 0);
    const target = new URLSearchParams({ inbox: location.pathname + location.search });
    if (row.kind === 'payroll_submission') {
      navigate(`/companies/${row.company_id}/payroll-submissions/${row.id}?${target}`);
      return;
    }
    if (row.kind === 'message' || row.kind === 'file_request') {
      target.set('thread_id', String(row.kind === 'message' ? row.id : row.thread_id ?? ''));
      navigate(`/companies/${row.company_id}/client-messages?${target}`);
      return;
    }
    target.set(row.kind === 'document' ? 'document_id' : 'request_id', String(row.id));
    navigate(`/companies/${row.company_id}/${row.kind === 'employee_change' ? 'client-change-requests' : 'client-documents'}?${target}`);
  };
  return <div ref={container}>
    <Header contextLabel="Workspace" contextValue="All accessible clients" title="Client Inbox" description="Portal work across your accessible clients. Choose an item to enter that client." />
    <div className="space-y-5 p-4 sm:p-6 lg:p-8">
      <Card><CardContent className="flex flex-wrap gap-x-8 gap-y-4 pt-6"><p><strong className="tabular-nums">{counts?.unread_count ?? '—'}</strong> unread <span className="block text-xs text-neutral-600">{counts ? `${counts.unread_messages} conversations · ${counts.unread_documents} files` : 'Loading counts'}</span></p><p><strong className="tabular-nums">{counts?.waiting_count ?? '—'}</strong> waiting on staff <span className="block text-xs text-neutral-600">{counts ? `${counts.waiting_payroll ?? 0} pay periods · ${counts.waiting_file_requests ?? 0} requested files · ${counts.pending_changes} pending employee changes · ` : ''}Reading does not complete the work</span></p></CardContent></Card>
      <div className="grid gap-3 sm:grid-cols-3">
        <label className="text-sm font-medium">Client<Select value={params.get('client') || ''} onChange={e => filter('client', e.target.value)}><option value="">All clients</option>{companies.filter(c => c.organization_id === user?.organization_id && c.active && c.payroll_environment === 'live').map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></label>
        <label className="text-sm font-medium">Kind<Select value={params.get('kind') || ''} onChange={e => filter('kind', e.target.value)}><option value="">All kinds</option><option value="message">Messages</option><option value="document">Client uploads</option><option value="employee_change">Employee changes</option><option value="payroll_submission">Pay period files</option><option value="file_request">File requests</option></Select></label>
        <label className="text-sm font-medium">Status<Select value={params.get('status') || 'waiting'} onChange={e => filter('status', e.target.value)}><option value="waiting">Waiting on staff</option><option value="unread">Unread</option><option value="all">All activity</option><option value="handled">Handled</option></Select></label>
      </div>
      <div className="flex items-center justify-between gap-3"><p className="text-sm text-neutral-600">Most recent client activity first</p><Button variant="outline" disabled={busy} onClick={() => void load(undefined, true)}>Refresh</Button></div>
      {error && <div role="alert" className="rounded-lg border border-danger-200 p-4"><p>{error}</p><Button variant="outline" onClick={() => void load(cursor || undefined)}>Retry</Button></div>}
      {!busy && !error && !rows.length && <p className="rounded-lg border border-neutral-200 bg-white p-6 text-neutral-600">No portal work matches these filters.</p>}
      <ul className="divide-y divide-neutral-200 rounded-xl border border-neutral-200 bg-white">{rows.map(row => <li key={row.key}><button type="button" onClick={() => open(row)} className="flex w-full flex-col gap-2 p-4 text-left hover:bg-primary-50 focus-visible:outline-2 focus-visible:outline-offset-2 sm:flex-row sm:items-center sm:justify-between"><span className="min-w-0"><span className="block break-words text-xs font-semibold text-primary-800">{row.company_name} · {labels[row.kind]}</span><span className="mt-1 block break-words font-semibold text-neutral-950">{row.title}</span><span className="mt-1 block text-sm text-neutral-600">{row.sender_name ? `From ${row.sender_name} · ` : ''}{row.unread ? 'Unread · ' : ''}{row.state_label || (row.waiting ? 'Waiting on staff' : 'Handled')}</span></span><time className="shrink-0 text-xs text-neutral-600" dateTime={row.activity_at}>{new Date(row.activity_at).toLocaleString('en-US', { timeZone: 'Pacific/Guam' })}</time></button></li>)}</ul>
      {busy && <p role="status">Loading portal work…</p>}
      {cursor && <Button variant="outline" className="w-full sm:w-auto" disabled={busy} onClick={() => void load(cursor)}>Load more</Button>}
    </div>
  </div>;
}
