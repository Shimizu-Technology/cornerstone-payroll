import { clientPayrollStatus } from '@/lib/clientPayrollStatus';
import { payRunPath } from '@/lib/routes';
import { ApiError } from '@/services/api';
import { useCallback, useEffect, useState, type ReactElement } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
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

function StaffActions({ period, onDone, mode = 'draft', busy, setBusy }: { mode?: 'status' | 'draft'; period: PeriodDetail; onDone: (detail: PeriodDetail) => void; busy: boolean; setBusy: (busy: boolean) => void }) {
  const api = adminPayrollSubmissionsApi;
  const [error, setError] = useState<string | null>(null);
  const current = period.submissions.find(s => s.current);
  const can = (action: string) => period.allowed_actions.includes(action as never);
  const run = async (work: () => Promise<{ data: PeriodDetail }>) => {
    setBusy(true); setError(null);
    try { onDone((await work()).data); } catch (err) { setError(err instanceof Error ? err.message : 'That did not save. Try again.'); } finally { setBusy(false); }
  };
  return <div className="space-y-4">
    {mode === 'status' && can('acknowledge') && current && <div className="space-y-2">
      <p className="text-sm text-neutral-700">Confirming tells the client you have revision {current.revision}.</p>
      <Button type="button" disabled={busy} onClick={() => void run(() => api.acknowledge(period.ref, current.id))}>Confirm receipt of revision {current.revision}</Button>
    </div>}
    {mode === 'status' && can('start_review') && <Button type="button" variant="outline" disabled={busy} onClick={() => void run(() => api.startReview(period.ref))}>Start review</Button>}
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
  const [staffBusy, setStaffBusy] = useState(false);
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
  // Links from the pay run point at a revision; bring it into view once loaded.
  const loaded = Boolean(period);
  useEffect(() => {
    if (loaded && window.location.hash) document.getElementById(window.location.hash.slice(1))?.scrollIntoView({ block: 'start' });
  }, [loaded]);
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
      void adminPayrollSubmissionsApi.seen(String(id), displayed).catch((error: unknown) => {
        if (!(error instanceof ApiError && error.isWriteMaintenance)) sent = false;
      });
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
  const reviewCompanyId = companyId ? Number(companyId) : activeCompanyId;
  return (
    <div>
      <Header title={`Payroll ${period.label}`} description={period.pay_date ? `Pay date ${formatDate(period.pay_date)}` : 'Pay date set by Cornerstone'} />
      <div className="mx-auto max-w-5xl space-y-5 p-4 sm:p-6 lg:p-8">
        {hasInboxReturn ? <InboxReturnLink /> : <Link to={listPath} className="inline-flex min-h-11 items-center text-sm font-semibold text-primary-800 underline">All pay periods</Link>}
        <section aria-labelledby="period-status" className="space-y-3 rounded-xl border border-neutral-200 bg-white p-4">
          <div className="flex flex-wrap items-center gap-2"><h2 id="period-status" className="text-base font-semibold text-neutral-950">Status</h2><Badge variant={statusVariant(period.status)}>{audience === 'client' && period.client_payroll_status ? clientPayrollStatus(period.client_payroll_status) : !canSendFiles && period.status === 'waiting_for_files' ? 'Messages and drafts' : period.status_label}</Badge>
            {audience === 'staff' && period.pay_period_id && <Link className="text-sm font-medium text-primary-800 underline" to={`/companies/${companyId || activeCompanyId}/pay-runs/${period.pay_period_id}`}>Open pay run</Link>}</div>
          {audience === 'client' && period.review_pay_period_id && reviewCompanyId && (
            <Link className="inline-flex min-h-11 items-center font-semibold text-primary-800 underline" to={payRunPath(reviewCompanyId, period.review_pay_period_id)}>
              {period.client_payroll_status === 'committed' ? 'View payroll' : 'Open payroll preview'}
            </Link>
          )}
          {audience === 'client' && period.status === 'in_review' && period.client_payroll_status === 'committed' && (
            <p className="text-sm text-neutral-700">{period.status_label}</p>
          )}
          {audience === 'staff' && <StaffActions mode="status" busy={staffBusy} setBusy={setStaffBusy} period={period} onDone={detail => { setNotice(null); accept(detail); }} />}
          {notice && <p role="status" className="rounded-lg bg-success-50 p-3 text-sm text-success-800">{notice}</p>}
          {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
        </section>

        <section aria-labelledby="revisions" className="space-y-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h2 id="revisions" className="text-base font-semibold text-neutral-950">What the client sent</h2>
            {audience === 'client' && canSubmit && current && !editing && <Button type="button" variant="outline" onClick={() => setEditing(true)}>Send an update or replace a file</Button>}
          </div>
          {period.submissions.length ? period.submissions.filter(revision => revision.current).map(revision => <RevisionCard key={revision.id} revision={revision} api={api} audience={audience} companyId={companyId ? Number(companyId) : activeCompanyId} />)
            : <p className="text-sm text-neutral-600">{canSendFiles ? 'No files for this period yet.' : audience === 'staff' ? 'Use this period for source files and messages. Review payroll in the preview section.' : 'Use this period for source files and messages.'}</p>}
        </section>

        {audience === 'staff' && <section aria-labelledby="next-step" className="space-y-3 rounded-xl border border-neutral-200 bg-white p-4">
          <h2 id="next-step" className="text-base font-semibold">Next step</h2>
          {current && (companyId || activeCompanyId) ? <PortalImportAction key={current.id} period={period} companyId={Number(companyId || activeCompanyId)} onApplied={() => void load()} />
            : <p className="text-sm text-neutral-700">{canSendFiles ? 'Client files are needed before import review.' : 'Open the payroll preview review or exchange a message below.'}</p>}
        </section>}
        <section aria-labelledby="draft-section" className="space-y-3 rounded-xl border border-neutral-200 bg-white p-4">
          <h2 id="draft-section" className="text-base font-semibold">Payroll preview review</h2>
          {audience === 'staff' ? (
            <p className="text-sm text-neutral-700">Review and approve the preview on the pay run. Payroll files finish when Cornerstone commits that run. Earlier uploaded drafts remain below as history.</p>
          ) : !period.review_pay_period_id && period.client_payroll_status !== 'committed' && (
            <p className="text-sm text-neutral-700">Cornerstone is preparing this payroll.</p>
          )}
          {audience === 'staff' && period.pay_period_link_error && <p role="alert" className="break-words text-sm text-warning-950">{period.pay_period_link_error}</p>}
          {audience === 'staff' && period.review_pay_period_id && <Link className="inline-flex min-h-11 items-center font-semibold text-primary-800 underline" to={`/companies/${companyId || activeCompanyId}/pay-runs/${period.review_pay_period_id}`}>Open payroll preview review</Link>}
          {audience === 'staff' && <StaffActions busy={staffBusy} setBusy={setStaffBusy} period={period} onDone={detail => { setNotice(null); accept(detail); }} />}

        {currentDraft && <div aria-labelledby="draft-review" className="space-y-3">
          <div className="flex flex-wrap items-center gap-2"><h3 id="draft-review" className="text-base font-semibold text-neutral-950">Earlier draft {currentDraft.revision}</h3><Badge variant="outline">History</Badge></div>
          <p className="text-sm text-neutral-700">Posted by {currentDraft.posted_by_name} · {formatGuam(currentDraft.posted_at)}</p>
          {currentDraft.note && <p className="whitespace-pre-wrap break-words text-sm text-neutral-800">{currentDraft.note}</p>}
          <DraftFiles draft={currentDraft} api={api} audience={audience} />
        </div>}
        {audience === 'client' && !currentDraft && !otherDrafts.length && <p className="text-sm text-neutral-600">No earlier uploaded drafts for this period.</p>}
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

        {(period.history.length > 0 || period.submissions.length > 1) && <section aria-labelledby="history" className="space-y-3 rounded-xl border border-neutral-200 bg-white p-4">
          <h2 id="history" className="text-base font-semibold text-neutral-950">History</h2>
          {period.submissions.filter(revision => !revision.current).map(revision => <RevisionCard key={revision.id} revision={revision} api={api} audience={audience} companyId={companyId ? Number(companyId) : activeCompanyId} />)}
          <ol className="mt-2 space-y-2">{[...period.history].reverse().map(event => <li key={event.id} className="text-sm text-neutral-800">
            <span className="font-medium">{event.to_status_label}</span> · {event.actor_name} ({event.actor_audience === 'staff' ? 'Cornerstone' : 'client'}) · <time dateTime={event.created_at}>{formatGuam(event.created_at)}</time>
            {event.note && <span className="block whitespace-pre-wrap break-words text-neutral-700">{event.note}</span>}
          </li>)}</ol>
        </section>}
      </div>
    </div>
  );
}
