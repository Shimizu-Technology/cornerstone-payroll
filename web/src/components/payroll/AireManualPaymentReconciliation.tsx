import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import Decimal from 'decimal.js';
import { Link, useLocation } from 'react-router';
import { useCompany } from '@/contexts/CompanyContext';
import { aireAccountConnectionPath, currentAppPath, payrollItemPath } from '@/lib/routes';
import { useAuth } from '@/contexts/AuthContext';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { formatDate, formatGuamDateTime } from '@/lib/utils';
import { payPeriodsApi } from '@/services/api';
import type { AireManualAllocation, AirePayrollManualReview, PayPeriodStatus, PayrollItem } from '@/types';

type Props = {
  payPeriodId: number;
  payPeriodStatus: PayPeriodStatus;
  payPeriodVoided: boolean;
  payrollItems: PayrollItem[];
  onChanged: () => void;
};

function decimalHours(value: string): Decimal | null {
  if (!/^\d+(?:\.\d{1,2})?$/.test(value.trim())) return null;
  const result = new Decimal(value.trim());
  return result.isFinite() && !result.isNegative() ? result : null;
}

const hours = (value: number) => Number(value).toFixed(2);
const stateLabel = (allocation: AireManualAllocation) => ({
  pending_commit: 'Saved locally; time tracking confirmation pending',
  committed: 'Linked; payment evidence pending',
  issued: 'Payment recorded in time tracking',
  voided: 'Allocation voided',
}[allocation.status] || 'Review allocation status');

export function AireManualPaymentReconciliation({ payPeriodId, payPeriodStatus, payPeriodVoided, payrollItems, onChanged }: Props) {
  const { hasCapability } = useAuth();
  const { activeCompanyId } = useCompany();
  const location = useLocation();
  const allowed = hasCapability('manage_historical_time_reconciliation');
  const [review, setReview] = useState<AirePayrollManualReview | null>(null);
  const [allocations, setAllocations] = useState<AireManualAllocation[]>([]);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [needsRefresh, setNeedsRefresh] = useState(false);
  const [entryKey, setEntryKey] = useState('');
  const [itemId, setItemId] = useState('');
  const [regular, setRegular] = useState('');
  const [overtime, setOvertime] = useState('');
  const [note, setNote] = useState('');
  const generation = useRef(0);
  const actionGeneration = useRef(0);
  const committed = payPeriodStatus === 'committed' && !payPeriodVoided;

  const load = useCallback(async () => {
    const current = ++generation.current;
    setLoading(true); setError('');
    try {
      const result = await payPeriodsApi.airePayrollManualReview(payPeriodId);
      if (current !== generation.current) return;
      setReview(result); setAllocations(result.cornerstone_manual_allocations || []); setNeedsRefresh(false);
      setEntryKey(''); setItemId(''); setRegular(''); setOvertime('');
    } catch (caught) {
      if (current === generation.current) {
        setReview(null); setNeedsRefresh(true);
        setError(caught instanceof Error ? caught.message : 'Could not load the manual reconciliation review');
      }
    } finally { if (current === generation.current) setLoading(false); }
  }, [payPeriodId]);

  useEffect(() => {
    setReview(null); setAllocations([]); setNotice(''); setNote(''); setBusy(false);
    if (allowed) void load();
    return () => { generation.current += 1; actionGeneration.current += 1; };
  }, [allowed, load]);

  const candidates = useMemo(() => (review?.employees || []).flatMap(employee => {
    const employeeId = employee.cornerstone.employee_id;
    if (!employeeId || !employee.source_user_uuid) return [];
    return employee.adjustments.filter(entry => entry.source_kind !== 'correction'
      && Number.isInteger(entry.source_time_entry_version) && Number(entry.source_time_entry_version) >= 0
      && Number.isFinite(Number(entry.regular_hours)) && Number(entry.regular_hours) >= 0
      && Number.isFinite(Number(entry.overtime_hours)) && Number(entry.overtime_hours) >= 0
      && Number(entry.regular_hours) + Number(entry.overtime_hours) > 0
      && !allocations.some(allocation => allocation.source_time_entry_id === entry.source_time_entry_id
        && allocation.status === 'pending_commit'))
      .map(entry => ({ ...entry, employeeId, uuid: employee.source_user_uuid!,
        name: employee.cornerstone.employee_name || employee.display_name,
        key: `${employee.source_user_uuid}:${entry.source_time_entry_id}:${entry.source_kind}` }));
  }), [review, allocations]);
  const selected = candidates.find(entry => entry.key === entryKey);
  const matchingItems = payrollItems.filter(item => item.employee_id === selected?.employeeId
    && !item.voided && !item.voided_at && item.check_status !== 'voided'
    && !item.time_tracking_provenance?.allocation_count
    && !allocations.some(allocation => allocation.payroll_item_id === item.id
      && allocation.source_time_entry_id === selected?.source_time_entry_id)
    && ['paper_check', 'direct_deposit'].includes(item.effective_payment_delivery_method || item.payment_delivery_method || item.employee_payment_delivery_method || 'paper_check'));
  const selectedItem = matchingItems.find(item => String(item.id) === itemId);
  const existing = allocations.filter(allocation => allocation.payroll_item_id === selectedItem?.id && allocation.status !== 'voided');
  const regularCapacity = Decimal.max(0, new Decimal(selectedItem?.hours_worked || 0)
    .minus(existing.reduce((sum, allocation) => sum.plus(allocation.regular_hours), new Decimal(0))));
  const overtimeCapacity = Decimal.max(0, new Decimal(selectedItem?.overtime_hours || 0)
    .minus(existing.reduce((sum, allocation) => sum.plus(allocation.overtime_hours), new Decimal(0))));
  const enteredRegular = decimalHours(regular);
  const enteredOvertime = decimalHours(overtime);
  const amountsValid = !!selected && !!selectedItem && !!enteredRegular && !!enteredOvertime
    && enteredRegular.plus(enteredOvertime).greaterThan(0)
    && enteredRegular.lessThanOrEqualTo(selected.regular_hours) && enteredOvertime.lessThanOrEqualTo(selected.overtime_hours)
    && enteredRegular.lessThanOrEqualTo(regularCapacity) && enteredOvertime.lessThanOrEqualTo(overtimeCapacity);
  const canManage = review?.command_access?.can_manage_manual_allocations === true;
  const canSubmit = canManage && committed && amountsValid && note.trim().length >= 10 && !needsRefresh && !busy && !loading;

  const remember = (allocation: AireManualAllocation) => setAllocations(current =>
    [...current.filter(row => row.id !== allocation.id), allocation]);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!canSubmit || !selected || !selectedItem || !enteredRegular || !enteredOvertime) return;
    const current = ++actionGeneration.current;
    setBusy(true); setError(''); setNotice('');
    try {
      const { manual_allocation: allocation } = await payPeriodsApi.createAireManualAllocation(payPeriodId, {
        payroll_item_id: selectedItem.id, source_time_entry_id: selected.source_time_entry_id,
        source_time_entry_version: selected.source_time_entry_version!, source_user_uuid: selected.uuid,
        original_work_date: selected.original_work_date, regular_hours: enteredRegular.toFixed(2),
        overtime_hours: enteredOvertime.toFixed(2), note: note.trim(),
      });
      if (current !== actionGeneration.current) return;
      remember(allocation); setNotice(stateLabel(allocation)); setNote('');
      await load();
      if (current === actionGeneration.current) onChanged();
    } catch (caught) {
      if (current === actionGeneration.current) {
        setNeedsRefresh(true);
        setError(`${caught instanceof Error ? caught.message : 'The linking request could not be confirmed'}. Refresh this review before creating another link. If a saved record appears, retry its sync.`);
      }
    } finally { if (current === actionGeneration.current) setBusy(false); }
  };

  const retry = async (allocation: AireManualAllocation) => {
    if (!canManage || busy || loading) return;
    const current = ++actionGeneration.current;
    setBusy(true); setError(''); setNotice('');
    try {
      const result = await payPeriodsApi.retryAireManualAllocation(payPeriodId, allocation.id);
      if (current !== actionGeneration.current) return;
      remember(result.manual_allocation); setNotice(stateLabel(result.manual_allocation));
      await load();
      if (current === actionGeneration.current) onChanged();
    } catch (caught) {
      if (current === actionGeneration.current) setError(caught instanceof Error ? caught.message : 'Could not retry time tracking sync');
    } finally { if (current === actionGeneration.current) setBusy(false); }
  };

  if (!allowed) return null;
  return <Card aria-label="Manual time tracking payroll reconciliation"><CardContent className="space-y-4 py-5">
    <div className="flex flex-wrap items-start justify-between gap-3">
      <div><h2 className="font-semibold text-neutral-900">Link manually entered hours to time tracking</h2>
        <p className="mt-1 max-w-3xl text-sm leading-6 text-neutral-600">Match exact time tracking hours to an existing committed payroll item. The link records which hours it covers and follows the payment evidence already recorded in Payroll.</p></div>
      <Button type="button" variant="outline" size="sm" disabled={busy || loading} onClick={() => void load()}>Refresh reconciliation</Button>
    </div>
    <p className="text-sm text-neutral-600">Printing prepares a check. Record its issuance when it is handed to time tracking; time tracking handles employee distribution. Direct deposits require bank confirmation. A reported-payment hold stays in place while its evidence is reviewed; retract it only if the payment report was incorrect.</p>
    {loading && <p role="status" className="text-sm">Loading exact source hours and existing links…</p>}
    {error && <p role="alert" className="rounded-lg bg-danger-50 p-3 text-sm text-danger-800">{error}</p>}
    {notice && <p role="status" className="rounded-lg bg-primary-50 p-3 text-sm text-primary-900">{notice}</p>}
    {hasCapability('manage_own_aire_account_link') && review?.command_access?.delegation_configured === false && <div className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm text-warning-900">
      <p>Your own time tracking access is needed before linking hours. Connecting does not grant manager approvals or configuration rights.</p>
      <Link className="mt-2 inline-flex min-h-11 items-center font-semibold underline underline-offset-4" to={aireAccountConnectionPath(undefined, currentAppPath(location.pathname, location.search))}>Connect my time tracking account</Link>
    </div>}
    {allocations.length > 0 && <ul aria-label="Existing manual allocations" className="space-y-3">
      {allocations.map(allocation => <li key={allocation.id} className="rounded-xl border border-neutral-200 p-4 text-sm">
        <div className="flex flex-wrap items-start justify-between gap-3"><div>
          <p className="font-semibold">{allocation.employee_name} · {formatDate(allocation.original_work_date)} · source entry {allocation.source_time_entry_id}</p>
          <p className="mt-1">{hours(allocation.regular_hours)} regular · {hours(allocation.overtime_hours)} OT · {activeCompanyId && allocation.pay_period_id === payPeriodId && allocation.payroll_item_id
            ? <Link className="font-semibold text-primary-800 underline underline-offset-4" to={payrollItemPath(activeCompanyId, payPeriodId, allocation.payroll_item_id, { returnTo: currentAppPath(location.pathname, location.search) })}>Payroll item {allocation.payroll_item_id}</Link>
            : 'payroll item review needed'}</p>
          <Badge className="mt-2" variant={allocation.status === 'issued' ? 'success' : allocation.status === 'voided' ? 'default' : 'warning'}>{stateLabel(allocation)}</Badge>
          {allocation.status === 'issued' && allocation.payment_evidence?.provenance === 'aire_issued_receipt'
            ? <p className="mt-2">Time tracking issued receipt · reference {allocation.payment_evidence.reference} · paid {formatDate(allocation.payment_evidence.effective_on)}</p>
            : <p className="mt-2 text-neutral-600">Verified issued receipt details are not available in this review.</p>}
          {allocation.last_synced_at && <p className="mt-1 text-xs text-neutral-600">Time tracking status confirmed {formatGuamDateTime(allocation.last_synced_at)}</p>}
          {allocation.last_sync_error && <p role="alert" className="mt-2 text-danger-800">{allocation.last_sync_error}</p>}
        </div>{canManage && allocation.status !== 'voided' && <Button type="button" variant="outline" size="sm" disabled={busy || loading}
          onClick={() => void retry(allocation)}>Retry sync for entry {allocation.source_time_entry_id}</Button>}</div>
      </li>)}
    </ul>}
    {review && <>
      {!canManage ? <p className="text-sm text-neutral-600">Linking is unavailable for this account and company. A permitted Payroll role and connected time tracking account or delegation are required.</p>
        : !committed ? <p className="text-sm text-neutral-600">Commit a nonvoid payroll run before linking its manually entered hours.</p>
          : <form onSubmit={event => void submit(event)} className="space-y-4 border-t border-neutral-200 pt-4">
            <div className="grid gap-4 md:grid-cols-2">
              <Select label="Exact time tracking time entry" value={entryKey} disabled={busy || loading || needsRefresh}
                onChange={event => { const entry = candidates.find(row => row.key === event.target.value); setEntryKey(event.target.value); setItemId('');
                  setRegular(entry ? hours(entry.regular_hours) : ''); setOvertime(entry ? hours(entry.overtime_hours) : ''); }}>
                <option value="">Choose approved, unallocated hours</option>
                {candidates.map(entry => <option key={entry.key} value={entry.key}>{entry.name} · {formatDate(entry.original_work_date)} · entry {entry.source_time_entry_id} · {hours(entry.regular_hours)} REG / {hours(entry.overtime_hours)} OT</option>)}
              </Select>
              <Select label="Existing committed payroll item" value={itemId} disabled={!selected || busy || loading || needsRefresh}
                onChange={event => setItemId(event.target.value)}>
                <option value="">Choose this employee's payroll item</option>
                {matchingItems.map(item => <option key={item.id} value={item.id}>Item {item.id} · {item.check_number ? `check ${item.check_number}` : (item.effective_payment_delivery_method || item.payment_delivery_method || item.employee_payment_delivery_method) === 'direct_deposit' ? 'direct deposit' : 'paper check'} · {hours(item.hours_worked || 0)} REG / {hours(item.overtime_hours || 0)} OT</option>)}
              </Select>
            </div>
            {selected && matchingItems.length === 0 && <p role="alert" className="text-sm text-warning-900">This employee has no eligible manual payroll item in this run. Voided and finalized-batch items must use their own reconciliation flow.</p>}
            {selectedItem && <p className="text-sm text-neutral-600">Available on payroll item {selectedItem.id}: {regularCapacity.toFixed(2)} regular · {overtimeCapacity.toFixed(2)} OT hours. Source time and committed paycheck totals are checked again when linking.</p>}
            <div className="grid gap-4 sm:grid-cols-2">
              <Input label="Regular hours to link" type="text" inputMode="decimal" value={regular} disabled={!selectedItem || busy || loading || needsRefresh} onChange={event => setRegular(event.target.value)} />
              <Input label="Overtime hours to link" type="text" inputMode="decimal" value={overtime} disabled={!selectedItem || busy || loading || needsRefresh} onChange={event => setOvertime(event.target.value)} />
            </div>
            {selectedItem && !amountsValid && <p role="alert" className="text-sm text-danger-800">Enter positive total hours with up to two decimals, within both the source hours and the paycheck's remaining regular and OT hours.</p>}
            <label className="block text-sm font-medium text-neutral-700" htmlFor={`manual-reconciliation-note-${payPeriodId}`}>Evidence and reconciliation reason</label>
            <Textarea id={`manual-reconciliation-note-${payPeriodId}`} value={note} minLength={10} maxLength={2000} required disabled={busy || loading || needsRefresh}
              onChange={event => setNote(event.target.value)} aria-describedby={`manual-reconciliation-help-${payPeriodId}`} />
            <p id={`manual-reconciliation-help-${payPeriodId}`} className="text-xs text-neutral-600">At least 10 characters. Identify the existing payroll item and why it covers these hours. Any regular/OT classification difference requires historical review.</p>
            <Button type="submit" disabled={!canSubmit}>{busy ? 'Saving reconciliation…' : 'Link hours to payroll item'}</Button>
            {candidates.length === 0 && <p className="text-sm text-neutral-600">No eligible source hours with a confirmed employee identity and current version are available. Review held entries, mappings, and existing links.</p>}
          </form>}
      {review.exclusions.length > 0 && <p className="text-sm text-warning-900">{review.exclusions.length} held entries remain outside this selection. Review their approval, cutoff, or payment evidence in time tracking Time Cards and reported-payment holds.</p>}
    </>}
  </CardContent></Card>;
}
