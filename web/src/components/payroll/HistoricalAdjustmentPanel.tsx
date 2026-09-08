import { useCallback, useEffect, useState, type ReactElement } from 'react';
import { AlertTriangle, FileClock, Plus, RefreshCw, RotateCcw } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { useAuth } from '@/contexts/AuthContext';
import { formatCurrency, formatDate, formatGuamDateTime } from '@/lib/utils';
import {
  historicalAdjustmentsApi,
  type HistoricalAdjustmentInput,
  type HistoricalAdjustmentPreview,
  type HistoricalPaycheck,
  type HistoricalPaycheckAdjustment,
} from '@/services/api';

interface HistoricalAdjustmentPanelProps {
  companyId: number;
  paycheck: HistoricalPaycheck;
}

const EMPTY_AMOUNTS = {
  gross_pay: 0,
  pretax_deductions: 0,
  federal_income_tax: 0,
  social_security_tax: 0,
  medicare_tax: 0,
  after_tax_deductions: 0,
  employer_taxes: 0,
  employer_contributions: 0,
};

export function HistoricalAdjustmentPanel({ companyId, paycheck }: HistoricalAdjustmentPanelProps): ReactElement {
  const { user } = useAuth();
  const canMutate = ['super_admin', 'org_admin', 'admin', 'manager'].includes(user?.role || '');
  const [rows, setRows] = useState<HistoricalPaycheckAdjustment[]>([]);
  const [loading, setLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [kind, setKind] = useState<'correction' | 'void'>('correction');
  const [reason, setReason] = useState('');
  const [reference, setReference] = useState('');
  const [amounts, setAmounts] = useState(EMPTY_AMOUNTS);
  const [preview, setPreview] = useState<HistoricalAdjustmentPreview | null>(null);
  const [acknowledgement, setAcknowledgement] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [reversingId, setReversingId] = useState<number | null>(null);
  const [reversalReason, setReversalReason] = useState('');
  const [reversalAcknowledgement, setReversalAcknowledgement] = useState('');

  const load = useCallback(async (): Promise<void> => {
    try {
      setLoading(true);
      const response = await historicalAdjustmentsApi.list(paycheck.id, companyId);
      setRows(response.data);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not load historical adjustments.');
    } finally {
      setLoading(false);
    }
  }, [companyId, paycheck.id]);

  useEffect((): void => { void load(); }, [load]);

  function input(): HistoricalAdjustmentInput {
    return {
      kind,
      effective_pay_date: paycheck.pay_date,
      reason,
      external_reference: reference || undefined,
      idempotency_key: `historical-${paycheck.id}-${Date.now()}`,
      ...(kind === 'correction' ? amounts : {}),
    };
  }

  async function buildPreview(): Promise<void> {
    try {
      setBusy(true);
      const response = await historicalAdjustmentsApi.preview(paycheck.id, input(), companyId);
      setPreview(response.data);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not preview this adjustment.');
    } finally {
      setBusy(false);
    }
  }

  async function recordAdjustment(): Promise<void> {
    if (!preview) return;
    try {
      setBusy(true);
      const reviewedInput = preview.attributes as unknown as HistoricalAdjustmentInput;
      await historicalAdjustmentsApi.create(paycheck.id, reviewedInput, preview.digest, acknowledgement, companyId);
      setShowForm(false);
      setPreview(null);
      setAcknowledgement('');
      setReason('');
      setReference('');
      setAmounts(EMPTY_AMOUNTS);
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not record this adjustment.');
    } finally {
      setBusy(false);
    }
  }

  async function recordEvent(adjustment: HistoricalPaycheckAdjustment, eventType: string): Promise<void> {
    try {
      setBusy(true);
      await historicalAdjustmentsApi.event(adjustment.id, eventType, '', companyId);
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not record the review decision.');
    } finally {
      setBusy(false);
    }
  }

  async function reverseAdjustment(adjustment: HistoricalPaycheckAdjustment): Promise<void> {
    try {
      setBusy(true);
      await historicalAdjustmentsApi.reverse(
        adjustment.id,
        reversalReason,
        `historical-reversal-${adjustment.id}-${Date.now()}`,
        reversalAcknowledgement,
        companyId,
      );
      setReversingId(null);
      setReversalReason('');
      setReversalAcknowledgement('');
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not reverse this adjustment.');
    } finally {
      setBusy(false);
    }
  }

  const reversedAdjustmentIds = new Set(
    rows.filter((row) => row.kind === 'reversal' && row.reverses_adjustment_id).map((row) => row.reverses_adjustment_id),
  );

  return (
    <div className="space-y-4 rounded-2xl border border-amber-200 bg-amber-50/60 p-4 sm:p-5">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div><p className="font-semibold text-neutral-950">Historical adjustment ledger</p><p className="mt-1 text-sm leading-6 text-neutral-600">Corrections are appended beside the locked QuickBooks record. The original values never change, and no payment or check is issued.</p></div>
        {canMutate && <Button size="sm" onClick={() => { setShowForm((value) => !value); setPreview(null); }}><Plus className="mr-2 h-4 w-4" />Record adjustment</Button>}
      </div>

      {error && <p className="rounded-xl border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">{error}</p>}
      {loading ? <p className="text-sm text-neutral-500">Loading adjustment ledger…</p> : rows.length === 0 ? <p className="text-sm text-neutral-500">No adjustments have been recorded for this source paycheck.</p> : (
        <ol className="space-y-3">
          {rows.map((row) => <li key={row.id} className="rounded-xl border border-neutral-200 bg-white p-4">
            <div className="flex flex-wrap items-center gap-2"><Badge variant="warning">{row.kind}</Badge><span className="text-sm font-semibold text-neutral-900">{formatDate(row.effective_pay_date)}</span><span className="text-sm text-neutral-500">Gross {formatCurrency(Number(row.values.gross_pay || 0))} · Net {formatCurrency(Number(row.values.net_pay || 0))}</span></div>
            <p className="mt-2 text-sm text-neutral-700">{row.reason}</p>
            <p className="mt-1 text-xs text-neutral-500">Recorded {formatGuamDateTime(row.created_at)}{row.created_by_name ? ` by ${row.created_by_name}` : ''} · Filing review: {row.filing_review_state.replaceAll('_', ' ')}</p>
            {canMutate && row.filing_review_state === 'unreviewed' && <div className="mt-3 flex flex-wrap gap-2"><Button variant="outline" size="sm" disabled={busy} onClick={() => void recordEvent(row, 'filing_reviewed_no_amendment')}>No amendment needed</Button><Button variant="outline" size="sm" disabled={busy} onClick={() => void recordEvent(row, 'filing_amendment_required')}>Amendment required</Button></div>}
            {canMutate && row.downstream_impact_required && !row.downstream_impact_acknowledged && <Button className="mt-2" variant="ghost" size="sm" disabled={busy} onClick={() => void recordEvent(row, 'downstream_impact_acknowledged')}>Acknowledge downstream payroll review</Button>}
            {canMutate && row.kind !== 'reversal' && !reversedAdjustmentIds.has(row.id) && <Button className="mt-2" variant="ghost" size="sm" disabled={busy} onClick={() => { setReversingId(row.id); setReversalReason(''); setReversalAcknowledgement(''); }}><RotateCcw className="mr-2 h-4 w-4" />Reverse adjustment</Button>}
            {reversingId === row.id && <div className="mt-3 space-y-3 rounded-xl border border-amber-200 bg-amber-50 p-3"><p className="text-sm font-semibold text-amber-950">Record an exact inverse</p><p className="text-sm leading-6 text-amber-800">This appends a reversal; it does not delete or rewrite either record.</p><label className="block text-sm font-semibold text-neutral-700">Reason<Textarea className="mt-2 bg-white" value={reversalReason} onChange={(event) => setReversalReason(event.target.value)} placeholder="Explain why this adjustment must be reversed" /></label><label className="block text-sm font-semibold text-neutral-700">Type REVERSE HISTORICAL ADJUSTMENT<Input className="mt-2 bg-white" value={reversalAcknowledgement} onChange={(event) => setReversalAcknowledgement(event.target.value)} /></label><div className="flex flex-wrap gap-2"><Button variant="outline" size="sm" disabled={busy} onClick={() => setReversingId(null)}>Cancel</Button><Button size="sm" disabled={busy || !reversalReason.trim() || reversalAcknowledgement !== 'REVERSE HISTORICAL ADJUSTMENT'} onClick={() => void reverseAdjustment(row)}><RotateCcw className="mr-2 h-4 w-4" />Record reversal</Button></div></div>}
          </li>)}
        </ol>
      )}

      {showForm && <div className="space-y-4 rounded-xl border border-neutral-200 bg-white p-4">
        <div className="grid gap-4 sm:grid-cols-2"><label className="text-sm font-semibold text-neutral-700">Action<select className="mt-2 min-h-11 w-full rounded-xl border border-neutral-300 bg-white px-3" value={kind} onChange={(event) => { setKind(event.target.value as 'correction' | 'void'); setPreview(null); }}><option value="correction">Record signed correction</option><option value="void">Void remaining source value</option></select></label><label className="text-sm font-semibold text-neutral-700">External reference<Input className="mt-2" value={reference} onChange={(event) => { setReference(event.target.value); setPreview(null); }} placeholder="Amended filing or case reference" /></label></div>
        <label className="block text-sm font-semibold text-neutral-700">Reason<Textarea className="mt-2" value={reason} onChange={(event) => { setReason(event.target.value); setPreview(null); }} placeholder="Explain the source evidence and why this adjustment is necessary" /></label>
        {kind === 'correction' && <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">{Object.entries(EMPTY_AMOUNTS).map(([field]) => <label key={field} className="text-xs font-semibold uppercase tracking-wide text-neutral-500">{field.replaceAll('_', ' ')}<Input className="mt-2" type="number" step="0.01" value={amounts[field as keyof typeof amounts]} onChange={(event) => { setAmounts((current) => ({ ...current, [field]: Number(event.target.value) })); setPreview(null); }} /></label>)}</div>}
        {!preview ? <Button disabled={busy || !reason.trim()} onClick={() => void buildPreview()}><FileClock className="mr-2 h-4 w-4" />Review impact</Button> : <div className="space-y-3 rounded-xl border border-primary-200 bg-primary-50 p-4"><p className="font-semibold text-primary-950">Preview {preview.ready ? 'is ready' : 'needs attention'}</p>{preview.errors.map((message) => <p key={message} className="text-sm text-danger-700">{message}</p>)}{preview.warnings.map((message) => <p key={message} className="flex gap-2 text-sm text-amber-800"><AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />{message}</p>)}<p className="text-sm text-neutral-600">Downstream committed payrolls to review: {preview.downstream_pay_period_ids.length}</p>{preview.ready && <><label className="block text-sm font-semibold text-neutral-700">Type RECORD HISTORICAL ADJUSTMENT<Input className="mt-2" value={acknowledgement} onChange={(event) => setAcknowledgement(event.target.value)} /></label><Button disabled={busy || acknowledgement !== 'RECORD HISTORICAL ADJUSTMENT'} onClick={() => void recordAdjustment()}><RefreshCw className="mr-2 h-4 w-4" />Record immutable adjustment</Button></>}</div>}
      </div>}
    </div>
  );
}
