import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { AlertTriangle, CheckCircle2, Loader2, RefreshCw } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { formatDate, formatDateRange } from '@/lib/utils';
import { payPeriodsApi } from '@/services/api';
import type { AirePayrollManualReview, AirePayrollManualReviewAdjustment, AirePayrollManualReviewEmployee, Employee, PayrollItem, PayPeriodStatus } from '@/types';

type PayrollHours = Record<string, { regular: number; overtime: number }>;

type Props = {
  payPeriodId: number;
  payPeriodStatus: PayPeriodStatus;
  payrollHours: PayrollHours;
  payrollItems?: PayrollItem[];
  employees?: Employee[];
  aireRecordLinked: boolean;
};

type LinkTarget = { employee: AirePayrollManualReviewEmployee; adjustment: AirePayrollManualReviewAdjustment };
type BulkLinkTarget = { employee: AirePayrollManualReviewEmployee; adjustments: AirePayrollManualReviewAdjustment[]; item: PayrollItem };

const hours = (value: number) => Number(value || 0).toFixed(2);
const sameHundredth = (left: number, right: number) => Math.round(left * 100) === Math.round(right * 100);
type CornerstoneAllocation = NonNullable<AirePayrollManualReview['cornerstone_manual_allocations']>[number];
const needsAireSync = (allocation: CornerstoneAllocation) => Boolean(
  allocation.last_sync_error || allocation.status === 'pending_commit' ||
  (allocation.status === 'committed' && allocation.payroll_item_check_status === 'delivered')
);

const exclusionLabel = (reason: string) => ({
  pending_approval: 'approval needed',
  approved_after_cutoff: 'approved after cutoff',
  created_after_cutoff: 'submitted after cutoff',
  open_clock: 'missing clock-out',
  pending_overtime: 'overtime approval needed',
  overtime_approved_after_cutoff: 'overtime approved after cutoff',
  denied_approval: 'time denied',
  denied_overtime: 'overtime denied',
}[reason] || reason.replaceAll('_', ' '));

const DEFAULT_LINK_NOTE = 'These AIRE hours match the committed Cornerstone payroll item';

export function AireManualHoursReview({ payPeriodId, payPeriodStatus, payrollHours, payrollItems = [], employees = [], aireRecordLinked }: Props) {
  const [review, setReview] = useState<AirePayrollManualReview | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const requestGeneration = useRef(0);
  const [linkTarget, setLinkTarget] = useState<LinkTarget | null>(null);
  const [bulkLinkTarget, setBulkLinkTarget] = useState<BulkLinkTarget | null>(null);
  const [bulkGrossVerified, setBulkGrossVerified] = useState(false);
  const [selectedItemId, setSelectedItemId] = useState('');
  const [regularToLink, setRegularToLink] = useState('0');
  const [overtimeToLink, setOvertimeToLink] = useState('0');
  const [linkNote, setLinkNote] = useState(DEFAULT_LINK_NOTE);
  const [linkBusy, setLinkBusy] = useState(false);
  const [linkError, setLinkError] = useState<string | null>(null);
  const [mapSourceId, setMapSourceId] = useState<string | null>(null);
  const [mapEmployeeId, setMapEmployeeId] = useState('');
  const [mapError, setMapError] = useState<string | null>(null);
  const [mapBusy, setMapBusy] = useState(false);
  const mapSourceEmployee = review?.employees.find((employee) => employee.source_user_id === mapSourceId);
  const mapTargetEmployee = employees.find((employee) => String(employee.id) === mapEmployeeId);

  const saveMapping = async () => {
    if (!mapSourceId || !mapSourceEmployee || !mapEmployeeId) return;
    setMapBusy(true);
    setMapError(null);
    try {
      await payPeriodsApi.mapAireEmployee(payPeriodId, { source_user_id: mapSourceId, employee_id: Number(mapEmployeeId) });
      setMapSourceId(null);
      setMapEmployeeId('');
      await load();
    } catch (caught) {
      setMapError(caught instanceof Error ? caught.message : 'Could not save the employee match');
    } finally {
      setMapBusy(false);
    }
  };

  const openLink = (employee: AirePayrollManualReviewEmployee, adjustment: AirePayrollManualReviewAdjustment) => {
    const item = payrollItems.find((candidate) => candidate.employee_id === employee.cornerstone.employee_id && !candidate.voided);
    setLinkTarget({ employee, adjustment });
    setSelectedItemId(item ? String(item.id) : '');
    setRegularToLink(String(Math.max(0, adjustment.regular_hours)));
    setOvertimeToLink(String(Math.max(0, adjustment.overtime_hours)));
    setLinkNote(DEFAULT_LINK_NOTE);
    setLinkError(null);
  };

  const saveLink = async () => {
    if (!linkTarget?.employee.source_user_uuid || linkTarget.adjustment.source_time_entry_version == null) {
      setLinkError('Refresh AIRE hours before linking: this entry is missing its permanent employee identity or version.');
      return;
    }
    const regular = Number(regularToLink);
    const overtime = Number(overtimeToLink);
    if (!selectedItemId || !Number.isFinite(regular) || !Number.isFinite(overtime) || regular < 0 || overtime < 0 || regular + overtime <= 0 ||
        regular > linkTarget.adjustment.regular_hours || overtime > linkTarget.adjustment.overtime_hours || linkNote.trim().length < 10) {
      setLinkError('Choose a paycheck, enter no more than the AIRE hours still owed, and explain the match.');
      return;
    }
    setLinkBusy(true);
    setLinkError(null);
    try {
      await payPeriodsApi.linkManualAireHours(payPeriodId, {
        payroll_item_id: Number(selectedItemId),
        source_time_entry_id: linkTarget.adjustment.source_time_entry_id,
        source_time_entry_version: linkTarget.adjustment.source_time_entry_version,
        source_user_uuid: linkTarget.employee.source_user_uuid,
        regular_hours: regular,
        overtime_hours: overtime,
        original_work_date: linkTarget.adjustment.original_work_date,
        note: linkNote.trim(),
      });
      setLinkTarget(null);
      await load();
    } catch (caught) {
      setLinkError(caught instanceof Error ? caught.message : 'Could not link these hours');
    } finally {
      setLinkBusy(false);
    }
  };

  const retryLink = async (allocationId: number) => {
    setLinkBusy(true);
    setLinkError(null);
    try {
      await payPeriodsApi.retryManualAireHours(payPeriodId, allocationId);
      await load();
    } catch (caught) {
      setLinkError(caught instanceof Error ? caught.message : 'Could not retry the AIRE sync');
    } finally {
      setLinkBusy(false);
    }
  };

  const retryAllLinks = async (allocationIds: number[]) => {
    setLinkBusy(true);
    setLinkError(null);
    let synced = 0;
    let firstError: string | null = null;
    for (const allocationId of allocationIds) {
      try {
        const result = await payPeriodsApi.retryManualAireHours(payPeriodId, allocationId);
        if (result.manual_allocation.last_sync_error) {
          firstError ||= result.manual_allocation.last_sync_error;
        } else {
          synced += 1;
        }
      } catch (caught) {
        firstError ||= caught instanceof Error ? caught.message : 'Could not sync this AIRE update';
      }
    }
    await load();
    if (firstError) setLinkError(`${synced} of ${allocationIds.length} AIRE updates synced. ${firstError} Review the remaining errors below.`);
    setLinkBusy(false);
  };

  const saveBulkLink = async () => {
    if (!bulkLinkTarget?.employee.source_user_uuid || linkNote.trim().length < 10 || !bulkGrossVerified) {
      setLinkError('Verify the wage category and gross pay, then explain why these AIRE entries match the paycheck.');
      return;
    }
    setLinkBusy(true);
    setLinkError(null);
    let linked = 0;
    try {
      for (const adjustment of bulkLinkTarget.adjustments) {
        await payPeriodsApi.linkManualAireHours(payPeriodId, {
          payroll_item_id: bulkLinkTarget.item.id,
          source_time_entry_id: adjustment.source_time_entry_id,
          source_time_entry_version: adjustment.source_time_entry_version!,
          source_user_uuid: bulkLinkTarget.employee.source_user_uuid,
          regular_hours: adjustment.regular_hours,
          overtime_hours: adjustment.overtime_hours,
          original_work_date: adjustment.original_work_date,
          note: linkNote.trim(),
        });
        linked += 1;
      }
      setBulkLinkTarget(null);
      await load();
    } catch (caught) {
      setBulkLinkTarget(null);
      await load();
      setLinkError(`${linked} of ${bulkLinkTarget.adjustments.length} entries linked. ${caught instanceof Error ? caught.message : 'The remaining entries could not be linked.'} Review the refreshed list before retrying.`);
    } finally {
      setLinkBusy(false);
    }
  };

  const load = useCallback(async () => {
    const generation = ++requestGeneration.current;
    setLoading(true);
    setError(null);
    try {
      const result = await payPeriodsApi.airePayrollManualReview(payPeriodId);
      if (!Array.isArray(result.employees) || !Array.isArray(result.exclusions) ||
          !result.summary || !result.issues || !result.start_date || !result.end_date) {
        throw new Error('AIRE returned an incomplete hours check. Refresh or contact support before relying on these totals.');
      }
      if (generation === requestGeneration.current) setReview(result);
    } catch (caught) {
      if (generation === requestGeneration.current) {
        setError(caught instanceof Error ? caught.message : 'Could not compare AIRE and Payroll hours');
      }
    } finally {
      if (generation === requestGeneration.current) setLoading(false);
    }
  }, [payPeriodId]);

  useEffect(() => {
    setReview(null);
    void load();
    return () => { requestGeneration.current += 1; };
  }, [load]);

  const rows = useMemo(() => (review?.employees || []).map((employee) => {
    const employeeId = employee.cornerstone.employee_id;
    const entered = employeeId ? payrollHours[String(employeeId)] : undefined;
    const payrollRegular = Number(entered?.regular || 0);
    const payrollOvertime = Number(entered?.overtime || 0);
    const carryover = employee.adjustments
      .filter((adjustment) => adjustment.source_kind === 'carryover')
      .reduce((sum, adjustment) => sum + Number(adjustment.total_hours), 0);
    const corrections = employee.adjustments
      .filter((adjustment) => adjustment.source_kind === 'correction')
      .reduce((sum, adjustment) => sum + Number(adjustment.total_hours), 0);
    const categories = [...new Set(employee.adjustments.map((adjustment) => adjustment.category?.name).filter(Boolean))] as string[];
    const matched = employee.cornerstone.status === 'mapped'
      && sameHundredth(payrollRegular, Number(employee.regular_hours))
      && sameHundredth(payrollOvertime, Number(employee.overtime_hours));

    return { employee, payrollRegular, payrollOvertime, carryover, corrections, categories, matched };
  }), [payrollHours, review?.employees]);

  const isCommitted = payPeriodStatus === 'committed';
  const matchedCount = rows.filter((row) => row.matched).length;
  const mismatchCount = rows.length - matchedCount;
  const attentionCount = Number(review?.summary.exclusion_count || 0)
    + Number(review?.issues.missing_category_count || 0)
    + Number(review?.issues.negative_adjustment_count || 0)
    + Number(review?.payment_attestations?.length || 0);
  const bulkCandidates = isCommitted ? (review?.employees || []).flatMap((employee) => {
    if (employee.cornerstone.status !== 'mapped' || !employee.source_user_uuid ||
        employee.adjustments.some((adjustment) => adjustment.regular_hours < 0 || adjustment.overtime_hours < 0)) return [];
    const candidates = employee.adjustments.filter((adjustment) =>
      adjustment.source_time_entry_version != null && adjustment.regular_hours >= 0 &&
      adjustment.overtime_hours >= 0 && adjustment.regular_hours + adjustment.overtime_hours > 0);
    if (candidates.length < 2 || new Set(candidates.map((entry) => entry.source_time_entry_id)).size !== candidates.length) return [];
    if (new Set(candidates.map((entry) => entry.category?.id || entry.category?.name).filter(Boolean)).size !== 1 ||
        candidates.some((entry) => !entry.category?.id && !entry.category?.name)) return [];
    const items = payrollItems.filter((item) => item.employee_id === employee.cornerstone.employee_id && !item.voided);
    if (items.length !== 1) return [];
    const item = items[0];
    const linked = (review?.cornerstone_manual_allocations || []).filter((allocation) =>
      allocation.payroll_item_id === item.id && allocation.status !== 'voided');
    const remainingRegular = Number(item.hours_worked || 0) - linked.reduce((sum, allocation) => sum + Number(allocation.regular_hours), 0);
    const remainingOvertime = Number(item.overtime_hours || 0) - linked.reduce((sum, allocation) => sum + Number(allocation.overtime_hours), 0);
    if (!sameHundredth(remainingRegular, candidates.reduce((sum, entry) => sum + entry.regular_hours, 0)) ||
        !sameHundredth(remainingOvertime, candidates.reduce((sum, entry) => sum + entry.overtime_hours, 0))) return [];
    return [{ employee, adjustments: candidates, item }];
  }) : [];
  const pendingSyncIds = (review?.cornerstone_manual_allocations || []).filter(needsAireSync).map((allocation) => allocation.id);
  const unlinkedHours = Number(review?.summary.total_hours || 0);
  const linkedAwaitingEvidenceHours = (review?.manual_allocations || [])
    .filter((allocation) => allocation.status === 'committed')
    .reduce((sum, allocation) => sum + Number(allocation.regular_hours) + Number(allocation.overtime_hours), 0);
  const outstandingHours = unlinkedHours + linkedAwaitingEvidenceHours;

  return (
    <Card className="overflow-hidden border-primary-200">
      <CardContent className="p-0">
        <div className="flex flex-col gap-4 border-b border-primary-100 bg-primary-50/60 px-6 py-6 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <div className="flex flex-wrap items-center gap-2">
              <h3 className="font-display text-lg font-bold text-neutral-950">Manual AIRE hours check</h3>
              <Badge variant="info">Live from AIRE</Badge>
            </div>

            <p className="mt-2 max-w-3xl text-sm leading-6 text-neutral-700">
              AIRE shows regular, overtime, and carryover hours still owed. Before payroll, compare these with the hours entered here. Connected imports link exact entries automatically at commitment; for manual hours, link them to the actual paycheck afterward.
            </p>
          </div>
          <Button type="button" size="sm" variant="outline" onClick={() => void load()} disabled={loading}>
            {loading ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : <RefreshCw className="mr-2 h-4 w-4" />}
            Refresh check
          </Button>
        </div>

        {loading && !review ? (
          <div className="flex items-center justify-center gap-4 px-6 py-10 text-sm text-neutral-600">
            <Loader2 className="h-5 w-5 animate-spin text-primary-700" /> Comparing AIRE with the hours entered in Payroll…
          </div>
        ) : error ? (
          <div role="alert" className="flex items-start gap-4 px-6 py-6 text-sm text-danger-800">
            <AlertTriangle className="h-4 w-4 shrink-0" />
            <div><p className="font-semibold">The manual check could not load.</p><p className="mt-2 leading-5">{error} You can still process payroll manually; verify the hours in AIRE before approving.</p></div>
          </div>
        ) : review && (
          <>
            {review.employees.some((employee) => employee.cornerstone.status !== 'mapped') && (
              <div className="border-b border-warning-200 bg-warning-50/50 px-6 py-5">
                <h4 className="font-semibold text-neutral-950">Match AIRE people before payroll</h4>
                <p className="mt-1 text-sm text-neutral-700">Choose the existing Cornerstone employee only after verifying it is the same person. If they are new, finish their payroll profile first; this does not create or pay anyone automatically.</p>
                <div className="mt-3 flex flex-wrap gap-2">
                  {review.employees.filter((employee) => employee.cornerstone.status !== 'mapped').map((employee) => (
                    <Button key={employee.source_user_id} type="button" size="sm" variant="outline" onClick={() => { setMapSourceId(employee.source_user_id); setMapEmployeeId(''); setMapError(null); }}>Match {employee.display_name}</Button>
                  ))}
                </div>
              </div>
            )}
            <div className="grid gap-4 border-b border-neutral-200 bg-white p-4 sm:grid-cols-3 sm:p-6">
              <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">AIRE hours still owed</p>
                <p className="mt-2 font-display text-xl font-bold text-neutral-950">{hours(unlinkedHours)} hrs</p>
                <p className="mt-2 text-xs text-neutral-600">{hours(review.summary.regular_hours)} regular · {hours(review.summary.overtime_hours)} OT</p>
              </div>
              <div className={`rounded-xl border p-4 ${isCommitted ? (outstandingHours > 0 ? 'border-primary-200 bg-primary-50' : 'border-success-200 bg-success-50') : mismatchCount ? 'border-warning-200 bg-warning-50' : 'border-success-200 bg-success-50'}`}>
                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">{isCommitted ? (outstandingHours > 0 ? 'Payment not yet confirmed' : 'No payable AIRE hours awaiting payment') : 'Payroll match'}</p>
                <p className="mt-2 font-display text-xl font-bold text-neutral-950">{isCommitted ? `${hours(outstandingHours)} hrs` : `${matchedCount}/${rows.length} employees`}</p>
                <p className="mt-2 text-xs text-neutral-600">{isCommitted ? (outstandingHours > 0 ? `${hours(unlinkedHours)} unlinked · ${hours(linkedAwaitingEvidenceHours)} linked, awaiting payment evidence. Do not pay linked hours twice.` : 'Paid entries are recorded below. Held or unapproved time remains separate.') : mismatchCount ? `${mismatchCount} need an hours update below` : 'Regular and OT totals match'}</p>
              </div>
              <div className={`rounded-xl border p-4 ${attentionCount ? 'border-warning-200 bg-warning-50' : 'border-neutral-200 bg-neutral-50'}`}>
                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Needs attention</p>
                <p className="mt-2 font-display text-xl font-bold text-neutral-950">{attentionCount}</p>
                <p className="mt-2 text-xs text-neutral-600">Review exclusions, categories, corrections, and payment evidence</p>
              </div>
            </div>

            <div className="divide-y divide-neutral-100 lg:hidden">
              {rows.map(({ employee, payrollRegular, payrollOvertime, carryover, corrections, categories, matched }) => (
                <article key={`compact-${employee.source_user_id}`} className={`px-6 py-6 ${matched ? 'bg-white' : 'bg-warning-50/40'}`}>
                  <div className="flex items-start justify-between gap-4">
                    <div>
                      <p className="font-semibold text-neutral-950">{employee.cornerstone.employee_name || employee.display_name}</p>
                      <div className="mt-2 flex flex-wrap gap-2">
                        {categories.map((category) => <Badge key={category} variant="default">{category}</Badge>)}
                        {employee.cornerstone.status !== 'mapped' && <Badge variant="danger">Not mapped</Badge>}
                      </div>
                    </div>
                    {isCommitted ? <Badge variant="warning">Reconcile</Badge> : matched ? <Badge variant="success"><CheckCircle2 className="mr-2 h-3.5 w-3.5" /> Matches</Badge> : <Badge variant="warning"><AlertTriangle className="mr-2 h-3.5 w-3.5" /> Update</Badge>}
                  </div>
                  <div className="mt-4 grid gap-4 sm:grid-cols-2">
                    <div className="rounded-lg border border-neutral-200 bg-white p-4">
                      <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">AIRE says to pay</p>
                      <p className="mt-2 font-semibold text-neutral-950">{hours(employee.regular_hours)} regular · {hours(employee.overtime_hours)} OT</p>
                      {carryover !== 0 && <p className="mt-2 text-xs font-semibold text-primary-800">Includes {hours(carryover)} carryover</p>}
                      {corrections !== 0 && <p className="mt-2 text-xs text-neutral-600">Includes {corrections > 0 ? '+' : ''}{hours(corrections)} correction</p>}
                    </div>
                    <div className="rounded-lg border border-neutral-200 bg-white p-4">
                      <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Entered in Payroll</p>
                      <p className="mt-2 font-semibold text-neutral-950">{hours(payrollRegular)} regular · {hours(payrollOvertime)} OT</p>
                      {!isCommitted && !matched && employee.cornerstone.status === 'mapped' && <p className="mt-2 text-xs text-warning-900">Change to {hours(employee.regular_hours)} regular and {hours(employee.overtime_hours)} OT below.</p>}
                    </div>
                  </div>
                </article>
              ))}
              {rows.length === 0 && <p className="px-6 py-8 text-center text-sm text-neutral-500">AIRE has no payable time for {formatDateRange(review.start_date, review.end_date)}.</p>}
            </div>

            <div className="hidden overflow-x-auto lg:block">
              <table className="w-full min-w-[760px] text-left text-sm">
                <thead className="border-b border-neutral-200 bg-neutral-50 text-xs uppercase tracking-wide text-neutral-500">
                  <tr><th className="px-6 py-4 font-semibold">Employee</th><th className="px-4 py-4 font-semibold">AIRE says to pay</th><th className="px-4 py-4 font-semibold">Entered in Payroll</th><th className="px-6 py-4 font-semibold">Result</th></tr>
                </thead>
                <tbody className="divide-y divide-neutral-100">
                  {rows.map(({ employee, payrollRegular, payrollOvertime, carryover, corrections, categories, matched }) => (
                    <tr key={employee.source_user_id} className={matched ? 'bg-white' : 'bg-warning-50/40'}>
                      <td className="px-6 py-4 align-top">
                        <p className="font-semibold text-neutral-950">{employee.cornerstone.employee_name || employee.display_name}</p>
                        <div className="mt-2 flex flex-wrap gap-2">
                          {categories.map((category) => <Badge key={category} variant="default">{category}</Badge>)}
                          {employee.cornerstone.status !== 'mapped' && <Badge variant="danger">Not mapped</Badge>}
                        </div>
                      </td>
                      <td className="px-4 py-4 align-top">
                        <p className="font-semibold text-neutral-950">{hours(employee.regular_hours)} regular · {hours(employee.overtime_hours)} OT</p>
                        {carryover !== 0 && <p className="mt-2 text-xs font-semibold text-primary-800">Includes {hours(carryover)} carryover</p>}
                        {corrections !== 0 && <p className="mt-2 text-xs text-neutral-600">Includes {corrections > 0 ? '+' : ''}{hours(corrections)} correction</p>}
                      </td>
                      <td className="px-4 py-4 align-top">
                        <p className="font-semibold text-neutral-950">{hours(payrollRegular)} regular · {hours(payrollOvertime)} OT</p>
                        {!isCommitted && !matched && employee.cornerstone.status === 'mapped' && (
                          <p className="mt-2 text-xs text-warning-900">Enter {hours(employee.regular_hours)} regular and {hours(employee.overtime_hours)} OT in the payroll table.</p>
                        )}
                      </td>
                      <td className="px-6 py-4 align-top">
                        {isCommitted ? <Badge variant="warning">Reconcile</Badge> : matched ? <Badge variant="success"><CheckCircle2 className="mr-2 h-3.5 w-3.5" /> Matches</Badge> : <Badge variant="warning"><AlertTriangle className="mr-2 h-3.5 w-3.5" /> Update needed</Badge>}
                      </td>
                    </tr>
                  ))}
                  {rows.length === 0 && <tr><td colSpan={4} className="px-6 py-8 text-center text-neutral-500">AIRE has no payable time for {formatDateRange(review.start_date, review.end_date)}.</td></tr>}
                </tbody>
              </table>
            </div>

            {review.exclusions.length > 0 && (
              <div className="border-t border-warning-200 bg-warning-50/60 px-6 py-6">
                <h4 className="font-semibold text-neutral-950">Do not enter these hours yet</h4>
                <p className="mt-2 text-sm text-neutral-600">They are excluded from the payable totals above. Fix them in AIRE, then select Refresh check.</p>
                <div className="mt-4 grid gap-2 sm:grid-cols-2">
                  {review.exclusions.map((exclusion) => (
                    <div key={`${exclusion.source_time_entry_id}-${exclusion.reason}`} className="rounded-lg border border-warning-200 bg-white p-4 text-sm">
                      <p className="font-semibold text-neutral-950">{exclusion.cornerstone.employee_name || exclusion.display_name} · {hours(exclusion.held_total_hours)} hrs</p>
                      <p className="mt-2 text-xs text-neutral-600">{formatDate(exclusion.original_work_date)} · {exclusionLabel(exclusion.reason)}</p>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {Boolean(review.payment_attestations?.length) && (
              <div className="border-t border-warning-200 bg-warning-50/60 px-6 py-6">
                <h4 className="font-semibold text-neutral-950">Payment reported; check details pending</h4>
                <p className="mt-1 text-sm font-medium text-warning-950">{review.payment_attestations?.length} {review.payment_attestations?.length === 1 ? 'entry' : 'entries'} · {hours(review.payment_attestations?.reduce((total, attestation) => total + attestation.hours, 0) || 0)} hours held</p>
                <p className="mt-2 text-sm leading-6 text-neutral-700">These exact AIRE hours are held out of new payroll to prevent a duplicate payment. The owner reported they were paid, but Cornerstone has not yet matched the check, amount, and delivery date. They are not counted as verified paid hours.</p>
                <div className="mt-4 grid gap-2 sm:grid-cols-2">
                  {review.payment_attestations?.map((attestation) => (
                    <div key={attestation.id} className="rounded-lg border border-warning-200 bg-white p-4 text-sm">
                      <p className="font-semibold text-neutral-950">{attestation.cornerstone?.employee_name || attestation.display_name} · {hours(attestation.hours)} hrs</p>
                      <p className="mt-2 text-xs text-neutral-700">Worked {formatDate(attestation.original_work_date)} · AIRE entry #{attestation.source_time_entry_id}</p>
                      {attestation.source_changed && <p className="mt-2 text-xs font-semibold text-danger-800">The time entry changed after the owner statement. Review it before matching payment evidence.</p>}
                    </div>
                  ))}
                </div>
              </div>
            )}

            <div className="border-t border-neutral-200 px-6 py-6">
              <h4 className="font-semibold text-neutral-950">AIRE hours and payment history</h4>
              <p className="mt-1 text-sm text-neutral-600">Hours below remain owed until linked to a committed paycheck. Linked hours become paid only after the paper check is recorded as issued or the bank payment is confirmed.</p>
              {linkError && !linkTarget && !bulkLinkTarget && <p role="alert" className="mt-3 text-sm text-danger-800">{linkError}</p>}
              {pendingSyncIds.length > 1 && <Button type="button" size="sm" variant="outline" className="mt-4" disabled={linkBusy} onClick={() => void retryAllLinks(pendingSyncIds)}>
                {linkBusy ? 'Syncing…' : `Sync all ${pendingSyncIds.length} pending AIRE updates`}
              </Button>}
              {bulkCandidates.length > 0 && <div className="mt-4 flex flex-wrap gap-2">
                {bulkCandidates.map((candidate) => <Button key={candidate.employee.source_user_id} type="button" size="sm" disabled={linkBusy} onClick={() => { setBulkLinkTarget(candidate); setBulkGrossVerified(false); setLinkNote(DEFAULT_LINK_NOTE); setLinkError(null); }}>
                  Link all {candidate.adjustments.length} entries for {candidate.employee.display_name}
                </Button>)}
              </div>}
              <div className="mt-4 space-y-3">
                {review.employees.flatMap((employee) => employee.adjustments.map((adjustment) => (
                  <div key={`${employee.source_user_id}-${adjustment.source_time_entry_id}-${adjustment.source_kind}`} className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-neutral-200 bg-neutral-50 p-4">
                    <div>
                      <p className="font-semibold text-neutral-950">{employee.cornerstone.employee_name || employee.display_name} · {hours(adjustment.regular_hours)} regular · {hours(adjustment.overtime_hours)} OT</p>
                      <p className="mt-1 text-xs text-neutral-600">{formatDate(adjustment.original_work_date)} · {adjustment.source_kind === 'carryover' ? 'Carryover still owed' : adjustment.source_kind === 'correction' ? 'Correction still owed' : 'Current period still owed'}</p>
                    </div>
                    {isCommitted && adjustment.regular_hours >= 0 && adjustment.overtime_hours >= 0 && (
                      <Button type="button" size="sm" variant="outline" disabled={employee.cornerstone.status !== 'mapped' || !payrollItems.some((item) => item.employee_id === employee.cornerstone.employee_id && !item.voided)} onClick={() => openLink(employee, adjustment)}>Link to paycheck</Button>
                    )}
                  </div>
                )))}
                {(review.manual_allocations || []).filter((allocation) => allocation.status !== 'voided').map((allocation) => (
                  <div key={`paid-${allocation.id}`} className="rounded-xl border border-success-200 bg-success-50/50 p-4">
                    <p className="font-semibold text-neutral-950">{allocation.cornerstone?.employee_name || allocation.display_name} · {hours(allocation.regular_hours)} regular · {hours(allocation.overtime_hours)} OT</p>
                    <p className="mt-1 text-xs text-neutral-600">{formatDate(allocation.original_work_date)} · {allocation.status === 'issued' ? `Paid${allocation.payment_reference ? ` · payment ${allocation.payment_reference}` : ''}` : 'Linked to committed payroll; awaiting payment evidence'}</p>
                  </div>
                ))}
                {(review.cornerstone_manual_allocations || []).filter(needsAireSync).map((allocation) => (
                  <div key={`sync-${allocation.id}`} className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-warning-200 bg-warning-50 p-4">
                    <div><p className="font-semibold text-neutral-950">{allocation.employee_name} · AIRE payment update pending</p><p className="mt-1 text-xs text-neutral-700">{allocation.last_sync_error || (allocation.status === 'pending_commit' ? 'The paycheck link has not reached AIRE yet.' : 'Check delivery is recorded in Cornerstone; AIRE has not confirmed it as paid yet.')}</p></div>
                    <Button type="button" size="sm" variant="outline" disabled={linkBusy} onClick={() => void retryLink(allocation.id)}>Sync now</Button>
                  </div>
                ))}
              </div>
            </div>

            <div className="border-t border-neutral-200 bg-neutral-950 px-6 py-6 text-sm text-neutral-200">
              <p className="font-semibold text-white">Finish payment tracking</p>
              <ol className="mt-2 grid gap-2 leading-5 md:grid-cols-4">
                <li><span className="font-semibold text-white">1.</span> Make every employee match.</li>
                <li><span className="font-semibold text-white">2.</span> Calculate, approve, then commit.</li>
                <li><span className="font-semibold text-white">3.</span> For manual hours, link each included AIRE entry to its paycheck. Connected imports link automatically.</li>
                <li><span className="font-semibold text-white">4.</span> Record check delivery or confirmed bank payment. Review the final AIRE lock seven days after the scheduled pay date.</li>
              </ol>
              <p className="mt-4 text-xs leading-5 text-neutral-300">
                {isCommitted
                  ? aireRecordLinked
                    ? 'The finalized AIRE record is linked. Recording payment evidence updates the included AIRE hours.'
                    : 'For manually entered payroll, link the included AIRE hours above. Connected imports link exact entries at commitment. Check delivery or bank confirmation then marks those hours paid in AIRE.'
                  : 'For manually entered payroll, commit first, then link each paid time entry to its paycheck. AIRE keeps any unlinked hours owed.'}
              </p>
            </div>
          </>
        )}
      </CardContent>
      <Dialog open={Boolean(linkTarget)} onOpenChange={(open) => { if (!open && !linkBusy) setLinkTarget(null); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Link AIRE hours to this paycheck</DialogTitle>
            <DialogDescription>Confirm only the hours actually included in the committed paycheck. This records the source time entry and leaves any remainder owed.</DialogDescription>
          </DialogHeader>
          {linkTarget && (
            <div className="space-y-4 text-sm">
              <p className="font-semibold text-neutral-950">{linkTarget.employee.display_name} · {formatDate(linkTarget.adjustment.original_work_date)} · up to {hours(linkTarget.adjustment.regular_hours)} regular and {hours(linkTarget.adjustment.overtime_hours)} OT</p>
              <label className="block font-medium text-neutral-700">Paycheck
                <select className="mt-1 w-full rounded-lg border border-neutral-300 bg-white px-3 py-2" value={selectedItemId} onChange={(event) => setSelectedItemId(event.target.value)}>
                  <option value="">Choose paycheck</option>
                  {payrollItems.filter((item) => item.employee_id === linkTarget.employee.cornerstone.employee_id && !item.voided).map((item) => <option key={item.id} value={item.id}>{item.effective_payment_delivery_method === 'direct_deposit' ? 'Direct deposit' : `Check #${item.check_number || item.id}`} · {hours(Number(item.hours_worked || 0))} regular / {hours(Number(item.overtime_hours || 0))} OT</option>)}
                </select>
              </label>
              <div className="grid grid-cols-1 gap-2 sm:grid-cols-2 sm:gap-3">
                <label className="font-medium text-neutral-700">Regular hours<input type="number" min="0" max={linkTarget.adjustment.regular_hours} step="0.01" className="mt-1 w-full rounded-lg border border-neutral-300 px-3 py-2" value={regularToLink} onChange={(event) => setRegularToLink(event.target.value)} /></label>
                <label className="font-medium text-neutral-700">OT hours<input type="number" min="0" max={linkTarget.adjustment.overtime_hours} step="0.01" className="mt-1 w-full rounded-lg border border-neutral-300 px-3 py-2" value={overtimeToLink} onChange={(event) => setOvertimeToLink(event.target.value)} /></label>
              </div>
              <label className="block font-medium text-neutral-700">Why these hours match<textarea className="mt-1 w-full rounded-lg border border-neutral-300 px-3 py-2" rows={3} value={linkNote} onChange={(event) => setLinkNote(event.target.value)} /></label>
              {linkError && <p role="alert" className="text-danger-800">{linkError}</p>}
            </div>
          )}
          <DialogFooter><Button type="button" variant="outline" disabled={linkBusy} onClick={() => setLinkTarget(null)}>Cancel</Button><Button type="button" disabled={linkBusy} onClick={() => void saveLink()}>{linkBusy ? 'Linking…' : 'Confirm link'}</Button></DialogFooter>
        </DialogContent>
      </Dialog>
      <Dialog open={Boolean(bulkLinkTarget)} onOpenChange={(open) => { if (!open && !linkBusy) setBulkLinkTarget(null); }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Link all matching AIRE entries</DialogTitle>
            <DialogDescription>This links exact source entries to the committed paycheck. It does not mark them paid until check delivery is recorded.</DialogDescription>
          </DialogHeader>
          {bulkLinkTarget && <div className="space-y-4 text-sm">
            <p className="font-semibold text-neutral-950">{bulkLinkTarget.employee.display_name} · {bulkLinkTarget.adjustments.length} entries · check #{bulkLinkTarget.item.check_number || bulkLinkTarget.item.id}</p>
            <p>{hours(bulkLinkTarget.adjustments.reduce((sum, entry) => sum + entry.regular_hours, 0))} regular · {hours(bulkLinkTarget.adjustments.reduce((sum, entry) => sum + entry.overtime_hours, 0))} OT exactly match the paycheck hours not already linked.</p>
            <label className="flex items-start gap-2 text-neutral-700"><input type="checkbox" className="mt-1" checked={bulkGrossVerified} onChange={(event) => setBulkGrossVerified(event.target.checked)} />I checked the wage category, rate, and gross pay on this paycheck against these AIRE entries.</label>
            <label className="block font-medium text-neutral-700">Why these hours match<textarea className="mt-1 w-full rounded-lg border border-neutral-300 px-3 py-2" rows={3} value={linkNote} onChange={(event) => setLinkNote(event.target.value)} /></label>
            {linkError && <p role="alert" className="text-danger-800">{linkError}</p>}
          </div>}
          <DialogFooter><Button type="button" variant="outline" disabled={linkBusy} onClick={() => setBulkLinkTarget(null)}>Cancel</Button><Button type="button" disabled={linkBusy} onClick={() => void saveBulkLink()}>{linkBusy ? 'Linking…' : 'Confirm all links'}</Button></DialogFooter>
        </DialogContent>
      </Dialog>
      <Dialog open={Boolean(mapSourceId)} onOpenChange={(open) => { if (!open && !mapBusy) setMapSourceId(null); }}>
        <DialogContent>
          <DialogHeader><DialogTitle>Match AIRE employee</DialogTitle><DialogDescription>Confirm these are the same person before saving. This permanent link cannot be silently reassigned.</DialogDescription></DialogHeader>
          {mapSourceEmployee && <div className="rounded-lg border border-primary-200 bg-primary-50 p-3 text-sm">
            <p className="text-xs font-semibold uppercase tracking-wide text-primary-700">Person in AIRE</p>
            <p className="mt-1 font-semibold text-neutral-950">{mapSourceEmployee.display_name}</p>
            {mapSourceEmployee.email && <p className="text-neutral-600">{mapSourceEmployee.email}</p>}
            <p className="mt-1 break-all text-xs text-neutral-500">AIRE ID: {mapSourceEmployee.source_user_uuid || mapSourceEmployee.source_user_id}</p>
          </div>}
          <label className="block text-sm font-medium text-neutral-700">Cornerstone employee
            <select className="mt-1 w-full rounded-lg border border-neutral-300 bg-white px-3 py-2" value={mapEmployeeId} onChange={(event) => setMapEmployeeId(event.target.value)}>
              <option value="">Choose the same person</option>
              {employees.map((employee) => <option key={employee.id} value={employee.id}>{[employee.first_name, employee.last_name].filter(Boolean).join(' ')}</option>)}
            </select>
          </label>
          {mapTargetEmployee && <p className="text-sm text-neutral-700">You are linking AIRE’s <strong>{mapSourceEmployee?.display_name}</strong> to Cornerstone’s <strong>{[mapTargetEmployee.first_name, mapTargetEmployee.last_name].filter(Boolean).join(' ')}</strong>{mapTargetEmployee.email ? ` (${mapTargetEmployee.email})` : ''}.</p>}
          {mapError && <p role="alert" className="text-sm text-danger-800">{mapError}</p>}
          <DialogFooter><Button type="button" variant="outline" disabled={mapBusy} onClick={() => setMapSourceId(null)}>Cancel</Button><Button type="button" disabled={mapBusy || !mapSourceEmployee || !mapEmployeeId} onClick={() => void saveMapping()}>{mapBusy ? 'Saving…' : 'Save match'}</Button></DialogFooter>
        </DialogContent>
      </Dialog>
    </Card>
  );
}
