import { useEffect, useId, useRef, useState, type FormEvent } from 'react';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { formatGuamDate } from '@/lib/utils';
import { employeeTaxFormsApi, type EmployeeTaxFormCopy, type EmployeeTaxForms, type W2Delivery } from '@/services/employee-tax-forms-api';

function noticeLabel(notice: EmployeeTaxFormCopy['notice']): string {
  if (!notice) return 'Unknown';
  if (notice.delivery_status === 'bounced') return 'Bounced';
  if (notice.delivery_status === 'complained') return 'Reported as spam';
  if (notice.status !== 'sent') return { pending: 'Waiting to send', skipped: 'Skipped', failed: 'Send failed' }[notice.status];
  return {
    unknown: 'Sent · Delivery unknown',
    delivered: 'Sent · Delivered',
    delayed: 'Sent · Delivery delayed',
  }[notice.delivery_status];
}

export function EmployeeW2Copies({ companyId, companyName, year, canWrite, checklistLoading }: {
  companyId: number;
  companyName: string;
  year: number;
  canWrite: boolean;
  checklistLoading: boolean;
}) {
  const [list, setList] = useState<EmployeeTaxForms | null>(null);
  const [loading, setLoading] = useState(true);
  const [refresh, setRefresh] = useState(0);
  const [loadError, setLoadError] = useState(false);
  const [actionError, setActionError] = useState('');
  const [message, setMessage] = useState('');
  const [pending, setPending] = useState(false);
  const [deliveryDraft, setDeliveryDraft] = useState<W2Delivery | '' | null>(null);
  const [withdrawing, setWithdrawing] = useState<EmployeeTaxFormCopy | null>(null);
  const [reason, setReason] = useState('');
  const [withdrawError, setWithdrawError] = useState('');
  const reasonId = useId();
  const historyTitle = useRef<HTMLHeadingElement>(null);
  const api = employeeTaxFormsApi(companyId, year);
  const delivery = deliveryDraft ?? list?.w2_delivery ?? '';
  const busy = checklistLoading || loading || pending;
  const canChange = canWrite && !busy && !loadError;

  useEffect(() => {
    if (checklistLoading) return;
    const controller = new AbortController();
    setLoading(true);
    setLoadError(false);
    void employeeTaxFormsApi(companyId, year).list(controller.signal).then((result) => {
      if (!controller.signal.aborted) setList(result);
    }).catch(() => {
      if (!controller.signal.aborted) setLoadError(true);
    }).finally(() => {
      if (!controller.signal.aborted) setLoading(false);
    });
    return () => controller.abort();
  }, [checklistLoading, companyId, refresh, year]);

  function reloadList() {
    setLoading(true);
    setRefresh((value) => value + 1);
  }

  async function act(run: () => Promise<void>, fallback: string) {
    if (!canChange) return;
    setPending(true);
    setActionError('');
    setMessage('');
    setWithdrawError('');
    try {
      await run();
    } catch (error) {
      const detail = error instanceof Error ? error.message : fallback;
      if (withdrawing) setWithdrawError(detail);
      else setActionError(detail);
    } finally {
      setPending(false);
    }
  }

  function postCopies() {
    void act(async () => {
      try {
        await api.postCopies();
        setMessage('Posting requested. Refresh the list to check which copies have posted.');
      } finally {
        reloadList();
      }
    }, 'Could not request posting. Try again.');
  }

  function saveDelivery(event: FormEvent) {
    event.preventDefault();
    void act(async () => {
      const { data } = await api.setDelivery(delivery || null);
      setList((current) => current && { ...current, w2_delivery: data.w2_delivery });
      setDeliveryDraft(null);
      setMessage('Paper W-2 delivery saved.');
    }, 'Could not save paper delivery. Try again.');
  }

  function withdrawCopy(event: FormEvent) {
    event.preventDefault();
    if (!withdrawing || !reason.trim()) return;
    void act(async () => {
      const { document } = await api.withdraw(withdrawing.id, reason.trim());
      setList((current) => current && { ...current, documents: current.documents.map((copy) => copy.id === document.id ? document : copy) });
      setWithdrawing(null);
      setMessage('Copy withdrawn.');
    }, 'Could not withdraw the copy. Try again.');
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Employee app W-2 copies</CardTitle>
        <CardDescription className="break-words">{companyName} · {year} tax year. Continue sending paper copies as usual.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-5">
        {loading && !list && <p role="status" className="text-sm text-neutral-700">Loading W-2 copies…</p>}
        {loadError && <p role="alert" className="text-sm text-danger-700">Could not load the latest W-2 copies. Refresh the list to try again.</p>}
        {list && (
          <>
            <form onSubmit={saveDelivery} className="flex flex-wrap items-end gap-2">
              <Select label="Paper W-2 delivery" value={delivery} disabled={!canChange}
                onChange={(event) => setDeliveryDraft(event.target.value as W2Delivery | '')}>
                <option value="">Not set</option>
                <option value="mailed">Mailed to employees</option>
                <option value="handed_out">Handed out at work</option>
              </Select>
              {canWrite && <Button type="submit" variant="outline" disabled={!canChange || delivery === (list.w2_delivery ?? '')}>Save delivery</Button>}
            </form>
            <div className="space-y-2">
              <p className="text-sm text-neutral-700">
                {list.can_post
                  ? 'The W-2s are ready. Posting adds any missing copies and schedules email notices for eligible employees.'
                  : list.blocker_message ?? 'Posting is unavailable for this tax year.'}
              </p>
              {!canWrite && <p className="text-sm text-neutral-700">You have read-only access to these copies.</p>}
              {canWrite && <Button type="button" onClick={postCopies} disabled={!canChange || !list.can_post}>Post {year} copies</Button>}
            </div>
          </>
        )}
        {actionError && <p role="alert" className="text-sm text-danger-700">{actionError}</p>}
        {message && <p role="status" className="text-sm text-success-800">{message}</p>}
        <div className="space-y-2">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h3 ref={historyTitle} tabIndex={-1} className="font-semibold text-neutral-950">Copy history</h3>
            <Button type="button" variant="outline" onClick={reloadList} disabled={busy}>Refresh list</Button>
          </div>
          {list?.documents.length === 0 && <p className="text-sm text-neutral-700">No copies have posted for {year}.</p>}
          {!!list?.documents.length && (
            <ul className="divide-y divide-neutral-200 rounded-xl border border-neutral-200">
              {list.documents.map((copy) => (
                <li key={copy.id} className="flex flex-wrap items-center justify-between gap-3 p-3">
                  <div className="min-w-0 space-y-1 text-sm [overflow-wrap:anywhere]">
                    <p className="font-semibold text-neutral-950">{copy.employee_name ?? `Employee #${copy.employee_id}`}</p>
                    <p className="text-neutral-700">{copy.status === 'posted' ? `Posted ${formatGuamDate(copy.posted_at)}` : 'Withdrawn'} · Email notice: {noticeLabel(copy.notice)}</p>
                    {copy.inputs_changed_since_posting && <p className="font-medium text-warning-800">W-2 figures changed since posting.</p>}
                    {copy.withdrawal_note && <p className="text-neutral-700">Withdrawal reason: {copy.withdrawal_note}</p>}
                  </div>
                  {canWrite && copy.status === 'posted' && <Button type="button" variant="outline" disabled={!canChange}
                    aria-label={`Withdraw copy for ${copy.employee_name ?? `employee #${copy.employee_id}`}`}
                    onClick={() => { setReason(''); setWithdrawError(''); setWithdrawing(copy); }}>Withdraw</Button>}
                </li>
              ))}
            </ul>
          )}
        </div>
      </CardContent>

      <Dialog open={withdrawing !== null} onOpenChange={(open) => { if (!open && !pending) setWithdrawing(null); }}
        onAfterClose={() => { if (document.activeElement === document.body) historyTitle.current?.focus(); }}>
        <DialogContent>
          <form onSubmit={withdrawCopy} className="space-y-4">
            <DialogHeader>
              <DialogTitle className="[overflow-wrap:anywhere]">Withdraw {withdrawing?.employee_name ? `the copy for ${withdrawing.employee_name}` : 'this copy'}?</DialogTitle>
              <DialogDescription>The employee will see that a corrected form is being prepared and lose access to this PDF.</DialogDescription>
            </DialogHeader>
            <div className="space-y-1">
              <label htmlFor={reasonId} className="text-sm font-medium text-neutral-900">Reason for withdrawal</label>
              <Textarea id={reasonId} value={reason} maxLength={500} required disabled={pending}
                onChange={(event) => setReason(event.target.value)} />
            </div>
            {withdrawError && <p role="alert" className="text-sm text-danger-700">{withdrawError}</p>}
            <DialogFooter>
              <Button type="button" variant="outline" disabled={pending} onClick={() => setWithdrawing(null)}>Cancel</Button>
              <Button type="submit" variant="destructive" loading={pending} loadingLabel="Withdrawing…" disabled={!canChange || !reason.trim()}>Withdraw copy</Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </Card>
  );
}
