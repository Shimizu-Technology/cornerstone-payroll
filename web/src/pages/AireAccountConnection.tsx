import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import { ArrowLeft, Link2, RefreshCw, ShieldCheck, Unplug } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Select } from '@/components/ui/select';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { payRunsPath, safeInternalReturnPath } from '@/lib/routes';
import { timeTrackingSourcesApi, type AireAccountLink, type TimeTrackingSource } from '@/services/api';

type ReturnContext = { companyId: number; returnTo: string };
const contextKey = (sourceId: number) => `aire-own-link-return:${sourceId}`;
const positiveId = (value: string | null) => value && /^\d+$/.test(value) && Number.isSafeInteger(Number(value)) && Number(value) > 0 ? Number(value) : null;
function readContext(sourceId: number | null): ReturnContext | null {
  if (!sourceId) return null;
  try {
    const context = JSON.parse(sessionStorage.getItem(contextKey(sourceId)) || 'null');
    return Number.isSafeInteger(context?.companyId) && context.companyId > 0 && typeof context.returnTo === 'string' ? context : null;
  } catch { return null; }
}
function companyReturn(value: string | null, companyId: number): string {
  const fallback = payRunsPath(companyId);
  const path = safeInternalReturnPath(value, fallback);
  return path.startsWith(`/companies/${companyId}/`) ? path : fallback;
}
function authorizationUrl(value: string): string {
  const url = new URL(value);
  const local = import.meta.env.DEV && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if ((url.protocol !== 'https:' && !(local && url.protocol === 'http:')) || url.username || url.password ||
      url.pathname !== '/admin/payroll-link' || !url.searchParams.get('token') || url.hash) {
    throw new Error('AIRE returned an invalid connection link. Refresh and try again.');
  }
  return url.toString();
}

export function AireAccountConnection({ navigateToAuthorization = (url: string) => window.location.assign(url) }: {
  navigateToAuthorization?: (url: string) => void;
}) {
  const { hasCapability } = useAuth();
  const { companies, loading: companyLoading, activeCompanyId, activeCompany, switchCompany } = useCompany();
  const [params] = useSearchParams();
  const sourceId = positiveId(params.get('source_id'));
  const result = params.get('aire_link');
  const context = result ? readContext(sourceId) : null;
  const callbackKey = result && sourceId ? `${sourceId}:${result}` : null;
  const [restoredCallbackKey, setRestoredCallbackKey] = useState<string | null>(null);
  const allowed = hasCapability('manage_own_aire_account_link');
  const restoreCompany = callbackKey !== restoredCallbackKey && context && companies.some(row => row.id === context.companyId) ? context.companyId : null;
  useEffect(() => {
    if (!allowed || companyLoading || !restoreCompany) return;
    if (restoreCompany !== activeCompanyId) switchCompany(restoreCompany);
    else setRestoredCallbackKey(callbackKey);
  }, [allowed, companyLoading, activeCompanyId, switchCompany, restoreCompany, callbackKey]);
  if (!allowed) return <div className="p-6"><p role="alert">Your account cannot manage a personal AIRE connection. Ask your payroll administrator to review your assigned company access.</p></div>;
  if (companyLoading || (restoreCompany && restoreCompany !== activeCompanyId)) return <p role="status" className="p-6">Loading your payroll company…</p>;
  if (!activeCompanyId) return <p className="p-6">Choose an assigned payroll company before connecting AIRE.</p>;
  return <ConnectionForCompany key={activeCompanyId} companyId={activeCompanyId}
    companyName={activeCompany?.name || 'Selected company'} requestedSourceId={sourceId}
    returnTo={companyReturn(params.get('return_to') || context?.returnTo || null, activeCompanyId)}
    result={result} navigateToAuthorization={navigateToAuthorization} />;
}

function ConnectionForCompany({ companyId, companyName, requestedSourceId, returnTo, result, navigateToAuthorization }: {
  companyId: number; companyName: string; requestedSourceId: number | null; returnTo: string;
  result: string | null; navigateToAuthorization: (url: string) => void;
}) {
  const [sources, setSources] = useState<TimeTrackingSource[]>([]);
  const [sourceId, setSourceId] = useState<number | null>(null);
  const [account, setAccount] = useState<AireAccountLink | null>(null);
  const [loading, setLoading] = useState(true);
  const [checking, setChecking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [disconnectOpen, setDisconnectOpen] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const generation = useRef(0);
  const source = sources.find(row => row.id === sourceId);
  const loadSources = useCallback(async () => {
    const current = ++generation.current;
    setLoading(true); setChecking(false); setAccount(null); setError('');
    try {
      const response = await timeTrackingSourcesApi.list();
      if (current !== generation.current) return;
      const active = response.time_tracking_sources.filter(row => row.company_id === companyId && row.active && row.source_type === 'aire_services');
      setSources(active);
      const requested = active.find(row => row.id === requestedSourceId);
      setSourceId(requested?.id || (!requestedSourceId && active.length === 1 ? active[0].id : null));
      if (requestedSourceId && !requested) setError('That AIRE source is unavailable for this company. Choose an active source or ask your administrator.');
    } catch (caught) {
      if (current === generation.current) { setSources([]); setSourceId(null); setError(caught instanceof Error ? caught.message : 'Could not load the company’s AIRE connection.'); }
    } finally { if (current === generation.current) setLoading(false); }
  }, [companyId, requestedSourceId]);
  useEffect(() => { void loadSources(); return () => { generation.current += 1; }; }, [loadSources]);

  const check = useCallback(async () => {
    if (!sourceId) return;
    const current = ++generation.current;
    setChecking(true); setAccount(null); setError('');
    try {
      const response = await timeTrackingSourcesApi.getAireAccountLink(sourceId);
      if (current !== generation.current) return;
      setAccount(response.account_link);
      if (result === 'connected') setNotice(response.account_link.connected
        ? 'AIRE confirmed your connection. Return to payroll to continue.' : 'AIRE returned, but your connection is not active. Connect again or ask your AIRE administrator.');
      else if (result === 'cancelled') setNotice('The connection was cancelled. Your current access is shown below.');
    } catch (caught) {
      if (current === generation.current) setError(caught instanceof Error ? caught.message : 'Could not confirm your AIRE access. Refresh before connecting or disconnecting.');
    } finally { if (current === generation.current) setChecking(false); }
  }, [sourceId, result]);
  useEffect(() => { setNotice(''); setBusy(false); setDisconnectOpen(false); void check(); return () => { generation.current += 1; }; }, [check]);

  const connect = async () => {
    if (!source || !account || checking || busy) return;
    const current = generation.current;
    setBusy(true); setError(''); setNotice('');
    try {
      const response = await timeTrackingSourcesApi.createAireAccountLink(source.id);
      if (current !== generation.current) return;
      const url = authorizationUrl(response.authorization_url);
      sessionStorage.setItem(contextKey(source.id), JSON.stringify({ companyId, returnTo }));
      navigateToAuthorization(url);
    } catch (caught) {
      if (current === generation.current) { setAccount(null); setError(caught instanceof Error ? caught.message : 'Could not start your AIRE connection. Refresh your connection status.'); setBusy(false); }
    }
  };
  const disconnect = async () => {
    if (!source || !account?.connected || busy) return;
    const current = generation.current;
    setBusy(true); setError('');
    try {
      const response = await timeTrackingSourcesApi.disconnectAireAccountLink(source.id);
      if (current !== generation.current) return;
      setAccount(response.account_link); setDisconnectOpen(false); setNotice('Your personal AIRE connection was disconnected. Existing payroll and payment records remain available.');
    } catch (caught) {
      if (current === generation.current) { setAccount(null); setDisconnectOpen(false); setError(caught instanceof Error ? caught.message : 'Could not confirm disconnection. Refresh your connection status.'); }
    } finally { if (current === generation.current) setBusy(false); }
  };
  return <div>
    <Header title="My AIRE connection" description={`Personal payroll access for ${companyName}`} />
    <div className="mx-auto max-w-3xl space-y-5 p-4 sm:p-6 lg:p-8">
      <Link to={returnTo} className="inline-flex min-h-11 items-center gap-2 font-medium text-primary-800"><ArrowLeft className="h-4 w-4" />Return to payroll</Link>
      <Card><CardContent className="space-y-5 py-6">
        <div className="flex items-start gap-3"><ShieldCheck className="mt-1 h-5 w-5 shrink-0 text-primary-700" /><div>
          <h1 className="text-lg font-semibold text-neutral-950">Connect your own AIRE account</h1>
          <p className="mt-2 text-sm leading-6 text-neutral-600">Sign in to AIRE with your own account that has payroll access and confirm the connection. This connects your identity for this company; it does not change your Payroll role. Managers still handle time approvals, employee mappings, settlement routing and calendar setup.</p>
          <p className="mt-2 text-sm leading-6 text-neutral-600">No tokens to copy. Access remains active until disconnected or your AIRE payroll access is disabled.</p>
        </div></div>
        {loading && <p role="status">Loading active AIRE sources…</p>}
        {error && <p role="alert" className="rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-800">{error}</p>}
        {notice && <p role="status" className="rounded-xl border border-primary-200 bg-primary-50 p-4 text-sm text-primary-900">{notice}</p>}
        {!loading && sources.length === 0 && <p className="text-sm leading-6 text-neutral-600">This company has no active AIRE source. Ask your payroll administrator to configure one, then refresh. Existing source settings and credentials are managed separately.</p>}
        {!loading && sources.length > 0 && <Select label="Active AIRE source" value={sourceId || ''} disabled={busy} onChange={event => setSourceId(positiveId(event.target.value))}>
          <option value="">Choose this company’s AIRE source</option>{sources.map(row => <option key={row.id} value={row.id}>{row.name}</option>)}
        </Select>}
        {checking && <p role="status">Checking your current AIRE access…</p>}
        {source && account && !checking && <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
          <Badge variant={account.connected ? 'success' : 'warning'}>{account.connected ? 'Connected' : 'Not connected'}</Badge>
          {account.connected ? <><p className="mt-3 font-semibold text-neutral-900">Connected as {account.aire_user_name || account.aire_user_email || 'your AIRE account'}</p>
            {account.aire_user_email && <p className="mt-1 text-sm text-neutral-600">{account.aire_user_email}</p>}
            <Button className="mt-4" variant="outline" disabled={busy} onClick={() => setDisconnectOpen(true)}><Unplug className="mr-2 h-4 w-4" />Disconnect my account</Button></>
            : <><p className="mt-3 text-sm leading-6 text-neutral-600">AIRE will ask you to sign in and approve this connection, then return here. A Payroll administrator cannot sign in on your behalf.</p>
              <Button className="mt-4" disabled={busy} onClick={() => void connect()}><Link2 className="mr-2 h-4 w-4" />{busy ? 'Opening AIRE…' : 'Connect my AIRE account'}</Button></>}
        </div>}
        <Button variant="outline" disabled={busy || loading || checking} onClick={() => sourceId ? void check() : void loadSources()}><RefreshCw className="mr-2 h-4 w-4" />Refresh connection status</Button>
      </CardContent></Card>
    </div>
    <Dialog open={disconnectOpen} onOpenChange={open => { if (!busy) setDisconnectOpen(open); }}><DialogContent>
      <DialogHeader><DialogTitle>Disconnect your AIRE account?</DialogTitle><DialogDescription>This removes your personal connection for {companyName}. Other staff connections, source settings and saved payroll records remain unchanged. You can reconnect later.</DialogDescription></DialogHeader>
      <DialogFooter><Button variant="outline" disabled={busy} onClick={() => setDisconnectOpen(false)}>Keep connected</Button><Button disabled={busy} onClick={() => void disconnect()}>{busy ? 'Disconnecting…' : 'Confirm disconnection'}</Button></DialogFooter>
    </DialogContent></Dialog>
  </div>;
}
