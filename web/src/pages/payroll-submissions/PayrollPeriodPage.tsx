import { useCallback, useEffect, useRef, useState, type FormEvent, type ReactElement } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { LabeledTextarea } from '@/components/payroll-submissions/LabeledTextarea';
import { InboxReturnLink } from '@/components/client-portal/InboxReturnLink';
import { useCompany } from '@/contexts/CompanyContext';
import { FileRow, RevisionCard } from '@/components/payroll-submissions/PeriodParts';
import { formatDate, formatGuam, statusVariant } from '@/lib/payrollSubmissionFormat';
import { SubmissionForm } from '@/components/payroll-submissions/SubmissionForm';
import { PortalImportAction } from '@/components/payroll-submissions/PortalImportAction';
import { PeriodConversation } from '@/components/payroll-submissions/PeriodConversation';
import { adminPayrollSubmissionsApi, clientPayrollSubmissionsApi, type PeriodDetail, type SubmissionDraft } from '@/services/payrollSubmissions';

type Audience = 'client' | 'staff';

function submissionReceipt(detail: PeriodDetail): string {
  const sent = detail.submissions.find(row => row.current);
  const workbook = sent?.workbook_choice === 'none' ? 'No tips or loans'
    : sent?.changes_link_url ? 'Link sent'
    : sent?.documents.some(doc => doc.role === 'changes_workbook') ? 'Workbook ✓' : 'Workbook not included';
  const changed = sent?.changes.filter(row => !row.skipped).length || 0;
  const skipped = sent?.changes.filter(row => row.skipped).length || 0;
  return `Sent. Revision ${detail.current_revision} is with Cornerstone. Revel PDF ✓ · ${workbook} · ${changed} changes${skipped ? ` · ${skipped} not this period` : ''}`;
}

function DraftFiles({ draft, api, audience }: { draft: SubmissionDraft; api: typeof clientPayrollSubmissionsApi | typeof adminPayrollSubmissionsApi; audience: Audience }) {
  return <ul className="divide-y divide-neutral-100">
    {draft.paycheck_document && <FileRow label="Draft paychecks" document={draft.paycheck_document} api={api} audience={audience} />}
    {draft.direct_deposit_document && <FileRow label="Draft direct deposits" document={draft.direct_deposit_document} api={api} audience={audience} />}
  </ul>;
}

function ClientDecision({ period, draft, onDone }: { period: PeriodDetail; draft: SubmissionDraft; onDone: (detail: PeriodDetail) => void }) {
  const [mode, setMode] = useState<'idle' | 'change'>('idle');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const decide = async (decision: 'approve' | 'request_changes') => {
    if (decision === 'request_changes' && !note.trim()) { setError('Describe the change you need.'); return; }
    setBusy(true); setError(null);
    try { onDone((await clientPayrollSubmissionsApi.decide(period.ref, { decision, draft_id: draft.id, note: note.trim() || undefined })).data); }
    catch (err) { setError(err instanceof Error ? err.message : 'That did not save. Try again.'); }
    finally { setBusy(false); }
  };
  return <div className="space-y-3">
    <p className="text-sm text-neutral-700">Check the draft paychecks and direct deposits, then approve them or tell Cornerstone what to change.</p>
    {mode === 'idle' ? <div className="flex flex-col gap-2 sm:flex-row">
      <Button type="button" disabled={busy} onClick={() => void decide('approve')}>Approve draft {draft.revision}</Button>
      <Button type="button" variant="outline" disabled={busy} onClick={() => setMode('change')}>Request a change</Button>
    </div> : <form className="space-y-2" onSubmit={(e: FormEvent) => { e.preventDefault(); void decide('request_changes'); }}>
      <LabeledTextarea label="What should change?" value={note} onChange={e => setNote(e.target.value)} rows={3} />
      <div className="flex flex-col gap-2 sm:flex-row">
        <Button type="submit" disabled={busy}>Send change request</Button>
        <Button type="button" variant="outline" disabled={busy} onClick={() => { setMode('idle'); setError(null); }}>Cancel</Button>
      </div>
    </form>}
    {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
  </div>;
}

function StaffActions({ period, onDone, mode = 'draft' }: { mode?: 'status' | 'draft'; period: PeriodDetail; onDone: (detail: PeriodDetail) => void }) {
  const api = adminPayrollSubmissionsApi;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [paycheck, setPaycheck] = useState<File | null>(null);
  const [deposits, setDeposits] = useState<File | null>(null);
  const [note, setNote] = useState('');
  const [confirmPaid, setConfirmPaid] = useState(false);
  const retry = useRef<{ identity: string; key: string } | null>(null);
  const formRef = useRef<HTMLFormElement>(null);
  const current = period.submissions.find(s => s.current);
  const unposted = period.drafts.find(d => !d.posted && d.revision === Math.max(...period.drafts.map(x => x.revision)));
  const can = (action: string) => period.allowed_actions.includes(action as never);
  const run = async (work: () => Promise<{ data: PeriodDetail }>) => {
    setBusy(true); setError(null);
    try { onDone((await work()).data); } catch (err) { setError(err instanceof Error ? err.message : 'That did not save. Try again.'); } finally { setBusy(false); }
  };
  const draft = (post: boolean) => {
    if (!paycheck && !deposits) { setError('Attach the draft paychecks, the direct deposits, or both.'); return; }
    const identity = JSON.stringify([paycheck?.name, paycheck?.size, deposits?.name, deposits?.size, note, post]);
    if (retry.current?.identity !== identity) retry.current = { identity, key: crypto.randomUUID() };
    const form = new FormData();
    if (paycheck) form.append('paycheck_pdf', paycheck);
    if (deposits) form.append('direct_deposit_pdf', deposits);
    if (note.trim()) form.append('note', note.trim());
    form.append('post', String(post));
    form.append('idempotency_key', retry.current.key);
    void run(async () => {
      const result = await api.createDraft(period.ref, form);
      retry.current = null; setPaycheck(null); setDeposits(null); setNote(''); formRef.current?.reset();
      return result;
    });
  };
  return <div className="space-y-4">
    {mode === 'status' && can('acknowledge') && current && <div className="space-y-2">
      <Button type="button" disabled={busy} onClick={() => void run(() => api.acknowledge(period.ref, current.id))}>Confirm receipt of revision {current.revision}</Button>
    </div>}
    {mode === 'status' && can('start_review') && <Button type="button" variant="outline" disabled={busy} onClick={() => void run(() => api.startReview(period.ref))}>Start review</Button>}
    {mode === 'draft' && unposted && can('post_draft') && <div className="rounded-lg border border-warning-200 bg-warning-50 p-3">
      <p className="text-sm text-neutral-800">Draft {unposted.revision} is saved for staff only.</p>
      <Button type="button" className="mt-2" disabled={busy} onClick={() => void run(() => api.postDraft(period.ref, unposted.id))}>Post draft {unposted.revision} to the client</Button>
    </div>}
    {mode === 'draft' && can('save_draft') && <form ref={formRef} className="space-y-3" onSubmit={(e: FormEvent) => { e.preventDefault(); draft(true); }}>
      <label className="block text-sm font-medium">Draft paychecks (PDF)
        <input type="file" accept="application/pdf,.pdf" onChange={e => setPaycheck(e.target.files?.[0] || null)} className="mt-1 block w-full text-sm file:mr-3 file:min-h-11 file:rounded-md file:border file:border-neutral-300 file:bg-white file:px-3" /></label>
      <label className="block text-sm font-medium">Draft direct deposits (PDF)
        <input type="file" accept="application/pdf,.pdf" onChange={e => setDeposits(e.target.files?.[0] || null)} className="mt-1 block w-full text-sm file:mr-3 file:min-h-11 file:rounded-md file:border file:border-neutral-300 file:bg-white file:px-3" /></label>
      <LabeledTextarea label="Note to the client (optional)" value={note} onChange={e => setNote(e.target.value)} rows={2} />
      <div className="flex flex-col gap-2 sm:flex-row">
        {can('post_draft') ? <Button type="submit" disabled={busy}>Post draft for review</Button>
          : <p className="text-sm text-neutral-700">Confirm receipt of the latest files before posting a draft.</p>}
        <Button type="button" variant="outline" disabled={busy} onClick={() => draft(false)}>Save staff-only</Button>
      </div>
    </form>}
    {mode === 'status' && can('mark_paid') && (confirmPaid
      ? <div className="flex flex-col gap-2 sm:flex-row sm:items-center"><span className="text-sm">{period.status === 'approved' ? 'Mark this period paid?' : 'The client has not approved in the portal. Mark paid anyway?'}</span>
        <Button type="button" disabled={busy} onClick={() => void run(() => api.markPaid(period.ref))}>Yes, mark paid</Button>
        <Button type="button" variant="outline" onClick={() => setConfirmPaid(false)}>Cancel</Button></div>
      : <Button type="button" variant="outline" disabled={busy} onClick={() => setConfirmPaid(true)}>Mark paid</Button>)}
    {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
  </div>;
}

export function PayrollPeriodPage({ audience }: { audience: Audience }): ReactElement {
  const { ref = '', companyId } = useParams();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const inbox = searchParams.get('inbox');
  const hasInboxReturn = Boolean(inbox && /^\/app\/client-inbox(?:\?|$)/.test(inbox));
  const { activeCompanyId, activeCompany } = useCompany();
  const api = audience === 'client' ? clientPayrollSubmissionsApi : adminPayrollSubmissionsApi;
  const [period, setPeriod] = useState<PeriodDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const listPath = audience === 'client' ? '/payroll-files' : companyId ? `/companies/${companyId}/payroll-submissions` : '/settings/payroll-submissions';

  const accept = useCallback((detail: PeriodDetail) => {
    setPeriod(detail);
    // A saved period gets a stable id; keep the address on it so reloads land here.
    if (detail.id && String(detail.id) !== ref) navigate(`${listPath}/${detail.id}${window.location.search}`, { replace: true });
  }, [listPath, navigate, ref]);
  const load = useCallback(async () => {
    try { setError(null); accept((await api.get(ref)).data); } catch (err) { setError(err instanceof Error ? err.message : 'Could not load this pay period'); }
  }, [api, ref, accept]);
  useEffect(() => { void load(); }, [load]);
  // Staff mark a period seen only once it is actually shown in the
  // foreground, and only through the latest client update on screen.
  useEffect(() => {
    const id = period?.id;
    const displayed = period?.latest_client_event_id;
    if (audience !== 'staff' || !id || !displayed) return;
    let sent = false;
    const mark = (): void => {
      if (sent || document.visibilityState !== 'visible' || !document.hasFocus()) return;
      sent = true;
      void adminPayrollSubmissionsApi.seen(String(id), displayed).catch(() => { sent = false; });
    };
    mark();
    window.addEventListener('focus', mark);
    document.addEventListener('visibilitychange', mark);
    return () => { window.removeEventListener('focus', mark); document.removeEventListener('visibilitychange', mark); };
  }, [audience, period?.id, period?.latest_client_event_id]);

  if (error && !period) return <div><Header title="Pay period" /><div className="p-4 sm:p-6 lg:p-8"><p role="alert" className="rounded-lg border border-danger-200 p-4">{error}</p><Button variant="outline" className="mt-3" onClick={() => void load()}>Try again</Button></div></div>;
  if (!period) return <div><Header title="Pay period" /><p role="status" className="p-6">Loading pay period…</p></div>;

  const current = period.submissions.find(s => s.current);
  const currentDraft = period.drafts.find(d => d.current);
  const otherDrafts = period.drafts.filter(d => d !== currentDraft);
  const canSendFiles = period.accepts_files ?? activeCompany?.payroll_intake_source_types?.includes('mosa_revel');
  const canSubmit = canSendFiles && period.allowed_actions.includes('submit');
  return (
    <div>
      <Header title={`Payroll ${period.label}`} description={period.pay_date ? `Pay date ${formatDate(period.pay_date)}` : 'Pay date set by Cornerstone'} />
      <div className="mx-auto max-w-5xl space-y-5 p-4 sm:p-6 lg:p-8">
        {hasInboxReturn ? <InboxReturnLink /> : <Link to={listPath} className="inline-flex min-h-11 items-center text-sm font-semibold text-primary-800 underline">All pay periods</Link>}
        <section aria-labelledby="period-status" className="space-y-3 rounded-xl border border-neutral-200 bg-white p-4">
          <div className="flex flex-wrap items-center gap-2"><h2 id="period-status" className="text-base font-semibold text-neutral-950">Status</h2><Badge variant={statusVariant(period.status)}>{!canSendFiles && period.status === 'waiting_for_files' ? 'Messages and drafts' : period.status_label}</Badge>
            {audience === 'staff' && period.pay_period_id && <Link className="text-sm font-medium text-primary-800 underline" to={`/companies/${companyId || activeCompanyId}/pay-runs/${period.pay_period_id}`}>Open pay run</Link>}</div>
          {audience === 'staff' && <StaffActions mode="status" period={period} onDone={detail => { setNotice(null); accept(detail); }} />}
          {notice && <p role="status" className="rounded-lg bg-success-50 p-3 text-sm text-success-800">{notice}</p>}
          {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
        </section>

        <section aria-labelledby="revisions" className="space-y-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h2 id="revisions" className="text-base font-semibold text-neutral-950">What the client sent</h2>
            {audience === 'client' && canSubmit && current && !editing && <Button type="button" variant="outline" onClick={() => setEditing(true)}>Send an update or replace a file</Button>}
          </div>
          {period.submissions.length ? period.submissions.filter(revision => revision.current).map(revision => <RevisionCard key={revision.id} revision={revision} api={api} audience={audience} companyId={companyId ? Number(companyId) : activeCompanyId} />)
            : <p className="text-sm text-neutral-600">{canSendFiles ? 'No files for this period yet.' : 'Use this period to exchange messages and review drafts.'}</p>}
        </section>

        {audience === 'staff' && <section aria-labelledby="next-step" className="space-y-3 rounded-xl border border-neutral-200 bg-white p-4">
          <h2 id="next-step" className="text-base font-semibold">Next step</h2>
          {current && (companyId || activeCompanyId) ? <PortalImportAction key={current.id} period={period} companyId={Number(companyId || activeCompanyId)} onApplied={() => void load()} />
            : <p className="text-sm text-neutral-700">{canSendFiles ? 'Client files are needed before import review.' : 'Review drafts or exchange a message below.'}</p>}
        </section>}
        <section aria-labelledby="draft-section" className="space-y-3 rounded-xl border border-neutral-200 bg-white p-4">
          <h2 id="draft-section" className="text-base font-semibold">Draft for client review</h2>
          {audience === 'staff' && <StaffActions period={period} onDone={detail => { setNotice(null); accept(detail); }} />}

        {currentDraft && <div aria-labelledby="draft-review" className="space-y-3">
          <div className="flex flex-wrap items-center gap-2"><h3 id="draft-review" className="text-base font-semibold text-neutral-950">Draft {currentDraft.revision} for review</h3><Badge variant="info">Current</Badge></div>
          <p className="text-sm text-neutral-700">Posted by {currentDraft.posted_by_name} · {formatGuam(currentDraft.posted_at)}</p>
          {currentDraft.note && <p className="whitespace-pre-wrap break-words text-sm text-neutral-800">{currentDraft.note}</p>}
          <DraftFiles draft={currentDraft} api={api} audience={audience} />
          {audience === 'client' && period.allowed_actions.includes('approve') && <ClientDecision period={period} draft={currentDraft} onDone={detail => { setNotice(detail.status === 'approved' ? 'Approved. Cornerstone has been told.' : 'Change request sent to Cornerstone.'); accept(detail); }} />}
        </div>}
        {otherDrafts.map(draft => <details key={draft.id} className="py-3">
          <summary className="cursor-pointer font-semibold text-neutral-800">Draft {draft.revision} {draft.posted ? <Badge variant="outline" className="ml-2">Superseded</Badge> : <Badge variant="warning" className="ml-2">Staff only, not shared</Badge>}</summary>
          <div className="mt-3"><DraftFiles draft={draft} api={api} audience={audience} /></div>
        </details>)}

        </section>

        {audience === 'client' && canSubmit && (!current || editing) && <section className="rounded-xl border border-neutral-200 bg-white p-4">
          <SubmissionForm period={period} current={current} onCancel={current ? () => setEditing(false) : undefined}
            onSent={(detail, outcome) => { setEditing(false); setNotice(outcome === 'duplicate' ? 'Nothing changed, so no new revision was made.' : submissionReceipt(detail)); accept(detail); }} />
        </section>}
        {audience === 'client' && canSendFiles && !canSubmit && !current && <p className="rounded-xl border border-neutral-200 bg-white p-4 text-sm text-neutral-700">{period.status === 'paid' ? 'This period is paid.' : `This period opens for files on ${formatDate(period.opens_on)}.`}</p>}

        <PeriodConversation api={api} periodRef={period.id ? String(period.id) : period.ref} threadId={period.thread_id} onThreadCreated={() => void load()} />

        <section aria-labelledby="history" className="space-y-3 rounded-xl border border-neutral-200 bg-white p-4">
          <h2 id="history" className="text-base font-semibold text-neutral-950">History</h2>
          {period.submissions.filter(revision => !revision.current).map(revision => <RevisionCard key={revision.id} revision={revision} api={api} audience={audience} companyId={companyId ? Number(companyId) : activeCompanyId} />)}
          <ol className="mt-2 space-y-2">{[...period.history].reverse().map(event => <li key={event.id} className="text-sm text-neutral-800">
            <span className="font-medium">{event.to_status_label}</span> · {event.actor_name} ({event.actor_audience === 'staff' ? 'Cornerstone' : 'client'}) · <time dateTime={event.created_at}>{formatGuam(event.created_at)}</time>
            {event.note && <span className="block whitespace-pre-wrap break-words text-neutral-700">{event.note}</span>}
          </li>)}</ol>
        </section>
      </div>
    </div>
  );
}
