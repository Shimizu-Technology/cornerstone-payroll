import { useEffect, useRef, useState, type FormEvent, type ReactElement } from 'react';
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
        <p>{facts.item_count} payroll {facts.item_count === 1 ? 'item' : 'items'} · {formatCurrency(facts.gross_pay)} gross</p>
        <p>{facts.void_reason ? `Void reason: ${facts.void_reason}` : 'No void reason recorded.'}</p>
        <p>Payment records show {facts.checks_printed} printed, {facts.checks_delivered_or_cleared} delivered or cleared, and {facts.direct_deposits_confirmed} confirmed direct deposits.</p>
        {facts.replacements.length > 0 ? (
          <ul className="space-y-1">
            {facts.replacements.map((run) => (
              <li key={run.id}>Possible replacement #{run.id} · {run.status} · {formatGuamDate(run.pay_date)} · {run.item_count} {run.item_count === 1 ? 'item' : 'items'} · {formatCurrency(run.gross_pay)} gross</li>
            ))}
          </ul>
        ) : <p>No matching replacement run found.</p>}
      </div>
    );
  }

  const { facts, subject_type: type } = item;
  const isLegacy = type === 'legacy_basis_gap';
  const isImported = type === 'imported_history';
  const paychecks = (
    <ul className="space-y-2">
      {facts.paychecks.map((check) => (
        <li key={check.id}>
          <p className="font-medium text-neutral-900">
            {check.employee_name && `${check.employee_name} · `}Paycheck #{check.id} · {formatGuamDate(check.pay_date)} · {formatCurrency(check.gross_pay)} gross
          </p>
          <p>
            Stored employee tax · Social Security {check.social_security_tax == null ? 'unrecorded' : formatCurrency(check.social_security_tax)}
            {' · Medicare '}{check.medicare_tax == null ? 'unrecorded' : formatCurrency(check.medicare_tax)}
          </p>
          {!!check.missing_bases?.length && <p>Missing {check.missing_bases.map((base) => BASE_LABELS[base]).join(', ')}</p>}
        </li>
      ))}
    </ul>
  );

  if (isLegacy || isImported) {
    const checks = facts.paychecks;
    const dates = checks.map((check) => check.pay_date).sort();
    const firstDate = formatGuamDate(dates[0], { month: 'short', day: 'numeric', year: undefined });
    const lastDate = formatGuamDate(dates.at(-1)!, { month: 'short', day: 'numeric', year: undefined });
    const gross = checks.reduce((sum, check) => sum + Number(check.gross_pay), 0);
    const totalTax = (field: 'social_security_tax' | 'medicare_tax') => (
      checks.some((check) => check[field] == null)
        ? 'incomplete'
        : formatCurrency(checks.reduce((sum, check) => sum + Number(check[field]), 0))
    );
    return (
      <div className="space-y-2 text-sm text-neutral-700">
        {isImported && (
          <p>{facts.batch_source === 'quickbooks_online' ? 'QuickBooks Online' : 'Prior payroll provider'} · {facts.batch_status}</p>
        )}
        <p>
          {checks.length} {isLegacy ? 'older ' : ''}{checks.length === 1 ? 'paycheck' : 'paychecks'} · {firstDate}
          {lastDate !== firstDate && `–${lastDate}`} · {formatCurrency(gross)} gross · Stored SS {totalTax('social_security_tax')} / Medicare {totalTax('medicare_tax')}
        </p>
        <details>
          <summary className="min-h-11 cursor-pointer py-2 font-medium text-primary-700 underline">Show paychecks</summary>
          {paychecks}
        </details>
      </div>
    );
  }

  return (
    <div className="space-y-2 text-sm text-neutral-700">
      {'employee_name' in facts && <p>{facts.employee_name}</p>}
      {'reason' in facts && facts.reason && <p>{facts.reason}</p>}
      {paychecks}
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
          <DialogFooter className="gap-2">
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

function ReviewList({ items, canReview, onSelect }: {
  items: HistoryReviewItem[];
  canReview: boolean;
  onSelect: (item: HistoryReviewItem) => void;
}): ReactElement {
  return (
    <ul className="space-y-3">
      {items.map((item) => (
        <li key={item.id} className="space-y-3 rounded-xl border border-neutral-200 p-3 [overflow-wrap:anywhere] sm:p-4">
          <div className="flex flex-wrap items-start gap-2">
            <h3 className="min-w-0 flex-1 basis-48 text-sm font-semibold text-neutral-950">{title(item)}</h3>
            {item.status === 'open' && <Badge variant="warning">Open</Badge>}
          </div>
          <Facts item={item} />
          {item.status === 'resolved' && (
            <div className="space-y-1 rounded-lg bg-neutral-50 p-2.5 text-sm text-neutral-700">
              <p>Reviewed by {item.resolved_by} on {item.resolved_at && formatGuamDateTimeShort(item.resolved_at)}</p>
              <p>{item.resolution_code && historyResolutionLabels[item.resolution_code]}</p>
              <p className="whitespace-pre-wrap">{item.resolution_reference}</p>
            </div>
          )}
          {canReview && (item.status === 'open' || item.can_reopen) && (
            <Button className="min-h-11" size="sm" variant="outline" onClick={() => onSelect(item)}
              aria-label={`${item.status === 'open' ? 'Resolve' : 'Reopen'} ${title(item)}`}>
              {item.status === 'open' ? 'Resolve' : 'Reopen'}
            </Button>
          )}
        </li>
      ))}
    </ul>
  );
}

export function PayrollHistoryReview({ companyId, year, onSaved, onRefresh }: {
  companyId: number;
  year: number;
  onSaved: (message: string) => Promise<void>;
  onRefresh: () => Promise<void>;
}): ReactElement {
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    if (window.location.hash === '#payroll-history-review') {
      heading.current?.scrollIntoView?.();
    }
  }, []);
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
    <section aria-labelledby="payroll-history-review">
      <Card>
        <CardHeader><h2 ref={heading} id="payroll-history-review" className="scroll-mt-24 text-base font-display font-bold text-neutral-950">Payroll history review</h2></CardHeader>
        <CardContent className="space-y-3">
          {loadError && (
            <div className="space-y-2">
              <p role="alert" className="text-sm text-danger-700">{loadError}</p>
              <Button size="sm" variant="outline" onClick={reload}>Try again</Button>
            </div>
          )}
          {!list && !loadError && <p role="status" className="text-sm text-neutral-600">Loading payroll history…</p>}
          {list && open.length === 0 && <p className="text-sm text-neutral-600">No payroll history items need review for this year.</p>}
          {list && !list.can_review && <p className="text-sm text-neutral-600">Admins can record these decisions.</p>}
          {list && open.length > 0 && <ReviewList items={open} canReview={list.can_review} onSelect={setSelected} />}
          {list && resolved.length > 0 && (
            <details className="rounded-xl border border-neutral-200 p-3">
              <summary className="min-h-11 cursor-pointer py-2 text-sm font-semibold text-neutral-950">Resolved ({resolved.length})</summary>
              <ReviewList items={resolved} canReview={list.can_review} onSelect={setSelected} />
            </details>
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
