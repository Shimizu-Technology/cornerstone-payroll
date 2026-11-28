import { useEffect, useRef, useState, type FormEvent, type RefObject } from 'react';
import { Link, useLocation, useParams, useSearchParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { ChangeComparison } from '@/components/employees/ChangeComparison';
import { Alert } from '@/components/ui/alert';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { useSelectedCompanyCapability } from '@/hooks/useSelectedCompanyCapability';
import { formatDate } from '@/lib/display-date';
import { canWriteCompany } from '@/lib/company-write-access';
import { formatGuamDateTime } from '@/lib/utils';
import { currentAppPath, employeeEditPath, employeePath, safeInternalReturnPath } from '@/lib/routes';
import { parsePositiveRouteId } from '@/lib/route-params';
import { ApiError } from '@/services/api';
import { staffEmployeeLifecycleApi, type VerificationDetails, type VerificationEvent, type VerificationRow, type VerificationStatus } from '@/services/staff-employee-lifecycle';
import { StaffReadinessChecklist } from './employees/StaffReadinessChecklist';
import { VerificationWarnings } from './employees/VerificationWarnings';

const eventLabels: Record<VerificationEvent, string> = {
  new_hire: 'New hire',
  compensation_change: 'Pay change',
  w4_change: 'W-4 change',
  payment_method_change: 'Payment method change',
  identity_tax_change: 'Tax ID or identity change',
  contractor_tax_change: 'Contractor tax change',
  termination: 'Termination',
  rehire: 'Rehire',
  profile_change: 'Profile change',
};

const statusLabels: Record<VerificationStatus, string> = {
  pending_verification: 'Pending verification',
  returned_to_client: 'Sent back to client',
  verified: 'Verified',
  superseded: 'Replaced by a newer item',
};

export interface SavedVerificationFix {
  id: number;
  companyId: number;
  employeeId: number;
  revision: string;
}

type Decision = 'verify' | 'send-back' | 'verify-fix';

function safeComparisonValues(values: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(values).map(([field, value]) => [field, maskValue(value, field)]));
}

function maskValue(value: unknown, field = ''): unknown {
  if (value == null) return value;
  if (/(^|_)(ssn|ein|tax_id)(_|$)/i.test(field)) {
    const digits = String(value).replace(/\D/g, '');
    return digits.length >= 4 ? `Ending in ${digits.slice(-4)}` : 'Hidden';
  }
  if (Array.isArray(value)) return value.map(entry => maskValue(entry));
  if (typeof value === 'object') return safeComparisonValues(value as Record<string, unknown>);
  return typeof value === 'string' ? maskSsnInText(value) : value;
}

function maskSsnInText(text: string) {
  return text.replace(/\b\d{3}[- ]?\d{2}[- ]?(\d{4})\b/g, '***-**-$1');
}

function isLifecycleDisabled(error: unknown) {
  return error instanceof ApiError && (error.data as { code?: string } | undefined)?.code === 'client_lifecycle_disabled';
}

export function EmployeeVerificationQueue() {
  const { companyId: rawCompanyId } = useParams();
  const companyId = parsePositiveRouteId(rawCompanyId) ?? 0;
  return <CompanyVerificationQueue key={companyId} companyId={companyId} />;
}

function CompanyVerificationQueue({ companyId }: { companyId: number }) {
  const [params, setParams] = useSearchParams();
  const location = useLocation();
  const { activeCompany, activeCompanyId, refreshCompanies } = useCompany();
  const { hasCapability } = useAuth();
  const canManage = useSelectedCompanyCapability('manage_client_configuration', companyId)
    && canWriteCompany(activeCompany, 'manage_client_configuration');
  const canStartFinalPay = hasCapability('payroll_operations') && canWriteCompany(activeCompany)
    && activeCompany?.test_workspace_purpose !== 'training_replay';
  const canViewAudit = hasCapability('view_audit_history');
  const companyReady = companyId > 0 && activeCompanyId === companyId;
  const selectedId = parsePositiveRouteId(params.get('item_id') ?? undefined);
  const eventFilter = params.get('event') as VerificationEvent | null;
  const event = eventFilter && Object.hasOwn(eventLabels, eventFilter) ? eventFilter : undefined;
  const statusFilter = params.get('status') as VerificationStatus | null;
  const status = statusFilter && Object.hasOwn(statusLabels, statusFilter) ? statusFilter : 'pending_verification';
  const search = params.get('q') ?? '';
  const page = parsePositiveRouteId(params.get('page') ?? undefined) ?? 1;
  const [list, setList] = useState<{ rows: VerificationRow[]; pages: number; error?: string } | null>(null);
  const [detail, setDetail] = useState<{ id: number; item?: VerificationDetails; error?: string } | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [decision, setDecision] = useState<{ itemId: number; action: Decision } | null>(null);
  const [dismissedFix, setDismissedFix] = useState<string | null>(null);
  const detailHeading = useRef<HTMLHeadingElement>(null);
  const decisionTrigger = useRef<HTMLButtonElement>(null);
  const lastCard = useRef<HTMLButtonElement | null>(null);
  const listHeading = useRef<HTMLHeadingElement>(null);
  const item = detail?.item;
  const currentItem = item && item.id === selectedId && item.company_id === companyId ? item : undefined;
  const savedFix = (location.state as { lifecycleFix?: SavedVerificationFix } | null)?.lifecycleFix;
  const matchesSavedFix = Boolean(savedFix && currentItem && savedFix.id === currentItem.id
    && savedFix.companyId === currentItem.company_id && savedFix.employeeId === currentItem.employee_id);
  const fixRevision = matchesSavedFix ? savedFix?.revision : undefined;

  useEffect(() => {
    if (!companyReady) return;
    const controller = new AbortController();
    staffEmployeeLifecycleApi.list(companyId, { status, event_kind: event, search: search || undefined, page, per_page: 25 }, controller.signal).then(
      response => { if (!controller.signal.aborted) setList({ rows: response.data, pages: response.meta.total_pages }); },
      (error: unknown) => {
        if (controller.signal.aborted) return;
        setList({ rows: [], pages: 0, error: isLifecycleDisabled(error) ? undefined : error instanceof Error ? error.message : 'Could not load employee changes.' });
      },
    );
    return () => controller.abort();
  }, [companyReady, companyId, status, event, search, page, attempt]);

  useEffect(() => {
    if (!companyReady || !selectedId) return;
    const controller = new AbortController();
    staffEmployeeLifecycleApi.get(companyId, selectedId, controller.signal).then(
      response => { if (!controller.signal.aborted) setDetail({ id: selectedId, item: response.data }); },
      (error: unknown) => {
        if (!controller.signal.aborted) setDetail({ id: selectedId, error: error instanceof Error ? error.message : 'Could not load this employee change.' });
      },
    );
    return () => controller.abort();
  }, [companyReady, companyId, selectedId, attempt]);

  const detailReady = currentItem?.id;
  useEffect(() => {
    if (detailReady) detailHeading.current?.focus();
  }, [detailReady]);

  const updateParams = (changes: Record<string, string | null>, replace = false) => {
    const changed = new URLSearchParams(params);
    for (const [key, value] of Object.entries(changes)) {
      if (value) changed.set(key, value);
      else changed.delete(key);
    }
    setParams(changed, { replace });
  };

  const pick = (id: number, trigger: HTMLButtonElement) => {
    lastCard.current = trigger;
    setDecision(null);
    updateParams({ item_id: String(id) });
  };

  const changeFilter = (key: string, value: string, replace = false) => {
    setList(null);
    setDecision(null);
    updateParams({ [key]: value, page: null, item_id: null }, replace);
  };

  const closeDetail = () => {
    updateParams({ item_id: null });
    setDecision(null);
    requestAnimationFrame(() => (lastCard.current?.isConnected ? lastCard.current : listHeading.current)?.focus());
  };

  const reload = () => {
    setDecision(null);
    setDismissedFix(location.key);
    setList(null);
    setDetail(null);
    setAttempt(value => value + 1);
  };

  const inbox = params.get('inbox');
  const inboxPath = inbox ? safeInternalReturnPath(inbox, '/app/client-inbox') : null;
  const queuePath = currentAppPath(location.pathname, location.search);
  const editPath = currentItem ? employeeEditPath(companyId, currentItem.employee_id, { returnTo: queuePath }) : '';
  const fixPath = `${editPath}${editPath.includes('?') ? '&' : '?'}verify_item_id=${currentItem?.id}`;
  const canReview = canManage && currentItem?.can_review;
  const selectedDecision = decision?.itemId === selectedId ? decision?.action : null;
  const openDecision = selectedDecision ?? (canReview && fixRevision === currentItem?.updated_at && dismissedFix !== location.key ? 'verify-fix' : null);

  return <>
    <Header title="To verify" description="Review employee changes made by your clients."
      actions={inboxPath ? <Link className="inline-flex min-h-11 items-center font-semibold text-primary-700 underline" to={inboxPath}>Back to Client Inbox</Link> : undefined} />
    <div className="grid min-w-0 gap-5 p-4 lg:grid-cols-[minmax(16rem,2fr)_minmax(0,3fr)] lg:p-8">
      <section className={selectedId ? 'hidden min-w-0 lg:block' : 'min-w-0'} aria-labelledby="verification-list-heading">
        <Card><CardContent className="space-y-4 pt-5">
          <h2 id="verification-list-heading" ref={listHeading} tabIndex={-1} className="font-semibold">Employee changes</h2>
          <div className="grid gap-3">
            <Input label="Search by employee" type="search" className="h-11 text-base!" value={search} onChange={e => changeFilter('q', e.target.value, true)} />
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-1 xl:grid-cols-2">
              <Select label="Status" className="h-11 text-base!" value={status} onChange={e => changeFilter('status', e.target.value)}>
                {Object.entries(statusLabels).filter(([key]) => key !== 'superseded').map(([key, label]) => <option key={key} value={key}>{label}</option>)}
              </Select>
              <Select label="Change type" className="h-11 text-base!" value={event ?? ''} onChange={e => changeFilter('event', e.target.value)}>
                <option value="">All changes</option>
                {Object.entries(eventLabels).map(([key, label]) => <option key={key} value={key}>{label}</option>)}
              </Select>
            </div>
          </div>
          {!list && <p role="status" className="text-sm text-neutral-600">Loading employee changes…</p>}
          {list?.error && <Alert tone="error">{list.error}<Button className="mt-2 block min-h-11!" variant="outline" onClick={reload}>Try again</Button></Alert>}
          {list && !list.error && !list.rows.length && <p className="text-sm text-neutral-600">No employee changes match these filters.</p>}
          <ul className="space-y-2">
            {list?.rows.map(row => <li key={row.id}>
              <button type="button" aria-current={selectedId === row.id ? 'true' : undefined}
                className="w-full min-w-0 rounded-lg border border-neutral-200 p-3 text-left hover:bg-primary-50 focus-visible:outline-2 focus-visible:outline-offset-2 aria-current:border-primary-400 aria-current:bg-primary-50"
                onClick={e => pick(row.id, e.currentTarget)}>
                <span className="block wrap-anywhere font-semibold">{row.employee_name}</span>
                <span className="block text-sm text-neutral-700">{eventLabels[row.event_kind]} · {statusLabels[row.status]}</span>
                <span className="block text-xs text-neutral-600">{formatGuamDateTime(row.updated_at)}</span>
              </button>
            </li>)}
          </ul>
          {list && (list.pages > 1 || page > 1) && <div className="flex flex-wrap items-center justify-between gap-2">
            <Button className="min-h-11!" variant="outline" disabled={page <= 1} onClick={() => changeFilter('page', String(page - 1))}>Previous</Button>
            <span className="text-sm">Page {page}</span>
            <Button className="min-h-11!" variant="outline" disabled={page >= list.pages} onClick={() => changeFilter('page', String(page + 1))}>Next</Button>
          </div>}
        </CardContent></Card>
      </section>
      <section className={selectedId ? 'min-w-0 space-y-3' : 'hidden min-w-0 lg:block'} aria-label="Verification details">
        {selectedId && <Button className="min-h-11 lg:hidden" variant="outline" onClick={closeDetail}>Back to employee changes</Button>}
        <Card><CardContent className="space-y-5 pt-5">
          {!selectedId && <p className="text-sm text-neutral-600">Select an employee change to review its details.</p>}
          {selectedId && detail?.id !== selectedId && <p role="status" className="text-sm text-neutral-600">Loading change details…</p>}
          {selectedId && detail?.id === selectedId && detail.error && <Alert tone="error">{detail.error}<Button className="mt-2 block min-h-11!" variant="outline" onClick={reload}>Try again</Button></Alert>}
          {currentItem && <>
            <div>
              <Badge variant={currentItem.status === 'verified' ? 'success' : 'outline'}>{statusLabels[currentItem.status]}</Badge>
              <h2 ref={detailHeading} tabIndex={-1} className="mt-2 wrap-anywhere text-xl font-semibold">{currentItem.employee_name}</h2>
              <p className="mt-1 wrap-anywhere text-sm text-neutral-700">{eventLabels[currentItem.event_kind]} · {currentItem.source_actor_name || 'Former portal user'} · {formatGuamDateTime(currentItem.resubmitted_at || (currentItem.status === 'pending_verification' ? currentItem.updated_at : currentItem.created_at))}</p>
              {currentItem.effective_on && <p className="mt-1 text-sm text-neutral-700">Effective {formatDate(currentItem.effective_on)}</p>}
              <Link className="inline-flex min-h-11 items-center font-semibold text-primary-700 underline" to={employeePath(companyId, currentItem.employee_id, 'overview', { returnTo: queuePath })}>Open employee record</Link>
            </div>
            <VerificationWarnings item={currentItem} canStartFinalPay={canStartFinalPay} />
            {currentItem.changed_fields.length > 0 && <div className="min-w-0">
              <h3 className="mb-2 font-semibold">Changes since last verification</h3>
              <ChangeComparison before={safeComparisonValues(currentItem.before_values)} after={safeComparisonValues(currentItem.after_values)} />
            </div>}
            <StaffReadinessChecklist checklist={currentItem.readiness_checklist} />
            {(currentItem.return_note || currentItem.audit_references.some(reference => reference.return_note)) && <div>
              <h3 className="font-semibold">Notes sent to the client</h3>
              <ul className="mt-1 space-y-2 text-sm">{[...new Set([...currentItem.audit_references.map(entry => entry.return_note), currentItem.return_note])].filter(Boolean).map(note => <li key={note} className="whitespace-pre-wrap wrap-anywhere">{note && maskSsnInText(note)}</li>)}</ul>
            </div>}
            {currentItem.client_response_note && <div><h3 className="font-semibold">Client response</h3><p className="whitespace-pre-wrap wrap-anywhere text-sm">{maskSsnInText(currentItem.client_response_note)}</p></div>}
            {currentItem.verification_note && <div><h3 className="font-semibold">Internal verification note</h3><p className="whitespace-pre-wrap wrap-anywhere text-sm">{maskSsnInText(currentItem.verification_note)}</p></div>}
            {canViewAudit && currentItem.audit_references.some(entry => entry.staff_edit_audit_id) &&
              <Link className="inline-flex min-h-11 items-center font-semibold text-primary-700 underline" to={employeePath(companyId, currentItem.employee_id, 'activity', { returnTo: queuePath })}>View employee edit history</Link>}
            {canReview && <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap">
              <Button className="min-h-11!" onClick={event => {
                decisionTrigger.current = event.currentTarget;
                setDecision({ itemId: currentItem.id, action: 'verify' });
              }}>Mark verified</Button>
              <Link className="inline-flex min-h-11 items-center justify-center rounded-lg border border-neutral-300 px-4 font-semibold text-neutral-800 hover:bg-neutral-50" to={fixPath}>Fix &amp; verify</Link>
              {currentItem.status === 'pending_verification' && <Button variant="outline" className="min-h-11!" onClick={event => {
                decisionTrigger.current = event.currentTarget;
                setDecision({ itemId: currentItem.id, action: 'send-back' });
              }}>Send back to client</Button>}
            </div>}
            {canReview && fixRevision && fixRevision !== currentItem.updated_at && <Alert>Employee details were saved. This verification item changed while you were editing. Review the latest details before deciding.</Alert>}
            {canReview && openDecision && <VerificationDecision key={`${currentItem.id}:${openDecision}`} item={currentItem} decision={openDecision}
              returnFocusRef={openDecision === 'verify-fix' ? detailHeading : decisionTrigger}
              onClose={() => { setDecision(null); setDismissedFix(location.key); }}
              onReload={reload} onSaved={saved => {
                setDetail({ id: saved.id, item: saved });
                setDecision(null);
                setDismissedFix(location.key);
                setAttempt(value => value + 1);
                requestAnimationFrame(() => detailHeading.current?.focus());
                window.dispatchEvent(new Event('portal-work-changed'));
                if (saved.status === 'verified' && !activeCompany?.client_managed_employee_lifecycle) void refreshCompanies?.();
              }} />}
          </>}
        </CardContent></Card>
      </section>
    </div>
  </>;
}

function VerificationDecision({ item, decision, returnFocusRef, onClose, onSaved, onReload }: {
  item: VerificationDetails;
  decision: Decision;
  returnFocusRef: RefObject<HTMLElement | null>;
  onClose: () => void;
  onSaved: (item: VerificationDetails) => void;
  onReload: () => void;
}) {
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<{ message: string; conflict: boolean } | null>(null);
  const sendingBack = decision === 'send-back';
  const title = sendingBack ? 'Send back to client' : decision === 'verify-fix' ? 'Mark the saved fix verified?' : 'Mark verified';
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (busy || (sendingBack && note.trim().length < 5)) return;
    setBusy(true);
    setFailure(null);
    try {
      const result = sendingBack
        ? await staffEmployeeLifecycleApi.sendBack(item.company_id, item.id, { updated_at: item.updated_at, return_note: note.trim() })
        : await staffEmployeeLifecycleApi.verify(item.company_id, item.id, {
          updated_at: item.updated_at, verification_note: note.trim(), fixed_by_staff: decision === 'verify-fix',
        });
      onSaved(result.data);
    } catch (error) {
      setFailure({ message: error instanceof Error ? error.message : 'Could not save the decision.', conflict: error instanceof ApiError && error.status === 409 });
    } finally {
      setBusy(false);
    }
  };
  return <Dialog open returnFocusRef={returnFocusRef} onOpenChange={open => { if (!open && !busy) onClose(); }}>
    <DialogContent>
      <DialogHeader>
        <DialogTitle>{title}</DialogTitle>
        <DialogDescription>{sendingBack ? 'Tell the client what to check or correct. They will see your note.' : 'The change will be marked verified and cleared from payroll verification warnings.'}</DialogDescription>
      </DialogHeader>
      <form className="space-y-4" onSubmit={submit}>
        <label className="block space-y-2 text-sm font-medium">
          <span>{sendingBack ? 'Note to client (5–1,000 characters)' : 'Internal note (optional)'}</span>
          <Textarea autoFocus className="text-base!" maxLength={1000} required={sendingBack}
            value={note} onChange={event => setNote(event.target.value)} disabled={busy} />
        </label>
        {failure && <Alert tone="error">{failure.message}</Alert>}
        <DialogFooter>
          <Button className="min-h-11!" type="button" variant="outline" disabled={busy} onClick={onClose}>Cancel</Button>
          {failure?.conflict ? <Button className="min-h-11!" type="button" onClick={onReload}>Load latest change</Button>
            : <Button className="min-h-11!" type="submit" disabled={busy || (sendingBack && note.trim().length < 5)}>{busy ? 'Saving…' : sendingBack ? 'Send back' : 'Mark verified'}</Button>}
        </DialogFooter>
      </form>
    </DialogContent>
  </Dialog>;
}
