import { useCallback, useEffect, useMemo, useState } from 'react';
import { Download, RefreshCw } from 'lucide-react';
import { useNavigate } from 'react-router';
import { checkRegisterApi } from '@/services/api';
import type { CheckPaymentStatus, CheckRegister as CheckRegisterData, CheckRegisterRow } from '@/types';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { guamBusinessDate } from '@/lib/payrollBusinessDate';

const STATUS_LABELS: Record<CheckPaymentStatus, string> = {
  unprepared: 'Not prepared',
  prepared: 'Prepared',
  issued: 'Issued',
  cleared: 'Cleared',
  replacement_required: 'Replacement needed',
  voided: 'Voided',
};

const STATUS_VARIANTS: Record<CheckPaymentStatus, 'default' | 'info' | 'success' | 'warning' | 'danger'> = {
  unprepared: 'default',
  prepared: 'info',
  issued: 'warning',
  cleared: 'success',
  replacement_required: 'danger',
  voided: 'default',
};

type ReconciliationAction = 'cleared' | 'clearing_reversed' | 'replacement_required';

interface CheckRegisterProps {
  companyId: number | null;
  refreshVersion?: number;
}

function guamYearStart(): string {
  return `${guamBusinessDate().slice(0, 4)}-01-01`;
}

function formatCurrency(value: string | number): string {
  return Number(value).toLocaleString(undefined, { style: 'currency', currency: 'USD' });
}

function formatDate(value: string | null): string {
  if (!value) return '—';
  return new Date(`${value}T00:00:00`).toLocaleDateString();
}

export function CheckRegister({ companyId, refreshVersion }: CheckRegisterProps) {
  const navigate = useNavigate();
  const [register, setRegister] = useState<CheckRegisterData | null>(null);
  const [from, setFrom] = useState(guamYearStart());
  const [to, setTo] = useState(guamBusinessDate());
  const [status, setStatus] = useState('');
  const [loading, setLoading] = useState(true);
  const [exporting, setExporting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [target, setTarget] = useState<CheckRegisterRow | null>(null);
  const [action, setAction] = useState<ReconciliationAction>('cleared');

  const load = useCallback(async (): Promise<void> => {
    setLoading(true);
    setError(null);
    try {
      const response = await checkRegisterApi.get({ from, to, status: status || undefined });
      setRegister(response.check_register);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not load the check register.');
    } finally {
      setLoading(false);
    }
  }, [from, status, to]);

  useEffect(() => {
    void companyId; // Re-fetch after the shared API client switches its company header.
    void refreshVersion;
    void load();
  }, [companyId, load, refreshVersion]);

  const exportCsv = async (): Promise<void> => {
    setExporting(true);
    setError(null);
    try {
      const result = await checkRegisterApi.exportCsv({ from, to, status: status || undefined });
      const url = URL.createObjectURL(result.blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = result.filename || `check_register_${from}_through_${to}.csv`;
      link.click();
      setTimeout(() => URL.revokeObjectURL(url), 100);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not export the check register.');
    } finally {
      setExporting(false);
    }
  };

  const openAction = (row: CheckRegisterRow, nextAction: ReconciliationAction): void => {
    setTarget(row);
    setAction(nextAction);
  };

  const rows = useMemo(() => register?.rows ?? [], [register]);

  return (
    <Card className="overflow-hidden">
      <div className="border-b border-neutral-200 bg-neutral-950 p-4 text-white sm:p-6">
        <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <p className="text-xs font-semibold uppercase tracking-[0.18em] text-primary-300">Physical check control</p>
            <h2 className="mt-2 text-xl font-semibold">Check register</h2>
            <p className="mt-2 max-w-2xl text-sm leading-6 text-neutral-300">
              Prepared, issued, cleared, voided, and replacement-needed checks stay distinct. Cleared evidence is optional until Cornerstone records it; issued checks remain visible as outstanding.
            </p>
          </div>
          <div className="grid grid-cols-2 gap-2 text-sm sm:grid-cols-3">
            <Summary label="Outstanding" value={register?.summary.outstanding_count ?? 0} />
            <Summary label="Reconciled" value={register?.summary.reconciled_count ?? 0} />
            <Summary label="Needs action" value={register?.summary.action_required_count ?? 0} tone="danger" />
          </div>
        </div>
      </div>

      <div className="space-y-4 p-4 sm:p-6">
        <div className="grid gap-4 md:grid-cols-4">
          <Input label="From" type="date" value={from} onChange={(event) => setFrom(event.target.value)} />
          <Input label="Through" type="date" value={to} onChange={(event) => setTo(event.target.value)} />
          <Select label="Payment status" value={status} onChange={(event) => setStatus(event.target.value)}>
            <option value="">All statuses</option>
            {Object.entries(STATUS_LABELS).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
          </Select>
          <div className="flex items-end gap-2">
            <Button className="flex-1" variant="outline" onClick={() => void load()} disabled={loading}>
              <RefreshCw className="mr-2 h-4 w-4" /> Refresh
            </Button>
            <Button className="flex-1" variant="outline" onClick={() => void exportCsv()} disabled={exporting || rows.length === 0}>
              <Download className="mr-2 h-4 w-4" /> {exporting ? 'Exporting…' : 'CSV'}
            </Button>
          </div>
        </div>

        {error && <div className="rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-700">{error}</div>}
        {loading ? (
          <div className="py-8 text-center text-sm text-neutral-500">Loading check register…</div>
        ) : rows.length === 0 ? (
          <div className="rounded-xl border border-dashed border-neutral-300 py-8 text-center text-sm text-neutral-500">No paper checks fall in this date range.</div>
        ) : (
          <div className="divide-y divide-neutral-200 rounded-xl border border-neutral-200">
            {rows.map((row) => (
              <div key={`${row.source_type}-${row.source_id}`} className="grid gap-4 p-4 lg:grid-cols-[minmax(0,1.5fr)_minmax(0,1fr)_auto] lg:items-center">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-mono text-sm font-semibold text-neutral-900">#{row.check_number}</span>
                    <Badge variant={STATUS_VARIANTS[row.status]}>{STATUS_LABELS[row.status]}</Badge>
                    <Badge variant="outline">{row.source_type === 'payroll_item' ? 'Employee' : 'Other payment'}</Badge>
                  </div>
                  <p className="mt-2 truncate font-medium text-neutral-900">{row.payee}</p>
                  <p className="mt-2 text-sm text-neutral-500">
                    {formatCurrency(row.amount)} · Register date {formatDate(row.register_date)}
                    {row.previous_check_numbers.length > 0 ? ` · Replaces ${row.previous_check_numbers.map((number) => `#${number}`).join(', ')}` : ''}
                  </p>
                </div>
                <div className="text-sm leading-6 text-neutral-600">
                  <p>{row.issued_on ? `Issued ${formatDate(row.issued_on)}${row.issued_by ? ` by ${row.issued_by}` : ''}` : 'Not issued yet'}</p>
                  {row.issuance_reference && <p>Issue reference: {row.issuance_reference}</p>}
                  {row.latest_reconciliation_event && (
                    <p>
                      Latest evidence: {row.latest_reconciliation_event.event_type.replaceAll('_', ' ')} on {formatDate(row.latest_reconciliation_event.effective_on)}
                      {row.latest_reconciliation_event.evidence_reference ? ` · ${row.latest_reconciliation_event.evidence_reference}` : ''}
                    </p>
                  )}
                  {row.latest_reconciliation_event?.reason && <p className="text-danger-700">{row.latest_reconciliation_event.reason}</p>}
                </div>
                <div className="grid grid-cols-2 gap-2 lg:flex lg:justify-end">
                  {row.status === 'issued' && (
                    <>
                      <Button size="sm" onClick={() => openAction(row, 'cleared')}>Mark Cleared</Button>
                      <Button size="sm" variant="outline" onClick={() => openAction(row, 'replacement_required')}>Needs Replacement</Button>
                    </>
                  )}
                  {row.status === 'cleared' && <Button size="sm" variant="outline" onClick={() => openAction(row, 'clearing_reversed')}>Correct Clearing</Button>}
                  {row.status === 'replacement_required' && row.pay_period_id && (
                    <Button size="sm" onClick={() => navigate(`/pay-periods/${row.pay_period_id}`)}>Open Payroll</Button>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {target && <ReconciliationDialog row={target} action={action} onClose={() => setTarget(null)} onSaved={async () => { setTarget(null); await load(); }} />}
    </Card>
  );
}

function Summary({ label, value, tone = 'default' }: { label: string; value: number; tone?: 'default' | 'danger' }) {
  return (
    <div className={`rounded-xl border p-4 ${tone === 'danger' ? 'border-danger-500/50 bg-danger-500/20' : 'border-white/15 bg-white/5'}`}>
      <p className="text-2xl font-semibold">{value}</p>
      <p className="mt-2 text-xs text-neutral-300">{label}</p>
    </div>
  );
}

function ReconciliationDialog({ row, action, onClose, onSaved }: { row: CheckRegisterRow; action: ReconciliationAction; onClose: () => void; onSaved: () => Promise<void> }) {
  const [effectiveOn, setEffectiveOn] = useState(guamBusinessDate());
  const [idempotencyKey] = useState(() => crypto.randomUUID());
  const [evidenceType, setEvidenceType] = useState('bank_statement');
  const [evidenceReference, setEvidenceReference] = useState('');
  const [reason, setReason] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const title = action === 'cleared' ? 'Record cleared check' : action === 'clearing_reversed' ? 'Correct cleared status' : 'Record replacement needed';

  const submit = async (): Promise<void> => {
    setSaving(true);
    setError(null);
    try {
      await checkRegisterApi.recordEvent({
        source_type: row.source_type,
        source_id: row.source_id,
        event_type: action,
        effective_on: effectiveOn,
        evidence_type: action === 'cleared' ? evidenceType : undefined,
        evidence_reference: action === 'cleared' ? evidenceReference.trim() : undefined,
        reason: action === 'cleared' ? undefined : reason.trim(),
        idempotency_key: idempotencyKey,
      });
      await onSaved();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save reconciliation evidence.');
    } finally {
      setSaving(false);
    }
  };

  const valid = Boolean(effectiveOn) && (action === 'cleared' ? Boolean(evidenceReference.trim()) : reason.trim().length >= 10);
  return (
    <Dialog open onOpenChange={(open) => { if (!open && !saving) onClose(); }}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription>Check #{row.check_number} · {row.payee} · {formatCurrency(row.amount)}</DialogDescription>
        </DialogHeader>
        <Input label={action === 'cleared' ? 'Cleared date' : 'Effective date'} type="date" value={effectiveOn} onChange={(event) => setEffectiveOn(event.target.value)} />
        {action === 'cleared' ? (
          <div className="grid gap-4 sm:grid-cols-2">
            <Select label="Evidence source" value={evidenceType} onChange={(event) => setEvidenceType(event.target.value)}>
              <option value="bank_statement">Bank statement</option>
              <option value="bank_portal">Bank portal</option>
              <option value="accountant_review">Accountant review</option>
              <option value="payee_confirmation">Payee confirmation</option>
              <option value="other">Other</option>
            </Select>
            <Input label="Evidence reference" helperText="Statement date, transaction ID, or review reference." value={evidenceReference} onChange={(event) => setEvidenceReference(event.target.value)} />
          </div>
        ) : (
          <Input label="Reason" helperText="At least 10 characters. This correction is kept permanently." value={reason} onChange={(event) => setReason(event.target.value)} />
        )}
        {action === 'replacement_required' && (
          <div className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm leading-5 text-warning-900">
            This does not issue a second payment. Reissue the employee check from its payroll period, or void and recreate an other payment, so the original history stays intact.
          </div>
        )}
        {error && <div className="rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-700">{error}</div>}
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={saving}>Cancel</Button>
          <Button onClick={() => void submit()} disabled={saving || !valid}>{saving ? 'Saving…' : 'Save Evidence'}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
