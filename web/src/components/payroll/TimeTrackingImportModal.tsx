import { useEffect, useMemo, useRef, useState } from 'react';
import { AlertTriangle, CheckCircle2, Clock3, History, Link2, LoaderCircle, ShieldCheck, X } from 'lucide-react';
import { useNavigate } from 'react-router';
import { Button } from '@/components/ui/button';
import { payPeriodsApi, timeTrackingSourcesApi } from '@/services/api';
import type { TimeTrackingImportData, TimeTrackingPreviewCategory, TimeTrackingPreviewRow, TimeTrackingSource } from '@/services/api';
import type { Employee, PayPeriod } from '@/types';

interface Props {
  open: boolean;
  onClose: () => void;
  payPeriod: PayPeriod;
  employees: Employee[];
  onImportComplete: () => void;
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

export function TimeTrackingImportModal({ open, onClose, payPeriod, employees, onImportComplete }: Props) {
  const navigate = useNavigate();
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
  const [error, setError] = useState<string | null>(null);
  const [appliedCount, setAppliedCount] = useState(0);
  const [appliedThisSession, setAppliedThisSession] = useState(false);
  const dialogRef = useRef<HTMLDivElement>(null);
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const onCloseRef = useRef(onClose);

  useEffect(() => {
    onCloseRef.current = onClose;
  }, [onClose]);

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
        'button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), a[href], [tabindex]:not([tabindex="-1"])'
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
    setAppliedThisSession(false);
    setSources([]);
    setSourceId('');
    setSourcesLoading(true);

    timeTrackingSourcesApi.list()
      .then((res) => {
        const active = res.time_tracking_sources.filter((source) => source.active);
        const eligible = payPeriod.status === 'committed'
          ? active.filter((source) => source.source_type === 'aire_services')
          : active;
        setSources(eligible);
        setSourceId(eligible[0]?.id || '');
      })
      .catch((err) => setError(err instanceof Error ? err.message : 'Failed to load time tracking sources'))
      .finally(() => setSourcesLoading(false));
  }, [open, payPeriod.start_date, payPeriod.end_date, payPeriod.status]);

  const selectedSource = useMemo(
    () => sources.find((source) => source.id === sourceId) || null,
    [sources, sourceId]
  );
  const selectedSourceIsAire = selectedSource?.source_type === 'aire_services';
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

    setLoading(true);
    setError(null);
    try {
      const res = await payPeriodsApi.previewTimeTrackingImport(payPeriod.id, {
        source_id: selectedSource.id,
        start_date: selectedSource.source_type === 'aire_services' ? payPeriod.start_date : startDate,
        end_date: selectedSource.source_type === 'aire_services' ? payPeriod.end_date : endDate,
      });
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
      setError(err instanceof Error ? err.message : 'Failed to fetch time tracking hours');
    } finally {
      setLoading(false);
    }
  };

  const handleApply = async () => {
    if (!preview) return;
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
      const res = isHistoricalReconciliation
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

      if (res.results.errors.length > 0) {
        setError('Some rows could not be imported. Resolve the highlighted mappings and try again.');
        return;
      }

      setAppliedCount('applied' in res.results ? res.results.applied.length : res.results.reconciled.length);
      setAppliedThisSession(true);
      setPreview(res.import);
      setStep('done');
      onImportComplete();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to apply time tracking import');
    } finally {
      setLoading(false);
    }
  };

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 sm:p-6">
      <button className="fixed inset-0 cursor-default bg-neutral-950/55" onClick={onClose} aria-label="Close time import" />
      <div ref={dialogRef} tabIndex={-1} role="dialog" aria-modal="true" aria-labelledby="time-import-title" className="relative z-50 flex max-h-[94vh] w-full max-w-5xl flex-col overflow-hidden rounded-2xl border border-neutral-200 bg-white shadow-2xl outline-none">
        <header className="flex items-start justify-between gap-4 border-b border-neutral-200 px-6 py-4 sm:px-8 sm:py-6">
          <div>
            <h2 id="time-import-title" className="text-lg font-semibold tracking-tight text-neutral-950 sm:text-xl">
              {isFinalizedBatch ? 'Review finalized AIRE batch' : 'Import time tracking'}
            </h2>
            <p className="mt-2 max-w-2xl text-sm text-neutral-600">
              {isFinalizedBatch
                ? isHistoricalReconciliation
                  ? 'Link this committed payroll to its immutable AIRE cutoff without recalculating or changing any pay.'
                  : 'Verify the immutable cutoff, employee mappings, and any corrections before adding the batch to this payroll.'
                : 'Pull approved hours from this client’s configured time tracking source.'}
            </p>
          </div>
          <button ref={closeButtonRef} onClick={onClose} className="rounded-full p-2 text-neutral-500 transition hover:bg-neutral-100 hover:text-neutral-900" aria-label="Close">
            <X className="h-5 w-5" aria-hidden="true" />
          </button>
        </header>

        <div className="flex-1 space-y-6 overflow-y-auto px-6 py-6 sm:px-8">
          {error && (
            <div className="flex gap-4 rounded-xl border border-danger-200 bg-danger-50 p-4 text-sm text-danger-800" role="alert">
              <AlertTriangle className="mt-2 h-4 w-4 shrink-0" aria-hidden="true" />
              <span>{error}</span>
            </div>
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
                    <p>{isHistoricalReconciliation ? 'No active AIRE time tracking source is configured for this client.' : 'No active time tracking source is configured for this client.'} Add one in Time Tracking Source settings, then return to this pay period.</p>
                  </div>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    className="mt-4"
                    onClick={() => {
                      onClose();
                      navigate('/time-tracking-sources');
                    }}
                  >
                    Configure time tracking
                  </Button>
                </div>
              ) : (
                <>
                  {selectedSource && (
                    <div className="rounded-xl border border-neutral-200 bg-neutral-50 p-4">
                      <div className="text-sm font-semibold text-neutral-950">{selectedSource.name}</div>
                      <div className="mt-2 text-sm text-neutral-600">
                        {selectedSourceIsAire
                          ? 'Cornerstone will retrieve the one finalized AIRE batch that exactly matches this pay period.'
                          : 'This is the active time source configured for the client.'}
                      </div>
                    </div>
                  )}

                  {selectedSourceIsAire ? (
                    <div className="grid gap-4 sm:grid-cols-3">
                      <div className="rounded-xl border border-primary-200 bg-primary-50/60 p-4 sm:col-span-2">
                        <div className="flex items-center gap-2 text-sm font-semibold text-primary-900">
                          <ShieldCheck className="h-4 w-4" aria-hidden="true" />
                          Finalized-batch import
                        </div>
                        <p className="mt-2 text-sm leading-6 text-primary-800">
                          {isHistoricalReconciliation
                            ? 'This is a read-only reconciliation. Cornerstone will verify each employee’s regular and overtime hours before it links the records; payroll values, taxes, deductions, and checks will not change.'
                            : 'Pending, denied, and open entries remain visible as unpaid exclusions. Late approvals and corrections arrive in a later finalized batch without changing this one.'}
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
            <div className="space-y-6">
              {isFinalizedBatch && (
                <section className="rounded-2xl border border-primary-200 bg-primary-50/50 p-4 sm:p-6">
                  <div className="flex items-center gap-2 text-sm font-semibold text-primary-950">
                    <ShieldCheck className="h-4 w-4" aria-hidden="true" />
                    Integrity verified
                  </div>
                  <div className="mt-4 grid gap-4 text-sm sm:grid-cols-2 lg:grid-cols-4">
                    <div>
                      <div className="text-xs font-semibold uppercase tracking-wide text-primary-700">Batch ID</div>
                      <div className="mt-2 break-all font-mono text-xs text-primary-950">{preview.external_batch_id}</div>
                    </div>
                    <div>
                      <div className="text-xs font-semibold uppercase tracking-wide text-primary-700">Cutoff</div>
                      <div className="mt-2 text-primary-950">{formatTimestamp(preview.source_cutoff_at)}</div>
                    </div>
                    <div>
                      <div className="text-xs font-semibold uppercase tracking-wide text-primary-700">Contract</div>
                      <div className="mt-2 text-primary-950">AIRE payroll batch v{preview.contract_version}</div>
                    </div>
                    <div>
                      <div className="text-xs font-semibold uppercase tracking-wide text-primary-700">SHA-256</div>
                      <div className="mt-2 break-all font-mono text-[11px] leading-4 text-primary-950">{preview.external_batch_checksum}</div>
                    </div>
                  </div>
                </section>
              )}

              <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
                <span className="text-neutral-600">
                  {includedPreviewRows.length} included · {excludedCount} skipped · {readyRows} ready · {unmappedIncludedCount} unmapped · {warningCount} warning{warningCount === 1 ? '' : 's'}
                </span>
                <span className="text-xs text-neutral-500">
                  {isFinalizedBatch ? `Finalized ${formatTimestamp(preview.processed_payload.finalized_at)}` : `OT window: ${preview.fetch_start_date} → ${preview.fetch_end_date}`}
                </span>
              </div>

              {(warningCount > 0 || unmappedIncludedCount > 0 || duplicateMappingCount > 0 || rowsNeedingWageRateMapping.length > 0) && (
                <div className="rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm leading-6 text-warning-900">
                  {isFinalizedBatch
                    ? 'Resolve every employee and earning-type mapping before applying. Finalized AIRE rows cannot be skipped; AIRE’s exclusions are shown separately and remain unpaid.'
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
                              Estimated Cornerstone gross adjustment: <span className="font-mono text-neutral-900">${Number(row.estimated_gross_delta).toFixed(2)}</span>
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
                          <span className="mt-2 block text-xs font-normal text-neutral-500">{row.match_method} match · {Math.round((row.match_score || 0) * 100)}%</span>
                        </label>
                      </div>

                      {categories.length > 0 && (
                        <div className="mt-4 border-t border-neutral-200 pt-4">
                          <div className="text-xs font-semibold uppercase tracking-wide text-neutral-500">
                            {isHistoricalReconciliation ? 'AIRE earning breakdown' : 'Payable earning dimensions'}
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
                    <h3 className="font-semibold text-neutral-950">Tracked but not paid in this batch</h3>
                  </div>
                  <p className="mt-2 text-sm text-neutral-600">These entries stay in AIRE. A later approval can appear as a carryover in a future finalized batch.</p>
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
                        <div className="mt-2 text-xs text-neutral-600">{formatHours(exclusion.held_total_hours)} held hours</div>
                      </div>
                    ))}
                  </div>
                </section>
              )}

              {isFinalizedBatch && negativeAdjustmentCount > 0 && (
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
                  <p className="mt-2 text-sm leading-6 text-primary-800">Explain what was compared. Cornerstone will refuse the link if any mapped employee’s regular or overtime hours differ from AIRE.</p>
                  <label className="mt-4 block text-sm font-medium text-primary-950">
                    Audit note
                    <textarea value={reconciliationNote} onChange={(event) => setReconciliationNote(event.target.value)} rows={3} placeholder="Example: Compared committed Aug 1–15 payroll to finalized AIRE cutoff" className="mt-2 w-full rounded-xl border border-primary-300 bg-white px-4 py-3 text-sm text-neutral-900" />
                  </label>
                </section>
              )}
            </div>
          )}

          {step === 'done' && (
            <div className="py-10 text-center">
              <CheckCircle2 className="mx-auto h-12 w-12 text-success-600" aria-hidden="true" />
              <h3 className="mt-4 text-lg font-semibold text-neutral-950">
                {!appliedThisSession && alreadyApplied ? 'This finalized batch was already linked' : isHistoricalReconciliation ? 'Historical payroll linked' : isFinalizedBatch ? 'Finalized batch applied' : 'Time tracking imported'}
              </h3>
              <p className="mt-2 text-sm text-neutral-600">
                {!appliedThisSession && alreadyApplied
                  ? `Cornerstone recorded this batch on ${formatTimestamp(preview?.applied_at)}. Its hours were not imported again.`
                  : isHistoricalReconciliation
                  ? `${appliedCount} employee record${appliedCount === 1 ? '' : 's'} reconciled. No payroll amounts were changed.`
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
                      ? 'Cornerstone has reported the existing committed payroll link to AIRE. Payment is reported separately only when the check is prepared and then delivered.'
                      : 'Cornerstone queues an import acknowledgement for AIRE. When this payroll is committed, Cornerstone sends a separate committed status. Importing hours does not by itself mean payment was issued.'}
                  </p>
                  {preview?.source_processing_sync_error && <p className="mt-2 text-danger-700">AIRE status delivery is retrying automatically: {preview.source_processing_sync_error}</p>}
                </div>
              )}
            </div>
          )}
        </div>

        <footer className="flex flex-col-reverse gap-4 border-t border-neutral-200 bg-neutral-50 px-6 py-4 sm:flex-row sm:justify-end sm:px-8">
          {step === 'select' && (
            <>
              <Button variant="outline" onClick={onClose}>Cancel</Button>
              <Button onClick={handlePreview} disabled={loading || !sourceId || sources.length === 0}>{loading ? 'Retrieving…' : selectedSourceIsAire ? 'Retrieve Finalized Batch' : 'Fetch Hours'}</Button>
            </>
          )}
          {step === 'review' && (
            <>
              <Button variant="outline" onClick={() => setStep('select')}>Back</Button>
              <Button onClick={handleApply} disabled={loading || !canApply}>{loading ? 'Saving…' : isHistoricalReconciliation ? 'Verify & Link AIRE Record' : isFinalizedBatch ? 'Apply Finalized Batch' : 'Apply Import'}</Button>
            </>
          )}
          {step === 'done' && <Button onClick={onClose}>Close</Button>}
        </footer>
      </div>
    </div>
  );
}
