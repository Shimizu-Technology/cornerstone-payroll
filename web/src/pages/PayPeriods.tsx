import { useEffect, useLayoutEffect, useState, useCallback, useMemo, useRef, type ReactElement } from 'react';
import { useLocation, useNavigate, useSearchParams } from 'react-router';
import { AlertCircle, LockKeyhole, Search } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card } from '@/components/ui/card';
import { MobileCardActions, MobileField, MobileRecordCard } from '@/components/ui/mobile-record';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { formatCurrency, formatDate, formatDateRange, formatGuamDateTimeShort, payPeriodStatusConfig } from '@/lib/utils';
import { useCompany } from '@/contexts/CompanyContext';
import { parsePayRunYear } from '@/lib/pay-run-filters';
import { correctionRunPath, currentAppPath, importedPayRunPath, payRunPath, type PayRunWorkspaceTab } from '@/lib/routes';
import { ApiError, companiesApi, payrollHistoryApi, payPeriodsApi, payScheduleSettingsApi, type PayrollGoLiveGateState, type PayrollHistoryRecord } from '@/services/api';
import type { PayPeriod, PayRunPurpose } from '@/types';

const RUN_PURPOSE_LABELS: Record<PayRunPurpose, string> = {
  regular: 'Regular payroll',
  off_cycle_tips: 'Off-cycle tips',
  bonus: 'Bonus',
  commission: 'Commission',
  correction: 'Correction',
  final: 'Final paycheck',
  adjustment: 'Adjustment',
};

interface PayPeriodMobileCardProps {
  period: PayrollHistoryRecord;
  actionInFlight: string | null;
  onView: () => void;
  onEdit: () => void;
  onDelete: () => void;
  onRun: () => void;
  onApprove: () => void;
  onCommit: () => void;
  onEnterHours: () => void;
}

function PayPeriodMobileCard({
  period,
  actionInFlight,
  onView,
  onEdit,
  onDelete,
  onRun,
  onApprove,
  onCommit,
  onEnterHours,
}: PayPeriodMobileCardProps): ReactElement {
  const statusLabel = period.status === 'locked' ? 'Locked' : payPeriodStatusConfig[period.status]?.label || period.status;

  return (
    <MobileRecordCard>
      <div className="flex items-start justify-between gap-3">
        <div>
          <p className="font-semibold text-neutral-950">{formatDateRange(period.start_date, period.end_date)}</p>
          <p className="mt-1 text-sm text-neutral-500">
            Pay date {new Date(period.pay_date).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' })}
          </p>
        </div>
        <Badge
          variant={
            period.correction_status === 'voided' ? 'danger' :
              period.status === 'committed' || period.status === 'locked' ? 'success' :
                period.status === 'approved' ? 'info' :
                  period.status === 'calculated' ? 'warning' : 'default'
          }
        >
          {period.correction_status === 'voided' ? 'Voided' : statusLabel}
        </Badge>
      </div>
      <div className="mt-3 flex flex-wrap gap-2">
        <Badge variant={period.run_purpose === 'regular' ? 'default' : 'warning'}>
          {RUN_PURPOSE_LABELS[period.run_purpose] || period.run_purpose}
        </Badge>
        {!period.includes_base_salary && <Badge variant="info">No base salary</Badge>}
        <Badge variant={period.record_type === 'imported' ? 'warning' : 'default'}>
          {period.record_type === 'imported' ? <><LockKeyhole className="mr-2 h-3 w-3" />QuickBooks import</> : 'Cornerstone'}
        </Badge>
        {period.parallel_run && <Badge variant="info"><LockKeyhole className="mr-2 h-3 w-3" />Parallel · cannot commit</Badge>}
      </div>
      <div className="mt-4 grid grid-cols-2 gap-3">
        <MobileField label="Employees" value={period.employee_count || 0} />
        <MobileField label="Gross" value={period.total_gross ? formatCurrency(period.total_gross) : '—'} />
        <MobileField label="Net" value={period.total_net ? formatCurrency(period.total_net) : '—'} />
        <MobileField
          label="Processed"
          value={period.processed_at ? formatGuamDateTimeShort(period.processed_at) : 'Not processed'}
        />
      </div>
      <MobileCardActions>
        <Button variant="outline" size="sm" onClick={onView}>View</Button>
        {period.capabilities.edit && <Button variant="ghost" size="sm" onClick={onEdit}>Edit</Button>}
        {period.capabilities.delete && <Button variant="ghost" size="sm" className="text-danger-700" onClick={onDelete} disabled={actionInFlight !== null}>Delete</Button>}
        {period.capabilities.enter_hours && <Button size="sm" onClick={onEnterHours}>Enter hours</Button>}
        {period.capabilities.run && period.status === 'calculated' && (
          <>
            <Button variant="outline" size="sm" onClick={onRun} disabled={actionInFlight !== null}>Recalculate</Button>
            {period.capabilities.approve && <Button size="sm" onClick={onApprove} disabled={actionInFlight !== null}>Approve</Button>}
          </>
        )}
        {period.capabilities.commit && <Button size="sm" onClick={onCommit} disabled={actionInFlight !== null}>Commit</Button>}
      </MobileCardActions>
    </MobileRecordCard>
  );
}

export function PayPeriods() {
  const location = useLocation();
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const { activeCompanyId } = useCompany();
  const returnTo = currentAppPath(location.pathname, location.search);
  const payRunDestination = (payRunId: number, tab: PayRunWorkspaceTab): string => (
    activeCompanyId
      ? payRunPath(activeCompanyId, payRunId, tab, { returnTo })
      : correctionRunPath(undefined, payRunId, { returnTo })
  );
  const [payPeriods, setPayPeriods] = useState<PayrollHistoryRecord[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [switchNotice, setSwitchNotice] = useState<string | null>(() => {
    const state = location.state as { companySwitchNotice?: string } | null;
    return state?.companySwitchNotice ?? null;
  });
  const statusParam = searchParams.get('status') || '';
  const statusFilter = ['draft', 'calculated', 'approved', 'committed', 'locked'].includes(statusParam) ? statusParam : undefined;
  const [statusCounts, setStatusCounts] = useState<Record<string, number>>({});
  const [payPeriodCompanyId, setPayPeriodCompanyId] = useState<number | null>(null);
  const searchTerm = searchParams.get('search') || '';
  const sourceParam = searchParams.get('source') || 'all';
  const sourceFilter = (['all', 'cornerstone', 'quickbooks'].includes(sourceParam) ? sourceParam : 'all') as 'all' | 'cornerstone' | 'quickbooks';
  const page = Math.max(1, Number.parseInt(searchParams.get('page') || '1', 10) || 1);
  const [totalPages, setTotalPages] = useState(0);
  const [years, setYears] = useState<number[]>([]);
  const [goLiveGate, setGoLiveGate] = useState<PayrollGoLiveGateState | null>(null);
  const requestedSort = searchParams.get('sort');
  const sortBy = (['pay_period', 'pay_date', 'processed', 'employees', 'gross', 'net', 'status', 'source'].includes(requestedSort || '') ? requestedSort : 'pay_period') as
    'pay_period' | 'pay_date' | 'processed' | 'employees' | 'gross' | 'net' | 'status' | 'source';
  const sortDirection = searchParams.get('direction') === 'asc' ? 'asc' : 'desc';
  const yearFilter = searchParams.get('year') || '';
  const payPeriodViewKey = `${statusFilter ?? ''}\u0000${yearFilter}\u0000${searchTerm}\u0000${sortBy}\u0000${sortDirection}\u0000${sourceFilter}\u0000${page}`;
  const updateViewParam = (key: string, value?: string, replace = false): void => {
    const next = new URLSearchParams(searchParams);
    if (value) next.set(key, value);
    else next.delete(key);
    if (key !== 'page') next.delete('page');
    setSearchParams(next, { replace });
  };
  const loadRequestIdRef = useRef(0);
  const activeCompanyIdRef = useRef(activeCompanyId);
  const payPeriodViewKeyRef = useRef(payPeriodViewKey);
  const payPeriodCompanyIdRef = useRef<number | null>(null);
  const defaultDatesRequestIdRef = useRef(0);
  const createDatesEditedRef = useRef(false);
  const checkSettingsRequestIdRef = useRef(0);
  const mutationGenerationRef = useRef(0);
  const loadPayPeriodsRef = useRef<(silent?: boolean) => Promise<void>>(async (): Promise<void> => undefined);

  useLayoutEffect((): void => {
    payPeriodViewKeyRef.current = payPeriodViewKey;
    loadRequestIdRef.current += 1;
    setLoading(true);
    setPayPeriods([]);
    setStatusCounts({});
    setTotalPages(0);
    setYears([]);
    setGoLiveGate(null);
    setPayPeriodCompanyId(null);
  }, [payPeriodViewKey]);

  useLayoutEffect((): void => {
    activeCompanyIdRef.current = activeCompanyId;
    defaultDatesRequestIdRef.current += 1;
    checkSettingsRequestIdRef.current += 1;
    mutationGenerationRef.current += 1;
    setIsCreateOpen(false);
    setIsEditOpen(false);
    setIsSubmitting(false);
    setIsEditSubmitting(false);
    setActionInFlight(null);
    setEditingPayPeriod(null);
    setError(null);
    setCreateError(null);
    setEditError(null);
    setCurrentNextCheckNumber(null);
    setCheckSettingsError(null);
    setLoadingCheckSettings(false);
  }, [activeCompanyId]);
  
  // Modal state
  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [isEditOpen, setIsEditOpen] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [isEditSubmitting, setIsEditSubmitting] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);
  const [editError, setEditError] = useState<string | null>(null);
  const [currentNextCheckNumber, setCurrentNextCheckNumber] = useState<number | null>(null);
  const [loadingCheckSettings, setLoadingCheckSettings] = useState(false);
  const [checkSettingsError, setCheckSettingsError] = useState<string | null>(null);
  const [scheduleContext, setScheduleContext] = useState<string>('Loading this client’s pay-schedule rules…');
  const [actionInFlight, setActionInFlight] = useState<string | null>(null);
  const [editingPayPeriod, setEditingPayPeriod] = useState<PayPeriod | null>(null);
  const [formData, setFormData] = useState({
    start_date: '',
    end_date: '',
    pay_date: '',
    starting_check_number: '',
    notes: '',
    run_purpose: 'regular' as PayRunPurpose,
    includes_base_salary: true,
    includes_recurring_items: true,
  });
  const [editFormData, setEditFormData] = useState({
    start_date: '',
    end_date: '',
    pay_date: '',
    notes: '',
    run_purpose: 'regular' as PayRunPurpose,
    includes_base_salary: true,
    includes_recurring_items: true,
  });

  const currentMutationGuard = (): (() => boolean) => {
    const requestedCompanyId = activeCompanyId;
    const requestedGeneration = mutationGenerationRef.current;
    return (): boolean => (
      requestedCompanyId === activeCompanyIdRef.current
      && requestedGeneration === mutationGenerationRef.current
    );
  };

  // Load pay periods
  const loadPayPeriods = useCallback(async (silent = false): Promise<void> => {
    const requestedCompanyId = activeCompanyId;
    const requestedViewKey = payPeriodViewKey;
    if (
      requestedCompanyId !== activeCompanyIdRef.current
      || requestedViewKey !== payPeriodViewKeyRef.current
    ) return;
    const requestId = ++loadRequestIdRef.current;
    const isCurrentRequest = (): boolean => (
      requestId === loadRequestIdRef.current
      && requestedCompanyId === activeCompanyIdRef.current
      && requestedViewKey === payPeriodViewKeyRef.current
    );

    if (payPeriodCompanyIdRef.current !== requestedCompanyId) {
      payPeriodCompanyIdRef.current = null;
      setPayPeriodCompanyId(null);
      setPayPeriods([]);
      setStatusCounts({});
      setTotalPages(0);
      setYears([]);
    }

    try {
      if (!silent) setLoading(true);
      setError(null);
      if (!requestedCompanyId) throw new Error('Select a company to view payroll.');
      const response = await payrollHistoryApi.list({
        page,
        per_page: 50,
        status: statusFilter,
        year: parsePayRunYear(yearFilter),
        search: searchTerm.trim() || undefined,
        sort: sortBy,
        direction: sortDirection,
        source: sourceFilter,
      }, requestedCompanyId);
      if (!isCurrentRequest()) return;
      setPayPeriods(response.data);
      setStatusCounts(response.meta.statuses);
      setTotalPages(response.meta.total_pages);
      setYears(response.meta.years);
      setGoLiveGate(response.meta.payroll_go_live ?? null);
      payPeriodCompanyIdRef.current = requestedCompanyId;
      setPayPeriodCompanyId(requestedCompanyId);
    } catch (err) {
      if (!isCurrentRequest()) return;
      if (!silent) {
        setPayPeriods([]);
        setStatusCounts({});
        setTotalPages(0);
        setYears([]);
        setGoLiveGate(null);
      }
      setError(err instanceof ApiError ? err.message : err instanceof Error ? err.message : 'Failed to load pay periods');
    } finally {
      if (isCurrentRequest() && !silent) {
        setLoading(false);
      }
    }
  }, [activeCompanyId, page, payPeriodViewKey, searchTerm, sortBy, sortDirection, sourceFilter, statusFilter, yearFilter]);
  useEffect((): void => {
    loadPayPeriodsRef.current = loadPayPeriods;
  }, [loadPayPeriods]);

  useEffect(() => {
    loadPayPeriods();
  }, [loadPayPeriods]);

  useEffect(() => {
    const state = location.state as { companySwitchNotice?: string } | null;
    if (!state?.companySwitchNotice) return;

    setSwitchNotice(state.companySwitchNotice);
    navigate({ pathname: location.pathname, search: location.search }, { replace: true, state: null });
  }, [location.pathname, location.search, location.state, navigate]);

  useEffect(() => {
    if (!switchNotice) return;

    const timer = window.setTimeout(() => {
      setSwitchNotice(null);
    }, 6000);

    return () => window.clearTimeout(timer);
  }, [switchNotice]);

  const handleCreate = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const startingCheckNumber = formData.starting_check_number.trim();

    if (formData.end_date <= formData.start_date) {
      setCreateError('End date must be after start date');
      return;
    }
    if (formData.pay_date < formData.end_date) {
      setCreateError('Pay date must be on or after end date');
      return;
    }
    if (startingCheckNumber && !/^\d+$/.test(startingCheckNumber)) {
      setCreateError('Starting check number must be numeric.');
      return;
    }

    const isCurrentMutation = currentMutationGuard();
    try {
      setIsSubmitting(true);
      setCreateError(null);
      setError(null);
      await payPeriodsApi.create({
        ...formData,
        starting_check_number: startingCheckNumber,
      });
      if (!isCurrentMutation()) return;
      setIsCreateOpen(false);
      setCurrentNextCheckNumber(null);
      setFormData({ start_date: '', end_date: '', pay_date: '', starting_check_number: '', notes: '', run_purpose: 'regular', includes_base_salary: true, includes_recurring_items: true });
      void loadPayPeriodsRef.current(true);
    } catch (err) {
      if (!isCurrentMutation()) return;
      setCreateError(err instanceof Error ? err.message : 'Failed to create pay period');
    } finally {
      if (isCurrentMutation()) setIsSubmitting(false);
    }
  };

  const handleRunPayroll = async (id: number) => {
    const isCurrentMutation = currentMutationGuard();
    try {
      setActionInFlight(`run-${id}`);
      setError(null);
      await payPeriodsApi.runPayroll(id);
      if (!isCurrentMutation()) return;
      void loadPayPeriodsRef.current(true);
    } catch (err) {
      if (!isCurrentMutation()) return;
      setError(err instanceof Error ? err.message : 'Failed to run payroll');
    } finally {
      if (isCurrentMutation()) setActionInFlight(null);
    }
  };

  const openEditModal = (period: PayPeriod) => {
    setEditingPayPeriod(period);
    setEditError(null);
    setError(null);
    setEditFormData({
      start_date: period.start_date,
      end_date: period.end_date,
      pay_date: period.pay_date,
      notes: period.notes || '',
      run_purpose: period.run_purpose,
      includes_base_salary: period.includes_base_salary,
      includes_recurring_items: period.includes_recurring_items,
    });
    setIsEditOpen(true);
  };

  const handleEdit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (!editingPayPeriod) return;

    if (editFormData.end_date <= editFormData.start_date) {
      setEditError('End date must be after start date');
      return;
    }
    if (editFormData.pay_date < editFormData.end_date) {
      setEditError('Pay date must be on or after end date');
      return;
    }

    if (
      editingPayPeriod.status !== 'draft' &&
      (editFormData.start_date !== editingPayPeriod.start_date ||
        editFormData.end_date !== editingPayPeriod.end_date ||
        editFormData.pay_date !== editingPayPeriod.pay_date) &&
      !window.confirm('Changing payroll dates affects tax year, YTD, checks, and reports. This pay period will be moved back to draft and must be recalculated before approval/commit. Continue?')
    ) {
      return;
    }

    const isCurrentMutation = currentMutationGuard();
    try {
      setIsEditSubmitting(true);
      setEditError(null);
      setError(null);
      await payPeriodsApi.update(
        editingPayPeriod.id,
        editingPayPeriod.status === 'draft'
          ? editFormData
          : {
              start_date: editFormData.start_date,
              end_date: editFormData.end_date,
              pay_date: editFormData.pay_date,
              notes: editFormData.notes,
            }
      );
      if (!isCurrentMutation()) return;
      setIsEditOpen(false);
      setEditingPayPeriod(null);
      void loadPayPeriodsRef.current(true);
    } catch (err) {
      if (!isCurrentMutation()) return;
      setEditError(err instanceof Error ? err.message : 'Failed to update pay period');
    } finally {
      if (isCurrentMutation()) setIsEditSubmitting(false);
    }
  };

  const handleApprove = async (id: number) => {
    const isCurrentMutation = currentMutationGuard();
    try {
      setActionInFlight(`approve-${id}`);
      setError(null);
      await payPeriodsApi.approve(id);
      if (!isCurrentMutation()) return;
      void loadPayPeriodsRef.current(true);
    } catch (err) {
      if (!isCurrentMutation()) return;
      setError(err instanceof Error ? err.message : 'Failed to approve pay period');
    } finally {
      if (isCurrentMutation()) setActionInFlight(null);
    }
  };

  const handleCommit = async (id: number) => {
    const period = payPeriodCompanyId === activeCompanyId
      ? payPeriods.find((candidate) => candidate.record_type === 'native' && candidate.id === id)
      : undefined;
    const warningText = period?.compliance_warnings?.length
      ? `\n\nAttention:\n${period.compliance_warnings.map((warning) => `• ${warning}`).join('\n')}`
      : '';
    if (!confirm(`Are you sure you want to commit this pay period? This action cannot be undone.${warningText}`)) {
      return;
    }
    const isCurrentMutation = currentMutationGuard();
    try {
      setActionInFlight(`commit-${id}`);
      setError(null);
      await payPeriodsApi.commit(id);
      if (!isCurrentMutation()) return;
      void loadPayPeriodsRef.current(true);
    } catch (err) {
      if (!isCurrentMutation()) return;
      setError(err instanceof Error ? err.message : 'Failed to commit pay period');
    } finally {
      if (isCurrentMutation()) setActionInFlight(null);
    }
  };

  const handleDelete = async (id: number) => {
    if (!confirm('Are you sure you want to delete this pay period?')) {
      return;
    }
    const isCurrentMutation = currentMutationGuard();
    try {
      setActionInFlight(`delete-${id}`);
      setError(null);
      await payPeriodsApi.delete(id);
      if (!isCurrentMutation()) return;
      setPayPeriods((prev) => prev.filter((period) => period.key !== `native:${id}`));
      void loadPayPeriodsRef.current(true);
    } catch (err) {
      if (!isCurrentMutation()) return;
      setError(err instanceof Error ? err.message : 'Failed to delete pay period');
    } finally {
      if (isCurrentMutation()) setActionInFlight(null);
    }
  };

  const toDateInput = (date: Date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
  const isComparisonOnlyPayDate = (payDate: string): boolean => Boolean(
    goLiveGate?.comparison_only
    && (!payDate || !goLiveGate.effective_on || payDate >= goLiveGate.effective_on)
  );
  const comparisonOnlyForSelectedPayDate = isComparisonOnlyPayDate(formData.pay_date);

  // Suggest dates only when the client has an explicit boundary rule. Manual
  // schedules intentionally start blank so a legacy assumption is never
  // presented as a confirmed payroll calendar.
  const setDefaultDates = async (): Promise<void> => {
    const requestId = ++defaultDatesRequestIdRef.current;
    const requestedCompanyId = activeCompanyId;
    const isCurrentRequest = (): boolean => (
      requestId === defaultDatesRequestIdRef.current
      && requestedCompanyId === activeCompanyIdRef.current
    );
    setScheduleContext('Loading this client’s pay-schedule rules…');
    try {
      const response = await payScheduleSettingsApi.get();
      if (!isCurrentRequest()) return;
      const schedule = response.pay_schedule_settings.pay_schedule;
      const confirmation = schedule.confirmation_status === 'confirmed' ? 'Confirmed' : 'Needs confirmation';

      if (schedule.period_rule === 'manual') {
        if (!createDatesEditedRef.current) {
          setFormData((current) => ({ ...current, start_date: '', end_date: '', pay_date: '' }));
        }
        setScheduleContext(`${confirmation}: period and pay dates are manual for this client.`);
        return;
      }
      if (schedule.period_rule === 'biweekly' && !schedule.period_anchor_date) {
        if (!createDatesEditedRef.current) {
          setFormData((current) => ({ ...current, start_date: '', end_date: '', pay_date: '' }));
        }
        setScheduleContext(`${confirmation}: this biweekly schedule has no anchor date. Enter and verify all dates manually, then confirm the schedule in Settings.`);
        return;
      }

      const today = new Date();
      let startDate: Date;
      let endDate: Date;
      if (schedule.period_rule === 'semimonthly') {
        const firstHalf = today.getDate() <= 15;
        startDate = new Date(today.getFullYear(), today.getMonth(), firstHalf ? 1 : 16);
        endDate = firstHalf
          ? new Date(today.getFullYear(), today.getMonth(), 15)
          : new Date(today.getFullYear(), today.getMonth() + 1, 0);
      } else if (schedule.period_rule === 'biweekly') {
        const anchorDate = new Date(`${schedule.period_anchor_date}T12:00:00`);
        const elapsedDays = Math.floor((today.getTime() - anchorDate.getTime()) / 86_400_000);
        const cycleOffset = Math.floor(elapsedDays / 14) * 14;
        startDate = new Date(anchorDate);
        startDate.setDate(anchorDate.getDate() + cycleOffset);
        endDate = new Date(startDate);
        endDate.setDate(startDate.getDate() + 13);
      } else {
        startDate = new Date(today);
        const startWeekday = schedule.period_start_weekday ?? 0;
        const daysSinceStart = (today.getDay() - startWeekday + 7) % 7;
        startDate.setDate(today.getDate() - daysSinceStart);
        endDate = new Date(startDate);
        endDate.setDate(startDate.getDate() + 6);
      }

      const payDate = schedule.pay_date_rule === 'days_after_period_end'
        ? new Date(endDate)
        : null;
      if (payDate) payDate.setDate(endDate.getDate() + (schedule.pay_date_offset_days ?? 0));

      const selectedPayDate = payDate ? toDateInput(payDate) : '';
      if (!createDatesEditedRef.current) {
        setFormData((current) => ({
          ...current,
          start_date: toDateInput(startDate),
          end_date: toDateInput(endDate),
          pay_date: selectedPayDate,
        }));
        if (!isComparisonOnlyPayDate(selectedPayDate)) void loadCurrentNextCheckNumber();
      }
      setScheduleContext(`${confirmation}: ${schedule.frequency} boundary rule applied${payDate ? ' with the configured pay-date offset' : '; enter the pay date manually'}.`);
    } catch {
      if (!isCurrentRequest()) return;
      if (!createDatesEditedRef.current) {
        setFormData((current) => ({ ...current, start_date: '', end_date: '', pay_date: '' }));
      }
      setScheduleContext('Schedule settings could not be loaded. Enter and verify all dates manually.');
    }
  };

  const loadCurrentNextCheckNumber = async (): Promise<void> => {
    const requestId = ++checkSettingsRequestIdRef.current;
    const requestedCompanyId = activeCompanyId;
    const isCurrentRequest = (): boolean => (
      requestId === checkSettingsRequestIdRef.current
      && requestedCompanyId === activeCompanyIdRef.current
    );

    if (!requestedCompanyId) {
      setCurrentNextCheckNumber(null);
      setCheckSettingsError(null);
      setLoadingCheckSettings(false);
      return;
    }

    try {
      setLoadingCheckSettings(true);
      setCheckSettingsError(null);
      const response = await companiesApi.get(requestedCompanyId);
      if (!isCurrentRequest()) return;
      setCurrentNextCheckNumber(response.company.next_check_number ?? null);
    } catch (err) {
      if (!isCurrentRequest()) return;
      setCurrentNextCheckNumber(null);
      const message = err instanceof Error ? err.message : 'Unable to load current check settings.';
      setCheckSettingsError(message);
    } finally {
      if (isCurrentRequest()) setLoadingCheckSettings(false);
    }
  };

  const openCreateModal = () => {
    createDatesEditedRef.current = false;
    setFormData({ start_date: '', end_date: '', pay_date: '', starting_check_number: '', notes: '', run_purpose: 'regular', includes_base_salary: true, includes_recurring_items: true });
    void setDefaultDates();
    setCreateError(null);
    setError(null);
    setCurrentNextCheckNumber(null);
    setCheckSettingsError(null);
    setIsCreateOpen(true);
    if (!comparisonOnlyForSelectedPayDate) void loadCurrentNextCheckNumber();
  };

  const handleCreateOpenChange = (open: boolean) => {
    setIsCreateOpen(open);
    if (!open) {
      setCreateError(null);
      setCurrentNextCheckNumber(null);
      setCheckSettingsError(null);
      setLoadingCheckSettings(false);
    }
  };

  const handleEditOpenChange = (open: boolean) => {
    setIsEditOpen(open);
    if (!open) {
      setEditError(null);
      setEditingPayPeriod(null);
    }
  };

  const companyPayPeriods = useMemo(
    (): PayrollHistoryRecord[] => payPeriodCompanyId === activeCompanyId ? payPeriods : [],
    [activeCompanyId, payPeriodCompanyId, payPeriods],
  );
  const companyStatusCounts = payPeriodCompanyId === activeCompanyId ? statusCounts : {};
  const visiblePayPeriods = companyPayPeriods;
  const recordDestination = (period: PayrollHistoryRecord, tab: PayRunWorkspaceTab): string => {
    if (period.record_type === 'imported' && activeCompanyId) {
      return importedPayRunPath(activeCompanyId, period.id, { returnTo });
    }
    return payRunDestination(period.id, tab);
  };

  return (
    <div>
      <Header
        title="Pay Periods"
        description="Review every payroll run in one place. QuickBooks imports are visible for continuity and remain read-only."
        actions={
          <Button onClick={openCreateModal}>
            {goLiveGate?.comparison_only ? 'New Comparison Run' : 'New Pay Period'}
          </Button>
        }
      />

      <div className="p-4 sm:p-6 lg:p-8">
        {goLiveGate?.comparison_only && (
          <div className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-4 text-amber-950">
            <div className="flex items-start gap-3">
              <LockKeyhole className="mt-0.5 h-5 w-5 shrink-0 text-amber-700" aria-hidden="true" />
              <div>
                <p className="font-semibold">Live payroll stays locked during cutover review</p>
                <p className="mt-1 text-sm leading-6 text-amber-900">
                  Payrolls dated {goLiveGate.effective_on ? formatDate(goLiveGate.effective_on) : 'after the cutover'} or later are created as comparison runs and cannot be committed until technical and operations approval is complete.
                </p>
              </div>
            </div>
          </div>
        )}
        {/* Error display */}
        {error && (
          <div className="mb-4 p-4 bg-red-50 border border-red-200 text-red-700 rounded-lg">
            {error}
          </div>
        )}
        {switchNotice && (
          <div
            role="status"
            className="mb-4 flex items-start justify-between gap-3 rounded-lg border border-primary-200 bg-primary-50 p-4 text-primary-800"
          >
            <span>{switchNotice}</span>
            <button
              type="button"
              onClick={() => setSwitchNotice(null)}
              className="shrink-0 rounded-md px-2 py-1 text-sm font-medium text-primary-700 transition-colors hover:bg-primary-100 hover:text-primary-900"
              aria-label="Dismiss company switch notice"
            >
              Dismiss
            </button>
          </div>
        )}

        {/* Status filter tabs */}
        <div className="mb-4 flex gap-2 overflow-x-auto pb-1 sm:flex-wrap">
          <Button
            variant={statusFilter === undefined ? 'primary' : 'outline'}
            size="sm"
            onClick={() => updateViewParam('status')}
          >
            All ({Object.values(companyStatusCounts).reduce((a, b) => a + b, 0)})
          </Button>
          {(['draft', 'calculated', 'approved', 'committed', 'locked'] as const).map((status) => (
            <Button
              key={status}
              variant={statusFilter === status ? 'primary' : 'outline'}
              size="sm"
              onClick={() => updateViewParam('status', status)}
            >
              {status === 'locked' ? 'Imported & locked' : payPeriodStatusConfig[status]?.label || status} ({companyStatusCounts[status] || 0})
            </Button>
          ))}
        </div>

        <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div className="relative w-full max-w-md">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-400" />
            <Input
              placeholder="Search pay periods..."
              value={searchTerm}
              onChange={(e) => updateViewParam('search', e.target.value, true)}
              className="pl-10"
            />
          </div>
          <div className="grid grid-cols-1 gap-3 sm:flex sm:flex-wrap">
            <Label htmlFor="pay-period-source-filter" className="sr-only">Filter pay periods by source</Label>
            <Select
              id="pay-period-source-filter"
              value={sourceFilter}
              onChange={(e) => updateViewParam('source', e.target.value)}
              className="w-full sm:w-44"
            >
              <option value="all">All sources</option>
              <option value="cornerstone">Cornerstone</option>
              <option value="quickbooks">QuickBooks imports</option>
            </Select>
            <Select
              value={sortBy}
              onChange={(e) => updateViewParam('sort', e.target.value)}
              className="w-full sm:w-44"
            >
              <option value="pay_period">Sort: Pay Period</option>
              <option value="pay_date">Sort: Pay Date</option>
              <option value="processed">Sort: Processed</option>
              <option value="employees">Sort: Employees</option>
              <option value="gross">Sort: Gross Pay</option>
              <option value="net">Sort: Net Pay</option>
              <option value="status">Sort: Status</option>
              <option value="source">Sort: Source</option>
            </Select>
            <Label htmlFor="pay-period-year-filter" className="sr-only">Filter pay periods by year</Label>
            <Select
              id="pay-period-year-filter"
              value={yearFilter}
              onChange={(e) => updateViewParam('year', e.target.value)}
              className="w-full sm:w-32"
            >
              <option value="">All years</option>
              {years.map((year) => <option key={year} value={year}>{year}</option>)}
            </Select>
            <Select
              value={sortDirection}
              onChange={(e) => updateViewParam('direction', e.target.value)}
              className="w-full sm:w-32"
            >
              <option value="desc">Newest / High</option>
              <option value="asc">Oldest / Low</option>
            </Select>
          </div>
        </div>

        {/* Pay Period Table */}
        <Card>
          {loading ? (
            <div className="p-8 text-center text-gray-500">Loading...</div>
          ) : visiblePayPeriods.length === 0 ? (
            <div className="p-8 text-center text-gray-500">
              {searchTerm ? 'No pay periods match the current filters.' : 'No pay periods found. Create your first pay period to get started.'}
            </div>
          ) : (
            <>
              <div className="space-y-3 p-3 sm:hidden">
                {visiblePayPeriods.map((period) => (
                  <PayPeriodMobileCard
                    key={period.key}
                    period={period}
                    actionInFlight={actionInFlight}
                    onView={() => navigate(recordDestination(period, 'overview'))}
                    onEnterHours={() => navigate(recordDestination(period, 'work'))}
                    onEdit={() => openEditModal(period as PayPeriod)}
                    onDelete={() => handleDelete(period.id)}
                    onRun={() => handleRunPayroll(period.id)}
                    onApprove={() => handleApprove(period.id)}
                    onCommit={() => handleCommit(period.id)}
                  />
                ))}
              </div>
              <div className="hidden sm:block">
                <Table stickyHeader containerClassName="max-h-[32rem]">
                  <TableHeader>
                <TableRow>
                  <TableHead stickyLeft className="w-[240px] min-w-[240px] bg-gray-50">Pay Period</TableHead>
                  <TableHead>Pay Date</TableHead>
                  <TableHead>Purpose</TableHead>
                  <TableHead>Employees</TableHead>
                  <TableHead>Gross Pay</TableHead>
                  <TableHead>Net Pay</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead>Processed</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {visiblePayPeriods.map((period, index) => {
                  const statusLabel = period.status === 'locked' ? 'Locked' : payPeriodStatusConfig[period.status]?.label || period.status;
                  const rowTone = index % 2 === 0 ? 'bg-white' : 'bg-slate-100';
                  return (
                    <TableRow key={period.key} className={rowTone}>
                      <TableCell stickyLeft className={`w-[240px] min-w-[240px] ${rowTone}`}>
                        <span className="font-medium text-gray-900">
                          {formatDateRange(period.start_date, period.end_date)}
                        </span>
                      </TableCell>
                      <TableCell className={rowTone}>
                        <span className="text-sm text-gray-700">
                          {new Date(period.pay_date).toLocaleDateString('en-US', {
                            weekday: 'short',
                            month: 'short',
                            day: 'numeric',
                          })}
                        </span>
                      </TableCell>
                      <TableCell className={rowTone}>
                        <div className="flex flex-col items-start gap-1">
                          <Badge variant={period.run_purpose === 'regular' ? 'default' : 'warning'}>
                            {RUN_PURPOSE_LABELS[period.run_purpose] || period.run_purpose}
                          </Badge>
                          {!period.includes_base_salary && <span className="text-xs font-medium text-primary-700">No base salary</span>}
                          <Badge variant={period.record_type === 'imported' ? 'warning' : 'default'}>
                            {period.record_type === 'imported' ? 'QuickBooks import' : 'Cornerstone'}
                          </Badge>
                        </div>
                      </TableCell>
                      <TableCell className={rowTone}>
                        <span className="text-sm text-gray-700">
                          {period.employee_count || 0}
                        </span>
                      </TableCell>
                      <TableCell className={rowTone}>
                        <span className="font-medium text-gray-900">
                          {period.total_gross ? formatCurrency(period.total_gross) : '—'}
                        </span>
                      </TableCell>
                      <TableCell className={rowTone}>
                        <span className="font-medium text-gray-900">
                          {period.total_net ? formatCurrency(period.total_net) : '—'}
                        </span>
                      </TableCell>
                      <TableCell className={rowTone}>
                        <div className="flex flex-col gap-1 items-start">
                          <Badge
                            variant={
                              period.correction_status === 'voided' ? 'danger' :
                              period.status === 'committed' || period.status === 'locked' ? 'success' :
                              period.status === 'approved' ? 'info' :
                              period.status === 'calculated' ? 'warning' :
                              'default'
                            }
                          >
                            {period.correction_status === 'voided' ? 'Voided' : statusLabel}
                          </Badge>
                          {period.correction_status === 'correction' && (
                            <Badge variant="warning">Correction</Badge>
                          )}
                        </div>
                      </TableCell>
                      <TableCell className={rowTone}>
                        {period.processed_at ? (
                          <div className="text-sm">
                            <p className="font-medium text-gray-900">
                              {formatGuamDateTimeShort(period.processed_at)}
                            </p>
                            <p className="text-xs text-gray-500">
                              {period.processed_by_name ? `by ${period.processed_by_name}` : 'Operator not recorded'}
                            </p>
                          </div>
                        ) : (
                          <span className="text-sm text-gray-400">Not processed</span>
                        )}
                      </TableCell>
                      <TableCell className={`text-right ${rowTone}`}>
                        <div className="flex items-center justify-end gap-3">
                          <div className="flex items-center gap-1 text-sm">
                            <button
                              className="text-gray-500 hover:text-gray-800 hover:underline"
                              onClick={() => navigate(recordDestination(period, 'overview'))}
                            >
                              View
                            </button>
                            {period.capabilities.edit && <><span className="text-gray-300">·</span><button className="text-gray-500 hover:text-gray-800 hover:underline" onClick={() => openEditModal(period as PayPeriod)}>Edit</button></>}
                            {period.capabilities.delete && <><span className="text-gray-300">·</span><button className="text-red-400 hover:text-red-600 hover:underline" onClick={() => handleDelete(period.id)} disabled={actionInFlight !== null}>Delete</button></>}
                          </div>

                          {period.capabilities.enter_hours && (
                            <Button
                              variant="outline"
                              size="sm"
                              onClick={() => navigate(recordDestination(period, 'work'))}
                            >
                              Enter Hours
                            </Button>
                          )}
                          {period.capabilities.run && period.status === 'calculated' && (
                            <div className="flex items-center gap-1.5">
                              <Button
                                variant="outline"
                                size="sm"
                                onClick={() => handleRunPayroll(period.id)}
                                disabled={actionInFlight !== null}
                              >
                                Recalculate
                              </Button>
                              {period.capabilities.approve && <Button
                                size="sm"
                                onClick={() => handleApprove(period.id)}
                                disabled={actionInFlight !== null}
                              >
                                Approve
                              </Button>}
                            </div>
                          )}
                          {period.parallel_run && <Badge variant="info">Parallel · cannot commit</Badge>}
                          {period.capabilities.commit && (
                            <Button
                              size="sm"
                              variant="primary"
                              onClick={() => handleCommit(period.id)}
                              disabled={actionInFlight !== null}
                            >
                              Commit
                            </Button>
                          )}
                        </div>
                      </TableCell>
                    </TableRow>
                  );
                })}
                  </TableBody>
                </Table>
              </div>
            </>
          )}
        </Card>

        {totalPages > 1 && (
          <div className="mt-4 flex items-center justify-between">
            <p className="text-sm text-neutral-500">Page {page} of {totalPages}</p>
            <div className="flex gap-2">
              <Button variant="outline" size="sm" disabled={page <= 1 || loading} onClick={() => updateViewParam('page', String(page - 1))}>Previous</Button>
              <Button variant="outline" size="sm" disabled={page >= totalPages || loading} onClick={() => updateViewParam('page', String(page + 1))}>Next</Button>
            </div>
          </div>
        )}

        {/* Workflow explanation */}
        <Card className="mt-8">
          <div className="p-6">
            <h3 className="text-lg font-medium text-gray-900 mb-4">Payroll Workflow</h3>
            <div className="grid gap-4 sm:flex sm:items-center sm:justify-between">
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-gray-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-gray-600">1</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Draft</p>
                  <p className="text-sm text-gray-500">Create pay period</p>
                </div>
              </div>
              <div className="hidden flex-1 h-px bg-gray-300 mx-4 sm:block" />
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-yellow-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-yellow-600">2</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Calculated</p>
                  <p className="text-sm text-gray-500">Review totals</p>
                </div>
              </div>
              <div className="hidden flex-1 h-px bg-gray-300 mx-4 sm:block" />
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-blue-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-blue-600">3</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Approved</p>
                  <p className="text-sm text-gray-500">Ready to commit</p>
                </div>
              </div>
              <div className="hidden flex-1 h-px bg-gray-300 mx-4 sm:block" />
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-green-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-green-600">4</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Committed</p>
                  <p className="text-sm text-gray-500">Locked & finalized</p>
                </div>
              </div>
            </div>
          </div>
        </Card>
      </div>

      {/* Create Pay Period Modal */}
      <Dialog open={isCreateOpen} onOpenChange={handleCreateOpenChange}>
        <DialogContent>
          <form onSubmit={handleCreate}>
            <DialogHeader>
              <DialogTitle>{comparisonOnlyForSelectedPayDate ? 'New Comparison Run' : 'New Pay Period'}</DialogTitle>
              <DialogDescription>
                {comparisonOnlyForSelectedPayDate
                  ? 'Build and reconcile payroll safely. This run cannot be committed while cutover approval is open.'
                  : 'Create a payroll run with an explicit purpose and verified dates.'}
              </DialogDescription>
            </DialogHeader>
            {createError && (
              <div role="alert" className="mt-4 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
                <div className="flex gap-2">
                  <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
                  <p>{createError}</p>
                </div>
              </div>
            )}
            <div className="grid gap-4 py-4">
              <div className="rounded-lg border border-primary-100 bg-primary-50 px-3 py-2 text-xs font-medium leading-5 text-primary-800">{scheduleContext}</div>
              <div className="rounded-xl border border-neutral-200 bg-neutral-50/80 p-4">
                <div className="grid gap-4 sm:grid-cols-2">
                  <div className="space-y-2">
                    <Label htmlFor="run_purpose">Run purpose</Label>
                    <Select
                      id="run_purpose"
                      value={formData.run_purpose}
                      onChange={(event) => {
                        const runPurpose = event.target.value as PayRunPurpose;
                        setFormData({ ...formData, run_purpose: runPurpose, includes_base_salary: runPurpose === 'regular', includes_recurring_items: runPurpose === 'regular' });
                      }}
                    >
                      {Object.entries(RUN_PURPOSE_LABELS).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
                    </Select>
                  </div>
                  <label className="flex items-start gap-3 rounded-xl border border-neutral-200 bg-white p-3">
                    <input
                      type="checkbox"
                      className="mt-1 h-4 w-4 rounded border-neutral-300 text-primary-600"
                      checked={formData.includes_base_salary}
                      disabled={formData.run_purpose === 'off_cycle_tips'}
                      onChange={(event) => setFormData({ ...formData, includes_base_salary: event.target.checked })}
                    />
                    <span><span className="block text-sm font-semibold text-neutral-900">Include ordinary base salary</span><span className="mt-1 block text-xs leading-5 text-neutral-500">Regular payroll includes it by default. Non-regular runs do not.</span></span>
                  </label>
                  <label className="flex items-start gap-3 rounded-xl border border-neutral-200 bg-white p-3 sm:col-span-2">
                    <input
                      type="checkbox"
                      className="mt-1 h-4 w-4 rounded border-neutral-300 text-primary-600"
                      checked={formData.includes_recurring_items}
                      onChange={(event) => setFormData({ ...formData, includes_recurring_items: event.target.checked })}
                    />
                    <span><span className="block text-sm font-semibold text-neutral-900">Include recurring employee setup</span><span className="mt-1 block text-xs leading-5 text-neutral-500">Adds each employee’s recurring earnings, deductions, loans, retirement, employer contributions, and extra withholding. Special runs leave these out unless you choose this.</span></span>
                  </label>
                </div>
                {formData.run_purpose === 'off_cycle_tips' && <p className="mt-3 text-xs font-medium text-primary-800">Tips-only runs exclude ordinary salary and automatic flat-fee contractor pay.</p>}
                {formData.run_purpose !== 'regular' && formData.run_purpose !== 'off_cycle_tips' && formData.includes_base_salary && <p className="mt-3 text-xs font-medium text-warning-800">You deliberately enabled base salary for a non-regular run. Verify this is intended before calculating payroll.</p>}
                {formData.run_purpose !== 'regular' && formData.includes_recurring_items && <p className="mt-3 text-xs font-medium text-warning-800">You deliberately enabled recurring employee setup for a special run. Review every recurring item before calculating payroll.</p>}
                {formData.run_purpose === 'regular' && !formData.includes_recurring_items && <p className="mt-3 text-xs font-medium text-warning-800">Recurring employee setup is excluded from this regular payroll. Confirm that every recurring deduction and contribution should be skipped.</p>}
              </div>
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor="start_date">Start Date</Label>
                  <Input
                    id="start_date"
                    type="date"
                    value={formData.start_date}
                    onChange={(e) => {
                      createDatesEditedRef.current = true;
                      setFormData({ ...formData, start_date: e.target.value });
                    }}
                    required
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="end_date">End Date</Label>
                  <Input
                    id="end_date"
                    type="date"
                    value={formData.end_date}
                    onChange={(e) => {
                      createDatesEditedRef.current = true;
                      setFormData({ ...formData, end_date: e.target.value });
                    }}
                    required
                  />
                </div>
              </div>
              <div className="space-y-2">
                <Label htmlFor="pay_date">Pay Date</Label>
                <Input
                  id="pay_date"
                  type="date"
                  value={formData.pay_date}
                  onChange={(e) => {
                    createDatesEditedRef.current = true;
                    const payDate = e.target.value;
                    const comparisonOnly = isComparisonOnlyPayDate(payDate);
                    setFormData({
                      ...formData,
                      pay_date: payDate,
                      starting_check_number: comparisonOnly ? '' : formData.starting_check_number,
                    });
                    if (!comparisonOnly && currentNextCheckNumber == null && !loadingCheckSettings) {
                      void loadCurrentNextCheckNumber();
                    }
                  }}
                  required
                />
              </div>
              {!comparisonOnlyForSelectedPayDate && <div className="space-y-2">
                <Label htmlFor="starting_check_number">Starting Check Number (optional)</Label>
                <Input
                  id="starting_check_number"
                  inputMode="numeric"
                  value={formData.starting_check_number}
                  onChange={(e) => setFormData({ ...formData, starting_check_number: e.target.value })}
                  placeholder="Use current check settings"
                />
                <p className="text-xs text-gray-500">
                  {loadingCheckSettings
                    ? 'Checking current company check settings...'
                    : checkSettingsError
                      ? 'Could not load the current next check number. You can still enter an unused check number; the server will reject duplicates.'
                      : currentNextCheckNumber != null
                        ? `Current next check number is ${currentNextCheckNumber}. Leave blank to use that setting, or enter any unused check number if the physical stock is out of sequence.`
                        : 'Sets the company’s next payroll check number before checks are assigned. Leave blank to use the current check settings.'}
                </p>
                {checkSettingsError && !loadingCheckSettings && (
                  <div role="status" className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800">
                    <div className="flex items-start gap-2">
                      <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden="true" />
                      <div className="space-y-1">
                        <p>Current check-number settings did not load: {checkSettingsError}</p>
                        <button
                          type="button"
                          className="font-medium underline decoration-amber-400 underline-offset-2 hover:text-amber-900"
                          onClick={() => void loadCurrentNextCheckNumber()}
                        >
                          Try loading settings again
                        </button>
                      </div>
                    </div>
                  </div>
                )}
                {formData.starting_check_number.trim() &&
                  currentNextCheckNumber != null &&
                  /^\d+$/.test(formData.starting_check_number.trim()) &&
                  Number(formData.starting_check_number.trim()) < currentNextCheckNumber && (
                    <p className="text-xs font-medium text-amber-700">
                      This will move the sequence to a lower check number. That is allowed, but the number must not already be used.
                    </p>
                  )}
              </div>}
              <div className="space-y-2">
                <Label htmlFor="notes">Notes (optional)</Label>
                <Textarea
                  id="notes"
                  value={formData.notes}
                  onChange={(e) => setFormData({ ...formData, notes: e.target.value })}
                  placeholder="Any notes about this pay period..."
                />
              </div>
            </div>
            <DialogFooter className="sticky bottom-0 -mx-4 !flex-row gap-2 border-t border-neutral-200 bg-white px-4 pb-1 sm:-mx-6 sm:px-6">
              <Button className="flex-1 sm:flex-none" type="button" variant="outline" onClick={() => handleCreateOpenChange(false)}>
                Cancel
              </Button>
              <Button className="flex-1 sm:flex-none" type="submit" disabled={isSubmitting}>
                {isSubmitting ? 'Creating...' : comparisonOnlyForSelectedPayDate ? 'Create Comparison Run' : 'Create Pay Period'}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      {/* Edit Pay Period Modal */}
      <Dialog open={isEditOpen} onOpenChange={handleEditOpenChange}>
        <DialogContent>
          <form onSubmit={handleEdit}>
            <DialogHeader>
              <DialogTitle>Edit Pay Period</DialogTitle>
              <DialogDescription>
                Update pay period dates and notes before commit.
              </DialogDescription>
            </DialogHeader>
            {editError && (
              <div role="alert" className="mt-4 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
                <div className="flex gap-2">
                  <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
                  <p>{editError}</p>
                </div>
              </div>
            )}
            <div className="grid gap-4 py-4">
              {editingPayPeriod?.status === 'draft' && (
                <div className="rounded-xl border border-neutral-200 bg-neutral-50/80 p-4">
                  <div className="grid gap-4 sm:grid-cols-2">
                    <div className="space-y-2"><Label htmlFor="edit_run_purpose">Run purpose</Label><Select id="edit_run_purpose" value={editFormData.run_purpose} onChange={(event) => { const runPurpose = event.target.value as PayRunPurpose; setEditFormData({ ...editFormData, run_purpose: runPurpose, includes_base_salary: runPurpose === 'regular', includes_recurring_items: runPurpose === 'regular' }); }}>{Object.entries(RUN_PURPOSE_LABELS).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</Select></div>
                    <label className="flex items-start gap-3 rounded-xl border border-neutral-200 bg-white p-3"><input type="checkbox" className="mt-1 h-4 w-4 rounded border-neutral-300 text-primary-600" checked={editFormData.includes_base_salary} disabled={editFormData.run_purpose === 'off_cycle_tips'} onChange={(event) => setEditFormData({ ...editFormData, includes_base_salary: event.target.checked })} /><span><span className="block text-sm font-semibold text-neutral-900">Include ordinary base salary</span><span className="mt-1 block text-xs leading-5 text-neutral-500">Locked after payroll is calculated.</span></span></label>
                    <label className="flex items-start gap-3 rounded-xl border border-neutral-200 bg-white p-3 sm:col-span-2"><input type="checkbox" className="mt-1 h-4 w-4 rounded border-neutral-300 text-primary-600" checked={editFormData.includes_recurring_items} onChange={(event) => setEditFormData({ ...editFormData, includes_recurring_items: event.target.checked })} /><span><span className="block text-sm font-semibold text-neutral-900">Include recurring employee setup</span><span className="mt-1 block text-xs leading-5 text-neutral-500">Includes recurring earnings, deductions, loans, retirement, employer contributions, and extra withholding. Locked after payroll is calculated.</span></span></label>
                  </div>
                  {editFormData.run_purpose === 'off_cycle_tips' && <p className="mt-3 text-xs font-medium text-primary-800">Tips-only runs exclude ordinary salary and automatic flat-fee contractor pay.</p>}
                </div>
              )}
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor="edit_start_date">Start Date</Label>
                  <Input
                    id="edit_start_date"
                    type="date"
                    value={editFormData.start_date}
                    onChange={(e) => setEditFormData({ ...editFormData, start_date: e.target.value })}
                    required
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="edit_end_date">End Date</Label>
                  <Input
                    id="edit_end_date"
                    type="date"
                    value={editFormData.end_date}
                    onChange={(e) => setEditFormData({ ...editFormData, end_date: e.target.value })}
                    required
                  />
                </div>
              </div>
              <div className="space-y-2">
                <Label htmlFor="edit_pay_date">Pay Date</Label>
                <Input
                  id="edit_pay_date"
                  type="date"
                  value={editFormData.pay_date}
                  onChange={(e) => setEditFormData({ ...editFormData, pay_date: e.target.value })}
                  required
                />
                {editingPayPeriod?.status !== 'draft' && (
                  editFormData.start_date !== editingPayPeriod?.start_date ||
                  editFormData.end_date !== editingPayPeriod?.end_date ||
                  editFormData.pay_date !== editingPayPeriod?.pay_date
                ) && (
                  <p className="text-xs text-amber-700">
                    Changing payroll dates will move this period back to draft so payroll can be recalculated with the new dates.
                  </p>
                )}
              </div>
              <div className="space-y-2">
                <Label htmlFor="edit_notes">Notes (optional)</Label>
                <Textarea
                  id="edit_notes"
                  value={editFormData.notes}
                  onChange={(e) => setEditFormData({ ...editFormData, notes: e.target.value })}
                  placeholder="Any notes about this pay period..."
                />
              </div>
            </div>
            <DialogFooter className="sticky bottom-0 -mx-4 !flex-row gap-2 border-t border-neutral-200 bg-white px-4 pb-1 sm:-mx-6 sm:px-6">
              <Button className="flex-1 sm:flex-none" type="button" variant="outline" onClick={() => handleEditOpenChange(false)}>
                Cancel
              </Button>
              <Button className="flex-1 sm:flex-none" type="submit" disabled={isEditSubmitting}>
                {isEditSubmitting ? 'Saving...' : 'Save Changes'}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  );
}
