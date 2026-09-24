import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link } from 'react-router';
import {
  AlertTriangle,
  ArrowRight,
  Check,
  CheckCircle2,
  ChevronDown,
  Clock3,
  FilePenLine,
  History,
  Loader2,
  LockKeyhole,
  RefreshCw,
  ShieldAlert,
  Split,
  Users,
  X,
} from 'lucide-react';
import { AirePayrollCalendarCard } from './AirePayrollCalendarCard';
import { AireManualHoursReview } from './AireManualHoursReview';
import { AirePostLockComparison } from './AirePostLockComparison';
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
import { useCompany } from '@/contexts/CompanyContext';
import { employeePath, newEmployeePath, payRunPath } from '@/lib/routes';
import { formatDate, formatDateRange, formatGuamDateTime } from '@/lib/utils';
import type {
  AirePayrollCalendarState,
  AirePayrollCockpitEmployee,
  AirePayrollCockpitOverview,
  AirePayrollExceptionsResponse,
  AirePayrollTimeEntriesResponse,
  AirePayrollTimeEntry,
  AirePayrollPagination,
  AirePayrollSettlementCase,
  AirePayrollSettlementCasesResponse,
} from '@/types';

type Props = {
  payPeriodId: number;
  payPeriodStatus?: import('@/types').PayPeriodStatus;
  payrollHours?: Record<string, { regular: number; overtime: number }>;
  payrollItems?: import('@/types').PayrollItem[];
  employees?: import('@/types').Employee[];
  aireRecordLinked?: boolean;
  calendar: AirePayrollCalendarState;
  onRefresh: () => Promise<void> | void;
};

type View = 'timecards' | 'exceptions' | 'held_time' | 'team' | 'history';
type ReviewKind = 'time' | 'overtime';
type Review = { entry: AirePayrollTimeEntry; decision: 'approve' | 'deny'; kind: ReviewKind; commandId: string };
type ReviewTarget = Omit<Review, 'commandId'>;
type FinalizeCommand = { commandId: string; version: number };
type CorrectionBreak = { start_time: string; end_time: string };
type Correction = {
  entry: AirePayrollTimeEntry;
  commandId: string;
  reason: string;
  workDate: string;
  startTime: string;
  endTime: string;
  timeCategoryId: string;
  description: string;
  breaks: CorrectionBreak[];
  preservesLegacyBreakMinutes: boolean;
};
type SettlementRoute = {
  settlementCase: AirePayrollSettlementCase;
  commandId: string;
  destinationKind: 'regular' | 'not_payable';
  targetExternalPayPeriodId: string;
  reason: string;
};

const lifecycleTone = (status?: string) => {
  if (['payment_issued', 'committed', 'imported', 'finalized', 'ready_for_cutoff'].includes(status || '')) return 'success' as const;
  if (['awaiting_approval', 'ready_for_next_batch', 'payment_failed', 'payment_voided'].includes(status || '')) return 'warning' as const;
  if (status === 'not_payable') return 'danger' as const;
  return 'default' as const;
};

const approvalTone = (entry: AirePayrollTimeEntry) => {
  if (['missing_category', 'partially_included'].includes(entry.state.payroll_disposition || '')) return 'warning' as const;
  if (entry.state.payable_now) return 'success' as const;
  if (entry.state.approval_status === 'denied' || entry.state.overtime_status === 'denied') return 'danger' as const;
  return 'warning' as const;
};

const dispositionLabel = (entry: AirePayrollTimeEntry) => {
  const disposition = entry.state.payroll_disposition;
  if (!['pending', 'denied'].includes(entry.state.approval_status) && entry.state.overtime_status === 'pending') return 'Overtime approval needed';
  if (entry.state.overtime_status === 'denied') return 'Overtime denied';
  if (disposition === 'missing_category') return 'Missing category';
  if (disposition === 'partially_included') return 'Partially included at cutoff';
  if (disposition === 'created_after_cutoff') return 'Submitted after cutoff';
  if (disposition === 'changed_after_cutoff') return entry.state.payable_now ? 'Included; changed after cutoff' : 'Changed after cutoff';
  if (entry.state.payable_now) return 'Eligible in AIRE snapshot';
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

const toTimeInput = (value?: string | null) => {
  if (!value) return '';
  const twelveHour = value.trim().match(/^(\d{1,2}):(\d{2})\s*([AP]M)$/i);
  if (twelveHour) {
    let hour = Number(twelveHour[1]) % 12;
    if (twelveHour[3].toUpperCase() === 'PM') hour += 12;
    return `${String(hour).padStart(2, '0')}:${twelveHour[2]}`;
  }
  if (value.includes('T')) {
    const parsed = new Date(value);
    if (!Number.isNaN(parsed.valueOf())) {
      const parts = new Intl.DateTimeFormat('en-US', {
        timeZone: 'Pacific/Guam',
        hour: '2-digit',
        minute: '2-digit',
        hourCycle: 'h23',
      }).formatToParts(parsed);
      const hour = parts.find((part) => part.type === 'hour')?.value;
      const minute = parts.find((part) => part.type === 'minute')?.value;
      if (hour && minute) return `${hour}:${minute}`;
    }
  }
  return value.slice(0, 5);
};

const startCorrection = (entry: AirePayrollTimeEntry): Correction => {
  const breaks = (entry.breaks || [])
    .map((breakRow) => ({ start_time: toTimeInput(breakRow.start_time), end_time: toTimeInput(breakRow.end_time) }));

  return {
    entry,
    commandId: commandId(),
    reason: '',
    workDate: entry.work_date,
    startTime: toTimeInput(entry.start_time),
    endTime: toTimeInput(entry.end_time),
    timeCategoryId: entry.category?.id || '',
    description: entry.description || '',
    breaks,
    preservesLegacyBreakMinutes: breaks.length === 0 && entry.break_minutes > 0,
  };
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

function MappingBadge({ status }: { status: 'mapped' | 'unmapped' | 'inactive' | 'not_required' | 'needs_verification' }) {
  if (status === 'mapped') return <Badge variant="success">Mapped</Badge>;
  if (status === 'not_required') return <Badge variant="default">No time mapping needed</Badge>;
  if (status === 'inactive') return <Badge variant="warning">Inactive in Cornerstone</Badge>;
  if (status === 'needs_verification') return <Badge variant="warning">Verify older link</Badge>;
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

function TimecardRow({ entry, canCommand, onReview, onCorrect }: {
  entry: AirePayrollTimeEntry;
  canCommand: boolean;
  onReview: (review: ReviewTarget) => void;
  onCorrect: (entry: AirePayrollTimeEntry) => void;
}) {
  const pending = entry.state.approval_status === 'pending';
  const needsTimeReview = pending && !entry.capture.ordinary;
  const needsOvertimeReview = entry.state.overtime_status === 'pending'
    && !['pending', 'denied'].includes(entry.state.approval_status);
  const statusLabel = dispositionLabel(entry);
  const captureSource = entry.capture.ordinary
    ? `${entry.capture.entry_method || 'clock'} entry${entry.capture.clock_source ? ` via ${entry.capture.clock_source}` : ''}`
    : `${entry.capture.entry_method || 'manual'} entry · administrator approval required`;
  const showLifecycle = entry.lifecycle
    && !(entry.lifecycle.status === 'awaiting_approval' && statusLabel.toLowerCase().includes('approval'))
    && entry.lifecycle.label.toLowerCase() !== statusLabel.toLowerCase();
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
        <p className="mt-2 text-xs text-neutral-500">{entry.break_minutes} min break · {captureSource}</p>
        {entry.description && <p className="mt-2 text-xs text-neutral-500">{entry.description}</p>}
      </div>
      <div>
        <p className="font-display text-lg font-bold text-neutral-950">{Number(entry.hours).toFixed(2)} hrs</p>
        <p className="mt-1 text-xs text-neutral-500">{entry.category?.name || 'Uncategorized'}</p>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant={approvalTone(entry)}>{statusLabel}</Badge>
        {showLifecycle && entry.lifecycle && <Badge variant={lifecycleTone(entry.lifecycle.status)}>{entry.lifecycle.label}</Badge>}
        {entry.state.missing_punch && <Badge variant="danger">Missing punch</Badge>}
        {entry.approval?.occurred_at && (
          <p className="basis-full text-xs leading-5 text-neutral-500">
            Time {entry.state.approval_status} by {entry.approval.actor?.name || 'AIRE administrator'} · {formatGuamDateTime(entry.approval.occurred_at)}
            {entry.approval.note ? ` · ${entry.approval.note}` : ''}
          </p>
        )}
        {entry.overtime_approval?.occurred_at && (
          <p className="basis-full text-xs leading-5 text-neutral-500">
            Overtime {entry.state.overtime_status} by {entry.overtime_approval.actor?.name || 'AIRE administrator'} · {formatGuamDateTime(entry.overtime_approval.occurred_at)}
            {entry.overtime_approval.note ? ` · ${entry.overtime_approval.note}` : ''}
          </p>
        )}
      </div>
      <div className="flex flex-wrap gap-2 lg:justify-end">
        {(entry.state.missing_punch || !entry.capture.ordinary) && (
          <Button type="button" size="sm" variant="outline" disabled={!canCommand} onClick={() => onCorrect(entry)}>
            <FilePenLine className="mr-1 h-3.5 w-3.5" /> Correct
          </Button>
        )}
        {needsTimeReview && (
          <>
            <Button type="button" size="sm" variant="outline" disabled={!canCommand} onClick={() => onReview({ entry, decision: 'deny', kind: 'time' })}>
              <X className="mr-2 h-3.5 w-3.5" /> Deny time
            </Button>
            <Button type="button" size="sm" disabled={!canCommand} onClick={() => onReview({ entry, decision: 'approve', kind: 'time' })}>
              <Check className="mr-2 h-3.5 w-3.5" /> Approve time
            </Button>
          </>
        )}
        {needsOvertimeReview && (
          <>
            <Button type="button" size="sm" variant="outline" disabled={!canCommand} onClick={() => onReview({ entry, decision: 'deny', kind: 'overtime' })}>
              <X className="mr-2 h-3.5 w-3.5" /> Deny overtime
            </Button>
            <Button type="button" size="sm" disabled={!canCommand} onClick={() => onReview({ entry, decision: 'approve', kind: 'overtime' })}>
              <Check className="mr-2 h-3.5 w-3.5" /> Approve overtime
            </Button>
          </>
        )}
      </div>
    </div>
  );
}

export function AirePayrollCockpit({
  payPeriodId,
  payPeriodStatus = 'draft',
  payrollHours = {},
  payrollItems = [],
  employees = [],
  aireRecordLinked = false,
  calendar,
  onRefresh,
}: Props) {
  const { activeCompanyId } = useCompany();
  const [overview, setOverview] = useState<AirePayrollCockpitOverview | null>(null);
  const [timeEntries, setTimeEntries] = useState<AirePayrollTimeEntriesResponse | null>(null);
  const [exceptions, setExceptions] = useState<AirePayrollExceptionsResponse | null>(null);
  const [settlementCases, setSettlementCases] = useState<AirePayrollSettlementCasesResponse | null>(null);
  const [view, setView] = useState<View>('timecards');
  const [detailsOpen, setDetailsOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [refreshError, setRefreshError] = useState<string | null>(null);
  const [commandError, setCommandError] = useState<string | null>(null);
  const [review, setReview] = useState<Review | null>(null);
  const [correction, setCorrection] = useState<Correction | null>(null);
  const [settlementRoute, setSettlementRoute] = useState<SettlementRoute | null>(null);
  const [commandSuccess, setCommandSuccess] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  const [showFinalize, setShowFinalize] = useState(false);
  const [finalizeCommand, setFinalizeCommand] = useState<FinalizeCommand | null>(null);
  const [finalizeReason, setFinalizeReason] = useState('Reviewed AIRE readiness and confirmed eligible time for cutoff');
  const [timePage, setTimePage] = useState(1);
  const [exceptionPage, setExceptionPage] = useState(1);
  const [leavePage, setLeavePage] = useState(1);
  const [employeePage, setEmployeePage] = useState(1);
  const [settlementPage, setSettlementPage] = useState(1);
  const [mappingTarget, setMappingTarget] = useState<AirePayrollCockpitEmployee | null>(null);
  const [mappingEmployeeId, setMappingEmployeeId] = useState('');
  const [mappingError, setMappingError] = useState<string | null>(null);
  const [mappingBusy, setMappingBusy] = useState(false);
  const requestGeneration = useRef(0);

  useEffect(() => {
    requestGeneration.current += 1;
    setOverview(null);
    setTimeEntries(null);
    setExceptions(null);
    setSettlementCases(null);
    setReview(null);
    setCorrection(null);
    setSettlementRoute(null);
    setShowFinalize(false);
    setCommandError(null);
    setCommandSuccess(null);
    setReason('');
    setTimePage(1);
    setExceptionPage(1);
    setLeavePage(1);
    setEmployeePage(1);
    setSettlementPage(1);
  }, [payPeriodId]);

  const load = useCallback(async () => {
    const generation = ++requestGeneration.current;
    const published = calendar.publication?.delivery_status === 'delivered' || Boolean(calendar.finalized_batch);
    if (!calendar.external_pay_period_id || !published) return;
    setLoading(true);
    setRefreshError(null);
    try {
      const [overviewResult, entriesResult, exceptionsResult, settlementResult] = await Promise.all([
        payPeriodsApi.airePayrollCockpit(payPeriodId, { employee_page: employeePage }),
        payPeriodsApi.airePayrollTimeEntries(payPeriodId, { page: timePage }),
        payPeriodsApi.airePayrollExceptions(payPeriodId, { page: exceptionPage, leave_page: leavePage }),
        payPeriodsApi.airePayrollSettlementCases(payPeriodId, { page: settlementPage }),
      ]);
      if (generation !== requestGeneration.current) return;
      setOverview(overviewResult.aire_payroll_cockpit);
      setTimeEntries(entriesResult);
      setExceptions(exceptionsResult);
      setSettlementCases(settlementResult);
    } catch (caught) {
      if (generation !== requestGeneration.current) return;
      setRefreshError(caught instanceof Error ? caught.message : 'Could not refresh AIRE payroll details');
    } finally {
      if (generation === requestGeneration.current) setLoading(false);
    }
  }, [calendar.external_pay_period_id, calendar.finalized_batch, calendar.publication?.delivery_status, employeePage, exceptionPage, leavePage, payPeriodId, settlementPage, timePage]);

  const saveEmployeeMapping = async () => {
    if (!mappingTarget || !mappingEmployeeId) return;
    setMappingBusy(true);
    setMappingError(null);
    try {
      await payPeriodsApi.mapAireEmployee(payPeriodId, {
        source_user_id: mappingTarget.id,
        employee_id: Number(mappingEmployeeId),
      });
      setMappingTarget(null);
      setMappingEmployeeId('');
      await load();
    } catch (caught) {
      setMappingError(caught instanceof Error ? caught.message : 'Could not link this AIRE person');
    } finally {
      setMappingBusy(false);
    }
  };

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
      setReview({ ...review, entry: latest, commandId: commandId() });
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
  const finalized = calendar.finalized_batch?.verification_status === 'verified';
  const attention = overview ? [
    overview.readiness.pending_approvals > 0 ? `${overview.readiness.pending_approvals} time approval${overview.readiness.pending_approvals === 1 ? '' : 's'}` : null,
    overview.readiness.pending_overtime > 0 ? `${overview.readiness.pending_overtime} overtime approval${overview.readiness.pending_overtime === 1 ? '' : 's'}` : null,
    overview.readiness.missing_punches > 0 ? `${overview.readiness.missing_punches} missing punch${overview.readiness.missing_punches === 1 ? '' : 'es'}` : null,
    unmappedCount > 0 ? `${unmappedCount} employee match${unmappedCount === 1 ? '' : 'es'}` : null,
  ].filter(Boolean) : [];
  const sourceError = refreshError || calendar.finalized_batch?.last_error
    || calendar.publication?.last_error || (!calendar.eligible ? calendar.eligibility_error : null);
  const summaryError = detailsOpen ? null : sourceError;

  const submitReview = async () => {
    if (!review || reason.trim().length < 3) return;
    setBusy(true);
    setCommandError(null);
    setCommandSuccess(null);
    try {
      const request = {
        command_id: review.commandId,
        expected_version: review.entry.version,
        decision: review.decision,
        reason: reason.trim(),
      } as const;
      if (review.kind === 'overtime') {
        await payPeriodsApi.reviewAireOvertime(payPeriodId, review.entry.id, request);
      } else {
        await payPeriodsApi.reviewAireTimeEntry(payPeriodId, review.entry.id, request);
      }
      const subject = review.kind === 'overtime' ? 'Overtime' : 'Time';
      setCommandSuccess(`${subject} ${review.decision === 'approve' ? 'approved' : 'denied'} in AIRE and saved in both audit histories.`);
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

  const submitCorrection = async () => {
    if (!correction || correction.reason.trim().length < 3 || !correction.workDate
      || !correction.startTime || !correction.endTime || !correction.timeCategoryId
      || correction.breaks.some((breakRow) => !breakRow.start_time || !breakRow.end_time)) return;
    setBusy(true);
    setCommandError(null);
    setCommandSuccess(null);
    try {
      const detailedBreaks = correction.breaks.length > 0 || !correction.preservesLegacyBreakMinutes
        ? { breaks: correction.breaks }
        : {};
      await payPeriodsApi.correctAireTimeEntry(payPeriodId, correction.entry.id, {
        command_id: correction.commandId,
        expected_version: correction.entry.version,
        reason: correction.reason.trim(),
        work_date: correction.workDate,
        start_time: correction.startTime,
        end_time: correction.endTime,
        time_category_id: correction.timeCategoryId,
        description: correction.description.trim(),
        ...detailedBreaks,
      });
      setCorrection(null);
      setCommandSuccess('Time corrected in AIRE. It now needs administrator approval before it can be paid.');
    } catch (caught) {
      if (caught instanceof ApiError && caught.status === 409) {
        setCorrection(null);
        setCommandError('That time entry changed in AIRE. The latest details have been reloaded; open the correction again before saving.');
      } else {
        setCommandError(caught instanceof Error ? caught.message : 'Could not correct the time entry');
      }
    } finally {
      await load();
      setBusy(false);
    }
  };

  const submitSettlementRoute = async () => {
    if (!settlementRoute || settlementRoute.reason.trim().length < 3
      || (settlementRoute.destinationKind === 'regular' && !settlementRoute.targetExternalPayPeriodId)) return;
    setBusy(true);
    setCommandError(null);
    setCommandSuccess(null);
    try {
      await payPeriodsApi.routeAireSettlementCase(payPeriodId, settlementRoute.settlementCase.id, {
        command_id: settlementRoute.commandId,
        expected_version: settlementRoute.settlementCase.version,
        reason: settlementRoute.reason.trim(),
        destination_kind: settlementRoute.destinationKind,
        ...(settlementRoute.destinationKind === 'regular'
          ? { target_external_pay_period_id: settlementRoute.targetExternalPayPeriodId }
          : {}),
      });
      setSettlementRoute(null);
      setCommandSuccess(settlementRoute.destinationKind === 'regular'
        ? 'Held time routed to the selected regular payroll in AIRE.'
        : 'Held time marked not payable in AIRE with your review reason.');
    } catch (caught) {
      if (caught instanceof ApiError && caught.status === 409) {
        setSettlementRoute(null);
        setCommandError('That held-time case changed in AIRE. The latest details have been reloaded; review it again.');
      } else {
        setCommandError(caught instanceof Error ? caught.message : 'Could not update the held-time destination');
      }
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
  const correctionCategories = correction?.entry.available_time_categories
    ?? (correction?.entry.category ? [correction.entry.category] : []);

  return (
    <div className="space-y-4">
      <Card className="overflow-hidden border-neutral-200">
        <CardContent className="p-0">
          <div className="flex flex-col gap-4 px-5 py-5 sm:flex-row sm:items-center sm:justify-between sm:px-6">
            <div>
              <div className="flex flex-wrap items-center gap-2">
                <h3 className="font-display text-lg font-bold text-neutral-950">AIRE time</h3>
                <Badge variant={finalized ? 'success' : calendar.cutoff_state === 'batch_rejected' || calendar.cutoff_state === 'publication_failed' ? 'danger' : 'info'}>
                  {finalized ? 'Final batch verified' : calendar.cutoff_state.replaceAll('_', ' ')}
                </Badge>
              </div>
              <p className="mt-1 text-sm text-neutral-600">
                {finalized ? 'Review the final cutoff against this payroll and its payment history.' : 'Review live hours before calculating payroll.'}
              </p>
            </div>
            <Button type="button" size="sm" variant="outline" aria-expanded={detailsOpen} aria-controls="aire-payroll-details" onClick={() => setDetailsOpen((open) => !open)}>
              {detailsOpen ? 'Hide AIRE details' : 'Review AIRE details'}
              <ChevronDown className={`ml-2 h-4 w-4 transition-transform ${detailsOpen ? 'rotate-180' : ''}`} aria-hidden="true" />
            </Button>
          </div>
          <div className="grid border-t border-neutral-200 bg-neutral-50/70 sm:grid-cols-3 sm:divide-x sm:divide-neutral-200" aria-live="polite">
            <div className="px-5 py-4 sm:px-6">
              <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">AIRE cutoff</p>
              <p className="mt-1 text-sm font-semibold text-neutral-950">{calendar.cutoff_at ? formatGuamDateTime(calendar.cutoff_at) : 'Not scheduled'}</p>
            </div>
            <div className="border-t border-neutral-200 px-5 py-4 sm:border-t-0 sm:px-6">
              <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">{finalized ? 'Included at cutoff' : payPeriodStatus === 'committed' ? 'Eligible AIRE time' : 'Ready for payroll'}</p>
              <p className="mt-1 font-display text-xl font-bold tabular-nums text-neutral-950">{overview ? `${Number(overview.readiness.eligible_hours).toFixed(2)} hrs` : '—'}</p>
            </div>
            <div className="border-t border-neutral-200 px-5 py-4 sm:border-t-0 sm:px-6">
              <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Held or unresolved</p>
              <p className="mt-1 font-display text-xl font-bold tabular-nums text-neutral-950">{overview ? `${heldHours.toFixed(2)} hrs` : '—'}</p>
            </div>
          </div>
          {(attention.length > 0 || summaryError) && (
            <div className="border-t border-warning-200 bg-warning-50 px-5 py-3 text-sm text-warning-950 sm:px-6" role={summaryError ? 'alert' : 'status'}>
              {summaryError || `Needs review: ${attention.join(' · ')}. Open AIRE details before finalizing or paying these hours.`}
            </div>
          )}
        </CardContent>
      </Card>

      <div id="aire-payroll-details" hidden={!detailsOpen} className="space-y-4">
      <AirePayrollCalendarCard payPeriodId={payPeriodId} calendar={calendar} onRefresh={async () => {
        await onRefresh();
        await load();
      }} />

      <AireManualHoursReview
        payPeriodId={payPeriodId}
        payPeriodStatus={payPeriodStatus}
        payrollHours={payrollHours}
        payrollItems={payrollItems}
        employees={employees}
        aireRecordLinked={aireRecordLinked}
      />

      {calendar.finalized_batch?.verification_status === 'verified' && (
        <AirePostLockComparison payPeriodId={payPeriodId} />
      )}

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
                    Review AIRE timecards and resolve exceptions here. The final AIRE lock occurs seven days after the scheduled pay date; use the live hours check before paying and reconcile the locked record afterward.
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

            {commandSuccess && !visibleError && (
              <div role="status" className="flex items-start gap-3 border-b border-success-200 bg-success-50 px-5 py-4 text-sm text-success-800 sm:px-6">
                <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" />
                <p>{commandSuccess}</p>
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
                  <Metric label="Approvals needed" value={overview.readiness.pending_approvals + overview.readiness.pending_overtime} detail={`${overview.readiness.missing_punches} missing punch${overview.readiness.missing_punches === 1 ? '' : 'es'}`} tone={overview.readiness.pending_approvals + overview.readiness.pending_overtime > 0 ? 'warning' : 'neutral'} />
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
                    <div className="min-w-0 flex-1">
                      <p className="font-semibold">Live details are available, but actions need your AIRE access</p>
                      <p className="mt-1 leading-5">Connect your administrator account once so AIRE can verify and record your approvals. The connection stays active until you disconnect it or your AIRE access is disabled.</p>
                      <Link
                        to={`/time-tracking-sources?source_id=${calendar.source_id}`}
                        className="mt-2 inline-flex min-h-9 items-center gap-2 rounded-full border border-warning-300 bg-white px-4 py-2 text-xs font-semibold text-warning-950 transition-colors hover:bg-warning-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-warning-400 focus-visible:ring-offset-2"
                      >
                        Connect my AIRE account
                        <ArrowRight className="h-3.5 w-3.5" aria-hidden="true" />
                      </Link>
                    </div>
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
                  <div className="flex gap-1 overflow-x-auto" aria-label="AIRE payroll details">
                    {([
                      ['timecards', 'Timecards', timeEntries?.pagination.total_count || 0],
                      ['exceptions', 'Needs attention', (exceptions?.time_exception_pagination.total_count || 0) + (exceptions?.leave_exception_pagination.total_count || 0)],
                      ['held_time', 'Held time', settlementCases?.pagination.total_count || 0],
                      ['team', 'Team', overview.employee_pagination.total_count],
                      ['history', 'Payment history', overview.processing_history.length],
                    ] as Array<[View, string, number]>).map(([key, label, count]) => (
                      <button
                        key={key}
                        type="button"
                        aria-pressed={view === key}
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
                      <TimecardRow
                        key={entry.id}
                        entry={entry}
                        canCommand={canCommand}
                        onReview={(next) => { setReview({ ...next, commandId: commandId() }); setReason(''); setCommandError(null); setCommandSuccess(null); }}
                        onCorrect={(target) => { setCorrection(startCorrection(target)); setCommandError(null); setCommandSuccess(null); }}
                      />
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

                {view === 'held_time' && (
                  <div>
                    <div className="border-b border-neutral-200 bg-warning-50/60 px-4 py-4 sm:px-6">
                      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                        <div>
                          <h4 className="font-semibold text-neutral-950">Hours excluded at cutoff</h4>
                          <p className="mt-1 text-sm leading-5 text-neutral-600">Every case stays here until it is placed in a later payroll, explicitly marked not payable, or fully settled.</p>
                        </div>
                        {settlementCases && (
                          <div className="flex flex-wrap gap-2 text-xs">
                            <Badge variant={settlementCases.summary.attention_due ? 'warning' : 'default'}>{settlementCases.summary.attention_due} due</Badge>
                            <Badge variant="default">{settlementCases.summary.scheduled} scheduled</Badge>
                            <Badge variant="success">{settlementCases.summary.settled} settled</Badge>
                          </div>
                        )}
                      </div>
                    </div>
                    {settlementCases?.settlement_cases.length ? (
                      <div className="divide-y divide-neutral-100">
                        {settlementCases.settlement_cases.map((settlementCase) => {
                          const matchingEntry = [
                            ...(timeEntries?.time_entries || []),
                            ...(exceptions?.time_exceptions || []),
                          ].find((entry) => entry.id === settlementCase.source_time_entry_id);
                          const routeOption = overview.routing_options.find((option) => (
                            option.external_pay_period_id === settlementCase.routing.target_external_pay_period_id
                          ));
                          const canManage = ['open', 'scheduled'].includes(settlementCase.status);
                          const statusLabel = {
                            open: 'Needs destination',
                            scheduled: 'Scheduled for payroll',
                            in_payroll: 'In payroll',
                            settled: 'Settled',
                            not_payable: 'Not payable',
                            superseded: 'Replaced by later change',
                          }[settlementCase.status];
                          return (
                            <article key={settlementCase.id} className="px-4 py-5 sm:px-6">
                              <div className="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                                <div className="min-w-0 flex-1">
                                  <div className="flex flex-wrap items-center gap-2">
                                    <h5 className="font-semibold text-neutral-950">{settlementCase.employee.name}</h5>
                                    <MappingBadge status={settlementCase.employee.cornerstone.status} />
                                    <Badge variant={lifecycleTone(settlementCase.status)}>{statusLabel}</Badge>
                                  </div>
                                  <p className="mt-2 text-sm text-neutral-700">
                                    <span className="font-semibold text-neutral-950">{Number(settlementCase.time.held_total_hours).toFixed(2)} held hours</span>
                                    {' · '}worked {formatDate(settlementCase.time.original_work_date)}
                                    {settlementCase.time.category?.name ? ` · ${settlementCase.time.category.name}` : ''}
                                  </p>
                                  <p className="mt-1 text-xs leading-5 text-neutral-500">
                                    Excluded because {settlementCase.origin.reason.replaceAll('_', ' ')} · AIRE batch {settlementCase.origin.payroll_batch_id}
                                  </p>
                                  {settlementCase.time.current_total_hours != null
                                    && Math.abs(Number(settlementCase.time.current_total_hours) - Number(settlementCase.time.held_total_hours)) >= 0.005 && (
                                    <p className="mt-2 rounded-lg border border-primary-100 bg-primary-50/70 px-3 py-2 text-xs font-medium leading-5 text-primary-900">
                                      Current corrected time is {Number(settlementCase.time.current_total_hours).toFixed(2)} hours. The held amount above remains the original cutoff record.
                                    </p>
                                  )}
                                  <div className="mt-3 grid gap-2 text-sm sm:grid-cols-2">
                                    <div className="rounded-lg border border-neutral-200 bg-neutral-50 p-3">
                                      <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Destination</p>
                                      <p className="mt-1 font-medium text-neutral-900">
                                        {settlementCase.routing.destination_kind === 'regular'
                                          ? routeOption ? `${formatDateRange(routeOption.start_date, routeOption.end_date)} · pay ${formatDate(routeOption.pay_date)}` : 'Future regular payroll'
                                          : settlementCase.routing.destination_kind === 'supplemental' ? 'Supplemental payroll' : settlementCase.routing.destination_kind === 'not_payable' ? 'Not payable' : 'Not selected yet'}
                                      </p>
                                      <p className="mt-1 text-xs text-neutral-500">Action due {formatDate(settlementCase.routing.action_due_on)}</p>
                                    </div>
                                    <div className="rounded-lg border border-neutral-200 bg-neutral-50 p-3">
                                      <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Latest payment fact</p>
                                      <p className="mt-1 font-medium text-neutral-900">{settlementCase.processing?.status.replaceAll('_', ' ') || 'Not imported into payroll'}</p>
                                      <p className="mt-1 text-xs text-neutral-500">
                                        {settlementCase.processing?.payment_reference
                                          ? `Reference ${settlementCase.processing.payment_reference}`
                                          : settlementCase.included_payroll_batch_id ? `AIRE batch ${settlementCase.included_payroll_batch_id}` : 'No payment has been recorded'}
                                      </p>
                                    </div>
                                  </div>
                                  {settlementCase.routing.note && <p className="mt-3 text-xs italic text-neutral-500">Last review note: {settlementCase.routing.note}</p>}
                                </div>
                                {canManage && (
                                  <div className="flex shrink-0 flex-wrap gap-2 xl:justify-end">
                                    {matchingEntry && (
                                      <Button type="button" size="sm" variant="outline" disabled={!canCommand || busy} onClick={() => { setCorrection(startCorrection(matchingEntry)); setCommandError(null); setCommandSuccess(null); }}>
                                        <FilePenLine className="mr-1 h-3.5 w-3.5" /> Correct time
                                      </Button>
                                    )}
                                    <Button type="button" size="sm" variant="outline" disabled={!canCommand || busy} onClick={() => {
                                      setSettlementRoute({
                                        settlementCase,
                                        commandId: commandId(),
                                        destinationKind: settlementCase.routing.destination_kind === 'not_payable' ? 'not_payable' : 'regular',
                                        targetExternalPayPeriodId: settlementCase.routing.target_external_pay_period_id
                                          || overview.routing_options[0]?.external_pay_period_id || '',
                                        reason: '',
                                      });
                                      setCommandError(null);
                                      setCommandSuccess(null);
                                    }}>
                                      <Split className="mr-1 h-3.5 w-3.5" /> {settlementCase.routing.destination_kind === 'unassigned' ? 'Choose destination' : 'Change destination'}
                                    </Button>
                                  </div>
                                )}
                              </div>
                            </article>
                          );
                        })}
                      </div>
                    ) : (
                      <div className="px-6 py-10 text-center">
                        <CheckCircle2 className="mx-auto h-6 w-6 text-success-600" />
                        <p className="mt-3 font-semibold text-neutral-900">No held-time cases for this payroll</p>
                        <p className="mt-1 text-sm text-neutral-500">Anything excluded at cutoff will appear here automatically.</p>
                      </div>
                    )}
                    <PageControls pagination={settlementCases?.pagination} onPage={setSettlementPage} />
                  </div>
                )}

                {view === 'team' && (
                  <div className="divide-y divide-neutral-100">
                    <div className="bg-primary-50/60 px-4 py-4 text-sm leading-6 text-primary-900 sm:px-6">
                      AIRE people appear here automatically. Match someone to an existing payroll profile, or set up a new profile with their pay and tax details. No one becomes payable from an AIRE name alone.
                    </div>
                    {overview.employees.length === 0 && (
                      <p className="px-6 py-10 text-center text-sm text-neutral-500">AIRE has no employees on this page.</p>
                    )}
                    {overview.employees.map((employee) => (
                      <div key={employee.id} className="flex flex-col gap-3 px-4 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-6">
                        <div className="flex items-center gap-3"><div className="flex h-9 w-9 items-center justify-center rounded-full bg-neutral-100 text-neutral-600"><Users className="h-4 w-4" /></div><div><p className="font-semibold text-neutral-950">{employee.full_name}</p><p className="text-xs text-neutral-500">{employee.email || 'No email'} · {employee.time_tracking_enabled ? 'Time tracking on' : 'Time tracking off'}</p></div></div>
                        <div className="flex flex-wrap items-center gap-2">
                          <MappingBadge status={employee.cornerstone.status} />
                          {employee.cornerstone.employee_name && <span className="text-xs text-neutral-500">{employee.cornerstone.employee_name}</span>}
                          {activeCompanyId && employee.cornerstone.employee_id && (
                            <Link className="text-xs font-semibold text-primary-700 hover:underline" to={employeePath(activeCompanyId, employee.cornerstone.employee_id, 'overview')}>
                              Review payroll profile
                            </Link>
                          )}
                          {employee.cornerstone.status === 'unmapped' && (
                            <>
                              <Button type="button" size="sm" variant="outline" onClick={() => { setMappingTarget(employee); setMappingEmployeeId(''); setMappingError(null); }}>Match existing</Button>
                              {activeCompanyId && employee.payroll_integration_id && (
                                <Link className="rounded-lg bg-primary-700 px-3 py-2 text-xs font-semibold text-white hover:bg-primary-800" to={`${newEmployeePath(activeCompanyId, { returnTo: payRunPath(activeCompanyId, payPeriodId, 'work') })}&aire_pay_period_id=${payPeriodId}&aire_staff_id=${encodeURIComponent(employee.id)}`}>
                                  Set up new payroll profile
                                </Link>
                              )}
                            </>
                          )}
                          {employee.cornerstone.status === 'needs_verification' && employee.cornerstone.employee_id && (
                            <Button type="button" size="sm" variant="outline" onClick={() => { setMappingTarget(employee); setMappingEmployeeId(String(employee.cornerstone.employee_id)); setMappingError(null); }}>
                              Verify permanent link
                            </Button>
                          )}
                        </div>
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
      </div>

      <Dialog
        open={Boolean(review)}
        onOpenChange={(open) => { if (!open && !busy) setReview(null); }}
        dismissOnEscape={!busy}
      >
        {review && (
          <DialogContent className="relative max-w-lg rounded-2xl p-5 sm:p-6">
            <DialogHeader className="pr-10 text-left">
              <DialogTitle className="font-display font-bold text-neutral-950">
                {review.decision === 'approve' ? 'Approve' : 'Deny'} {review.kind === 'overtime' ? 'overtime' : 'manual time'}
              </DialogTitle>
              <DialogDescription className="leading-6 text-neutral-600">
                {review.entry.employee.name} · {formatDate(review.entry.work_date)} · {Number(review.entry.hours).toFixed(2)} hours
                {review.kind === 'overtime' && ' · Cornerstone will still calculate the legally required regular and overtime split.'}
              </DialogDescription>
            </DialogHeader>
            {commandError && <div role="alert" className="mt-4 rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-800">{commandError}</div>}
            <label className="mt-5 block text-sm font-semibold text-neutral-800">Reason<span className="font-normal text-neutral-500"> (saved in both audit histories)</span><textarea autoFocus value={reason} onChange={(event) => setReason(event.target.value)} rows={4} placeholder="What did you verify?" className="mt-2 w-full resize-none rounded-xl border border-neutral-300 px-3 py-2 text-sm font-normal" /></label>
            <button type="button" onClick={() => setReview(null)} disabled={busy} aria-label="Close review" className="absolute right-5 top-5 rounded-full p-2 text-neutral-500 hover:bg-neutral-100 disabled:opacity-50 sm:right-6 sm:top-6"><X className="h-5 w-5" /></button>
            <DialogFooter className="mt-4 !flex-row gap-2 pt-0"><Button type="button" variant="outline" onClick={() => setReview(null)} disabled={busy}>Cancel</Button><Button type="button" variant={review.decision === 'deny' ? 'danger' : 'primary'} onClick={() => void submitReview()} disabled={busy || reason.trim().length < 3}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}{review.decision === 'approve' ? 'Approve' : 'Deny'} {review.kind === 'overtime' ? 'overtime' : 'time'}</Button></DialogFooter>
          </DialogContent>
        )}
      </Dialog>

      <Dialog
        open={Boolean(correction)}
        onOpenChange={(open) => { if (!open && !busy) setCorrection(null); }}
        dismissOnEscape={!busy}
      >
        {correction && (
          <DialogContent className="relative max-h-[90vh] max-w-2xl overflow-y-auto rounded-2xl p-5 sm:p-6">
            <DialogHeader className="pr-10 text-left">
              <DialogTitle className="font-display font-bold text-neutral-950">Correct time in AIRE</DialogTitle>
              <DialogDescription className="leading-6 text-neutral-600">
                {correction.entry.employee.name} · Changes are written to AIRE and will require a separate administrator approval.
              </DialogDescription>
            </DialogHeader>
            {commandError && <div role="alert" className="mt-4 rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-800">{commandError}</div>}
            <div className="mt-5 grid gap-4 sm:grid-cols-2">
              <label className="text-sm font-semibold text-neutral-800">Work date<input aria-label="Work date" type="date" value={correction.workDate} onChange={(event) => setCorrection({ ...correction, workDate: event.target.value })} className="mt-2 w-full rounded-xl border border-neutral-300 px-3 py-2 font-normal" /></label>
              <label className="text-sm font-semibold text-neutral-800">Time category<select aria-label="Time category" value={correction.timeCategoryId} onChange={(event) => setCorrection({ ...correction, timeCategoryId: event.target.value })} className="mt-2 w-full rounded-xl border border-neutral-300 bg-white px-3 py-2 font-normal"><option value="">Choose category</option>{correctionCategories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}</select></label>
              <label className="text-sm font-semibold text-neutral-800">Start time<input aria-label="Start time" type="time" value={correction.startTime} onChange={(event) => setCorrection({ ...correction, startTime: event.target.value })} className="mt-2 w-full rounded-xl border border-neutral-300 px-3 py-2 font-normal" /></label>
              <label className="text-sm font-semibold text-neutral-800">End time<input aria-label="End time" type="time" value={correction.endTime} onChange={(event) => setCorrection({ ...correction, endTime: event.target.value })} className="mt-2 w-full rounded-xl border border-neutral-300 px-3 py-2 font-normal" /></label>
            </div>
            <label className="mt-4 block text-sm font-semibold text-neutral-800">Description<input aria-label="Description" type="text" value={correction.description} onChange={(event) => setCorrection({ ...correction, description: event.target.value })} placeholder="What work was performed?" className="mt-2 w-full rounded-xl border border-neutral-300 px-3 py-2 font-normal" /></label>
            <div className="mt-5 rounded-xl border border-neutral-200 p-4">
              <div className="flex items-center justify-between gap-3"><div><p className="text-sm font-semibold text-neutral-900">Breaks</p><p className="mt-1 text-xs text-neutral-500">Include the complete corrected break list.</p></div><Button type="button" size="sm" variant="outline" onClick={() => setCorrection({ ...correction, breaks: [...correction.breaks, { start_time: '', end_time: '' }] })}>Add break</Button></div>
              {correction.breaks.length === 0 && correction.preservesLegacyBreakMinutes ? (
                <div className="mt-3 rounded-lg border border-warning-200 bg-warning-50 p-3 text-sm leading-5 text-warning-900">
                  AIRE has {correction.entry.break_minutes} total break minutes but no exact break times. That total will stay unchanged unless you add detailed break times.
                </div>
              ) : correction.breaks.length === 0 ? <p className="mt-3 text-sm text-neutral-500">No breaks recorded.</p> : (
                <div className="mt-3 space-y-3">
                  {correction.breaks.map((breakRow, index) => (
                    <div key={index} className="grid gap-2 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
                      <label className="text-xs font-semibold text-neutral-600">Break starts<input aria-label={`Break ${index + 1} start`} type="time" value={breakRow.start_time} onChange={(event) => setCorrection({ ...correction, breaks: correction.breaks.map((row, rowIndex) => rowIndex === index ? { ...row, start_time: event.target.value } : row) })} className="mt-1 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm font-normal" /></label>
                      <label className="text-xs font-semibold text-neutral-600">Break ends<input aria-label={`Break ${index + 1} end`} type="time" value={breakRow.end_time} onChange={(event) => setCorrection({ ...correction, breaks: correction.breaks.map((row, rowIndex) => rowIndex === index ? { ...row, end_time: event.target.value } : row) })} className="mt-1 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm font-normal" /></label>
                      <Button type="button" size="sm" variant="ghost" aria-label={`Remove break ${index + 1}`} onClick={() => setCorrection({ ...correction, breaks: correction.breaks.filter((_, rowIndex) => rowIndex !== index) })}><X className="h-4 w-4" /></Button>
                    </div>
                  ))}
                </div>
              )}
            </div>
            <label className="mt-5 block text-sm font-semibold text-neutral-800">Correction reason<span className="font-normal text-neutral-500"> (saved in both audit histories)</span><textarea aria-label="Correction reason" value={correction.reason} onChange={(event) => setCorrection({ ...correction, reason: event.target.value })} rows={3} placeholder="What did you verify and why was this changed?" className="mt-2 w-full resize-none rounded-xl border border-neutral-300 px-3 py-2 text-sm font-normal" /></label>
            <button type="button" onClick={() => setCorrection(null)} disabled={busy} aria-label="Close correction" className="absolute right-5 top-5 rounded-full p-2 text-neutral-500 hover:bg-neutral-100 disabled:opacity-50 sm:right-6 sm:top-6"><X className="h-5 w-5" /></button>
            <DialogFooter className="mt-5 !flex-row gap-2 pt-0"><Button type="button" variant="outline" onClick={() => setCorrection(null)} disabled={busy}>Cancel</Button><Button type="button" onClick={() => void submitCorrection()} disabled={busy || correction.reason.trim().length < 3 || !correction.workDate || !correction.startTime || !correction.endTime || !correction.timeCategoryId || correction.breaks.some((breakRow) => !breakRow.start_time || !breakRow.end_time)}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Save correction</Button></DialogFooter>
          </DialogContent>
        )}
      </Dialog>

      <Dialog
        open={Boolean(settlementRoute)}
        onOpenChange={(open) => { if (!open && !busy) setSettlementRoute(null); }}
        dismissOnEscape={!busy}
      >
        {settlementRoute && overview && (
          <DialogContent className="relative max-w-lg rounded-2xl p-5 sm:p-6">
            <DialogHeader className="pr-10 text-left">
              <DialogTitle className="font-display font-bold text-neutral-950">Choose where these hours go</DialogTitle>
              <DialogDescription className="leading-6 text-neutral-600">
                {settlementRoute.settlementCase.employee.name} · {
                  settlementRoute.settlementCase.time.current_total_hours != null
                    && Math.abs(Number(settlementRoute.settlementCase.time.current_total_hours) - Number(settlementRoute.settlementCase.time.held_total_hours)) >= 0.005
                    ? `${Number(settlementRoute.settlementCase.time.current_total_hours).toFixed(2)} current corrected hours (originally held ${Number(settlementRoute.settlementCase.time.held_total_hours).toFixed(2)})`
                    : `${Number(settlementRoute.settlementCase.time.held_total_hours).toFixed(2)} held hours`
                } · worked {formatDate(settlementRoute.settlementCase.time.original_work_date)}
              </DialogDescription>
            </DialogHeader>
            {commandError && <div role="alert" className="mt-4 rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-800">{commandError}</div>}
            <div className="mt-5 grid gap-3">
              <label className={`cursor-pointer rounded-xl border p-4 ${settlementRoute.destinationKind === 'regular' ? 'border-primary-500 bg-primary-50/60' : 'border-neutral-200'}`}><span className="flex items-start gap-3"><input type="radio" name="settlement-destination" value="regular" checked={settlementRoute.destinationKind === 'regular'} onChange={() => setSettlementRoute({ ...settlementRoute, destinationKind: 'regular', targetExternalPayPeriodId: settlementRoute.targetExternalPayPeriodId || overview.routing_options[0]?.external_pay_period_id || '' })} className="mt-1" /><span><span className="block font-semibold text-neutral-950">Pay in a future regular payroll</span><span className="mt-1 block text-sm leading-5 text-neutral-600">This schedules the unpaid hours for review in that run. Confirm the hours and include them before paying; AIRE’s later cutoff records what remains.</span></span></span></label>
              <label className={`cursor-pointer rounded-xl border p-4 ${settlementRoute.destinationKind === 'not_payable' ? 'border-danger-300 bg-danger-50' : 'border-neutral-200'}`}><span className="flex items-start gap-3"><input type="radio" name="settlement-destination" value="not_payable" checked={settlementRoute.destinationKind === 'not_payable'} onChange={() => setSettlementRoute({ ...settlementRoute, destinationKind: 'not_payable', targetExternalPayPeriodId: '' })} className="mt-1" /><span><span className="block font-semibold text-neutral-950">Mark not payable</span><span className="mt-1 block text-sm leading-5 text-neutral-600">Use only after confirming these hours should never be paid. The decision and reason remain in AIRE’s history.</span></span></span></label>
            </div>
            {settlementRoute.destinationKind === 'regular' && (
              <label className="mt-5 block text-sm font-semibold text-neutral-800">Regular payroll<select aria-label="Regular payroll" value={settlementRoute.targetExternalPayPeriodId} onChange={(event) => setSettlementRoute({ ...settlementRoute, targetExternalPayPeriodId: event.target.value })} className="mt-2 w-full rounded-xl border border-neutral-300 bg-white px-3 py-2 font-normal"><option value="">Choose a published future payroll</option>{overview.routing_options.map((option) => <option key={option.external_pay_period_id} value={option.external_pay_period_id}>{formatDateRange(option.start_date, option.end_date)} · pay {formatDate(option.pay_date)}</option>)}</select>{overview.routing_options.length === 0 && <span className="mt-2 block text-xs font-normal leading-5 text-warning-800">Publish the next regular pay period to AIRE before routing these hours.</span>}</label>
            )}
            <label className="mt-5 block text-sm font-semibold text-neutral-800">Review reason<span className="font-normal text-neutral-500"> (saved in both audit histories)</span><textarea aria-label="Routing reason" value={settlementRoute.reason} onChange={(event) => setSettlementRoute({ ...settlementRoute, reason: event.target.value })} rows={3} placeholder={settlementRoute.destinationKind === 'regular' ? 'Why is this the correct payroll?' : 'Why should these hours never be paid?'} className="mt-2 w-full resize-none rounded-xl border border-neutral-300 px-3 py-2 text-sm font-normal" /></label>
            <button type="button" onClick={() => setSettlementRoute(null)} disabled={busy} aria-label="Close destination" className="absolute right-5 top-5 rounded-full p-2 text-neutral-500 hover:bg-neutral-100 disabled:opacity-50 sm:right-6 sm:top-6"><X className="h-5 w-5" /></button>
            <DialogFooter className="mt-5 !flex-row gap-2 pt-0"><Button type="button" variant="outline" onClick={() => setSettlementRoute(null)} disabled={busy}>Cancel</Button><Button type="button" variant={settlementRoute.destinationKind === 'not_payable' ? 'danger' : 'primary'} onClick={() => void submitSettlementRoute()} disabled={busy || settlementRoute.reason.trim().length < 3 || (settlementRoute.destinationKind === 'regular' && !settlementRoute.targetExternalPayPeriodId)}>{busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}{settlementRoute.destinationKind === 'regular' ? 'Route to payroll' : 'Mark not payable'}</Button></DialogFooter>
          </DialogContent>
        )}
      </Dialog>

      <Dialog open={Boolean(mappingTarget)} onOpenChange={(open) => { if (!open && !mappingBusy) setMappingTarget(null); }} dismissOnEscape={!mappingBusy}>
        {mappingTarget && (
          <DialogContent className="max-w-lg rounded-2xl p-5 sm:p-6">
            <DialogHeader className="text-left">
              <DialogTitle>{mappingTarget.cornerstone.status === 'needs_verification' ? 'Verify' : 'Match'} {mappingTarget.full_name} to payroll</DialogTitle>
              <DialogDescription>{mappingTarget.cornerstone.status === 'needs_verification' ? 'This older link points to the payroll profile shown below. Confirm it is the same person; AIRE’s current permanent ID will be checked before the link is upgraded. This does not change their payroll status or pay settings.' : 'Choose an existing Cornerstone profile only after verifying it is the same person. This permanent match is used for future AIRE hours.'}</DialogDescription>
            </DialogHeader>
            {mappingTarget.cornerstone.status === 'needs_verification' ? (
              <div className="mt-4 rounded-xl border border-warning-200 bg-warning-50 p-3 text-sm text-neutral-800">
                Existing payroll profile: <span className="font-semibold">{mappingTarget.cornerstone.employee_name}</span>
                {mappingTarget.cornerstone.employee_active === false && <span className="ml-2 text-warning-800">Inactive — this action will not reactivate them.</span>}
              </div>
            ) : (
              <label className="mt-4 block text-sm font-semibold text-neutral-800">Existing payroll employee
                <select aria-label="Existing payroll employee" value={mappingEmployeeId} onChange={(event) => setMappingEmployeeId(event.target.value)} className="mt-2 w-full rounded-xl border border-neutral-300 bg-white px-3 py-2 font-normal">
                  <option value="">Choose a verified person</option>
                  {employees.filter((row) => row.status !== 'terminated').map((row) => <option key={row.id} value={row.id}>{row.first_name} {row.last_name}</option>)}
                </select>
              </label>
            )}
            {mappingError && <p role="alert" className="mt-3 text-sm text-danger-700">{mappingError}</p>}
            <DialogFooter className="mt-5 gap-2"><Button type="button" variant="outline" disabled={mappingBusy} onClick={() => setMappingTarget(null)}>Cancel</Button><Button type="button" disabled={!mappingEmployeeId || mappingBusy} onClick={() => void saveEmployeeMapping()}>{mappingBusy ? 'Matching…' : 'Confirm permanent match'}</Button></DialogFooter>
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
