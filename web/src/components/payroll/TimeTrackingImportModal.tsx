import { supportsSourceOperation } from '@/lib/time-tracking';
import { formatCurrency, formatDate, formatDateRange } from '@/lib/utils';
import { useCompany } from '@/contexts/CompanyContext';
import { useFeedbackState, ActionFeedback } from '@/components/ui/action-feedback';
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { AlertTriangle, CheckCircle2, Clock3, History, Link2, LoaderCircle, ShieldCheck, X } from 'lucide-react';
import { useNavigate } from 'react-router';
import { Button } from '@/components/ui/button';
import { useAuth } from '@/contexts/AuthContext';
import { ApiError, payPeriodsApi, timeTrackingSourcesApi } from '@/services/api';
import type { ExactTimeCorrectionDisposition, ExactTimeCorrectionLine, ExactTimeCorrectionPreview, TimeTrackingImportData, TimeTrackingImportResultError, TimeTrackingPreviewCategory, TimeTrackingPreviewRow, TimeTrackingSource } from '@/services/api';
import type { Employee, PayPeriod } from '@/types';

interface Props {
  open: boolean;
  onClose: () => void;
  payPeriod: PayPeriod;
  employees: Employee[];
  onImportComplete: () => void;
  onCorrectionRecorded?: () => void;
  initialSourceId?: number;
  autoPreview?: boolean;
}

type Step = 'select' | 'review' | 'done';
type WageRateMappingState = Map<string, Record<string, number | null>>;

function categoryMappingKey(category: TimeTrackingPreviewCategory): string {
  return [category.source_category_id || '', category.key || '', category.name || '', (category.source_kinds || []).join(',')].join('|');
}

function categoryHours(category: TimeTrackingPreviewCategory): number {
  return Number(category.total_hours ?? category.hours ?? 0);
}

function normalizeMatchKey(value: string | null | undefined): string {
  return (value || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

function formatHours(value: number | null | undefined): string {
  return Number(value || 0).toFixed(2);
}

function formatRate(cents: number | null | undefined): string {
  return cents == null ? 'Cornerstone rate not mapped' : `$${(cents / 100).toFixed(2)}/hr in Cornerstone`;
}

function formatTimestamp(value: string | null | undefined): string {
  if (!value) return 'Unavailable';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
}

function exclusionLabel(reason: string): string {
  return reason.replaceAll('_', ' ').replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function withReconciliationErrors(
  importData: TimeTrackingImportData,
  errors: TimeTrackingImportResultError[],
  mappings: Map<string, number | null>
): TimeTrackingImportData {
  const errorsBySourceId = new Map<string, string>();
  errors.forEach((item): void => {
    const sourceUserId = item.source_user_id || (
      item.employee_id == null
        ? undefined
        : Array.from(mappings.entries()).find(([, employeeId]): boolean => employeeId === item.employee_id)?.[0]
    );
    if (sourceUserId) errorsBySourceId.set(sourceUserId, item.error);
  });
  return {
    ...importData,
    processed_payload: {
      ...importData.processed_payload,
      rows: importData.processed_payload.rows.map((row) => {
        const message = errorsBySourceId.get(row.source_user_id);
        if (!message) return row;

        return {
          ...row,
          warnings: [
            ...(row.warnings || []).filter((warning) => warning.code !== 'reconciliation_mismatch'),
            { code: 'reconciliation_mismatch', message },
          ],
        };
      }),
    },
  };
}

export function TimeTrackingImportModal({
  open,
  onClose,
  payPeriod,
  employees,
  onImportComplete,
  onCorrectionRecorded,
  initialSourceId,
  autoPreview = false,
}: Props) {
  const { isAdmin } = useAuth();
  const { activeCompany, companies } = useCompany();
  const payrollCompany = activeCompany?.id === payPeriod.company_id
    ? activeCompany
    : companies.find((company) => company.id === payPeriod.company_id);
  const clientLabel = payrollCompany?.name || (payPeriod.company_id ? `Client #${payPeriod.company_id}` : 'This payroll’s client');
  const navigate = useNavigate();
  const [correction, setCorrection] = useState<ExactTimeCorrectionPreview | null>(null);
  const [correctionReason, setCorrectionReason] = useState('');
  const [correctionAcknowledged, setCorrectionAcknowledged] = useState(false);
  const [correctionBusy, setCorrectionBusy] = useState(false);
  const [step, setStep] = useState<Step>('select');
  const [sources, setSources] = useState<TimeTrackingSource[]>([]);
  const [sourceId, setSourceId] = useState<number | ''>('');
  const [startDate, setStartDate] = useState(payPeriod.start_date);
  const [endDate, setEndDate] = useState(payPeriod.end_date);
  const [preview, setPreview] = useState<TimeTrackingImportData | null>(null);
  const [mappings, setMappings] = useState<Map<string, number | null>>(new Map());
  const [wageRateMappings, setWageRateMappings] = useState<WageRateMappingState>(new Map());
  const [includedRows, setIncludedRows] = useState<Set<string>>(new Set());
  const [negativeAdjustmentsReviewed, setNegativeAdjustmentsReviewed] = useState(false);
  const [negativeAdjustmentNote, setNegativeAdjustmentNote] = useState('');
  const [reconciliationNote, setReconciliationNote] = useState('');
  const [loading, setLoading] = useState(false);
  const [sourcesLoading, setSourcesLoading] = useState(false);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [appliedCount, setAppliedCount] = useState(0);
  const [roundingExceptionCount, setRoundingExceptionCount] = useState(0);
  const [appliedThisSession, setAppliedThisSession] = useState(false);
  const dialogRef = useRef<HTMLDivElement>(null);
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const onCloseRef = useRef(onClose);
  const autoPreviewAttemptedRef = useRef(false);
  const requestGenerationRef = useRef(0);
  const requestScopeRef = useRef('');
  const sourceDiscoveryRef = useRef({ current: '', loaded: '' });
  const sourceDiscoveryScope = JSON.stringify([open, activeCompany?.id, initialSourceId, payPeriod.id, payPeriod.company_id,
    payPeriod.start_date, payPeriod.end_date, payPeriod.pay_date, payPeriod.status]);
  const requestScope = JSON.stringify([open, payPeriod.id, payPeriod.company_id, activeCompany?.id,
    payPeriod.start_date, payPeriod.end_date, payPeriod.pay_date, payPeriod.status, initialSourceId, sourceId, startDate, endDate]);

  useLayoutEffect(() => {
    requestScopeRef.current = requestScope;
    requestGenerationRef.current += 1;
    setCorrection(null);
    setPreview(null);
    setStep('select');
    setCorrectionReason('');
    setCorrectionAcknowledged(false);
    setCorrectionBusy(false);
    setLoading(false);
    setError(null);
    return () => {
      requestGenerationRef.current += 1;
      requestScopeRef.current = '';
    };
  }, [requestScope, setError]);

  useLayoutEffect(() => {
    sourceDiscoveryRef.current = { current: sourceDiscoveryScope, loaded: '' };
    return () => { sourceDiscoveryRef.current = { current: '', loaded: '' }; };
  }, [sourceDiscoveryScope]);

  const closeModal = useCallback(() => {
    requestGenerationRef.current += 1;
    requestScopeRef.current = '';
    sourceDiscoveryRef.current = { current: '', loaded: '' };
    onClose();
  }, [onClose]);

  useEffect(() => {
    onCloseRef.current = closeModal;
  }, [closeModal]);

  const beginScopedRequest = () => {
    const generation = ++requestGenerationRef.current;
    return () => requestGenerationRef.current === generation && requestScopeRef.current === requestScope;
  };

  useEffect(() => {
    if (!open) return;

    const previouslyFocused = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    closeButtonRef.current?.focus();
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        onCloseRef.current();
        return;
      }
      if (event.key !== 'Tab' || !dialogRef.current) return;

      const focusable = Array.from(dialogRef.current.querySelectorAll<HTMLElement>(
        'button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), a[href], summary, [tabindex]:not([tabindex="-1"])'
      ));
      if (focusable.length === 0) {
        event.preventDefault();
        dialogRef.current.focus();
        return;
      }

      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };

    document.addEventListener('keydown', handleKeyDown);
    return () => {
      document.removeEventListener('keydown', handleKeyDown);
      previouslyFocused?.focus();
    };
  }, [open]);

  useEffect(() => {
    if (!open) return;

    closeButtonRef.current?.focus();
  }, [open, step]);

  useEffect(() => {
    if (!open) return;
    let cancelled = false;

    setCorrection(null);
    setCorrectionReason('');
    setCorrectionAcknowledged(false);
    setStep('select');
    setPreview(null);
    setMappings(new Map());
    setWageRateMappings(new Map());
    setIncludedRows(new Set());
    setNegativeAdjustmentsReviewed(false);
    setNegativeAdjustmentNote('');
    setReconciliationNote('');
    setError(null);
    setStartDate(payPeriod.start_date);
    setEndDate(payPeriod.end_date);
    setAppliedCount(0);
    setRoundingExceptionCount(0);
    setAppliedThisSession(false);
    autoPreviewAttemptedRef.current = false;
    setSources([]);
    setSourceId('');
    setSourcesLoading(true);

    timeTrackingSourcesApi.list()
      .then((res) => {
        if (cancelled || sourceDiscoveryRef.current.current !== sourceDiscoveryScope) return;
        sourceDiscoveryRef.current.loaded = sourceDiscoveryScope;

        const active = res.time_tracking_sources.filter((source) => source.active);
        const eligible = payPeriod.status === 'committed'
          ? active.filter((source) => supportsSourceOperation(source, 'finalized_batch_v2'))
          : active;
        const preferred = eligible.find((source) => source.id === initialSourceId);
        setSources(eligible);
        setSourceId(preferred?.id || eligible[0]?.id || '');
      })
      .catch((err) => {
        if (!cancelled && sourceDiscoveryRef.current.current === sourceDiscoveryScope) setError(err instanceof Error ? err.message : 'Failed to load time tracking sources');
      })
      .finally(() => {
        if (!cancelled && sourceDiscoveryRef.current.current === sourceDiscoveryScope) setSourcesLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [activeCompany?.id, initialSourceId, open, payPeriod.id, payPeriod.company_id, payPeriod.start_date, payPeriod.end_date, payPeriod.pay_date, payPeriod.status, sourceDiscoveryScope, setError]);

  const selectedSource = useMemo(
    () => sources.find((source) => source.id === sourceId) || null,
    [sources, sourceId]
  );
  const selectedSourceSupportsFinalizedBatch = supportsSourceOperation(selectedSource, 'finalized_batch_v2');
  const isHistoricalReconciliation = payPeriod.status === 'committed';
  const rows = useMemo(() => preview?.processed_payload?.rows || [], [preview]);
  const isFinalizedBatch = preview?.processed_payload?.validation_version === 'payroll_batch_v2';
  const exclusions = preview?.processed_payload?.exclusions || [];
  const negativeAdjustmentCount = Number(preview?.processed_payload?.negative_adjustment_count || 0);
  const alreadyApplied = preview?.status === 'applied';
  const employeeById = useMemo(() => new Map(employees.map((employee) => [employee.id, employee])), [employees]);

  const activeWageRatesFor = (employeeId: number | null | undefined) => {
    const employee = employeeId ? employeeById.get(employeeId) : null;
    return (employee?.wage_rates || []).filter((rate) => rate.active !== false && rate.id != null);
  };

  const employeeNeedsRateMapping = (employeeId: number | null | undefined) => {
    const employee = employeeId ? employeeById.get(employeeId) : null;
    return employee?.employment_type === 'hourly' ||
      (employee?.employment_type === 'contractor' && employee.contractor_pay_type === 'hourly');
  };

  const defaultWageRateMappingFor = (row: TimeTrackingPreviewRow, employeeId: number | null, finalized: boolean) => {
    const activeRates = activeWageRatesFor(employeeId);
    const ratesByLabel = new Map(activeRates.map((rate) => [normalizeMatchKey(rate.label), rate.id ?? null]));
    const onlyRateId = !finalized && activeRates.length === 1 ? activeRates[0]?.id ?? null : null;

    return (row.categories || []).reduce<Record<string, number | null>>((acc, category) => {
      const backendMatch = activeRates.some((rate) => rate.id === category.employee_wage_rate_id) ? category.employee_wage_rate_id ?? null : null;
      const labelMatch = ratesByLabel.get(normalizeMatchKey(category.name)) ?? ratesByLabel.get(normalizeMatchKey(category.key || '')) ?? null;
      acc[categoryMappingKey(category)] = backendMatch ?? labelMatch ?? onlyRateId;
      return acc;
    }, {});
  };

  const rowCategories = (row: TimeTrackingPreviewRow) => (row.categories || []).filter((category) => (
    isFinalizedBatch ? categoryHours(category) !== 0 : categoryHours(category) > 0
  ));

  const rowWageRateMappingsComplete = (row: TimeTrackingPreviewRow) => {
    if (isHistoricalReconciliation) return true;
    const employeeId = mappings.get(row.source_user_id) || null;
    if (!employeeNeedsRateMapping(employeeId)) return true;
    const categories = rowCategories(row);
    if (categories.length === 0) return true;

    const activeRates = activeWageRatesFor(employeeId);
    if (!isFinalizedBatch && activeRates.length <= 1) return true;
    if (activeRates.length === 0) return false;
    const rowMappings = wageRateMappings.get(row.source_user_id) || {};
    return categories.every((category) => Boolean(rowMappings[categoryMappingKey(category)]));
  };

  const effectiveWarningsFor = (row: TimeTrackingPreviewRow) => (row.warnings || []).filter((warning) => {
    if (warning.code === 'unmatched_employee' && mappings.get(row.source_user_id)) return false;
    if (warning.code === 'unmapped_wage_rate' && rowWageRateMappingsComplete(row)) return false;
    if (isHistoricalReconciliation && ['negative_net_hours', 'negative_net_pay_delta'].includes(warning.code)) return false;
    return true;
  });

  const includedPreviewRows = rows.filter((row) => includedRows.has(row.source_user_id));
  const includedRegularHours = includedPreviewRows.reduce((sum, row) => sum + Number(row.regular_hours || 0), 0);
  const includedOvertimeHours = includedPreviewRows.reduce((sum, row) => sum + Number(row.overtime_hours || 0), 0);
  const heldHours = exclusions.reduce((sum, exclusion) => sum + Number(exclusion.held_total_hours || 0), 0);
  const mappedIncludedRows = includedPreviewRows.filter((row) => mappings.get(row.source_user_id));
  const includedEmployeeIds = mappedIncludedRows.map((row) => mappings.get(row.source_user_id)).filter((id): id is number => Boolean(id));
  const duplicateEmployeeIds = new Set(includedEmployeeIds.filter((id, index) => includedEmployeeIds.indexOf(id) !== index));
  const rowsNeedingWageRateMapping = mappedIncludedRows.filter((row) => !rowWageRateMappingsComplete(row));
  const rowsNeedingFrontendOnlyWageRateWarning = rowsNeedingWageRateMapping.filter((row) => !(row.warnings || []).some((warning) => warning.code === 'unmapped_wage_rate')).length;
  const warningCount = mappedIncludedRows.reduce((sum, row) => sum + effectiveWarningsFor(row).length, 0) + rowsNeedingFrontendOnlyWageRateWarning;
  const duplicateMappingCount = mappedIncludedRows.filter((row) => duplicateEmployeeIds.has(mappings.get(row.source_user_id) as number)).length;
  const excludedCount = rows.length - includedPreviewRows.length;
  const unmappedIncludedCount = includedPreviewRows.length - mappedIncludedRows.length;
  const readyRows = mappedIncludedRows.filter((row) => (
    effectiveWarningsFor(row).length === 0 &&
    rowWageRateMappingsComplete(row) &&
    !duplicateEmployeeIds.has(mappings.get(row.source_user_id) as number)
  )).length;
  const negativeReviewComplete = negativeAdjustmentCount === 0 ||
    (negativeAdjustmentsReviewed && negativeAdjustmentNote.trim().length >= 10);
  const trimmedReconciliationNote = reconciliationNote.trim();
  const reconciliationNoteTooShort = trimmedReconciliationNote.length > 0 && trimmedReconciliationNote.length < 10;
  const finalizedRowsComplete = includedPreviewRows.length === rows.length &&
    unmappedIncludedCount === 0 &&
    rowsNeedingWageRateMapping.length === 0;
  const canApply = isHistoricalReconciliation
    ? finalizedRowsComplete && duplicateEmployeeIds.size === 0 && reconciliationNote.trim().length >= 10
    : isFinalizedBatch
    ? finalizedRowsComplete && warningCount === 0 && duplicateEmployeeIds.size === 0 && negativeReviewComplete
    : mappedIncludedRows.length > 0 && warningCount === 0 && duplicateEmployeeIds.size === 0;

  const handlePreview = async () => {
    if (!selectedSource) {
      setError('Configure an active time tracking source for this client first.');
      return;
    }

    const isCurrentRequest = beginScopedRequest();
    setLoading(true);
    setError(null);
    try {
      const res = await payPeriodsApi.previewTimeTrackingImport(payPeriod.id, {
        source_id: selectedSource.id,
        start_date: selectedSourceSupportsFinalizedBatch ? payPeriod.start_date : startDate,
        end_date: selectedSourceSupportsFinalizedBatch ? payPeriod.end_date : endDate,
      });
      if (!isCurrentRequest()) return;
      const finalized = res.import.processed_payload.validation_version === 'payroll_batch_v2';
      const nextMappings = new Map<string, number | null>();
      const nextWageRateMappings: WageRateMappingState = new Map();
      const included = new Set<string>();
      (res.import.processed_payload.rows || []).forEach((row) => {
        nextMappings.set(row.source_user_id, row.employee_id);
        nextWageRateMappings.set(row.source_user_id, defaultWageRateMappingFor(row, row.employee_id, finalized));
        included.add(row.source_user_id);
      });
      setPreview(res.import);
      setMappings(nextMappings);
      setWageRateMappings(nextWageRateMappings);
      setIncludedRows(included);
      setNegativeAdjustmentsReviewed(false);
      setNegativeAdjustmentNote('');
      setStep(res.import.status === 'applied' ? 'done' : 'review');
    } catch (err) {
      if (isCurrentRequest()) setError(err instanceof Error ? err.message : 'Failed to fetch time tracking hours');
    } finally {
      if (isCurrentRequest()) setLoading(false);
    }
  };

  const handlePreviewRef = useRef(handlePreview);
  handlePreviewRef.current = handlePreview;

  useEffect(() => {
    if (!open || !autoPreview || sourcesLoading || step !== 'select' || !selectedSource || autoPreviewAttemptedRef.current || sourceDiscoveryRef.current.loaded !== sourceDiscoveryScope) return;
    if (initialSourceId && selectedSource.id !== initialSourceId) return;

    autoPreviewAttemptedRef.current = true;
    void handlePreviewRef.current();
  }, [autoPreview, initialSourceId, open, selectedSource, sourceDiscoveryScope, sourcesLoading, step]);

  const reviewCorrection = async (line: ExactTimeCorrectionLine) => {
    if (!preview) return;
    const isCurrentRequest = beginScopedRequest();
    setCorrectionBusy(true);
    setError(null);
    setCorrection(null);
    setCorrectionReason('');
    setCorrectionAcknowledged(false);
    try {
      const response = await payPeriodsApi.previewTimeTrackingCorrection(payPeriod.id, {
        import_id: preview.id, source_user_id: line.source_user_id,
        source_time_entry_id: line.source_time_entry_id, line_key: line.line_key,
      });
      if (!isCurrentRequest()) return;
      setCorrection(response.correction);
    } catch (err) {
      if (isCurrentRequest()) setError(err instanceof Error ? err.message : 'Could not review the accounting correction');
    } finally { if (isCurrentRequest()) setCorrectionBusy(false); }
  };

  const confirmCorrection = async () => {
    if (!preview || !correction) return;
    const isCurrentRequest = beginScopedRequest();
    setCorrectionBusy(true);
    setError(null);
    try {
      const response = await payPeriodsApi.confirmTimeTrackingCorrection(payPeriod.id, {
        import_id: preview.id, source_user_id: correction.source_user_id,
        source_time_entry_id: correction.source_time_entry_id, line_key: correction.line_key,
        preview_token: correction.preview_token, reason: correctionReason,
        acknowledge_accounting_only: correctionAcknowledged,
      });
      if (!isCurrentRequest()) return;
      setPreview(response.import);
      setCorrection(null);
      setIncludedRows(new Set(response.import.processed_payload.rows.map((row) => row.source_user_id)));
      setNegativeAdjustmentsReviewed(false);
      setNegativeAdjustmentNote('');
      onCorrectionRecorded?.();
    } catch (err) {
      if (isCurrentRequest()) setError(err instanceof Error ? err.message : 'Could not commit the accounting correction');
    } finally { if (isCurrentRequest()) setCorrectionBusy(false); }
  };

  const refreshCorrectionDelivery = async (disposition: ExactTimeCorrectionDisposition, retry = false) => {
    if (!preview) return;
    const isCurrentRequest = beginScopedRequest();
    setCorrectionBusy(true);
    setError(null);
    try {
      const params = { import_id: preview.id, disposition_id: disposition.id };
      const response = retry
        ? await payPeriodsApi.retryTimeTrackingCorrectionDelivery(payPeriod.id, params)
        : await payPeriodsApi.timeTrackingCorrectionDelivery(payPeriod.id, params);
      if (!isCurrentRequest()) return;
      setPreview(current => current && ({ ...current, correction_dispositions: (current.correction_dispositions || [])
        .map(row => row.id === response.disposition.id ? response.disposition : row) }));
      onCorrectionRecorded?.();
    } catch (err) {
      if (isCurrentRequest()) setError(err instanceof Error ? err.message : 'Could not refresh the source confirmation');
    } finally { if (isCurrentRequest()) setCorrectionBusy(false); }
  };

  const handleApply = async () => {
    if (!preview) return;
    const isCurrentRequest = beginScopedRequest();
    setLoading(true);
    setError(null);
    try {
      const applyMappings = rows.map((row) => {
        const employeeId = mappings.get(row.source_user_id) || null;
        const rowRateMappings = wageRateMappings.get(row.source_user_id) || {};
        return {
          source_user_id: row.source_user_id,
          employee_id: employeeId,
          include: includedRows.has(row.source_user_id) && Boolean(employeeId),
          wage_rate_mappings: (row.categories || []).map((category) => ({
            source_category_id: category.source_category_id,
            source_category_key: category.key,
            source_category_name: category.name,
            source_kind: (category.source_kinds || []).join(',') || null,
            employee_wage_rate_id: rowRateMappings[categoryMappingKey(category)] || null,
          })),
        };
      });
      const response = isHistoricalReconciliation
        ? await payPeriodsApi.reconcileTimeTrackingImport(payPeriod.id, {
          import_id: preview.id,
          mappings: applyMappings.map(({ source_user_id, employee_id }) => ({ source_user_id, employee_id })),
          reconciliation_note: reconciliationNote.trim(),
        })
        : await payPeriodsApi.applyTimeTrackingImport(payPeriod.id, {
          import_id: preview.id,
          mappings: applyMappings,
          acknowledge_negative_adjustments: negativeAdjustmentsReviewed,
          negative_adjustment_note: negativeAdjustmentNote.trim(),
        });
      if (!isCurrentRequest()) return;
      const res = 'data' in response ? response.data : response;

      if (res.results.errors.length > 0) {
        if (isHistoricalReconciliation) {
          setPreview(withReconciliationErrors(res.import, res.results.errors, mappings));
          setError(`Cornerstone could not link this time tracking record. ${res.results.errors.map((item) => item.error).join(' ')}`);
        } else {
          setError('Some rows could not be imported. Resolve the highlighted mappings and try again.');
        }
        return;
      }

      setAppliedCount('applied' in res.results ? res.results.applied.length : res.results.reconciled.length);
      setRoundingExceptionCount('rounding_exceptions' in res.results ? res.results.rounding_exceptions.length : 0);
      setAppliedThisSession(true);
      setPreview(res.import);
      setStep('done');
      onImportComplete();
    } catch (err) {
      if (!isCurrentRequest()) return;
      const message = err instanceof Error ? err.message : 'Failed to apply time tracking import';
      if (isHistoricalReconciliation && preview) {
        const payload = err instanceof ApiError && err.data && typeof err.data === 'object'
          ? err.data as { data?: { source_user_id?: string; employee_id?: number } }
          : null;
        if (payload?.data?.source_user_id || payload?.data?.employee_id != null) {
          setPreview(withReconciliationErrors(preview, [ { ...payload.data, error: message } ], mappings));
        }
        setError(`Cornerstone could not link this time tracking record. ${message}`);
      } else {
        setError(message);
      }
    } finally {
      if (isCurrentRequest()) setLoading(false);
    }
  };

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 sm:p-6">
      <button className="fixed inset-0 cursor-default bg-neutral-950/55" onClick={closeModal} aria-label="Close time import" />
      <div ref={dialogRef} tabIndex={-1} role="dialog" aria-modal="true" aria-labelledby="time-import-title" className="relative z-50 flex max-h-[94vh] w-full max-w-5xl flex-col overflow-hidden rounded-2xl border border-neutral-200 bg-white shadow-2xl outline-none">
        <header className="flex items-start justify-between gap-3 border-b border-neutral-200 px-4 py-4 sm:px-8 sm:py-6">
          <div className="min-w-0">
            <h2 id="time-import-title" className="text-lg font-semibold tracking-tight text-neutral-950 sm:text-xl">
              {isFinalizedBatch ? 'Review time tracking hours' : 'Import time tracking'}
            </h2>
            <div className="mt-2 text-sm text-neutral-700">
              <div className="break-words font-semibold text-neutral-950">{clientLabel}</div>
              <div>Work period: {formatDateRange(payPeriod.start_date, payPeriod.end_date)}</div>
              <div>Pay date: {formatDate(payPeriod.pay_date)}</div>
            </div>
            <p className="mt-2 max-w-2xl text-xs text-neutral-600">
              {isFinalizedBatch
                ? isHistoricalReconciliation
                  ? 'Link the committed payroll to this cutoff. Pay will stay unchanged.'
                  : 'Check the hours, employee links, and held entries before adding them.'
                : 'Pull approved hours from this client’s configured time tracking source.'}
            </p>
          </div>
          <button ref={closeButtonRef} onClick={closeModal} className="shrink-0 rounded-full p-2 text-neutral-500 transition hover:bg-neutral-100 hover:text-neutral-900" aria-label="Close">
            <X className="h-5 w-5" aria-hidden="true" />
          </button>
        </header>

        <div className="flex-1 space-y-4 overflow-y-auto px-4 py-4 sm:px-8 sm:py-6">
          {error && (
            <ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error}><AlertTriangle className="mt-2 h-4 w-4 shrink-0" aria-hidden="true" />
              <span>{error}</span></ActionFeedback>
          )}

          {step === 'select' && (
            <div className="space-y-6">
              {sourcesLoading ? (
                <div className="flex items-center gap-2 rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm text-neutral-600">
                  <LoaderCircle className="h-4 w-4 animate-spin" aria-hidden="true" />
                  Loading this client’s time tracking source…
                </div>
              ) : sources.length === 0 ? (
                <div className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm text-warning-900">
                  <div className="flex items-start gap-2">
                    <Link2 className="mt-2 h-4 w-4 shrink-0" aria-hidden="true" />
                    <p>No active time tracking source is configured for this client. {isAdmin ? 'Enable one in Time Tracking Source settings, then return to this pay period.' : 'Ask an administrator to configure the client’s time tracking integration.'}</p>
                  </div>
                  {isAdmin && <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    className="mt-4"
                    onClick={() => {
                      closeModal();
                      navigate('/time-tracking-sources');
                    }}
                  >
                    Configure time tracking
                  </Button>}
                </div>
              ) : (
                <>
                  {selectedSource && (
                    <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
                      <div className="text-sm font-semibold text-neutral-950">{selectedSource.name}</div>
                      <div className="mt-2 text-sm text-neutral-600">
                        {selectedSourceSupportsFinalizedBatch
                          ? 'Cornerstone will retrieve the one finalized time tracking batch that exactly matches this pay period.'
                          : 'This is the active time source configured for the client.'}
                      </div>
                    </div>
                  )}

                  {selectedSourceSupportsFinalizedBatch ? (
                    <div className="grid gap-4 sm:grid-cols-3">
                      <div className="rounded-xl border border-primary-200 bg-primary-50/60 p-4 sm:col-span-2">
                        <div className="flex items-center gap-2 text-sm font-semibold text-primary-900">
                          <ShieldCheck className="h-4 w-4" aria-hidden="true" />
                          Finalized-batch import
                        </div>
                        <p className="mt-2 text-sm leading-6 text-primary-800">
                          {isHistoricalReconciliation
                            ? 'This is a read-only reconciliation. Cornerstone will verify each employee’s regular and overtime hours before it links the records; payroll values, taxes, deductions, and checks will not change.'
                            : 'Pending, denied, and open entries remain visible as held exclusions. Late approvals and corrections arrive in a later finalized batch without changing this one.'}
                        </p>
                      </div>
                      <div className="rounded-xl border border-neutral-200 p-4">
                        <div className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Pay period</div>
                        <div className="mt-2 text-sm font-medium text-neutral-900">{payPeriod.start_date}</div>
                        <div className="text-sm text-neutral-500">through {payPeriod.end_date}</div>
                      </div>
                    </div>
                  ) : (
                    <>
                      <div className="grid gap-4 sm:grid-cols-2">
                        <label className="block text-sm font-medium text-neutral-700">
                          Start date
                          <input type="date" value={startDate} onChange={(event) => setStartDate(event.target.value)} className="mt-2 w-full rounded-xl border border-neutral-300 px-4 py-2 text-sm" />
                        </label>
                        <label className="block text-sm font-medium text-neutral-700">
                          End date
                          <input type="date" value={endDate} onChange={(event) => setEndDate(event.target.value)} className="mt-2 w-full rounded-xl border border-neutral-300 px-4 py-2 text-sm" />
                        </label>
                      </div>
                      <div className="rounded-xl border border-primary-200 bg-primary-50/60 p-4 text-sm leading-6 text-primary-800">
                        Cornerstone will fetch the surrounding full workweeks, calculate the weekly overtime split, and import only hours inside this pay period.
                      </div>
                    </>
                  )}
                </>
              )}
            </div>
          )}

          {step === 'review' && preview && (
            <div className="space-y-4">
              {isFinalizedBatch && (
                <div className="flex items-start gap-2 text-xs text-primary-900">
                  <ShieldCheck className="h-4 w-4 shrink-0" aria-hidden="true" />
                  <span><span className="font-semibold">Verified cutoff:</span> {formatTimestamp(preview.source_cutoff_at)}</span>
                </div>
              )}

              {!isHistoricalReconciliation && (preview.correction_lines || []).filter((line) => !(preview.correction_dispositions || []).some((done) => done.source_user_id === line.source_user_id && done.source_time_entry_id === line.source_time_entry_id && done.line_key === line.line_key)).map((line) => (
                <section key={`${line.source_user_id}:${line.source_time_entry_id}:${line.line_key}`} aria-label="Source accounting correction" className="rounded-xl border border-warning-200 bg-warning-50 p-4">
                  <p className="text-sm font-semibold">Review source correction: {formatHours(line.regular_hours)} REG / {formatHours(line.overtime_hours)} OT</p>
                  <p className="mt-2 text-sm">Record the correction against the original payroll before adding the remaining ordinary hours.</p>
                  <Button className="mt-3" variant="outline" disabled={loading || correctionBusy} onClick={() => void reviewCorrection(line)}>Review correction</Button>
                </section>
              ))}
              {correction && (
                <section aria-label="Confirm accounting correction" className="space-y-3 rounded-xl border border-warning-300 p-4">
                  <p className="font-semibold">{correction.employee_name} · original check {correction.original_check_number || 'unassigned'}</p>
                  <p className="text-sm">Original payroll #{correction.original_pay_period_id}, item #{correction.original_payroll_item_id}. Corrective supplemental pay date: {formatDate(correction.pay_date)}.</p>
                  <p className="text-sm">Source entry #{correction.source_time_entry_id}{correction.original_source_time_entry_version != null && correction.source_change.source_time_entry_version != null ? ` · version ${correction.original_source_time_entry_version} → ${correction.source_change.source_time_entry_version}` : ''}: {formatHours(correction.source_change.regular_hours)} REG / {formatHours(correction.source_change.overtime_hours)} OT.</p>
                  <dl className="grid grid-cols-2 gap-2 text-sm">
                    <dt>Gross</dt><dd>{formatCurrency(correction.original.gross_pay)} → {formatCurrency(correction.corrected.gross_pay)} ({formatCurrency(correction.deltas.gross_pay)})</dd>
                    <dt>Social Security delta</dt><dd>{formatCurrency(correction.deltas.social_security_tax)}</dd>
                    <dt>Medicare delta</dt><dd>{formatCurrency(correction.deltas.medicare_tax)}</dd>
                    <dt>Income tax delta</dt><dd>{formatCurrency(correction.deltas.withholding_tax)}</dd>
                    <dt>Net</dt><dd>{formatCurrency(correction.original.net_pay)} → {formatCurrency(correction.corrected.net_pay)} ({formatCurrency(correction.deltas.net_pay)})</dd>
                  </dl>
                  <p className="text-sm font-medium">Accounting correction only. The original check remains. No new payment or recovery is recorded.</p>
                  <label className="block text-sm">Reason<textarea className="mt-2 w-full rounded-lg border p-2" value={correctionReason} onChange={(event) => setCorrectionReason(event.target.value)} /></label>
                  <label className="flex items-start gap-2 text-sm"><input type="checkbox" checked={correctionAcknowledged} onChange={(event) => setCorrectionAcknowledged(event.target.checked)} />I reviewed the signed adjustment and understand no new payment or recovery is recorded.</label>
                  <Button disabled={correctionBusy || !correctionAcknowledged || correctionReason.trim().length < 10} onClick={() => void confirmCorrection()}>Confirm accounting correction</Button>
                </section>
              )}
              {(preview.correction_dispositions || []).map((done) => (
                <section key={done.id} aria-label="Accounting correction delivery" className="space-y-2 rounded-xl border border-neutral-200 bg-neutral-50 p-3 text-sm">
                  <p className="font-semibold">Recorded in Payroll supplemental #{done.corrective_pay_period_id}, item #{done.corrective_payroll_item_id}: {formatHours(done.total_hours)} hours.</p>
                  <p>No new payment or recovery recorded. The accounting entry is already posted; refresh or retry only its source confirmation.</p>
                  {done.source_receipt?.status === 'confirmed' ? (
                    <p className="font-medium text-success-800">Source confirmation verified · {formatTimestamp(done.source_receipt.confirmed_at)}</p>
                  ) : done.source_receipt?.status === 'error' ? (
                    <div className="rounded-lg border border-warning-200 bg-warning-50 p-2 text-warning-900">
                      <p className="font-semibold">Source confirmation needs attention.</p>
                      <p>{done.source_receipt.error || 'The exact accounting receipt could not be verified.'}</p>
                    </div>
                  ) : <p className="text-neutral-700">Source confirmation pending.{done.source_receipt?.queued_at ? ` Queued ${formatTimestamp(done.source_receipt.queued_at)}.` : ''}</p>}
                  <div className="flex flex-wrap gap-2">
                    <Button variant="outline" size="sm" disabled={loading || correctionBusy} onClick={() => void refreshCorrectionDelivery(done)}>Refresh source confirmation</Button>
                    {done.source_receipt?.can_retry && <Button variant="outline" size="sm" disabled={loading || correctionBusy} onClick={() => void refreshCorrectionDelivery(done, true)}>Retry source confirmation</Button>}
                  </div>
                </section>
              ))}
              <section aria-label="Hours included in this review" className="rounded-xl border border-neutral-200 bg-neutral-50 p-3">
                <div className="grid grid-cols-2 gap-3">
                  <div>
                    <div className="text-xs font-medium text-neutral-600">Regular hours</div>
                    <div className="mt-1 font-mono text-lg font-semibold text-neutral-950">{formatHours(includedRegularHours)}</div>
                  </div>
                  <div>
                    <div className="text-xs font-medium text-neutral-600">Overtime hours</div>
                    <div className="mt-1 font-mono text-lg font-semibold text-neutral-950">{formatHours(includedOvertimeHours)}</div>
                  </div>
                </div>
                <p className="mt-2 text-xs text-neutral-600">
                  {includedPreviewRows.length} included · {readyRows} ready
                  {excludedCount > 0 && ` · ${excludedCount} skipped`}
                  {unmappedIncludedCount > 0 && ` · ${unmappedIncludedCount} unmapped`}
                  {warningCount > 0 && ` · ${warningCount} warning${warningCount === 1 ? '' : 's'}`}
                </p>
                {!isFinalizedBatch && <p className="mt-1 text-xs text-neutral-500">OT window: {formatDateRange(preview.fetch_start_date, preview.fetch_end_date)}</p>}
              </section>

              {isFinalizedBatch && exclusions.length > 0 && (
                <p className="rounded-lg border border-warning-200 bg-warning-50 px-3 py-2 text-xs text-warning-900">
                  <span className="font-semibold">{exclusions.length} held {exclusions.length === 1 ? 'entry' : 'entries'} · {formatHours(heldHours)} held hours at cutoff.</span> See held entries below; they will not be added to this payroll.
                </p>
              )}

              {(warningCount > 0 || unmappedIncludedCount > 0 || duplicateMappingCount > 0 || rowsNeedingWageRateMapping.length > 0) && (
                <div className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm leading-6 text-warning-900">
                  {isFinalizedBatch
                    ? 'Resolve every employee and earning-type mapping before applying. Finalized time tracking rows cannot be skipped; the source’s exclusions are shown separately and are not added to this payroll.'
                    : 'Resolve included employee and earning-type mappings before applying. Ordinary import rows may be skipped when they should not be added to this payroll.'}
                </div>
              )}

              <div className="space-y-4">
                {rows.length === 0 && (
                  <div className="rounded-2xl border border-neutral-200 bg-neutral-50 p-6 text-center">
                    <CheckCircle2 className="mx-auto h-6 w-6 text-success-600" aria-hidden="true" />
                    <div className="mt-2 font-semibold text-neutral-900">No payable employee adjustments</div>
                    <p className="mt-2 text-sm text-neutral-600">
                      {isFinalizedBatch
                        ? 'This finalized batch can still be recorded as applied, preserving its cutoff and exclusions.'
                        : 'This source returned no payable rows for the selected dates. No employee hours need to be applied.'}
                    </p>
                  </div>
                )}

                {rows.map((row) => {
                  const included = includedRows.has(row.source_user_id);
                  const mappedEmployeeId = mappings.get(row.source_user_id) || null;
                  const mapped = Boolean(mappedEmployeeId);
                  const duplicateMapping = mappedEmployeeId != null && duplicateEmployeeIds.has(mappedEmployeeId);
                  const effectiveWarnings = effectiveWarningsFor(row);
                  const activeWageRates = activeWageRatesFor(mappedEmployeeId);
                  const categories = rowCategories(row);
                  const lacksActiveWageRates = Boolean(!isHistoricalReconciliation && isFinalizedBatch && included && mapped &&
                    employeeNeedsRateMapping(mappedEmployeeId) && categories.length > 0 && activeWageRates.length === 0);
                  const needsRateMapping = !isHistoricalReconciliation && included && mapped && employeeNeedsRateMapping(mappedEmployeeId) && categories.length > 0 &&
                    (isFinalizedBatch || activeWageRates.length > 1);
                  const rowRateMappings = wageRateMappings.get(row.source_user_id) || {};

                  return (
                    <article key={row.source_user_id} className={`rounded-2xl border p-4 sm:p-6 ${!included ? 'border-neutral-200 bg-neutral-50 opacity-70' : effectiveWarnings.length || !mapped || duplicateMapping ? 'border-warning-200 bg-warning-50/40' : 'border-neutral-200 bg-white'}`}>
                      <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                        <div className="min-w-0 flex-1">
                          <div className="flex flex-wrap items-center gap-2">
                            {!isFinalizedBatch && (
                              <label className="inline-flex items-center gap-2 text-xs font-semibold text-neutral-700">
                                <input
                                  type="checkbox"
                                  checked={included}
                                  onChange={(event) => setIncludedRows((previous) => {
                                    const next = new Set(previous);
                                    if (event.target.checked) next.add(row.source_user_id); else next.delete(row.source_user_id);
                                    return next;
                                  })}
                                  className="rounded border-neutral-300"
                                />
                                Include
                              </label>
                            )}
                            <h3 className="font-semibold text-neutral-950">{row.source_display_name}</h3>
                            {Object.entries(row.source_kind_counts || {}).map(([kind, count]) => Number(count) > 0 && (
                              <span key={kind} className="rounded-full bg-neutral-100 px-2 text-[11px] font-semibold capitalize text-neutral-700">{kind} {count}</span>
                            ))}
                          </div>
                          {row.source_email && <div className="mt-2 text-xs text-neutral-500">{row.source_email}</div>}

                          <div className="mt-4 grid grid-cols-3 gap-2 sm:max-w-md">
                            <div className="rounded-lg bg-neutral-50 p-2">
                              <div className="text-[11px] font-semibold uppercase tracking-wide text-neutral-500">Regular</div>
                              <div className="mt-2 font-mono text-sm text-neutral-900">{formatHours(row.regular_hours)}</div>
                            </div>
                            <div className="rounded-lg bg-neutral-50 p-2">
                              <div className="text-[11px] font-semibold uppercase tracking-wide text-neutral-500">Overtime</div>
                              <div className="mt-2 font-mono text-sm text-neutral-900">{formatHours(row.overtime_hours)}</div>
                            </div>
                            <div className="rounded-lg bg-neutral-50 p-2">
                              <div className="text-[11px] font-semibold uppercase tracking-wide text-neutral-500">Total</div>
                              <div className="mt-2 font-mono text-sm font-semibold text-neutral-950">{formatHours(row.total_hours)}</div>
                            </div>
                          </div>
                          {isFinalizedBatch && !isHistoricalReconciliation && row.estimated_gross_delta != null && (
                            <div className="mt-2 text-xs font-medium text-neutral-600">
                              Estimated Cornerstone gross adjustment: <span className="font-mono text-neutral-900">{formatCurrency(row.estimated_gross_delta)}</span>
                            </div>
                          )}
                        </div>

                        <label className="block min-w-0 text-sm font-medium text-neutral-700 lg:w-72">
                          Payroll employee
                          <select
                            value={mappedEmployeeId ?? ''}
                            onChange={(event) => {
                              const nextEmployeeId = event.target.value ? Number(event.target.value) : null;
                              setMappings((previous) => new Map(previous).set(row.source_user_id, nextEmployeeId));
                              setWageRateMappings((previous) => {
                                const next = new Map(previous);
                                next.set(row.source_user_id, defaultWageRateMappingFor(row, nextEmployeeId, Boolean(isFinalizedBatch)));
                                return next;
                              });
                            }}
                            disabled={!included}
                            className="mt-2 w-full rounded-xl border border-neutral-300 bg-white px-4 py-2 text-sm disabled:bg-neutral-100"
                          >
                            <option value="">Select employee</option>
                            {employees.map((employee) => (
                              <option key={employee.id} value={employee.id}>{[employee.first_name, employee.last_name].filter(Boolean).join(' ')}</option>
                            ))}
                          </select>
                          <span className="mt-2 block text-xs font-normal text-neutral-500">
                            {row.match_method === 'saved_mapping'
                              ? 'Confirmed saved link'
                              : row.suggested_employee_name
                                ? `Suggestion: ${row.suggested_employee_name} · same ${row.suggestion_method || 'identity'} · confirm before importing`
                                : 'No confirmed payroll link'}
                          </span>
                        </label>
                      </div>

                      {categories.length > 0 && (
                        <div className="mt-4 border-t border-neutral-200 pt-4">
                          <div className="text-xs font-semibold uppercase tracking-wide text-neutral-500">
                            {isHistoricalReconciliation ? 'time tracking earning breakdown' : 'Payable earning dimensions'}
                          </div>
                          <div className="mt-2 grid gap-2 lg:grid-cols-2">
                            {categories.map((category) => {
                              const selectedRateId = rowRateMappings[categoryMappingKey(category)] ?? category.employee_wage_rate_id;
                              const selectedRate = activeWageRates.find((rate) => rate.id === selectedRateId);
                              const selectedRateCents = selectedRate
                                ? Math.round(Number(selectedRate.rate || 0) * 100)
                                : category.payroll_rate_cents;

                              return (
                              <div key={categoryMappingKey(category)} className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
                                <div className="flex flex-wrap items-start justify-between gap-2">
                                  <div>
                                    <div className="text-sm font-semibold text-neutral-900">{category.name}</div>
                                    <div className="mt-2 text-xs text-neutral-500">
                                      {!isHistoricalReconciliation && <>{formatRate(selectedRateCents)} · </>}
                                      {formatHours(category.regular_hours)} reg / {formatHours(category.overtime_hours)} OT
                                    </div>
                                  </div>
                                  {(category.source_kinds || []).map((kind) => (
                                    <span key={kind} className="rounded-full bg-white px-2 text-[10px] font-semibold capitalize text-neutral-600">{kind}</span>
                                  ))}
                                </div>
                                {needsRateMapping && lacksActiveWageRates && (
                                  <p className="mt-4 rounded-lg border border-warning-200 bg-warning-50 p-2 text-xs font-medium text-warning-900">
                                    Add an active wage rate for this employee before applying the finalized batch.
                                  </p>
                                )}
                                {needsRateMapping && !lacksActiveWageRates && (
                                  <label className="mt-4 block text-xs font-medium text-neutral-700">
                                    Payroll earning type
                                    <select
                                      value={rowRateMappings[categoryMappingKey(category)] ?? ''}
                                      onChange={(event) => setWageRateMappings((previous) => {
                                        const next = new Map(previous);
                                        next.set(row.source_user_id, {
                                          ...(next.get(row.source_user_id) || {}),
                                          [categoryMappingKey(category)]: event.target.value ? Number(event.target.value) : null,
                                        });
                                        return next;
                                      })}
                                      className="mt-2 w-full rounded-lg border border-neutral-300 bg-white px-2 py-2 text-xs"
                                    >
                                      <option value="">Select earning type</option>
                                      {activeWageRates.map((rate) => (
                                        <option key={rate.id} value={rate.id}>{rate.label} (${Number(rate.rate || 0).toFixed(2)}/hr)</option>
                                      ))}
                                    </select>
                                  </label>
                                )}
                              </div>
                              );
                            })}
                          </div>
                        </div>
                      )}

                      <div className="mt-4 flex flex-wrap items-center gap-2">
                        {!included ? (
                          <span className="rounded-full bg-neutral-100 px-2 py-2 text-xs font-semibold text-neutral-700">Skipped</span>
                        ) : !mapped ? (
                          <span className="rounded-full bg-warning-100 px-2 py-2 text-xs font-semibold text-warning-900">Employee mapping required</span>
                        ) : duplicateMapping ? (
                          <span className="rounded-full bg-danger-100 px-2 py-2 text-xs font-semibold text-danger-800">Duplicate payroll employee</span>
                        ) : lacksActiveWageRates ? (
                          <span className="rounded-full bg-warning-100 px-2 py-2 text-xs font-semibold text-warning-900">Active wage rate required</span>
                        ) : !rowWageRateMappingsComplete(row) ? (
                          <span className="rounded-full bg-warning-100 px-2 py-2 text-xs font-semibold text-warning-900">Earning type mapping required</span>
                        ) : effectiveWarnings.length > 0 ? (
                          effectiveWarnings.map((warning, index) => (
                            <span key={`${warning.code}-${index}`} className="rounded-full bg-warning-100 px-2 py-2 text-xs font-semibold text-warning-900">{warning.message}</span>
                          ))
                        ) : (
                          <span className="inline-flex items-center gap-2 rounded-full bg-success-100 px-2 py-2 text-xs font-semibold text-success-800">
                            <CheckCircle2 className="h-3.5 w-3.5" aria-hidden="true" /> Ready
                          </span>
                        )}
                      </div>
                    </article>
                  );
                })}
              </div>

              {isFinalizedBatch && exclusions.length > 0 && (
                <section className="rounded-2xl border border-neutral-200 bg-neutral-50 p-4 sm:p-6">
                  <div className="flex items-center gap-2">
                    <Clock3 className="h-4 w-4 text-neutral-600" aria-hidden="true" />
                    <h3 className="font-semibold text-neutral-950">Held entries outside this payroll</h3>
                  </div>
                  <p className="mt-2 text-sm text-neutral-600">These entries remain in time tracking for follow-up. Each reason explains why the entry is outside this payroll.</p>
                  <div className="mt-4 grid gap-2 lg:grid-cols-2">
                    {exclusions.map((exclusion) => (
                      <div key={`${exclusion.source_time_entry_id}-${exclusion.reason}`} className="rounded-xl border border-neutral-200 bg-white p-4">
                        <div className="flex items-start justify-between gap-4">
                          <div>
                            <div className="text-sm font-semibold text-neutral-900">{exclusion.display_name || exclusion.source_user_id}</div>
                            <div className="mt-2 text-xs text-neutral-500">{exclusion.original_work_date} · {exclusion.category?.name || 'Uncategorized'}</div>
                          </div>
                          <span className="rounded-full bg-neutral-100 px-2 text-[11px] font-semibold text-neutral-700">{exclusionLabel(exclusion.reason)}</span>
                        </div>
                        <div className="mt-2 text-xs text-neutral-600">{formatHours(exclusion.held_total_hours)} held hours at cutoff</div>
                      </div>
                    ))}
                  </div>
                </section>
              )}

              {isFinalizedBatch && (
                <details className="rounded-xl border border-neutral-200 bg-neutral-50 text-sm">
                  <summary className="cursor-pointer rounded-xl px-4 py-3 font-medium text-neutral-700 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-600">
                    Batch audit details
                  </summary>
                  <dl className="grid min-w-0 gap-4 border-t border-neutral-200 p-4 sm:grid-cols-2">
                    <div className="min-w-0">
                      <dt className="text-xs font-semibold text-neutral-500">Batch ID</dt>
                      <dd className="mt-1 break-all font-mono text-xs text-neutral-950">{preview.external_batch_id || 'Unavailable'}</dd>
                    </div>
                    <div>
                      <dt className="text-xs font-semibold text-neutral-500">Contract version</dt>
                      <dd className="mt-1 break-all text-neutral-950">{preview.contract_version || 'Unavailable'}</dd>
                    </div>
                    <div>
                      <dt className="text-xs font-semibold text-neutral-500">Cutoff</dt>
                      <dd className="mt-1 text-neutral-950">{formatTimestamp(preview.source_cutoff_at)}</dd>
                    </div>
                    <div>
                      <dt className="text-xs font-semibold text-neutral-500">Finalized</dt>
                      <dd className="mt-1 text-neutral-950">{formatTimestamp(preview.processed_payload.finalized_at)}</dd>
                    </div>
                    <div className="min-w-0 sm:col-span-2">
                      <dt className="text-xs font-semibold text-neutral-500">SHA-256</dt>
                      <dd className="mt-1 break-all font-mono text-xs leading-5 text-neutral-950">{preview.external_batch_checksum || 'Unavailable'}</dd>
                    </div>
                  </dl>
                </details>
              )}

              {isFinalizedBatch && !isHistoricalReconciliation && negativeAdjustmentCount > 0 && (
                <section className="rounded-2xl border border-warning-300 bg-warning-50 p-4 sm:p-6">
                  <div className="flex items-center gap-2 font-semibold text-warning-950">
                    <History className="h-4 w-4" aria-hidden="true" />
                    Negative corrections require review
                  </div>
                  <p className="mt-2 text-sm leading-6 text-warning-900">
                    This batch contains {negativeAdjustmentCount} negative adjustment{negativeAdjustmentCount === 1 ? '' : 's'}. Confirm that the reversals and replacement lines are expected before applying them.
                  </p>
                  <label className="mt-4 flex items-start gap-4 text-sm font-medium text-warning-950">
                    <input type="checkbox" checked={negativeAdjustmentsReviewed} onChange={(event) => setNegativeAdjustmentsReviewed(event.target.checked)} className="mt-2 rounded border-warning-400" />
                    I reviewed the negative corrections and their replacement lines.
                  </label>
                  <label className="mt-4 block text-sm font-medium text-warning-950">
                    Review note
                    <textarea
                      value={negativeAdjustmentNote}
                      onChange={(event) => setNegativeAdjustmentNote(event.target.value)}
                      rows={3}
                      placeholder="Describe what you verified (minimum 10 characters)"
                      className="mt-2 w-full rounded-xl border border-warning-300 bg-white px-4 py-2 text-sm text-neutral-900"
                    />
                  </label>
                </section>
              )}

              {isHistoricalReconciliation && (
                <section className="rounded-2xl border border-primary-200 bg-primary-50/50 p-4 sm:p-6">
                  <div className="flex items-center gap-2 font-semibold text-primary-950">
                    <History className="h-4 w-4" aria-hidden="true" /> Historical reconciliation note
                  </div>
                  <p className="mt-2 text-sm leading-6 text-primary-800">Explain what was compared. Cornerstone will refuse the link if any mapped employee’s regular or overtime hours differ from time tracking.</p>
                  <label htmlFor="reconciliation-note" className="mt-4 block text-sm font-medium text-primary-950">
                    Audit note
                  </label>
                  <textarea
                    id="reconciliation-note"
                    value={reconciliationNote}
                    onChange={(event) => setReconciliationNote(event.target.value)}
                    rows={3}
                    minLength={10}
                    aria-describedby="reconciliation-note-help"
                    aria-invalid={reconciliationNoteTooShort}
                    placeholder="Example: Compared committed Aug 1–15 payroll to finalized time tracking cutoff"
                    className="mt-2 w-full rounded-xl border border-primary-300 bg-white px-4 py-4 text-sm text-neutral-900"
                  />
                  <p id="reconciliation-note-help" className={`mt-2 text-xs ${reconciliationNoteTooShort ? 'text-danger-700' : 'text-primary-700'}`}>
                    {reconciliationNoteTooShort ? 'Enter at least 10 characters before linking the records.' : 'Required: briefly explain what records you compared (minimum 10 characters).'}
                  </p>
                </section>
              )}
            </div>
          )}

          {step === 'done' && (
            <div className="py-10 text-center">
              <CheckCircle2 className="mx-auto h-12 w-12 text-success-600" aria-hidden="true" />
              <h3 className="mt-4 text-lg font-semibold text-neutral-950">
                {!appliedThisSession && alreadyApplied ? 'These time tracking hours are already linked' : isHistoricalReconciliation ? 'Historical payroll linked' : isFinalizedBatch ? 'Time tracking hours added to payroll' : 'Time tracking imported'}
              </h3>
              <p className="mt-2 text-sm text-neutral-600">
                {!appliedThisSession && alreadyApplied
                  ? `Cornerstone recorded this batch on ${formatTimestamp(preview?.applied_at)}. Its hours were not imported again.`
                  : isHistoricalReconciliation
                  ? `${appliedCount} employee record${appliedCount === 1 ? '' : 's'} reconciled. No payroll amounts were changed.${roundingExceptionCount > 0 ? ` ${roundingExceptionCount} documented legacy rounding exception${roundingExceptionCount === 1 ? ' was' : 's were'} recorded.` : ''}`
                  : appliedCount === 0
                  ? isFinalizedBatch
                    ? 'The empty finalized batch and its audit evidence were recorded without adding employee hours.'
                    : 'No employee rows were applied. This can be valid when every ordinary import row was skipped.'
                  : `${appliedCount} employee row${appliedCount === 1 ? '' : 's'} applied. Run payroll to calculate taxes and deductions.`}
              </p>
              {isFinalizedBatch && (
                <div className="mx-auto mt-5 max-w-xl rounded-xl border border-primary-200 bg-primary-50/60 p-4 text-left text-sm leading-6 text-primary-900">
                  <div className="font-semibold">What happens next</div>
                  <p className="mt-1">
                    {isHistoricalReconciliation
                      ? 'Cornerstone recorded the existing payroll link and is delivering the acknowledgement to time tracking. If delivery is interrupted, it will retry automatically until confirmed. Payment is reported separately only when the check is prepared and then delivered.'
                      : 'Cornerstone queues an import acknowledgement for time tracking. When this payroll is committed, Cornerstone sends a separate committed status. Importing hours does not by itself mean payment was issued.'}
                  </p>
                  {preview?.source_processing_sync_error && <p className="mt-2 text-danger-700">Time tracking status delivery is retrying automatically: {preview.source_processing_sync_error}</p>}
                </div>
              )}
            </div>
          )}
        </div>

        <footer className="flex flex-col-reverse gap-3 border-t border-neutral-200 bg-neutral-50 px-4 py-3 sm:flex-row sm:justify-end sm:px-8">
          {step === 'select' && (
            <>
              <Button variant="outline" onClick={closeModal}>Cancel</Button>
              <Button onClick={handlePreview} disabled={loading || !sourceId || sources.length === 0}>{loading ? 'Retrieving…' : selectedSourceSupportsFinalizedBatch ? 'Retrieve Finalized Batch' : 'Fetch Hours'}</Button>
            </>
          )}
          {step === 'review' && (
            <>
              <Button variant="outline" onClick={() => setStep('select')}>Back</Button>
              <Button onClick={handleApply} disabled={loading || correctionBusy || !canApply}>{loading ? 'Saving…' : isHistoricalReconciliation ? 'Verify & Link time tracking Record' : isFinalizedBatch ? 'Add time tracking Hours to Payroll' : 'Apply Import'}</Button>
            </>
          )}
          {step === 'done' && <Button onClick={closeModal}>Close</Button>}
        </footer>
      </div>
    </div>
  );
}
