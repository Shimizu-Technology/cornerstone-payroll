import { useEffect, useState, type FormEvent, type ReactElement } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { formatCurrency, formatGuamDate, formatGuamDateTimeShort } from '@/lib/utils';
import { ApiError } from '@/services/api';
import { historyResolutionLabels, payrollHistoryReviewApi, type HistoryReviewItem, type HistoryReviewList } from '@/services/payroll-history-review';

const BASE_LABELS: Record<string, string> = {
  fit_taxable_wages: 'Guam income tax wages',
  social_security_taxable_wages: 'Social Security wages',
  social_security_taxable_tips: 'Social Security tips',
  medicare_taxable_wages: 'Medicare wages',
  additional_medicare_taxable_wages: 'Additional Medicare wages',
};

function title(item: HistoryReviewItem): string {
  switch (item.subject_type) {
    case 'voided_pay_period': return `Voided payroll #${item.facts.id}`;
    case 'reversed_payroll_item': return `Reversed paycheck #${item.facts.paychecks[0].id}`;
    case 'legacy_disposition': return `Legacy disposition for paycheck #${item.facts.paychecks[0].id}`;
    case 'legacy_basis_gap': return `${item.facts.employee_name} · Missing stored taxable wages`;
    case 'imported_history': return `Imported payroll batch #${item.facts.batch_id}`;
  }
}

function Facts({ item }: { item: HistoryReviewItem }): ReactElement {
  if (item.subject_type === 'voided_pay_period') {
    const facts = item.facts;
    return (
      <div className="space-y-2 text-sm text-neutral-700">
        <p>{formatGuamDate(facts.start_date)} – {formatGuamDate(facts.end_date)} · Pay date {formatGuamDate(facts.pay_date)}</p>
        <p>{facts.item_count} payroll items · {formatCurrency(facts.gross_pay)} gross</p>
        <p>{facts.void_reason ? `Void reason: ${facts.void_reason}` : 'No void reason recorded.'}</p>
        <p>Payment records show {facts.checks_printed} printed, {facts.checks_delivered_or_cleared} delivered or cleared, and {facts.direct_deposits_confirmed} confirmed direct deposits.</p>
        {facts.replacements.length > 0 ? (
          <ul className="space-y-1">
            {facts.replacements.map((run) => (
              <li key={run.id}>Possible replacement #{run.id} · {run.status} · {formatGuamDate(run.pay_date)} · {run.item_count} items · {formatCurrency(run.gross_pay)} gross</li>
            ))}
          </ul>
        ) : <p>No matching replacement run found.</p>}
      </div>
    );
  }

  const { facts } = item;
  return (
    <div className="space-y-2 text-sm text-neutral-700">
      {'employee_name' in facts && item.subject_type !== 'legacy_basis_gap' && <p>{facts.employee_name}</p>}
      {'reason' in facts && facts.reason && <p>{facts.reason}</p>}
      <ul className="space-y-2">
        {facts.paychecks.map((check) => (
          <li key={check.id}>
            <p className="font-medium text-neutral-900">Paycheck #{check.id} · {formatGuamDate(check.pay_date)} · {formatCurrency(check.gross_pay)} gross</p>
            <p>
              Stored employee tax · Social Security {check.social_security_tax == null ? 'unrecorded' : formatCurrency(check.social_security_tax)}
              {' · Medicare '}{check.medicare_tax == null ? 'unrecorded' : formatCurrency(check.medicare_tax)}
            </p>
            {!!check.missing_bases?.length && <p>Missing {check.missing_bases.map((base) => BASE_LABELS[base]).join(', ')}</p>}
          </li>
        ))}
      </ul>
    </div>
  );
}

function ReviewDialog({ item, onDismiss, onSave, onRefresh }: {
  item: HistoryReviewItem;
  onDismiss: () => void;
  onSave: (change: { resolution_code: string; reference: string } | { reason: string }) => Promise<void>;
  onRefresh: () => void;
}): ReactElement {
  const reopen = item.status === 'resolved';
  const [code, setCode] = useState('');
  const [reference, setReference] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showStale, setShowStale] = useState(false);
  const minimum = reopen ? 1 : 10;
  const text = reference.trim();
  const valid = (reopen || code !== '') && text.length >= minimum && text.length <= 1000;

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!valid || saving || showStale) return;
    setSaving(true);
    setError(null);
    try {
      await onSave(reopen ? { reason: text } : { resolution_code: code, reference: text });
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : 'Could not save the payroll history decision.');
      setShowStale(failure instanceof ApiError && failure.status === 409);
    } finally {
      setSaving(false);
    }
  }

  return (
    <Dialog open onOpenChange={(open) => { if (!open && !saving) onDismiss(); }} dismissOnEscape={!saving}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{reopen ? 'Reopen payroll history review' : 'Resolve payroll history review'}</DialogTitle>
          <DialogDescription className="[overflow-wrap:anywhere]">{title(item)}</DialogDescription>
        </DialogHeader>
        <form className="space-y-4" onSubmit={(event) => void submit(event)}>
          {!reopen && (
            <Select label="Resolution reason" placeholder="Choose a reason" required value={code} disabled={saving || showStale}
              onChange={(event) => setCode(event.target.value)}
              options={item.resolution_codes.map((value) => ({ value, label: historyResolutionLabels[value] }))} />
          )}
          <div className="space-y-1.5">
            <label htmlFor="history-review-reference" className="text-sm font-medium text-neutral-900">
              {reopen ? 'Why are you reopening this item?' : 'Review reference'}
            </label>
            <Textarea id="history-review-reference" aria-describedby="history-review-reference-help" required minLength={minimum} maxLength={1000}
              value={reference} onChange={(event) => setReference(event.target.value)} disabled={saving || showStale} rows={3} />
            <p id="history-review-reference-help" className="text-sm text-neutral-600">
              {reopen ? 'Describe what needs another review.' : 'Describe what you verified or cite the supporting record. Enter 10–1,000 characters.'}
            </p>
          </div>
          {error && <p role="alert" className="text-sm text-danger-700">{error}</p>}
          <DialogFooter>
            <Button type="button" variant="outline" disabled={saving} onClick={onDismiss}>Cancel</Button>
            {showStale ? <Button type="button" onClick={onRefresh}>Refresh review items</Button> : (
              <Button type="submit" disabled={!valid} loading={saving} loadingLabel="Saving…">{reopen ? 'Confirm reopen' : 'Confirm resolution'}</Button>
            )}
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

export function PayrollHistoryReview({ companyId, year, onSaved, onRefresh }: {
  companyId: number;
  year: number;
  onSaved: (message: string) => Promise<void>;
  onRefresh: () => Promise<void>;
}): ReactElement {
  const [list, setList] = useState<HistoryReviewList | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [selected, setSelected] = useState<HistoryReviewItem | null>(null);
  const [refresh, setRefresh] = useState(0);

  useEffect(() => {
    let cancelled = false;
    void payrollHistoryReviewApi.list(companyId, year).then(
      (result) => { if (!cancelled) setList(result); },
      (error: unknown) => {
        if (!cancelled) setLoadError(error instanceof Error ? error.message : 'Could not load payroll history.');
      },
    );
    return () => { cancelled = true; };
  }, [companyId, year, refresh]);

  function reload() {
    setSelected(null);
    setList(null);
    setLoadError(null);
    setRefresh((attempt) => attempt + 1);
    void onRefresh();
  }

  const open = list?.data.filter((item) => item.status === 'open') ?? [];
  const resolved = list?.data.filter((item) => item.status === 'resolved') ?? [];

  return (
    <section aria-labelledby="payroll-history-review" className="scroll-mt-4">
      <Card>
        <CardHeader><h2 id="payroll-history-review" className="text-base font-display font-bold text-neutral-950">Payroll history review</h2></CardHeader>
        <CardContent className="space-y-3">
          {loadError && (
            <div className="space-y-2">
              <p role="alert" className="text-sm text-danger-700">{loadError}</p>
              <Button size="sm" variant="outline" onClick={reload}>Try again</Button>
            </div>
          )}
          {!list && !loadError && <p role="status" className="text-sm text-neutral-600">Loading payroll history…</p>}
          {list && open.length === 0 && <p className="text-sm text-neutral-600">No payroll history items need review for this year.</p>}
          {list && list.data.length > 0 && (
            <ul className="space-y-3">
              {[...open, ...resolved].map((item) => (
                <li key={item.id} className="space-y-3 rounded-xl border border-neutral-200 p-3 [overflow-wrap:anywhere] sm:p-4">
                  <div className="flex flex-wrap items-start gap-2">
                    <h3 className="min-w-0 flex-1 basis-48 text-sm font-semibold text-neutral-950">{title(item)}</h3>
                    <Badge variant={item.status === 'open' ? 'warning' : 'success'}>{item.status === 'open' ? 'Open' : 'Resolved'}</Badge>
                  </div>
                  <Facts item={item} />
                  {item.status === 'resolved' && (
                    <div className="space-y-1 rounded-lg bg-neutral-50 p-2.5 text-sm text-neutral-700">
                      <p>Reviewed by {item.resolved_by} on {item.resolved_at && formatGuamDateTimeShort(item.resolved_at)}</p>
                      <p>{item.resolution_code && historyResolutionLabels[item.resolution_code]}</p>
                      <p className="whitespace-pre-wrap">{item.resolution_reference}</p>
                    </div>
                  )}
                  {list.can_review && (
                    <Button className="min-h-11" size="sm" variant="outline" onClick={() => setSelected(item)}
                      aria-label={`${item.status === 'open' ? 'Resolve' : 'Reopen'} ${title(item)}`}>
                      {item.status === 'open' ? 'Resolve' : 'Reopen'}
                    </Button>
                  )}
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>
      {selected && (
        <ReviewDialog key={selected.id} item={selected} onDismiss={() => setSelected(null)} onRefresh={reload} onSave={async (change) => {
          const { data } = await payrollHistoryReviewApi.change(companyId, year, selected, change);
          setList((current) => current && { ...current, data: current.data.map((item) => item.id === data.id ? data : item) });
          setSelected(null);
          await onSaved(data.status === 'resolved' ? 'Payroll history item resolved.' : 'Payroll history item reopened.');
        }} />
      )}
    </section>
  );
}
