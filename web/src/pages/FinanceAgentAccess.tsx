import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router';
import { ArrowLeft, Copy, KeyRound } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { FinanceBookSelector, useFinanceBook } from '@/contexts/FinanceBookContext';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { financeApiTokensApi, getApiBaseUrl, type FinanceApiToken } from '@/services/api';

export function FinanceAgentAccess() {
  const { activeBook } = useFinanceBook();
  const bookIdRef = useRef(activeBook.id);
  bookIdRef.current = activeBook.id;
  const [tokens, setTokens] = useState<FinanceApiToken[]>([]);
  const [loadedBookId, setLoadedBookId] = useState<number | null>(null);
  const [name, setName] = useState('');
  const [draftWrite, setDraftWrite] = useState(false);
  const [issued, setIssued] = useState<{ bookId: number; secret: string } | null>(null);
  const [confirmRevokeId, setConfirmRevokeId] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [retryLoad, setRetryLoad] = useState(0);

  useEffect(() => {
    let current = true;
    setLoading(true);
    setLoadedBookId(null);
    setTokens([]);
    setIssued(null);
    setConfirmRevokeId(null);
    setError(null);
    void financeApiTokensApi.list().then((result) => {
      if (!current) return;
      if (result.finance_book_id !== activeBook.id) throw new Error('Financial book changed. Reload this page.');
      setTokens(result.tokens);
      setLoadedBookId(activeBook.id);
    }).catch((loadError) => {
      if (current) setError(loadError instanceof Error ? loadError.message : 'Unable to load access keys');
    }).finally(() => { if (current) setLoading(false); });
    return () => { current = false; };
  }, [activeBook.id, retryLoad]);

  async function createToken(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!name.trim()) return;
    setBusy(true);
    setError(null);
    try {
      const result = await financeApiTokensApi.create(name.trim(), draftWrite);
      if (result.token.finance_book_id !== bookIdRef.current) throw new Error('The book changed while creating this key. Return to the previous book to revoke it.');
      setTokens((current) => [result.token, ...current]);
      setIssued({ bookId: activeBook.id, secret: result.secret });
      setName('');
      setDraftWrite(false);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Unable to create access key');
    } finally { setBusy(false); }
  }

  async function revokeToken(token: FinanceApiToken) {
    setBusy(true);
    setError(null);
    try {
      const result = await financeApiTokensApi.revoke(token.id);
      if (result.token.finance_book_id === bookIdRef.current) {
        setTokens((current) => current.map((entry) => entry.id === token.id ? result.token : entry));
      }
      setIssued(null);
      setConfirmRevokeId(null);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Unable to revoke access key');
    } finally { setBusy(false); }
  }

  return <div className="min-h-screen bg-[#f8f7f4]">
    <Header title="Agent access" description="Give an agent read-only access to one financial book. Keys expire after 90 days and can be revoked here."
      contextLabel="Financial book" contextValue={activeBook.name} />
    <main className="mx-auto max-w-4xl space-y-6 px-4 py-6 sm:px-6 lg:px-8">
      <Link to="/tools/finance" className="inline-flex min-h-11 items-center gap-2 text-sm font-semibold text-primary-800 hover:underline"><ArrowLeft className="h-4 w-4" />Finance overview</Link>
      <FinanceBookSelector disabled={loading || busy} />
      <section aria-label="Agent connection details" className="rounded-2xl border border-neutral-200 bg-white p-5 text-sm shadow-sm sm:p-6">
        <h2 className="font-semibold text-neutral-950">Connection details for this book</h2>
        <p className="mt-1 text-neutral-600">Give your agent these values along with the key shown once after creation.</p>
        <dl className="mt-3 grid gap-3 sm:grid-cols-2">
          <div><dt className="text-neutral-600">Organization ID</dt><dd className="font-mono font-medium">{activeBook.organization_id}</dd></div>
          <div><dt className="text-neutral-600">Financial book ID</dt><dd className="font-mono font-medium">{activeBook.id}</dd></div>
          <div className="sm:col-span-2"><dt className="text-neutral-600">API URL</dt><dd className="break-all font-mono font-medium">{getApiBaseUrl()}</dd></div>
        </dl>
      </section>
      <section className="rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm sm:p-6">
        <div className="flex items-center gap-2"><KeyRound className="h-5 w-5 text-primary-700" /><h2 className="text-lg font-semibold">Create an agent key</h2></div>
        <p className="mt-2 text-sm leading-6 text-neutral-600">Every key can view this book’s invoices, expenses, and overview. You can also allow draft invoice editing. Keys cannot issue or send invoices, record payments, or access another book.</p>
        <form onSubmit={createToken} className="mt-5 flex flex-col gap-3 sm:flex-row sm:items-end">
          <label className="min-w-0 flex-1 text-sm font-medium text-neutral-800">Key name
            <Input className="mt-1" maxLength={80} required value={name} onChange={(event) => { setName(event.target.value); setError(null); }} placeholder="Shimizu invoice agent" />
          </label>
          <label className="flex min-h-11 items-center gap-2 text-sm text-neutral-800"><input type="checkbox" checked={draftWrite} onChange={(event) => setDraftWrite(event.target.checked)} disabled={busy} />Allow draft creation and editing</label>
          <Button type="submit" disabled={busy || loading || loadedBookId !== activeBook.id}>Create key</Button>
        </form>
        {issued?.bookId === activeBook.id && <div className="mt-5 rounded-xl border border-amber-300 bg-amber-50 p-4">
          <p className="text-sm font-semibold text-amber-950">Copy this key now. It will not be shown again.</p>
          <div className="mt-2 flex flex-col gap-2 sm:flex-row">
            <Input aria-label="New access key" readOnly value={issued.secret} className="min-w-0 font-mono text-xs" />
            <Button type="button" variant="outline" onClick={() => void navigator.clipboard.writeText(issued.secret)}><Copy className="mr-2 h-4 w-4" />Copy</Button>
          </div>
        </div>}
      </section>
      {error && <div role="alert" className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-800"><span>{error}</span>{loadedBookId !== activeBook.id && <Button type="button" variant="outline" onClick={() => setRetryLoad((value) => value + 1)}>Retry loading keys</Button>}</div>}
      <section className="rounded-2xl border border-neutral-200 bg-white p-5 shadow-sm sm:p-6">
        <h2 className="text-lg font-semibold">Keys for this book</h2>
        {loading || loadedBookId !== activeBook.id ? <p role="status" className="mt-4 text-sm text-neutral-600">{loading ? 'Loading keys…' : 'Keys could not be loaded.'}</p>
            : tokens.length === 0 ? <p className="mt-4 text-sm text-neutral-600">No agent keys yet.</p>
            : <ul className="mt-4 divide-y divide-neutral-100">{tokens.map((token) => <li key={token.id} className="flex flex-col gap-3 py-4 sm:flex-row sm:items-center sm:justify-between">
              <div className="min-w-0"><p className="font-medium text-neutral-950">{token.name}</p><p className="text-xs text-neutral-600">{token.scopes.includes('draft_write') ? 'Draft editing' : 'Read only'} · {token.revoked_at ? 'Revoked' : new Date(token.expires_at) <= new Date() ? 'Expired' : 'Active'} · Expires {new Date(token.expires_at).toLocaleDateString()} · Last used {token.last_used_at ? new Date(token.last_used_at).toLocaleString() : 'never'}</p></div>
              {!token.revoked_at && (confirmRevokeId === token.id
                ? <div className="flex flex-wrap items-center gap-2"><span className="text-xs text-rose-800">This agent will lose access immediately.</span><Button type="button" variant="outline" disabled={busy} onClick={() => setConfirmRevokeId(null)}>Cancel</Button><Button type="button" disabled={busy} onClick={() => void revokeToken(token)}>Confirm revoke</Button></div>
                : <Button type="button" variant="outline" disabled={busy} onClick={() => setConfirmRevokeId(token.id)}>Revoke</Button>)}
            </li>)}</ul>}
      </section>
    </main>
  </div>;
}
