import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  AlertTriangle,
  Check,
  CheckCircle2,
  Clock3,
  History,
  Loader2,
  LockKeyhole,
  RefreshCw,
  ShieldAlert,
  Users,
  X,
} from 'lucide-react';
import { AirePayrollCalendarCard } from './AirePayrollCalendarCard';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { ApiError, payPeriodsApi } from '@/services/api';
import { formatDate, formatDateRange, formatGuamDateTime } from '@/lib/utils';
import type {
  AirePayrollCalendarState,
  AirePayrollCockpitOverview,
  AirePayrollExceptionsResponse,
  AirePayrollTimeEntriesResponse,
  AirePayrollTimeEntry,
  AirePayrollPagination,
} from '@/types';

type Props = {
  payPeriodId: number;
  calendar: AirePayrollCalendarState;
  onRefresh: () => Promise<void> | void;
};

type View = 'timecards' | 'exceptions' | 'team' | 'history';
type Review = { entry: AirePayrollTimeEntry; decision: 'approve' | 'deny'; commandId: string };
type ReviewTarget = Omit<Review, 'commandId'>;
type FinalizeCommand = { commandId: string; version: number };

const lifecycleTone = (status?: string) => {
  if (['payment_issued', 'committed', 'imported', 'finalized', 'ready_for_cutoff'].includes(status || '')) return 'success' as const;
  if (['awaiting_approval', 'ready_for_next_batch', 'payment_failed', 'payment_voided'].includes(status || '')) return 'warning' as const;
  if (status === 'not_payable') return 'danger' as const;
  return 'default' as const;
};

const approvalTone = (entry: AirePayrollTimeEntry) => {
  if (['missing_category', 'partially_included'].includes(entry.state.payroll_disposition || '')) return 'warning' as const;
  if (entry.state.payable_now) return 'success' as const;
  if (entry.state.approval_status === 'denied') return 'danger' as const;
  return 'warning' as const;
};

const dispositionLabel = (entry: AirePayrollTimeEntry) => {
  const disposition = entry.state.payroll_disposition;
  if (disposition === 'missing_category') return 'Missing category';
  if (disposition === 'partially_included') return 'Partially included at cutoff';
  if (disposition === 'created_after_cutoff') return 'Submitted after cutoff';
  if (disposition === 'changed_after_cutoff') return entry.state.payable_now ? 'Included; changed after cutoff' : 'Changed after cutoff';
  if (entry.state.payable_now) return 'Included at cutoff';
  if (disposition === 'approved_after_cutoff') return 'Approved after cutoff';
  if (disposition === 'overtime_approved_after_cutoff') return 'Overtime approved after cutoff';
  if (disposition === 'open_clock') return 'Missing punch';
  if (disposition === 'denied_approval' || disposition === 'denied_overtime') return 'Not payable';
  if (disposition === 'pending_overtime') return 'Overtime approval needed';
  if (disposition === 'pending_approval') return 'Awaiting approval';
  return entry.state.approval_status.replaceAll('_', ' ');
};

const commandId = () => {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();

  const bytes = new Uint8Array(16);
  if (globalThis.crypto?.getRandomValues) globalThis.crypto.getRandomValues(bytes);
  else bytes.forEach((_, index) => { bytes[index] = Math.floor(Math.random() * 256); });
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const value = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
  return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(12, 16)}-${value.slice(16, 20)}-${value.slice(20)}`;
};

function Metric({ label, value, detail, tone = 'neutral' }: { label: string; value: string | number; detail: string; tone?: 'neutral' | 'success' | 'warning' }) {
  const toneClass = tone === 'success'
    ? 'border-success-200 bg-success-50/70'
    : tone === 'warning' ? 'border-warning-200 bg-warning-50/70' : 'border-neutral-200 bg-white';
  return (
    <div className={`rounded-xl border p-4 ${toneClass}`}>
      <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">{label}</p>
      <p className="mt-2 font-display text-2xl font-bold tracking-tight text-neutral-950">{value}</p>
      <p className="mt-1 text-xs leading-5 text-neutral-600">{detail}</p>
    </div>
  );
}

function MappingBadge({ status }: { status: 'mapped' | 'unmapped' | 'inactive' | 'not_required' }) {
  if (status === 'mapped') return <Badge variant="success">Mapped</Badge>;
  if (status === 'not_required') return <Badge variant="default">No time mapping needed</Badge>;
  if (status === 'inactive') return <Badge variant="warning">Inactive in Cornerstone</Badge>;
  return <Badge variant="danger">Not mapped</Badge>;
}

function PageControls({ pagination, onPage }: { pagination?: AirePayrollPagination; onPage: (page: number) => void }) {
  if (!pagination || pagination.total_pages <= 1) return null;
  return (
    <div className="flex items-center justify-between gap-3 border-t border-neutral-200 bg-neutral-50 px-4 py-3 text-xs text-neutral-600 sm:px-6">
      <span>Page {pagination.current_page} of {pagination.total_pages} · {pagination.total_count} records</span>
      <div className="flex gap-2">
        <Button type="button" size="sm" variant="outline" disabled={pagination.current_page <= 1} onClick={() => onPage(pagination.current_page - 1)}>Previous</Button>
        <Button type="button" size="sm" variant="outline" disabled={pagination.current_page >= pagination.total_pages} onClick={() => onPage(pagination.current_page + 1)}>Next</Button>
      </div>
    </div>
  );
}

function TimecardRow({ entry, canCommand, onReview }: {
  entry: AirePayrollTimeEntry;
  canCommand: boolean;
  onReview: (review: ReviewTarget) => void;
}) {
  const pending = entry.state.approval_status === 'pending';
  const needsReview = pending && !entry.capture.ordinary;
  return (
    <div className="grid gap-3 border-t border-neutral-100 px-4 py-4 first:border-t-0 lg:grid-cols-[1.2fr_1fr_0.8fr_1.1fr_auto] lg:items-center">
      <div>
        <p className="font-semibold text-neutral-950">{entry.employee.name || 'Unknown AIRE employee'}</p>
        <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-neutral-500">
          <span>{formatDate(entry.work_date)}</span>
          <MappingBadge status={entry.employee.cornerstone.status} />
        </div>
      </div>
      <div className="text-sm text-neutral-700">
        <p className="font-medium text-neutral-950">{entry.start_time || 'Missing'} – {entry.end_time || 'Missing'}</p>
        <p className="mt-1 text-xs text-neutral-500">{entry.break_minutes} min break · {entry.capture.entry_method || 'unknown'} entry</p>
      </div>
      <div>
        <p className="font-display text-lg font-bold text-neutral-950">{Number(entry.hours).toFixed(2)} hrs</p>
        <p className="mt-1 text-xs text-neutral-500">{entry.category?.name || 'Uncategorized'}</p>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant={approvalTone(entry)}>{dispositionLabel(entry)}</Badge>
        {entry.lifecycle && <Badge variant={lifecycleTone(entry.lifecycle.status)}>{entry.lifecycle.label}</Badge>}
        {entry.state.missing_punch && <Badge variant="danger">Missing punch</Badge>}
      </div>
      <div className="flex gap-2 lg:justify-end">
        {needsReview && (
          <>
            <Button type="button" size="sm" variant="outline" disabled={!canCommand} onClick={() => onReview({ entry, decision: 'deny' })}>
              <X className="mr-1 h-3.5 w-3.5" /> Deny
            </Button>
            <Button type="button" size="sm" disabled={!canCommand} onClick={() => onReview({ entry, decision: 'approve' })}>
              <Check className="mr-1 h-3.5 w-3.5" /> Approve
            </Button>
          </>
        )}
      </div>
    </div>
  );
}

export function AirePayrollCockpit({ payPeriodId, calendar, onRefresh }: Props) {
  const [overview, setOverview] = useState<AirePayrollCockpitOverview | null>(null);
  const [timeEntries, setTimeEntries] = useState<AirePayrollTimeEntriesResponse | null>(null);
  const [exceptions, setExceptions] = useState<AirePayrollExceptionsResponse | null>(null);
  const [view, setView] = useState<View>('timecards');
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [refreshError, setRefreshError] = useState<string | null>(null);
  const [commandError, setCommandError] = useState<string | null>(null);
  const [review, setReview] = useState<Review | null>(null);
  const [reason, setReason] = useState('');
  const [showFinalize, setShowFinalize] = useState(false);
  const [finalizeCommand, setFinalizeCommand] = useState<FinalizeCommand | null>(null);
  const [finalizeReason, setFinalizeReason] = useState('Reviewed AIRE readiness and confirmed eligible time for cutoff');
  const [timePage, setTimePage] = useState(1);
  const [exceptionPage, setExceptionPage] = useState(1);
  const [leavePage, setLeavePage] = useState(1);
  const [employeePage, setEmployeePage] = useState(1);
  const requestGeneration = useRef(0);

  const load = useCallback(async () => {
    const generation = ++requestGeneration.current;
    const published = calendar.publication?.delivery_status === 'delivered' || Boolean(calendar.finalized_batch);
    if (!calendar.external_pay_period_id || !published) return;
    setLoading(true);
    setRefreshError(null);
    try {
      const [overviewResult, entriesResult, exceptionsResult] = await Promise.all([
        payPeriodsApi.airePayrollCockpit(payPeriodId, { employee_page: employeePage }),
        payPeriodsApi.airePayrollTimeEntries(payPeriodId, { page: timePage }),
        payPeriodsApi.airePayrollExceptions(payPeriodId, { page: exceptionPage, leave_page: leavePage }),
      ]);
      if (generation !== requestGeneration.current) return;
      setOverview(overviewResult.aire_payroll_cockpit);
      setTimeEntries(entriesResult);
      setExceptions(exceptionsResult);
    } catch (caught) {
      if (generation !== requestGeneration.current) return;
      setRefreshError(caught instanceof Error ? caught.message : 'Could not refresh AIRE payroll details');
    } finally {
      if (generation === requestGeneration.current) setLoading(false);
    }
  }, [calendar.external_pay_period_id, calendar.finalized_batch, calendar.publication?.delivery_status, employeePage, exceptionPage, leavePage, payPeriodId, timePage]);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => () => {
    requestGeneration.current += 1;
  }, []);

  useEffect(() => {
    if (!review) return;

    const latest = [
      ...(timeEntries?.time_entries || []),
      ...(exceptions?.time_exceptions || []),
    ].find((entry) => entry.id === review.entry.id);
    if (latest && latest.version !== review.entry.version) {
      setReview({ entry: latest, decision: review.decision, commandId: commandId() });
    }
  }, [exceptions?.time_exceptions, review, timeEntries?.time_entries]);

  useEffect(() => {
    if (!showFinalize || !overview) return;
    const version = overview.payroll_period.version;
    setFinalizeCommand((current) => current?.version === version
      ? current
      : { commandId: commandId(), version });
  }, [overview, showFinalize]);

  const employeesRequiringMapping = useMemo(
    () => overview?.employees.filter((employee) => employee.cornerstone.status !== 'not_required') || [],
    [overview]
  );
  const unmappedCount = employeesRequiringMapping.filter((employee) => employee.cornerstone.status !== 'mapped').length;
  const heldHours = overview
    ? overview.readiness.held_hours ?? Math.max(0, overview.readiness.total_hours - overview.readiness.eligible_hours)
    : 0;
  const canCommand = overview?.command_access.can_command === true;

  const submitReview = async () => {
    if (!review || reason.trim().length < 3) return;
    setBusy(true);
    setCommandError(null);
    try {
      await payPeriodsApi.reviewAireTimeEntry(payPeriodId, review.entry.id, {
        command_id: review.commandId,
        expected_version: review.entry.version,
        decision: review.decision,
        reason: reason.trim(),
      });
      setReview(null);
      setReason('');
    } catch (caught) {
      setCommandError(caught instanceof ApiError && caught.status === 409
        ? 'That time entry changed in AIRE. The latest details have been reloaded; review it again before deciding.'
        : caught instanceof Error ? caught.message : 'Could not update the time entry');
    } finally {
      await load();
      setBusy(false);
    }
  };

  const finalize = async () => {
    if (!overview || !finalizeCommand || finalizeReason.trim().length < 3) return;
    setBusy(true);
    setCommandError(null);
    let commandSucceeded = false;
    try {
      await payPeriodsApi.finalizeAirePayrollPeriod(payPeriodId, {
        command_id: finalizeCommand.commandId,
        expected_version: finalizeCommand.version,
        reason: finalizeReason.trim(),
      });
      commandSucceeded = true;
      setShowFinalize(false);
      setFinalizeCommand(null);
    } catch (caught) {
      setCommandError(caught instanceof ApiError && caught.status === 409
        ? 'The AIRE period changed before it could be locked. The latest details have been reloaded.'
        : caught instanceof Error ? caught.message : 'Could not lock the AIRE payroll period');
    } finally {
      await load();
      if (commandSucceeded) {
        try {
          await onRefresh();
        } catch (caught) {
          setRefreshError(caught instanceof Error
            ? `AIRE was locked, but Cornerstone could not refresh: ${caught.message}`
            : 'AIRE was locked, but Cornerstone could not refresh its payroll status.');
        }
      }
      setBusy(false);
    }
  };

  const renderedEntries = view === 'exceptions' ? exceptions?.time_exceptions : timeEntries?.time_entries;
  const periodCanFinalize = overview?.payroll_period.cutoff_state === 'due' || overview?.payroll_period.cutoff_state === 'attention_required';
  const cockpitPublished = calendar.publication?.delivery_status === 'delivered' || Boolean(calendar.finalized_batch);
  const visibleError = commandError || refreshError;

  return (
    <div className="space-y-4">
      <AirePayrollCalendarCard payPeriodId={payPeriodId} calendar={calendar} onRefresh={async () => {
        await onRefresh();
        await load();
      }} />

      {calendar.external_pay_period_id && cockpitPublished && (
        <Card className="overflow-hidden">
          <CardContent className="p-0">
            <div className="border-b border-neutral-200 bg-neutral-950 px-5 py-5 text-white sm:px-6">
              <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
                <div>
                  <div className="flex flex-wrap items-center gap-2">
                    <h3 className="font-display text-lg font-bold">AIRE payroll workspace</h3>
                    <Badge className="bg-white/10 text-white">Live from AIRE</Badge>
                  </div>
                  <p className="mt-1 max-w-3xl text-sm leading-6 text-neutral-300">
                    Review the exact AIRE timecards, resolve manual entries, lock the cutoff, and follow every hour through payroll without leaving Cornerstone.
                  </p>
                </div>
                <div className="flex flex-wrap gap-2">
                  <Button type="button" size="sm" variant="secondary" onClick={() => void load()} disabled={loading || busy}>
                    <RefreshCw className={`mr-2 h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Refresh AIRE
                  </Button>
                  {overview?.payroll_period.status !== 'finalized' && (
                    <Button type="button" size="sm" onClick={() => {
                      const version = overview?.payroll_period.version;
                      if (version != null) {
                        setFinalizeCommand((current) => current?.version === version
                          ? current
                          : { commandId: commandId(), version });
                      }
                      setCommandError(null);
                      setShowFinalize(true);
                    }} disabled={!canCommand || !periodCanFinalize || busy || loading}>
                      <LockKeyhole className="mr-2 h-4 w-4" />
                      Lock AIRE cutoff
                    </Button>
                  )}
                </div>
              </div>
            </div>

            {visibleError && (
              <div role="alert" className="flex items-start gap-3 border-b border-danger-200 bg-danger-50 px-5 py-4 text-sm text-danger-800 sm:px-6">
                <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
                <p>{visibleError}</p>
              </div>
            )}

            {loading && !overview ? (
              <div className="flex items-center justify-center gap-3 px-6 py-14 text-sm text-neutral-600">
                <Loader2 className="h-5 w-5 animate-spin text-primary-700" /> Loading live AIRE payroll details…
              </div>
            ) : overview && (
              <>
                <div className="grid gap-3 border-b border-neutral-200 bg-neutral-50/70 p-4 sm:grid-cols-2 xl:grid-cols-5 sm:p-6">
                  <Metric label="Total time" value={`${Number(overview.readiness.total_hours).toFixed(2)} hrs`} detail={`${overview.readiness.total_entries} timecards in AIRE`} />
                  <Metric label="Ready this payroll" value={`${Number(overview.readiness.eligible_hours).toFixed(2)} hrs`} detail={`${overview.readiness.eligible_entries} eligible timecards`} tone="success" />
                  <Metric label="Held or unresolved" value={`${heldHours.toFixed(2)} hrs`} detail={`${overview.readiness.held_entries ?? '—'} held timecards · not included`} tone={heldHours > 0 ? 'warning' : 'neutral'} />
                  <Metric label="Approvals needed" value={overview.readiness.pending_approvals + overview.readiness.pending_overtime} detail={`${overview.readiness.missing_punches} missing punch${overview.readiness.missing_punches === 1 ? '' : 'es'}`} tone={overview.readiness.pending_approvals > 0 ? 'warning' : 'neutral'} />
                  <Metric
                    label="Visible mapping"
                    value={`${employeesRequiringMapping.length - unmappedCount}/${employeesRequiringMapping.length}`}
                    detail={unmappedCount
                      ? `${unmappedCount} on this page need attention`
                      : overview.employee_pagination.total_pages > 1 ? `${overview.employee_pagination.total_count} employees across all pages` : 'Everyone is linked'}
                    tone={unmappedCount ? 'warning' : 'success'}
                  />
                </div>

                {!overview.command_access.delegation_configured && (
                  <div className="flex items-start gap-3 border-b border-warning-200 bg-warning-50 px-5 py-4 text-sm text-warning-900 sm:px-6">
                    <ShieldAlert className="mt-0.5 h-4 w-4 shrink-0" />
                    <div><p className="font-semibold">Live details are available, but actions need your AIRE delegation</p><p className="mt-1 leading-5">Add your personal token in Settings → Time Tracking Source. It lets AIRE verify and record your approvals; it is never shared with another Cornerstone user.</p></div>
                  </div>
                )}

                {overview.payroll_period.status !== 'finalized' && !periodCanFinalize && (
                  <div className="flex items-start gap-3 border-b border-primary-100 bg-primary-50/60 px-5 py-4 text-sm text-primary-900 sm:px-6">
                    <Clock3 className="mt-0.5 h-4 w-4 shrink-0" />
                    <p>The cutoff can be locked on {formatGuamDateTime(overview.payroll_period.cutoff_at)}. Continue reviewing time now; ordinary clock and kiosk entries are already eligible.</p>
                  </div>
                )}

                {overview.payroll_period.status === 'finalized' && (
                  <div className="flex items-start gap-3 border-b border-success-200 bg-success-50 px-5 py-4 text-sm text-success-800 sm:px-6">
                    <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" />
                    <p><span className="font-semibold">AIRE cutoff locked.</span> Batch {overview.finalized_batch?.id || overview.payroll_period.payroll_batch_id || 'is being prepared'} contains the eligible hours. Held hours remain visible below for the next available payroll.</p>
                  </div>
                )}

                <div className="border-b border-neutral-200 px-4 pt-4 sm:px-6">
                  <div className="flex gap-1 overflow-x-auto" role="tablist" aria-label="AIRE payroll details">
                    {([
                      ['timecards', 'Timecards', timeEntries?.pagination.total_count || 0],
                      ['exceptions', 'Needs attention', (exceptions?.time_exception_pagination.total_count || 0) + (exceptions?.leave_exception_pagination.total_count || 0)],
                      ['team', 'Team', overview.employee_pagination.total_count],
                      ['history', 'Payment history', overview.processing_history.length],
                    ] as Array<[View, string, number]>).map(([key, label, count]) => (
                      <button
                        key={key}
                        type="button"
                        role="tab"
                        aria-selected={view === key}
                        onClick={() => setView(key)}
                        className={`whitespace-nowrap border-b-2 px-4 py-3 text-sm font-semibold transition-colors ${view === key ? 'border-primary-700 text-primary-800' : 'border-transparent text-neutral-500 hover:text-neutral-900'}`}
                      >
                        {label} <span className="ml-1 text-xs">{count}</span>
                      </button>
                    ))}
                  </div>
                </div>

                {(view === 'timecards' || view === 'exceptions') && (
                  <div>
                    {renderedEntries?.length ? renderedEntries.map((entry) => (
                      <TimecardRow key={entry.id} entry={entry} canCommand={canCommand} onReview={(next) => { setReview({ ...next, commandId: commandId() }); setReason(''); setCommandError(null); }} />
                    )) : (
                      <div className="px-6 py-10 text-center text-sm text-neutral-500">
                        {view === 'exceptions' ? 'No timecard exceptions need attention.' : 'AIRE has no timecards in this pay period.'}
                      </div>
                    )}

                    {view === 'exceptions' && exceptions?.leave_exceptions.map((leave) => (
                      <div key={`leave-${leave.id}`} className="grid gap-2 border-t border-neutral-100 px-4 py-4 sm:grid-cols-[1fr_auto] sm:items-center">
                        <div><p className="font-semibold text-neutral-950">{leave.employee.name} · {leave.leave_type}</p><p className="mt-1 text-sm text-neutral-600">{formatDateRange(leave.start_date, leave.end_date)} · {leave.total_days} day{leave.total_days === 1 ? '' : 's'} · pending in AIRE</p></div>
                        <MappingBadge status={leave.employee.cornerstone.status} />
                      </div>
                    ))}

                    {view === 'exceptions' && exceptions?.carryovers.items?.length ? (
                      <div className="border-t border-neutral-200 bg-warning-50/50 px-4 py-5 sm:px-6">
                        <h4 className="font-semibold text-neutral-950">Held hours carried forward</h4>
                        <p className="mt-1 text-sm text-neutral-600">These hours were not eligible at an earlier cutoff. Their current payment state comes directly from AIRE.</p>
                        <div className="mt-4 space-y-2">
                          {exceptions.carryovers.items.map((item) => (
                            <div key={`${item.latest_excluded_batch_id}-${item.source_time_entry_id}`} className="flex flex-col gap-2 rounded-lg border border-warning-200 bg-white p-3 text-sm sm:flex-row sm:items-center sm:justify-between">
                              <div><p className="font-medium text-neutral-950">{item.display_name} · {Number(item.held_total_hours).toFixed(2)} hrs</p><p className="mt-1 text-xs text-neutral-500">Worked {formatDate(item.original_work_date)} · {item.exclusion_reason.replaceAll('_', ' ')}</p></div>
                              <Badge variant={lifecycleTone(item.status)}>{item.status.replaceAll('_', ' ')}</Badge>
                            </div>
                          ))}
                        </div>
                      </div>
                    ) : null}
                    {view === 'timecards' && <PageControls pagination={timeEntries?.pagination} onPage={setTimePage} />}
                    {view === 'exceptions' && <PageControls pagination={exceptions?.time_exception_pagination} onPage={setExceptionPage} />}
                    {view === 'exceptions' && exceptions && exceptions.leave_exception_pagination.total_pages > 1 && (
                      <div className="border-t border-neutral-200"><PageControls pagination={exceptions.leave_exception_pagination} onPage={setLeavePage} /></div>
                    )}
                  </div>
                )}

                {view === 'team' && (
                  <div className="divide-y divide-neutral-100">
                    {overview.employees.length === 0 && (
                      <p className="px-6 py-10 text-center text-sm text-neutral-500">AIRE has no employees on this page.</p>
                    )}
                    {overview.employees.map((employee) => (
                      <div key={employee.id} className="flex flex-col gap-3 px-4 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-6">
                        <div className="flex items-center gap-3"><div className="flex h-9 w-9 items-center justify-center rounded-full bg-neutral-100 text-neutral-600"><Users className="h-4 w-4" /></div><div><p className="font-semibold text-neutral-950">{employee.full_name}</p><p className="text-xs text-neutral-500">{employee.email || 'No email'} · {employee.time_tracking_enabled ? 'Time tracking on' : 'Time tracking off'}</p></div></div>
                        <div className="flex flex-wrap items-center gap-2"><MappingBadge status={employee.cornerstone.status} />{employee.cornerstone.employee_name && <span className="text-xs text-neutral-500">{employee.cornerstone.employee_name}</span>}</div>
                      </div>
                    ))}
                    <PageControls pagination={overview.employee_pagination} onPage={setEmployeePage} />
                  </div>
                )}

                {view === 'history' && (
                  <div className="px-4 py-5 sm:px-6">
                    {overview.processing_history.length ? (
                      <div className="space-y-3">
                        {overview.processing_history.map((event) => (
                          <div key={event.event_id} className="flex items-start gap-3 rounded-xl border border-neutral-200 p-4">
                            <History className="mt-0.5 h-4 w-4 shrink-0 text-primary-700" />
                            <div><p className="font-semibold text-neutral-950">{event.status.replaceAll('_', ' ')}</p><p className="mt-1 text-xs text-neutral-500">{formatGuamDateTime(event.occurred_at)}{event.external_system ? ` · ${event.external_system}` : ''}</p></div>
                          </div>
                        ))}
                      </div>
                    ) : <p className="py-6 text-center text-sm text-neutral-500">Payment history will appear after AIRE’s batch reaches Cornerstone.</p>}
                  </div>
                )}
              </>
            )}
          </CardContent>
        </Card>
      )}

      <Dialog
        open={Boolean(review)}
        onOpenChange={(open) => { if (!open && !busy) setReview(null); }}
        dismissOnEscape={!busy}
      >
        {review && (
          <DialogContent className="relative max-w-lg rounded-2xl p-5 sm:p-6">
            <DialogHeader className="pr-10 text-left">
              <DialogTitle className="font-display font-bold text-neutral-950">
                {review.decision === 'approve' ? 'Approve' : 'Deny'} manual time
              </DialogTitle>
              <DialogDescription className="leading-6 text-neutral-600">
                {review.entry.employee.name} · {formatDate(review.entry.work_date)} · {Number(review.entry.hours).toFixed(2)} hours
              </DialogDescription>
            </DialogHeader>
            {commandError && <div role="alert" className="mt-4 rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-800">{commandError}</div>}
            <label className="mt-5 block text-sm font-semibold text-neutral-800">Reason<span className="font-normal text-neutral-500"> (saved in both audit histories)</span><textarea autoFocus value={reason} onChange={(event) => setReason(event.target.value)} rows={4} placeholder="What did you verify?" className="mt-2 w-full resize-none rounded-xl border border-neutral-300 px-3 py-2 text-sm font-normal" /></label>
            <button type="button" onClick={() => setReview(null)} disabled={busy} aria-label="Close review" className="absolute right-5 top-5 rounded-full p-2 text-neutral-500 hover:bg-neutral-100 disabled:opacity-50 sm:right-6 sm:top-6"><X className="h-5 w-5" /></button>
            <DialogFooter className="mt-5 !flex-row gap-2 pt-0"><Button type="button" variant="outline" onClick={() => setReview(null)} disabled={busy}>Cancel</Button><Button type="button" variant={review.decision === 'deny' ? 'danger' : 'primary'} onClick={() => void submitReview()} disabled={busy || reason.trim().length < 3}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}{review.decision === 'approve' ? 'Approve time' : 'Deny time'}</Button></DialogFooter>
          </DialogContent>
        )}
      </Dialog>

      <Dialog
        open={showFinalize && Boolean(overview)}
        onOpenChange={(open) => { if (!open && !busy) setShowFinalize(false); }}
        dismissOnEscape={!busy}
      >
        {overview && (
          <DialogContent className="relative max-w-lg rounded-2xl p-5 sm:p-6">
            <DialogHeader className="pr-10 text-left">
              <DialogTitle className="font-display font-bold text-neutral-950">Lock the AIRE cutoff</DialogTitle>
              <DialogDescription className="leading-6 text-neutral-600">AIRE will lock {Number(overview.readiness.eligible_hours).toFixed(2)} eligible hours. {heldHours.toFixed(2)} hours will remain held or unresolved and stay visible for a later payroll.</DialogDescription>
            </DialogHeader>
            {commandError && <div role="alert" className="mt-4 rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-800">{commandError}</div>}
            <div className="mt-4 rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm text-warning-900"><p className="font-semibold">This locks time in AIRE only.</p><p className="mt-1 leading-5">It does not calculate Cornerstone payroll, issue checks, or mark wages paid.</p></div>
            <label className="mt-5 block text-sm font-semibold text-neutral-800">Review note<span className="font-normal text-neutral-500"> (saved in both audit histories)</span><textarea autoFocus value={finalizeReason} onChange={(event) => setFinalizeReason(event.target.value)} rows={3} className="mt-2 w-full resize-none rounded-xl border border-neutral-300 px-3 py-2 text-sm font-normal" /></label>
            <button type="button" onClick={() => setShowFinalize(false)} disabled={busy} aria-label="Close cutoff confirmation" className="absolute right-5 top-5 rounded-full p-2 text-neutral-500 hover:bg-neutral-100 disabled:opacity-50 sm:right-6 sm:top-6"><X className="h-5 w-5" /></button>
            <DialogFooter className="mt-5 !flex-row gap-2 pt-0"><Button type="button" variant="outline" onClick={() => setShowFinalize(false)} disabled={busy}>Cancel</Button><Button type="button" onClick={() => void finalize()} disabled={busy || !finalizeCommand || finalizeReason.trim().length < 3}>{busy ? <Loader2 className="mr-2 h-4 w-4 animate-spin" /> : <LockKeyhole className="mr-2 h-4 w-4" />}Lock eligible time</Button></DialogFooter>
          </DialogContent>
        )}
      </Dialog>
    </div>
  );
}
