import { useEffect, useState, type FormEvent } from 'react';
import { isReverificationCancelledError } from '@clerk/react/errors';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { useCompany } from '@/contexts/CompanyContext';
import { useStepUpRequest } from '@/lib/useStepUpRequest';
import api, { getApiBaseUrl } from '@/services/api';
import type { SupportGrant } from './grant';

interface Target { id: string; name: string }
interface Targets { clients: Target[]; employees: Target[]; employee_site_enabled: boolean }
const controlClass = 'mt-1 block w-full rounded-md border border-neutral-300 bg-white px-3 py-2 text-base';

export function StartSupportView() {
  const { activeCompanyId, activeCompany } = useCompany();
  return activeCompanyId && activeCompany ? (
    <SupportForm key={activeCompanyId} companyId={activeCompanyId} companyName={activeCompany.name} />
  ) : null;
}

function SupportForm({ companyId, companyName }: { companyId: number; companyName: string }) {
  const [targets, setTargets] = useState<Targets | null>(null);
  const [query, setQuery] = useState('');
  const [type, setType] = useState<'client' | 'employee'>('client');
  const [target, setTarget] = useState('');
  const [reason, setReason] = useState('');
  const [error, setError] = useState('');
  const [targetError, setTargetError] = useState('');
  const [starting, setStarting] = useState(false);
  const [loadAttempt, setLoadAttempt] = useState(0);

  useEffect(() => {
    const abort = new AbortController();
    const timer = window.setTimeout(() => {
      void api.get<Targets>('/auth/view_as/targets', { q: query }, { companyId, signal: abort.signal })
        .then((result) => { if (!abort.signal.aborted) setTargets(result); })
        .catch(() => { if (!abort.signal.aborted) setTargetError('Could not load people for this company.'); });
    }, 200);
    return () => { abort.abort(); window.clearTimeout(timer); };
  }, [companyId, query, loadAttempt]);

  const request = useStepUpRequest((token: string) => fetch(`${getApiBaseUrl()}/auth/view_as`, {
    method: 'POST', cache: 'no-store', redirect: 'error',
    headers: { Authorization: `Bearer ${token}`, 'X-Company-Id': String(companyId), 'Content-Type': 'application/json' },
    body: JSON.stringify({ target_type: type, target_id: target, reason }),
  }));

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!target || !reason.trim() || starting) return;
    setError('');
    setStarting(true);
    try {
      const response = await request();
      const data = await response.json().catch(() => null) as (SupportGrant & { token: string; error?: string }) | null;
      if (!response.ok || !data) {
        setError(data?.error || 'Could not start the support view.');
        return;
      }
      const destination = new URL(data.employee_url || '/app', window.location.origin);
      destination.hash = new URLSearchParams({ 'support-view': data.token }).toString();
      // An employee handoff navigates to a separate origin. A client handoff
      // reloads the main app so all data and providers use the effective client.
      window.location.assign(destination);
    } catch (failure) {
      if (!isReverificationCancelledError(failure)) setError('Could not start the support view. Try again.');
    } finally {
      setStarting(false);
    }
  };

  const people = type === 'client' ? targets?.clients : targets?.employees;
  const retryLoad = () => { setTargetError(''); setTargets(null); setLoadAttempt((attempt) => attempt + 1); };
  const missing = [!target && 'choose a person', !reason.trim() && 'enter a reason'].filter(Boolean).join(' and ');
  const missingHint = !starting && missing ? `${missing[0].toUpperCase()}${missing.slice(1)}.` : '';
  return (
    <>
      <Header title="Sign in as" description={companyName} />
      <form onSubmit={(event) => void submit(event)} className="max-w-xl space-y-5 p-4 sm:p-6">
        <p className="text-sm text-neutral-700">Open a view-only session for up to 30 minutes. The client can see this access in their support log.</p>
        <fieldset disabled={starting} className="space-y-4">
          <label className="block text-sm font-medium">View
            <select className={controlClass} value={type} onChange={(event) => {
              setType(event.target.value === 'employee' ? 'employee' : 'client');
              setTarget('');
            }}>
              <option value="client">Client portal</option>
              <option value="employee" disabled={!targets?.employee_site_enabled}>Employee app</option>
            </select>
          </label>
          <label className="block text-sm font-medium">Find by name
            <Input className="mt-1 text-base" value={query} onChange={(event) => {
              setQuery(event.target.value); setTarget(''); setTargets(null); setTargetError('');
            }} />
          </label>
          <label className="block text-sm font-medium">Person
            <select required className={controlClass} value={target} aria-invalid={targetError ? true : undefined}
              aria-describedby={targetError ? 'support-target-error' : undefined} onChange={(event) => setTarget(event.target.value)}>
              <option value="">{targetError ? 'People not loaded' : !people ? 'Loading…' : people.length ? 'Select a person' : 'No matching people'}</option>
              {people?.map((person) => <option key={person.id} value={person.id}>{person.name}</option>)}
            </select>
          </label>
          {targetError && (
            <div id="support-target-error" role="alert" className="-mt-2 flex flex-wrap items-center gap-3 text-sm text-red-800">
              <span>{targetError}</span>
              <Button type="button" variant="outline" size="sm" onClick={retryLoad}>Try again</Button>
            </div>
          )}
          <label className="block text-sm font-medium">Reason
            <textarea className={controlClass} rows={3} required maxLength={500} value={reason} onChange={(event) => setReason(event.target.value)} />
          </label>
        </fieldset>
        {error && <p role="alert" className="text-sm text-red-800">{error}</p>}
        <div>
          <Button type="submit" disabled={starting || !target || !reason.trim()} aria-describedby={missingHint ? 'support-start-hint' : undefined}>
            {starting ? 'Opening…' : 'Start view-only session'}
          </Button>
          {missingHint && <p id="support-start-hint" className="mt-2 text-sm text-neutral-600">{missingHint}</p>}
        </div>
      </form>
    </>
  );
}
