import { estimateDraftGross } from '@/lib/draft-gross';
import { needsSourceCoverageAcknowledgement } from '@/lib/payroll-source-coverage';
import { useFeedbackState } from '@/components/ui/action-feedback';

import { type NamedLoanDraft } from '@/components/payroll/NamedLoanInputs';

import { type PayrollCalculationFailure } from '@/components/payroll/PayrollCalculationIssues';
import { useEffect, useState, useCallback, useRef } from 'react';
import type { FormEvent } from 'react';
import { useParams, useLocation, useSearchParams } from 'react-router';

import { Button } from '@/components/ui/button';

import { formatDate, payPeriodStatusConfig } from '@/lib/utils';
import { payrollTaxSummary } from '@/lib/payroll-tax-summary';
import { capturedSourceHoursLocked, worksheetHoursInvalid, worksheetPayBasisHold } from '@/lib/captured-source-worksheet';
import { parsePayRunId } from '@/lib/pay-run-filters';
import { ApiError, payPeriodsApi, employeesApi } from '@/services/api';

import { useAireCalendarRefresh } from '@/hooks/useAireCalendarRefresh';
import { useCompany } from '@/contexts/CompanyContext';

import { WorkspaceLoader } from '@/components/records/WorkspaceLoader';
import { currentAppPath, payRunsPath, safeInternalReturnPath } from '@/lib/routes';
import type { PayPeriod, PayrollItem, Employee, PayrollItemWageRateHours, TaxSyncStatus, NonEmployeeCheck, SupplementalPayPeriodSummary, PayPeriodComparisonResponse, PayrollFieldDefinition, PayrollLiabilityReconciliation, PayPeriodPayrollFieldAssignment, PayPeriodPayrollFieldInputs, NamedLoanOption } from '@/types';
import { type HoursEntry, type PayrollFieldDraftEntry, MAX_HOURS_PER_PERIOD, toNumber, payrollFieldAmountsEqual, effectiveLoanDeduction, buildHoursMap, derivePayrollUiState, numericRecordsEqual, tipRecordsEqual, hoursRecordsEqual, taxSyncStatusConfig, type PayPeriodDetailProps, type CoverageAcknowledgement, type EmploymentGroup } from './payRunSupport';

export function usePayRunController({
  active = true,
  initialPayPeriod,
  onPayPeriodChange,
  refreshToken = 0,
}: PayPeriodDetailProps) {
  const { companyId: companyIdParam, id } = useParams<{ companyId: string; id: string }>();
  const location = useLocation();
  const [searchParams] = useSearchParams();
  const companyId = Number(companyIdParam);
  const payRunId = parsePayRunId(id) ?? 0;
  const returnTo = safeInternalReturnPath(searchParams.get('return_to'), payRunsPath(companyId));
  const currentPath = currentAppPath(location.pathname, location.search);
  const [payPeriod, setPayPeriod] = useState<PayPeriod | null>(null);
  const initialPayPeriodRef = useRef(initialPayPeriod);
  const loadRequestIdRef = useRef(0);
  const lastRefreshTokenRef = useRef(refreshToken);
  const loadedPeriodIdRef = useRef<number | null>(null);
  const [payrollItems, setPayrollItems] = useState<PayrollItem[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [payrollFields, setPayrollFields] = useState<PayrollFieldDefinition[]>([]);
  const [estimateOnlyAssignments, setEstimateOnlyAssignments] = useState<NonNullable<PayPeriodPayrollFieldInputs['estimate_only_assignments']>>([]);
  const [payrollFieldAssignments, setPayrollFieldAssignments] = useState<PayPeriodPayrollFieldAssignment[]>([]);
  const [retainedRetirementEntries, setRetainedRetirementEntries] = useState<NonNullable<PayPeriodPayrollFieldInputs['retained_manual_entries']>>([]);
  const [payrollFieldDrafts, setPayrollFieldDrafts] = useState<Record<string, PayrollFieldDraftEntry>>({});
  // Mirrors the non-employee checks loaded by NonEmployeeChecksPanel so we
  // can detect when the FIT auto-deposit amount has been overridden away
  // from the calculated total. Updated via the panel's onChecksLoaded prop.
  const [nonEmployeeChecks, setNonEmployeeChecks] = useState<NonEmployeeCheck[]>([]);
  const [hoursMap, setHoursMap] = useState<Record<string, HoursEntry>>({});
  const [bonusMap, setBonusMap] = useState<Record<string, number>>({});
  const [bonusEdits, setBonusEdits] = useState<Record<string, number>>({});
  const [salaryOverrideMap, setSalaryOverrideMap] = useState<Record<string, number>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [calculationFailures, setCalculationFailures] = useState<PayrollCalculationFailure[]>([]);
  const [calculationNotice, setCalculationNotice] = useState<string | null>(null);
  const [worksheetRefreshWarning, setWorksheetRefreshWarning] = useState<string | null>(null);
  const [processing, setProcessing] = useState(false);
  const [sourceCoverageOpen, setSourceCoverageOpen] = useState(false);
  const [sourceCoverageReason, setSourceCoverageReason] = useState('');
  const [sourceCoverageAcknowledged, setSourceCoverageAcknowledged] = useState(false);
  const pendingCoverageActionRef = useRef<{
    action: 'calculate' | 'refresh'; companyId: number; payRunId: number; generation: number;
    refreshScope?: { includes_recurring_items: boolean; includes_base_salary: boolean };
  } | null>(null);
  const [savedImportReloadRequired, setSavedImportReloadRequired] = useState(false);
  const savedImportReloadRequiredRef = useRef(false);
  const [commitPeriodId, setCommitPeriodId] = useState<number | null>(null);
  const commitInFlightRef = useRef(false);
  const commitRouteGenerationRef = useRef(0);
  const refreshInFlightRouteRef = useRef<number | null>(null);
  const activePageScopeRef = useRef({ companyId, payRunId });
  activePageScopeRef.current = { companyId, payRunId };
  const { activeCompany } = useCompany();
  const [paymentMethodItem, setPaymentMethodItem] = useState<PayrollItem | null>(null);
  const [clientApprovalOpen, setClientApprovalOpen] = useState(false);
  const [clientApprovalLoading, setClientApprovalLoading] = useState(false);
  const [clientApprovers, setClientApprovers] = useState<Array<{ id: number; name: string; email: string }>>([]);
  const [clientApproverId, setClientApproverId] = useState('');
  const [clientApprovalEvidence, setClientApprovalEvidence] = useState('');
  const [clientApprovalNotes, setClientApprovalNotes] = useState('');
  const [clientApprovalConfirmed, setClientApprovalConfirmed] = useState(false);
  const [adoptingConfirmedWorkweek, setAdoptingConfirmedWorkweek] = useState(false);
  const [retryingSyncTax, setRetryingSyncTax] = useState(false);
  const [importModalOpen, setImportModalOpen] = useState(false);
  const [payrollIntakeImportOpen, setPayrollIntakeImportOpen] = useState(false);
  const [timeTrackingImportOpen, setTimeTrackingImportOpen] = useState(false);
  const [timeTrackingAutoPreview, setTimeTrackingAutoPreview] = useState(false);
  const [aireRecordsOpen, setAireRecordsOpen] = useState(false);
  const [checkPrintOpen, setCheckPrintOpen] = useState(false);
  const [checkPrintRefreshToken, setCheckPrintRefreshToken] = useState(0);
  const [finalRecordRefreshToken, setFinalRecordRefreshToken] = useState(0);
  const handleNonEmployeeChecksLoaded = useCallback((checks: NonEmployeeCheck[]) => {
    setNonEmployeeChecks(checks);
    setFinalRecordRefreshToken(token => token + 1);
  }, []);
  const handleNonEmployeeChecksChanged = useCallback(() => {
    setFinalRecordRefreshToken(token => token + 1);
  }, []);
  const [aireSourceRefreshToken, setAireSourceRefreshToken] = useState(0);
  const invalidateAireSource = useCallback(() => {
    setAireSourceRefreshToken(token => token + 1);
    return true;
  }, []);
  const [payDateCorrectionOpen, setPayDateCorrectionOpen] = useState(false);
  const [payDateCorrectionDate, setPayDateCorrectionDate] = useState('');
  const [payDateCorrectionReason, setPayDateCorrectionReason] = useState('');
  const [payDateCorrectionSubmitting, setPayDateCorrectionSubmitting] = useState(false);
  const [reviewingItem, setReviewingItem] = useState<PayrollItem | null>(null);
  const [editingItem, setEditingItem] = useState<PayrollItem | null>(null);
  const [correctingItem, setCorrectingItem] = useState<PayrollItem | null>(null);
  const [replacingItem, setReplacingItem] = useState<PayrollItem | null>(null);
  const [supplementals, setSupplementals] = useState<SupplementalPayPeriodSummary[]>([]);
  const [supplementalsLoading, setSupplementalsLoading] = useState(false);
  const [comparison, setComparison] = useState<PayPeriodComparisonResponse | null>(null);
  const [comparisonLoading, setComparisonLoading] = useState(false);
  const [comparisonError, setComparisonError] = useState<string | null>(null);
  const [liabilityReconciliation, setLiabilityReconciliation] = useState<PayrollLiabilityReconciliation | null>(null);
  const [liabilityLoading, setLiabilityLoading] = useState(false);
  const [liabilityError, setLiabilityError] = useState<string | null>(null);
  const [additionalEmployeeIds, setAdditionalEmployeeIds] = useState<Set<number>>(new Set());
  const [searchTerm, setSearchTerm] = useState('');
  const [employeeTypeFilter, setEmployeeTypeFilter] = useState<'all' | 'salary' | 'hourly' | 'contractor'>('all');
  const [departmentFilter, setDepartmentFilter] = useState<string>('all');
  const [hoursSortBy, setHoursSortBy] = useState<'name' | 'rate' | 'hours' | 'gross'>('name');
  const [hoursSortDirection, setHoursSortDirection] = useState<'asc' | 'desc'>('asc');
  const [resultsSortBy, setResultsSortBy] = useState<'name' | 'rate' | 'hours' | 'gross' | 'net' | 'fit'>('name');
  const [resultsSortDirection, setResultsSortDirection] = useState<'asc' | 'desc'>('asc');
  const [hoursTableOpen, setHoursTableOpen] = useState(true);
  const [tipsMap, setTipsMap] = useState<Record<string, { amount: number; pool: string }>>({});
  const [tipsPaidOutMap, setTipsPaidOutMap] = useState<Record<string, number>>({});
  const tipsPaidOutMapRef = useRef<Record<string, number>>({});
  const [namedLoanOptions, setNamedLoanOptions] = useState<NamedLoanOption[]>([]);
  const [namedLoanDrafts, setNamedLoanDrafts] = useState<Record<string, Record<string, NamedLoanDraft>>>({});
  const [refreshSetupOpen, setRefreshSetupOpen] = useState(false);
  const [refreshRecurring, setRefreshRecurring] = useState(false);
  const [refreshBaseSalary, setRefreshBaseSalary] = useState(false);
  const [loansMap, setLoansMap] = useState<Record<string, number>>({});
  const [showTipsLoans, setShowTipsLoans] = useState(false);
  const [showPayrollFields, setShowPayrollFields] = useState(false);
  const tipsLoansVisibilityModeRef = useRef<'auto' | 'manual'>('auto');

  useEffect(() => {
    tipsPaidOutMapRef.current = tipsPaidOutMap;
  }, [tipsPaidOutMap]);

  const syncDerivedPayrollState = useCallback((items: PayrollItem[]) => {
    const derivedState = derivePayrollUiState(items);
    setSalaryOverrideMap(derivedState.salaryOverrides);
    setBonusMap(derivedState.bonuses);
    setBonusEdits({});
    setTipsMap(derivedState.tips);
    tipsPaidOutMapRef.current = derivedState.tipsPaidOut;
    setTipsPaidOutMap(derivedState.tipsPaidOut);
    setLoansMap(derivedState.loans);
    setShowTipsLoans((previous) => (
      tipsLoansVisibilityModeRef.current === 'manual' ? previous : derivedState.showTipsLoans
    ));
  }, []);

  const syncPayrollFieldInputs = useCallback((worksheet: PayPeriodPayrollFieldInputs) => {
    setNamedLoanOptions(worksheet.named_loan_options || []);
    setNamedLoanDrafts((worksheet.named_loan_options || []).reduce<Record<string, Record<string, NamedLoanDraft>>>((drafts, option) => {
      drafts[String(option.employee_id)] ||= {};
      drafts[String(option.employee_id)][String(option.loan_id)] = { mode: option.mode, amount: option.requested_amount ?? option.scheduled_amount };
      return drafts;
    }, {}));
    setPayrollFields(worksheet.fields);
    setPayrollFieldAssignments(worksheet.assignments);
    setEstimateOnlyAssignments(worksheet.estimate_only_assignments || []);
    setRetainedRetirementEntries(worksheet.retained_manual_entries || []);
    setShowPayrollFields(worksheet.assignments.length > 0);
    setPayrollFieldDrafts(Object.fromEntries(worksheet.assignments.map((assignment) => {
      const key = `${assignment.employee_id}:${assignment.payroll_field_definition_id}`;
      return [key, {
        mode: assignment.overridden ? 'override' : 'default',
        amount: assignment.requested_amount ?? assignment.current_amount ?? assignment.suggested_amount ?? null,
        replace_request: false,
      } satisfies PayrollFieldDraftEntry];
    })));
  }, []);

  const loadEligibleEmployees = useCallback(async (periodId: number) => {
    const allEmployees: Employee[] = [];
    let page = 1;
    let totalPages = 1;

    try {
      do {
        const response = await employeesApi.list({ eligible_pay_period_id: periodId, per_page: 100, page });
        allEmployees.push(...response.data);
        totalPages = response.meta.total_pages;
        page += 1;
      } while (page <= totalPages);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Unknown error';
      throw new Error(`Failed to load pay-period employees page ${page}: ${message}`);
    }

    return allEmployees;
  }, []);

  const loadPayPeriod = useCallback(async (periodId: number, silent = false, preserveInputs = false): Promise<'loaded' | 'superseded' | 'failed'> => {
    const requestId = ++loadRequestIdRef.current;
    // Saved check, correction and payment changes invalidate the final record
    // even if the surrounding pay-run reload subsequently fails.
    setFinalRecordRefreshToken(token => token + 1);
    const requiresSavedSourceWorksheet = savedImportReloadRequiredRef.current;
    const retainInputs = preserveInputs && !requiresSavedSourceWorksheet;
    const isCurrentRequest = (): boolean => loadRequestIdRef.current === requestId;

    try {
      if (!silent) setLoading(true);
      setError(null);

      setLiabilityLoading(true);
      setLiabilityError(null);
      const prefetchedPayPeriod = initialPayPeriodRef.current?.id === periodId
        ? initialPayPeriodRef.current
        : null;
      initialPayPeriodRef.current = undefined;

      const [ppResponse, empResponse, liabilityResponse, payrollFieldResponse] = await Promise.all([
        prefetchedPayPeriod
          ? Promise.resolve({ pay_period: prefetchedPayPeriod })
          : payPeriodsApi.get(periodId),
        loadEligibleEmployees(periodId),
        payPeriodsApi.liabilities(periodId).catch((err) => {
          if (isCurrentRequest()) {
            setLiabilityError(err instanceof Error ? err.message : 'Failed to load payroll liabilities');
          }
          return null;
        }),
        payPeriodsApi.payrollFieldInputs(periodId).catch((err) => {
          if (requiresSavedSourceWorksheet) {
            throw new Error(`Saved payroll worksheet could not load: ${err instanceof Error ? err.message : 'Unknown error'}`);
          }
          console.warn('Failed to load payroll field worksheet', err);
          return { payroll_field_inputs: { fields: [], assignments: [] } };
        }),
      ]);

      if (!isCurrentRequest()) return 'superseded';
      setPayPeriod(ppResponse.pay_period);
      setPayrollItems(ppResponse.pay_period.payroll_items || []);
      setEmployees(empResponse);
      if (!retainInputs) syncPayrollFieldInputs(payrollFieldResponse.payroll_field_inputs);
      setLiabilityReconciliation(liabilityResponse?.payroll_liability_reconciliation || null);
      if (!retainInputs) {
        setHoursMap(buildHoursMap(ppResponse.pay_period.payroll_items || [], empResponse));
        syncDerivedPayrollState(ppResponse.pay_period.payroll_items || []);
        // Canonical reloads after import, commit, or saved check changes must
        // refresh receipts/history even when the finalized event is unchanged.
        if (loadedPeriodIdRef.current === periodId) invalidateAireSource();
      }
      loadedPeriodIdRef.current = periodId;
      savedImportReloadRequiredRef.current = false;
      setSavedImportReloadRequired(false);
      return 'loaded';
    } catch (err) {
      if (!isCurrentRequest()) return 'superseded';
      setError(err instanceof Error ? err.message : 'Failed to load pay period');
      return 'failed';
    } finally {
      if (isCurrentRequest()) {
        setLiabilityLoading(false);
        setLoading(false);
      }
    }
  }, [invalidateAireSource, loadEligibleEmployees, setError, syncDerivedPayrollState, syncPayrollFieldInputs]);

  useEffect((): (() => void) => {
    // Reset cross-pay-period observer state so divergence indicators don't
    // momentarily render against the previous period's checks while the
    // new panel loads.
    setPayPeriod(null);
    setReviewingItem(null);
    setCommitPeriodId(null);
    setRefreshSetupOpen(false);
    setSourceCoverageOpen(false);
    pendingCoverageActionRef.current = null;
    if (refreshInFlightRouteRef.current !== null) {
      refreshInFlightRouteRef.current = null;
      setProcessing(false);
    }
    setCalculationFailures([]);
    setCalculationNotice(null);
    setWorksheetRefreshWarning(null);
    savedImportReloadRequiredRef.current = false;
    setSavedImportReloadRequired(false);
    setTimeTrackingImportOpen(false);
    setTimeTrackingAutoPreview(false);
    setAireRecordsOpen(false);
    setPayrollItems([]);
    setNonEmployeeChecks([]);
    setSupplementals([]);
    setComparison(null);
    setComparisonError(null);
    tipsLoansVisibilityModeRef.current = 'auto';

    if (payRunId < 1) {
      setPayPeriod(null);
      setError('This pay-run processing link is invalid.');
      setLoading(false);
      return (): void => {
        loadRequestIdRef.current += 1;
      };
    }

    void loadPayPeriod(payRunId);

    return (): void => {
      loadRequestIdRef.current += 1;
    };
  }, [companyId, loadPayPeriod, payRunId, setError]);

  useEffect(() => {
    if (lastRefreshTokenRef.current === refreshToken) return;
    lastRefreshTokenRef.current = refreshToken;
    if (payRunId > 0) {
      setCheckPrintRefreshToken((token) => token + 1);
      invalidateAireSource();
      // Sibling check changes refresh server state, not an operator's drafts.
      // A superseded initial load or a new run still needs input initialization.
      void loadPayPeriod(payRunId, true, payPeriod?.id === payRunId);
    }
  }, [invalidateAireSource, loadPayPeriod, payPeriod?.id, payRunId, refreshToken]);

  useEffect(() => {
    if (payPeriod) onPayPeriodChange?.(payPeriod);
  }, [onPayPeriodChange, payPeriod]);

  const calendarRefreshError = useAireCalendarRefresh({
    companyId, payPeriodId: payRunId,
    calendar: payPeriod?.time_tracking?.aire_calendar,
    enabled: active && payPeriod?.run_purpose === 'regular',
    onUpdated: calendar => {
      setPayPeriod(current => current?.id === payRunId && current.company_id === companyId
        ? { ...current, time_tracking: { ...current.time_tracking!, aire_calendar: calendar } }
        : current);
      invalidateAireSource();
    },
  });

  const loadComparison = useCallback(async (payPeriodId: number) => {
    setComparisonLoading(true);
    setComparisonError(null);
    try {
      const res = await payPeriodsApi.comparison(payPeriodId);
      setComparison(res);
    } catch (err) {
      setComparison(null);
      setComparisonError(err instanceof Error ? err.message : 'Failed to load pay period comparison');
    } finally {
      setComparisonLoading(false);
    }
  }, []);

  // Load any linked corrective supplemental periods for a regular,
  // committed period. Refetches whenever a new corrective is issued.
  const loadSupplementals = useCallback(async (payPeriodId: number) => {
    setSupplementalsLoading(true);
    try {
      const res = await payPeriodsApi.supplementalPayPeriods(payPeriodId);
      setSupplementals(res.supplemental_pay_periods);
    } catch {
      // Non-fatal: hide the section silently
      setSupplementals([]);
    } finally {
      setSupplementalsLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!payPeriod) return;
    if (payPeriod.cycle === 'supplemental' || !['calculated', 'approved', 'committed'].includes(payPeriod.status)) {
      setComparison(null);
      setComparisonError(null);
      return;
    }
    loadComparison(payPeriod.id);
  }, [payPeriod, loadComparison]);

  useEffect(() => {
    if (!payPeriod) return;
    if (payPeriod.cycle === 'supplemental') return; // never loads its own supplementals
    if (payPeriod.status !== 'committed') return;
    loadSupplementals(payPeriod.id);
  }, [payPeriod, loadSupplementals]);

  const updateHours = (employeeId: number, field: 'regular' | 'overtime', value: number) => {
    if (capturedSourceHoursLocked(payrollItems.find(item => item.employee_id === employeeId))) return;
    const clampedValue = Math.max(0, Math.min(MAX_HOURS_PER_PERIOD, value));
    setHoursMap((prev) => ({
      ...prev,
      [String(employeeId)]: {
        ...prev[String(employeeId)],
        [field]: clampedValue,
        ...(prev[String(employeeId)]?.wage_rates?.length === 1 ? {
          wage_rates: prev[String(employeeId)].wage_rates!.map(rate => ({
            ...rate,
            [field === 'regular' ? 'regular_hours' : 'overtime_hours']: clampedValue,
          })),
        } : {}),
      },
    }));
  };

  const updateWageRateHours = (
    employeeId: number,
    index: number,
    field: 'regular_hours' | 'overtime_hours',
    value: number
  ) => {
    if (capturedSourceHoursLocked(payrollItems.find(item => item.employee_id === employeeId))) return;
    const clampedValue = Math.max(0, Math.min(MAX_HOURS_PER_PERIOD, value));
    setHoursMap((prev) => {
      const current = prev[String(employeeId)];
      const wageRates = [...(current?.wage_rates || [])];
      if (!wageRates[index]) return prev;

      wageRates[index] = {
        ...wageRates[index],
        [field]: clampedValue,
      };

      return {
        ...prev,
        [String(employeeId)]: {
          regular: wageRates.reduce((sum, entry) => sum + toNumber(entry.regular_hours), 0),
          overtime: wageRates.reduce((sum, entry) => sum + toNumber(entry.overtime_hours), 0),
          wage_rates: wageRates,
        },
      };
    });
  };

  const updateSalaryOverride = (employeeId: number, value: number) => {
    setSalaryOverrideMap((prev) => ({ ...prev, [String(employeeId)]: Math.max(0, value) }));
  };

  const updateTip = (employeeId: number, amount: number, pool?: string) => {
    setTipsMap((prev) => {
      const existing = prev[String(employeeId)] || { amount: 0, pool: '' };
      const paidOut = toNumber(tipsPaidOutMapRef.current[String(employeeId)]);
      return { ...prev, [String(employeeId)]: { amount: Math.max(0, amount, paidOut), pool: pool ?? existing.pool } };
    });
  };

  const updateLoan = (employeeId: number, amount: number) => {
    setLoansMap((prev) => ({ ...prev, [String(employeeId)]: Math.max(0, amount) }));
  };

  const updateTipsPaidOut = (employeeId: number, amount: number) => {
    const paidOut = Math.max(0, amount);
    const key = String(employeeId);
    tipsPaidOutMapRef.current = { ...tipsPaidOutMapRef.current, [key]: paidOut };
    setTipsPaidOutMap((prev) => {
      const next = { ...prev, [key]: paidOut };
      tipsPaidOutMapRef.current = next;
      return next;
    });
    setTipsMap((prev) => {
      const existing = prev[key] || { amount: 0, pool: '' };
      if (toNumber(existing.amount) >= paidOut) return prev;
      return { ...prev, [key]: { ...existing, amount: paidOut } };
    });
  };

  const updatePayrollFieldDraft = (employeeId: number, fieldId: number, amount: number | null) => {
    const assignment = payrollFieldAssignments.find((candidate) => (
      candidate.employee_id === employeeId && candidate.payroll_field_definition_id === fieldId
    ));
    if (!assignment) return;

    const key = `${employeeId}:${fieldId}`;
    const excludesRecurring = payPeriod?.includes_recurring_items === false;
    const normalizedAmount = amount == null ? null : Math.max(0, amount);
    const defaultAmount = assignment.requested_amount ?? assignment.current_amount ?? assignment.suggested_amount ?? null;

    setPayrollFieldDrafts((previous) => {
      const current = previous[key];
      if (excludesRecurring && normalizedAmount == null && current?.mode !== 'override') return previous;
      if (current && payrollFieldAmountsEqual(current.amount, normalizedAmount)
        && !(current.mode === 'default' && excludesRecurring)) return previous;

      const returnedToDefault = !assignment.overridden
        && !excludesRecurring
        && payrollFieldAmountsEqual(normalizedAmount, defaultAmount);

      return {
        ...previous,
        [key]: returnedToDefault
          ? { mode: 'default', amount: defaultAmount }
          : { mode: 'override', amount: normalizedAmount, replace_request: true },
      };
    });
  };

  const resetPayrollFieldDraft = (employeeId: number, fieldId: number) => {
    const assignment = payrollFieldAssignments.find((candidate) => (
      candidate.employee_id === employeeId && candidate.payroll_field_definition_id === fieldId
    ));
    if (!assignment) return;

    const key = `${employeeId}:${fieldId}`;
    setPayrollFieldDrafts((previous) => ({
      ...previous,
      [key]: {
        mode: 'default',
        amount: assignment.amount_type === 'percentage'
          ? null
          : assignment.assigned_amount ?? assignment.default_amount ?? 0,
      },
    }));
  };


  const requestSourceCoverage = (action: 'calculate' | 'refresh', refreshScope?: { includes_recurring_items: boolean; includes_base_salary: boolean }) => {
    pendingCoverageActionRef.current = { action, companyId, payRunId, generation: commitRouteGenerationRef.current, refreshScope };
    setSourceCoverageReason('');
    setSourceCoverageAcknowledged(false);
    setSourceCoverageOpen(true);
  };

  const handleRunPayroll = async (coverage?: CoverageAcknowledgement) => {
    if (savedImportReloadRequiredRef.current || !payPeriod) return;
    if (needsSourceCoverageAcknowledgement(payPeriod) && !coverage) {
      requestSourceCoverage('calculate');
      return;
    }
    try {
      setProcessing(true);
      setError(null);
      setCalculationFailures([]);
      setCalculationNotice(null);
      setWorksheetRefreshWarning(null);

      const heldItem = payrollItems.find(item => !item.voided && worksheetPayBasisHold(item, employees.find(employee => employee.id === item.employee_id)));
      if (heldItem) {
        setError(worksheetPayBasisHold(heldItem, employees.find(employee => employee.id === heldItem.employee_id))!.reason);
        return;
      }
      const invalidHours = Object.entries(hoursMap).find(([employeeId, entry]) => worksheetHoursInvalid(
        entry, payrollItems.find(item => item.employee_id === Number(employeeId)), MAX_HOURS_PER_PERIOD,
      ));
      if (invalidHours) {
        setError(`Hours must be between 0 and ${MAX_HOURS_PER_PERIOD} per period`);
        return;
      }

      const selectedEmployeeIds = new Set([...(payPeriod.default_employee_ids || []), ...payrollItems.map(item => item.employee_id), ...additionalEmployeeIds]);
      if (!Array.isArray(payPeriod.default_employee_ids) && payPeriod.status === 'draft' && payrollItems.length === 0 && payPeriod.run_purpose === 'regular') {
        employees.forEach(employee => {
          if (!(payPeriod.excluded_employee_ids || []).includes(employee.id)) selectedEmployeeIds.add(employee.id);
        });
      }
      Object.entries(hoursMap).forEach(([employeeId, entry]) => {
        if (entry.regular > 0 || entry.overtime > 0) selectedEmployeeIds.add(Number(employeeId));
      });
      [salaryOverrideMap, bonusMap, tipsPaidOutMap].forEach(values => {
        Object.entries(values).forEach(([employeeId, amount]) => {
          if (toNumber(amount) > 0) selectedEmployeeIds.add(Number(employeeId));
        });
      });
      Object.entries(tipsMap).forEach(([employeeId, entry]) => {
        if (entry.amount > 0) selectedEmployeeIds.add(Number(employeeId));
      });
      const named_loan_payments: Record<string, Record<string, { mode: 'default' | 'override'; amount?: number }>> = {};
      Object.entries(namedLoanDrafts).forEach(([employeeId, drafts]) => {
        if (!selectedEmployeeIds.has(Number(employeeId))) return;
        named_loan_payments[employeeId] = {};
        Object.entries(drafts).forEach(([loanId, draft]) => {
          const option = namedLoanOptions.find(candidate => String(candidate.employee_id) === employeeId && String(candidate.loan_id) === loanId);
          if (draft.mode === 'override' && !option?.eligible && toNumber(draft.amount) > 0) {
            throw new Error(`The saved repayment for ${option?.name || 'this loan'} is no longer available. Choose no repayment or enter zero, then recalculate.`);
          }
          if (draft.mode === 'override' && draft.amount == null) throw new Error('Enter the linked loan repayment amount, or choose the scheduled default.');
          named_loan_payments[employeeId][loanId] = draft.mode === 'override' ? { mode: 'override', amount: draft.amount ?? 0 } : { mode: 'default' };
        });
      });

      // Build hours payload
      const hours: Record<string, { regular?: number; overtime?: number; wage_rates?: PayrollItemWageRateHours[] }> = {};
      Object.entries(hoursMap).forEach(([empId, entry]) => {
        if (!selectedEmployeeIds.has(Number(empId))) return;
        const preservesSourceRates = payrollItems.some(item => item.employee_id === Number(empId)
          && (item.timekeeping_source === 'correction_reference' || item.import_source?.startsWith('time_tracking:')));
        hours[empId] = entry.wage_rates && entry.wage_rates.length > 0
          && (entry.wage_rates.length > 1 || preservesSourceRates)
          ? {
              regular: entry.regular,
              overtime: entry.overtime,
              wage_rates: entry.wage_rates,
            }
          : { regular: entry.regular, overtime: entry.overtime };
      });

      // Build salary overrides payload for variable salary employees.
      // Send zeroes too so clearing a variable salary amount removes stale overrides.
      const includedEmployeeIds = new Set([
        ...payrollItems.map((pi) => pi.employee_id),
        ...additionalEmployeeIds,
      ]);
      const salary_overrides: Record<string, number> = {};
      const missingVariableSalaryEmployees: string[] = [];
      employees.forEach((employee) => {
        if (employee.employment_type === 'salary' && employee.salary_type === 'variable') {
          const amount = Math.max(0, toNumber(salaryOverrideMap[String(employee.id)]));
          if (!includedEmployeeIds.has(employee.id) && amount <= 0) return;
          salary_overrides[String(employee.id)] = amount;
          if (amount <= 0 && payPeriod.includes_base_salary !== false) {
            missingVariableSalaryEmployees.push(`${employee.first_name} ${employee.last_name}`);
          }
        }
      });

      if (missingVariableSalaryEmployees.length > 0) {
        setError(`Enter period pay before recalculating for variable salary employee(s): ${missingVariableSalaryEmployees.join(', ')}`);
        return;
      }

      // Build tips payload. Tips paid out are already in the employee's hands,
      // but they are still taxable tips, so the reported-tip amount must be at
      // least the paid-out offset.
      const tips: Record<string, { amount: number; pool: string }> = {};
      const tips_paid_out: Record<string, number> = {};
      Object.entries(tipsPaidOutMap).forEach(([empId, amount]) => {
        tips_paid_out[empId] = Math.max(0, toNumber(amount));
      });
      new Set([...Object.keys(tipsMap), ...Object.keys(tips_paid_out)]).forEach((empId) => {
        const data = tipsMap[empId];
        const amount = Math.max(0, toNumber(data?.amount), toNumber(tips_paid_out[empId]));
        if (amount > 0 || data) {
          tips[empId] = { amount, pool: data?.pool || '' };
        }
      });

      // Build loan deductions payload
      const loan_deductions: Record<string, number> = {};
      Object.entries(loansMap).forEach(([empId, amount]) => {
        loan_deductions[empId] = Math.max(0, toNumber(amount));
      });

      const payroll_field_inputs: Record<string, Record<string, { mode: 'default' | 'override'; amount?: number; replace_request?: boolean }>> = {};
      payrollFieldAssignments.forEach((assignment) => {
        const field = worksheetPayrollFields.find((candidate) => candidate.id === assignment.payroll_field_definition_id);
        const isLoanField = field?.category === 'loan' && field.tax_treatment === 'post_tax_deduction';
        if (!assignment.editable && !isLoanField) return;
        const key = `${assignment.employee_id}:${assignment.payroll_field_definition_id}`;
        const draft = payrollFieldDrafts[key] || { mode: 'default' as const, amount: null };
        if (draft.mode === 'override' && draft.amount == null) {
          const fieldName = worksheetPayrollFields.find(
            (field) => field.id === assignment.payroll_field_definition_id,
          )?.name || 'payroll field';
          const employee = employees.find((candidate) => candidate.id === assignment.employee_id);
          const employeeName = employee
            ? `${employee.first_name} ${employee.last_name}`
            : `employee #${assignment.employee_id}`;
          throw new Error(
            `Enter an amount for ${fieldName} for ${employeeName}, or use the employee default.`,
          );
        }

        payroll_field_inputs[String(assignment.employee_id)] ||= {};
        payroll_field_inputs[String(assignment.employee_id)][String(assignment.payroll_field_definition_id)] = draft.mode === 'override'
          ? { mode: 'override', amount: Math.max(0, toNumber(draft.amount)), ...(draft.replace_request ? { replace_request: true } : {}) }
          : { mode: 'default' };
      });

      // Include any manually-added employees who were missing from the import
      const employee_ids = [...selectedEmployeeIds];
      if (employee_ids.length === 0) throw new Error('Enter pay or add an employee before calculating this payroll.');
      const selectedRecords = <T,>(values: Record<string, T>) => Object.fromEntries(Object.entries(values).filter(([employeeId]) => selectedEmployeeIds.has(Number(employeeId))));

      const response = await payPeriodsApi.runPayroll(payPeriod.id, {
        ...coverage,
        hours,
        ...(Object.keys(bonusEdits).length > 0 ? { bonuses: selectedRecords(bonusEdits) } : {}),
        ...(Object.keys(salary_overrides).length > 0 ? { salary_overrides: selectedRecords(salary_overrides) } : {}),
        ...(Object.keys(tips).length > 0 ? { tips: selectedRecords(tips) } : {}),
        ...(Object.keys(tips_paid_out).length > 0 ? { tips_paid_out: selectedRecords(tips_paid_out) } : {}),
        ...(Object.keys(loan_deductions).length > 0 ? { loan_deductions: selectedRecords(loan_deductions) } : {}),
        ...(Object.keys(payroll_field_inputs).length > 0 ? { payroll_field_inputs: selectedRecords(payroll_field_inputs) } : {}),
        employee_ids,
        named_loan_payments,
      });
      setPayPeriod(response.pay_period);
      invalidateAireSource();
      setPayrollItems(response.pay_period.payroll_items || []);
      setHoursMap(buildHoursMap(response.pay_period.payroll_items || [], employees));
      syncDerivedPayrollState(response.pay_period.payroll_items || []);
      setSalaryOverrideMap((previous) => ({ ...previous, ...salary_overrides }));
      const failedEmployeeIds = new Set(response.results.errors.map((failure) => String(failure.employee_id)));
      const failedBonuses = Object.fromEntries(Object.entries(bonusEdits).filter(([employeeId]) => failedEmployeeIds.has(employeeId)));
      setBonusEdits(failedBonuses);
      setBonusMap((previous) => ({ ...previous, ...failedBonuses }));
      setHoursMap((previous) => ({ ...previous, ...Object.fromEntries(Object.entries(hoursMap).filter(([employeeId]) => failedEmployeeIds.has(employeeId))) }));
      setAdditionalEmployeeIds(new Set([...additionalEmployeeIds].filter((employeeId) => failedEmployeeIds.has(String(employeeId)))));
      await payPeriodsApi.payrollFieldInputs(payPeriod.id)
        .then((updatedPayrollFieldResponse) => {
          syncPayrollFieldInputs(updatedPayrollFieldResponse.payroll_field_inputs);
          setNamedLoanDrafts(previous => ({
            ...previous,
            ...Object.fromEntries(Object.entries(namedLoanDrafts).filter(([employeeId]) => failedEmployeeIds.has(employeeId))),
          }));
        })
        .catch((refreshError) => {
          console.warn('Payroll ran successfully, but the payroll field worksheet could not be refreshed.', refreshError);
          setWorksheetRefreshWarning('The calculation returned, but payroll fields could not refresh. Reload the page before reviewing or editing the worksheet.');
        });

      setCalculationFailures(response.results.errors);
      if (response.results.errors.length > 0) {
        setError(`Calculated ${response.results.success.length} employees. ${response.results.errors.length} ${response.results.errors.length === 1 ? 'employee needs' : 'employees need'} attention before approval.`);
      } else {
        setCalculationNotice(`Payroll calculated for ${response.results.success.length} ${response.results.success.length === 1 ? 'employee' : 'employees'}${response.results.skipped.length ? `; ${response.results.skipped.length} skipped` : ''}. Review the results before approval.`);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to run payroll');
    } finally {
      setProcessing(false);
    }
  };

  const handleRefreshSetup = async (
    refreshScope = { includes_recurring_items: refreshRecurring, includes_base_salary: refreshBaseSalary },
    coverage?: CoverageAcknowledgement,
  ) => {
    if (savedImportReloadRequiredRef.current || !payPeriod || payPeriod.id !== payRunId || processing || refreshInFlightRouteRef.current !== null) return;
    if (payrollItems.length > 0 && needsSourceCoverageAcknowledgement(payPeriod) && !coverage) {
      requestSourceCoverage('refresh', refreshScope);
      return;
    }
    const scope = { companyId, payRunId, generation: commitRouteGenerationRef.current };
    const isCurrentRoute = () => scope.companyId === activePageScopeRef.current.companyId &&
      scope.payRunId === activePageScopeRef.current.payRunId && scope.generation === commitRouteGenerationRef.current;
    refreshInFlightRouteRef.current = scope.generation;
    setProcessing(true);
    setError(null);
    setCalculationFailures([]);
    setCalculationNotice(null);
    try {
      const response = await payPeriodsApi.refreshSetup(payPeriod.id, { ...refreshScope, ...coverage });
      if (!isCurrentRoute()) return;
      setRefreshSetupOpen(false);
      const reloaded = await loadPayPeriod(scope.payRunId, true);
      if (!isCurrentRoute()) return;
      if (reloaded === 'superseded') return;
      if (reloaded === 'failed') {
        setPayPeriod(null);
        setPayrollItems([]);
        setError('Setup changed, but the updated payroll could not load. Your inputs are retained. Try again before reviewing or committing payroll.');
        return;
      }
      setCalculationFailures(response.results.errors);
      const failureCount = response.results.errors.length;
      if (failureCount > 0) {
        setError(`${failureCount} ${failureCount === 1 ? 'employee needs' : 'employees need'} attention after refreshing setup.`);
      } else {
        setCalculationNotice('Current setup applied to the saved employees and inputs. Review the recalculated payroll and obtain approval again.');
      }
    } catch (err) {
      if (isCurrentRoute()) setError(err instanceof Error ? err.message : 'Unable to refresh payroll setup.');
    } finally {
      if (isCurrentRoute()) {
        refreshInFlightRouteRef.current = null;
        setProcessing(false);
      }
    }
  };

  const handleAdoptConfirmedWorkweek = async (): Promise<void> => {
    if (!payPeriod) return;

    try {
      setAdoptingConfirmedWorkweek(true);
      setError(null);
      const response = await payPeriodsApi.adoptConfirmedWorkweek(payPeriod.id);
      setPayPeriod(response.pay_period);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Failed to use the confirmed workweek');
    } finally {
      setAdoptingConfirmedWorkweek(false);
    }
  };

  const handleApprove = async () => {
    if (savedImportReloadRequiredRef.current || !payPeriod) return;
    const heldItem = payrollItems.find(item => !item.voided && worksheetPayBasisHold(item, employees.find(employee => employee.id === item.employee_id)));
    if (heldItem) { setError(worksheetPayBasisHold(heldItem, employees.find(employee => employee.id === heldItem.employee_id))!.reason); return; }
    try {
      setProcessing(true);
      setError(null);
      const response = await payPeriodsApi.approve(payPeriod.id);
      setPayPeriod(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to approve');
    } finally {
      setProcessing(false);
    }
  };

  const openClientApproval = async (): Promise<void> => {
    if (!payPeriod) return;
    setClientApprovalLoading(true);
    setError(null);
    try {
      const response = await payPeriodsApi.clientReview(payPeriod.id);
      setClientApprovers(response.authorized_client_approvers);
      setClientApproverId(response.authorized_client_approvers[0]?.id.toString() || '');
      setClientApprovalEvidence('');
      setClientApprovalNotes('');
      setClientApprovalConfirmed(false);
      setClientApprovalOpen(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load client approval');
    } finally {
      setClientApprovalLoading(false);
    }
  };

  const recordClientApproval = async (event: FormEvent): Promise<void> => {
    event.preventDefault();
    if (!payPeriod?.payroll_review || !clientApproverId) return;
    setClientApprovalLoading(true);
    setError(null);
    try {
      const response = await payPeriodsApi.recordClientApproval(payPeriod.id, {
        client_approver_id: Number(clientApproverId),
        acknowledgement: clientApprovalConfirmed ? payPeriod.payroll_review.acknowledgement : '',
        evidence_reference: clientApprovalEvidence.trim(),
        notes: clientApprovalNotes.trim() || undefined,
      });
      setPayPeriod({ ...payPeriod, payroll_review: response.payroll_review });
      setClientApprovalOpen(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to record client approval');
    } finally {
      setClientApprovalLoading(false);
    }
  };

  const handleUnapprove = async () => {
    if (!payPeriod) return;
    if (!confirm('Roll back approval? This will return the pay period to "Calculated" status.')) return;
    try {
      setProcessing(true);
      setError(null);
      const response = await payPeriodsApi.unapprove(payPeriod.id);
      setPayPeriod(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to unapprove');
    } finally {
      setProcessing(false);
    }
  };

  useEffect(() => {
    commitRouteGenerationRef.current += 1;
    return () => { commitRouteGenerationRef.current += 1; };
  }, [companyId, payRunId]);

  useEffect(() => {
    if (payPeriod?.status !== 'approved' || payPeriod.correction_status === 'voided') setCommitPeriodId(null);
  }, [payPeriod?.id, payPeriod?.status, payPeriod?.correction_status]);

  const handleCommit = async (confirmedPeriodId: number) => {
    if (savedImportReloadRequiredRef.current || !payPeriod || payPeriod.id !== payRunId || confirmedPeriodId !== payRunId || commitPeriodId !== confirmedPeriodId ||
        payPeriod.status !== 'approved' || payPeriod.correction_status === 'voided' || processing || commitInFlightRef.current) return;
    commitInFlightRef.current = true;
    const currentRouteGeneration = commitRouteGenerationRef.current;
    const isCurrentRoute = () => currentRouteGeneration === commitRouteGenerationRef.current;
    setCommitPeriodId(null);
    setProcessing(true);
    setError(null);
    try {
      const response = await payPeriodsApi.commit(confirmedPeriodId);
      if (!isCurrentRoute()) return;
      setPayPeriod(response.pay_period);
      await loadPayPeriod(confirmedPeriodId, true);
    } catch (err) {
      if (isCurrentRoute()) setError(err instanceof Error ? err.message : 'Failed to commit');
    } finally {
      commitInFlightRef.current = false;
      setProcessing(false);
    }
  };

  const handleRetryTaxSync = async () => {
    if (!payPeriod) return;
    try {
      setRetryingSyncTax(true);
      setError(null);
      const response = await payPeriodsApi.retryTaxSync(payPeriod.id);
      setPayPeriod(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to retry tax sync');
    } finally {
      setRetryingSyncTax(false);
    }
  };

  const openPayDateCorrection = () => {
    if (!payPeriod) return;
    setPayDateCorrectionDate(payPeriod.pay_date);
    setPayDateCorrectionReason('');
    setPayDateCorrectionOpen(true);
  };

  const handleCorrectPayDate = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!payPeriod) return;

    if (!payDateCorrectionDate) {
      setError('Pay date is required');
      return;
    }

    if (payDateCorrectionDate < payPeriod.end_date) {
      setError('Pay date must be on or after end date');
      return;
    }

    if (!payDateCorrectionReason.trim()) {
      setError('A reason is required to correct a committed pay date');
      return;
    }

    try {
      setPayDateCorrectionSubmitting(true);
      setError(null);
      const response = await payPeriodsApi.correctPayDate(payPeriod.id, {
        pay_date: payDateCorrectionDate,
        reason: payDateCorrectionReason.trim(),
      });
      setPayPeriod(response.pay_period);
      setPayDateCorrectionOpen(false);
      setPayDateCorrectionReason('');
      await loadPayPeriod(payPeriod.id, true);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to correct pay date');
    } finally {
      setPayDateCorrectionSubmitting(false);
    }
  };

  const reloadSavedSourceImport = async (): Promise<boolean> => {
    const scope = { companyId, payRunId, generation: commitRouteGenerationRef.current };
    const isCurrentRoute = () => scope.companyId === activePageScopeRef.current.companyId &&
      scope.payRunId === activePageScopeRef.current.payRunId && scope.generation === commitRouteGenerationRef.current;
    if (!isCurrentRoute() || !payPeriod || payPeriod.id !== payRunId) return false;
    savedImportReloadRequiredRef.current = true;
    setSavedImportReloadRequired(true);
    setCalculationNotice(null);
    const result = await loadPayPeriod(scope.payRunId, true);
    if (!isCurrentRoute()) return false;
    if (result === 'failed') {
      setError('Source hours were saved, but the current payroll could not load. Reload saved payroll before calculating, approving or committing; do not import the hours again.');
    }
    return result === 'loaded' || (result === 'superseded' && !savedImportReloadRequiredRef.current);
  };

  const handleImportComplete = (updatedPayPeriod: PayPeriod & { payroll_items?: PayrollItem[] }) => {
    // Import endpoints return the newly calculated rows but not every field
    // from the canonical pay-run response. Preserve the current run context
    // (notably the base-salary intent) and then refresh the full record.
    setPayPeriod((current) => current ? { ...current, ...updatedPayPeriod } : updatedPayPeriod);
    setPayrollItems(updatedPayPeriod.payroll_items || []);
    setHoursMap(buildHoursMap(updatedPayPeriod.payroll_items || [], employees));
    syncDerivedPayrollState(updatedPayPeriod.payroll_items || []);
    setAdditionalEmployeeIds(new Set());
    void loadPayPeriod(updatedPayPeriod.id, true);
  };

  const handlePayrollItemSaved = (updated: PayrollItem) => {
    setPayrollItems((prev) =>
      prev.map((item) => (item.id === updated.id ? updated : item))
    );
    if (payPeriod) void loadPayPeriod(payPeriod.id, true);
  };

  const handlePayrollItemApplied = (updated?: PayrollItem) => {
    if (!updated) return;

    setPayrollItems((prev) => {
      const exists = prev.some((item) => item.id === updated.id);
      return exists
        ? prev.map((item) => (item.id === updated.id ? { ...item, ...updated } : item))
        : [...prev, updated];
    });
    setHoursMap((prev) => {
      const updatedHours = buildHoursMap([updated], employees)[String(updated.employee_id)] || {
        regular: toNumber(updated.hours_worked),
        overtime: toNumber(updated.overtime_hours),
        wage_rates: updated.wage_rate_hours,
      };

      return {
        ...prev,
        [String(updated.employee_id)]: updatedHours,
      };
    });
  };

  useEffect(() => {
    if (loading || !payPeriod?.id || location.hash !== '#time-tracking-sync') return;
    const target = document.getElementById('time-tracking-sync');
    target?.scrollIntoView?.({ block: 'start' });
    target?.focus({ preventScroll: true });
  }, [loading, payPeriod?.id, location.hash]);

  const correctionRouteGeneration = commitRouteGenerationRef.current;

  if (loading) {
    return { status: 'loading' as const, fallback: <WorkspaceLoader label="Loading payroll processing tools" minHeightClassName="min-h-[24rem]" /> };
  }

  if (!payPeriod) {
    return { status: 'missing' as const, fallback: (
      <div className="rounded-2xl border border-danger-200 bg-danger-50 p-6" role="alert">
        <p className="font-semibold text-danger-800">Pay period not found</p>
        {error && <p className="mt-1 text-sm text-danger-700">{error}</p>}
        {payRunId > 0 && (
          <Button className="mt-4" variant="outline" onClick={() => void loadPayPeriod(payRunId)}>Try again</Button>
        )}
      </div>
    ) };
  }

  const isDraft = payPeriod.status === 'draft';
  const isCalculated = payPeriod.status === 'calculated';
  const isApproved = payPeriod.status === 'approved';
  const isCommitted = payPeriod.status === 'committed';
  const isVoided = payPeriod.correction_status === 'voided';
  const isCorrection = payPeriod.correction_status === 'correction';
  const payableItems = payrollItems.filter((item) => !item.voided && toNumber(item.net_pay) > 0);
  const paperCheckCount = payableItems.filter((item) => item.effective_payment_delivery_method !== 'direct_deposit').length;
  const directDepositCount = payableItems.filter((item) => item.effective_payment_delivery_method === 'direct_deposit').length;
  const statusConfig = payPeriodStatusConfig[payPeriod.status];

  const syncStatus = payPeriod.tax_sync_status as TaxSyncStatus | null | undefined;
  const syncConfig = syncStatus ? taxSyncStatusConfig[syncStatus] : null;
  const MAX_SYNC_ATTEMPTS = 5;
  const canRetrySyncTax = isCommitted && (syncStatus === 'failed' || syncStatus === 'pending');
  const canEditPayPeriod = !isCommitted && !isVoided && !savedImportReloadRequired;
  const canImportMosa = canEditPayPeriod && (payPeriod.payroll_intake_source_types || []).includes('mosa_revel');
  const canImportSpikeIntake = canEditPayPeriod && (payPeriod.payroll_intake_source_types || []).includes('spike_email');
  const activeTimeTrackingSources = payPeriod.time_tracking?.active_source_types || [];
  const canImportTimeTracking = isDraft && canEditPayPeriod && activeTimeTrackingSources.length > 0;
  const canLinkAireRecord = isCommitted && !isVoided && ((payPeriod.time_tracking?.active_source_capabilities || []).includes('finalized_batch_v2') || activeTimeTrackingSources.includes('aire_services'));
  const linkedAireRecords = payPeriod.time_tracking?.linked_aire_records || [];
  const finalizedAireBatchId = payPeriod.time_tracking?.aire_calendar?.finalized_batch?.payroll_batch_id;
  const currentAireRecord = finalizedAireBatchId
    ? linkedAireRecords.find((record) => record.external_batch_id === finalizedAireBatchId) || null
    : linkedAireRecords[0] || null;

  // Summaries
  const reportablePayrollItems = payrollItems.filter(i => i.payroll_included !== false);
  // Committed history may predate captured earning evidence. Only explicit
  // server holds apply there; worksheet fallbacks still protect editable runs.
  const hasCorrectionPayBasisHold = reportablePayrollItems.some((item): boolean => isCommitted
    ? Boolean(item.correction_pay_basis_hold)
    : Boolean(worksheetPayBasisHold(item, employees.find((employee): boolean => employee.id === item.employee_id))));
  const correctionCalculationHeld = !isCommitted && hasCorrectionPayBasisHold;
  const financialActionsHeld = correctionCalculationHeld || savedImportReloadRequired;
  const hasLinkedAireRecord = linkedAireRecords.length > 0;
  const payrollItemByEmployeeId = new Map(reportablePayrollItems.map((item) => [item.employee_id, item]));
  const contractorItems = reportablePayrollItems.filter(i => i.employment_type === 'contractor');
  const totalGross = reportablePayrollItems.reduce((s, i) => s + toNumber(i.gross_pay), 0);
  const totalWithholding = reportablePayrollItems.reduce((s, i) => s + toNumber(i.withholding_tax), 0);
  const totalAddlWH = reportablePayrollItems.reduce((s, i) => s + toNumber(i.additional_withholding), 0);
  const totalSS = reportablePayrollItems.reduce((s, i) => s + toNumber(i.social_security_tax), 0);
  const totalMedicare = reportablePayrollItems.reduce(
    (s, i) => s + payrollTaxSummary(i).totalMedicare,
    0,
  );
  const totalDeductions = reportablePayrollItems.reduce((s, i) => s + toNumber(i.total_deductions), 0);
  const totalNet = reportablePayrollItems.reduce((s, i) => s + toNumber(i.net_pay), 0);
  const totalEmployerSS = reportablePayrollItems.reduce((s, i) => s + toNumber(i.employer_social_security_tax), 0);
  const totalEmployerMedicare = reportablePayrollItems.reduce((s, i) => s + toNumber(i.employer_medicare_tax), 0);
  const totalDRTDeposit = totalWithholding + totalAddlWH;

  // Detect FIT-deposit override: if the user has edited the auto-FIT
  // non-employee check's amount, it'll no longer equal the calculated
  // FIT total derived from PayrollItem.withholding_tax. Surfacing this
  // divergence prevents silent desync between "what payroll says we owe"
  // and "what we're actually depositing."
  const fitDepositCheck = nonEmployeeChecks.find(
    c =>
      !c.voided &&
      (c.auto_generated_type === 'fit_deposit' ||
        (c.check_type === 'tax_deposit' &&
          (c.payable_to === 'Treasurer of Guam' || c.payable_to === 'EFTPS - Federal Income Tax')))
  );
  const fitDepositAmount = fitDepositCheck ? Number(fitDepositCheck.amount) : null;
  const fitDivergence =
    fitDepositAmount !== null && Math.abs(fitDepositAmount - totalDRTDeposit) > 0.005
      ? { calculated: totalDRTDeposit, deposited: fitDepositAmount, delta: fitDepositAmount - totalDRTDeposit }
      : null;
  const totalContractorPay = contractorItems.reduce((s, i) => s + toNumber(i.gross_pay), 0);

  const comparisonHighlights = comparison
    ? ['employee_count', 'gross_pay', 'net_pay', 'fit', 'reported_tips', 'loan_deduction']
      .filter((key) => comparison.summary[key])
      .map((key) => ({ key, ...comparison.summary[key] }))
    : [];
  const comparisonFlagTone = comparison?.review_flags.status === 'warning'
    ? 'border-danger-200 bg-danger-50 text-danger-800'
    : comparison?.review_flags.status === 'review'
      ? 'border-warning-200 bg-warning-50 text-warning-800'
      : 'border-emerald-200 bg-emerald-50 text-emerald-800';
  const comparisonRowLimit = 10;
  const comparisonTotalRows = comparison?.employee_changes.length || 0;
  const comparisonRows = comparison?.employee_changes.slice(0, comparisonRowLimit) || [];
  const comparisonHiddenRows = Math.max(0, comparisonTotalRows - comparisonRows.length);

  const visiblePayrollFields = payrollFields
    .filter((field) => field.show_in_payroll_grid)
    .filter((field) => payrollItems.some((item) => (item.payroll_field_entries || []).some((entry) => entry.active !== false && entry.payroll_field_definition_id === field.id)))
    .sort((left, right) => (left.sort_order - right.sort_order) || left.name.localeCompare(right.name));
  const worksheetPayrollFields = payrollFields
    .filter((field) => field.show_in_payroll_grid)
    .filter((field) => payrollFieldAssignments.some((assignment) => assignment.payroll_field_definition_id === field.id))
    .sort((left, right) => (left.sort_order - right.sort_order) || left.name.localeCompare(right.name));
  const payrollFieldAssignmentLookup = new Map(
    payrollFieldAssignments.map((assignment) => [
      `${assignment.employee_id}:${assignment.payroll_field_definition_id}`,
      assignment,
    ])
  );
  const calculatedUiState = derivePayrollUiState(payrollItems);
  const calculatedHoursMap = buildHoursMap(payrollItems, employees);
  const payrollFieldDraftsChanged = payrollFieldAssignments.some((assignment) => {
    const key = `${assignment.employee_id}:${assignment.payroll_field_definition_id}`;
    const currentDraft = payrollFieldDrafts[key];
    const calculatedMode = assignment.overridden ? 'override' : 'default';
    const calculatedAmount = assignment.requested_amount ?? assignment.current_amount ?? assignment.suggested_amount ?? null;
    return !currentDraft
      || currentDraft.mode !== calculatedMode
      || !payrollFieldAmountsEqual(currentDraft.amount, calculatedAmount);
  });
  const hasStagedWorksheetChanges = (
    additionalEmployeeIds.size > 0
    || !hoursRecordsEqual(hoursMap, calculatedHoursMap)
    || !numericRecordsEqual(salaryOverrideMap, calculatedUiState.salaryOverrides)
    || !numericRecordsEqual(bonusMap, calculatedUiState.bonuses)
    || !tipRecordsEqual(tipsMap, calculatedUiState.tips)
    || !numericRecordsEqual(tipsPaidOutMap, calculatedUiState.tipsPaidOut)
    || !numericRecordsEqual(loansMap, calculatedUiState.loans)
    || namedLoanOptions.some(option => {
      const draft = namedLoanDrafts[String(option.employee_id)]?.[String(option.loan_id)];
      return draft && (draft.mode !== option.mode || (draft.mode === 'override'
        && Math.abs(toNumber(draft.amount) - toNumber(option.requested_amount)) > 0.005));
    })
    || payrollFieldDraftsChanged
  );
  const hasPendingCalculationChanges = isCalculated && hasStagedWorksheetChanges;
  const standaloneLoanConflicts = namedLoanOptions.filter(option => {
    const draft = namedLoanDrafts[String(option.employee_id)]?.[String(option.loan_id)];
    const mode = draft?.mode ?? option.mode;
    const requestedAmount = draft ? draft.amount : option.requested_amount;
    const draftDiffers = draft && (draft.mode !== option.mode
      || Math.abs(toNumber(draft.amount) - toNumber(option.requested_amount)) > 0.005);
    const hasStagedNamedRepayment = draftDiffers && draft?.mode === 'override'
      && draft.amount != null && draft.amount > 0;
    return option.eligible
      && toNumber(loansMap[String(option.employee_id)]) > 0
      && toNumber(option.current_amount) <= 0
      && !hasStagedNamedRepayment
      && !(mode === 'override' && requestedAmount != null && toNumber(requestedAmount) === 0);
  });
  const estimateWorksheetGross = (employee: Employee): number | null => {
    const item = payrollItemByEmployeeId.get(employee.id);
    if ((isCalculated || worksheetPayBasisHold(item, employee)) && item) return toNumber(item.gross_pay);
    const key = String(employee.id);
    return estimateDraftGross({
      employee, item, period: payPeriod, hours: hoursMap[key],
      salaryOverride: salaryOverrideMap[key], bonus: bonusMap[key],
      reportedTips: tipsMap[key]?.amount, tipsPaidOut: tipsPaidOutMap[key],
      fields: [...payrollFields.flatMap(field => {
        const assignment = payrollFieldAssignmentLookup.get(`${employee.id}:${field.id}`);
        if (!assignment) return [];
        const draft = payrollFieldDrafts[`${employee.id}:${field.id}`];
        return [{ id: field.id, taxTreatment: field.tax_treatment, amountType: assignment.amount_type,
          editable: assignment.editable, mode: draft?.mode ?? 'default', source: assignment.current_source,
          currentAmount: assignment.current_amount,
          amount: draft?.mode === 'override' ? draft.amount : assignment.assigned_amount ?? assignment.default_amount,
          percentage: assignment.assigned_percentage ?? assignment.default_percentage }];
      }), ...estimateOnlyAssignments.filter(assignment => assignment.employee_id === employee.id).map(assignment => ({
        id: assignment.payroll_field_definition_id, taxTreatment: assignment.tax_treatment,
        amountType: assignment.amount_type, editable: false, automatic: true, mode: 'default' as const,
        source: assignment.current_source, currentAmount: assignment.current_amount, currentActive: assignment.current_active,
        amount: assignment.assigned_amount ?? assignment.default_amount,
        percentage: assignment.assigned_percentage ?? assignment.default_percentage,
      }))],
    });
  };

  // showTipsLoans is toggled by user or auto-set when imported data has tips/loans

  const employeeLookup = new Map(employees.map((emp) => [emp.id, emp]));
  const payrollItemNameParts = (item: PayrollItem): { firstName: string; lastName: string } => {
    const employee = employeeLookup.get(item.employee_id);
    const firstName = item.employee_first_name || employee?.first_name || '';
    const lastName = item.employee_last_name || employee?.last_name || '';

    if (!firstName && !lastName && item.employee_name) {
      return { firstName: '', lastName: item.employee_name };
    }

    return {
      firstName,
      lastName,
    };
  };
  const payrollItemDisplayedHours = (item: PayrollItem): number => {
    const employee = employeeLookup.get(item.employee_id);
    const contractorPayType = item.contractor_pay_type || employee?.contractor_pay_type;
    const regularHours = toNumber(item.hours_worked);
    const overtimeHours = toNumber(item.overtime_hours);
    const isSalary = item.employment_type === 'salary';
    const isContractorFlat = item.employment_type === 'contractor' && contractorPayType !== 'hourly';
    const hasSalaryTimekeeping = Boolean(item.timekeeping_source) || regularHours > 0 || overtimeHours > 0;
    const activeWageRates = (item.wage_rate_hours || []).filter((rate) => rate.active !== false);
    const showsMultiRateHours = (item.employment_type === 'hourly' || contractorPayType === 'hourly')
      && (item.wage_rate_hours || []).length > 1;

    if (isContractorFlat || (isSalary && !hasSalaryTimekeeping)) return 0;
    if (showsMultiRateHours) {
      return activeWageRates.reduce(
        (sum, rate) => sum + toNumber(rate.regular_hours) + toNumber(rate.overtime_hours),
        0
      );
    }

    return regularHours + overtimeHours;
  };
  const departmentOptions = Array.from(
    new Map(
      [
        ...employees
          .filter((emp) => emp.department_id && emp.department?.name)
          .map((emp) => [String(emp.department_id), emp.department?.name || ''] as const),
        ...payrollItems
          .filter((item) => item.department_id && item.department_name)
          .map((item) => [String(item.department_id), item.department_name || ''] as const),
      ].sort((left, right) => left[1].localeCompare(right[1]))
    ).entries()
  );

  const employmentGroupKey = (employmentType: string): EmploymentGroup => employmentType === 'contractor' ? 'contractor' : 'w2';
  const employmentGroupOrder: Record<EmploymentGroup, number> = { w2: 0, contractor: 1 };
  const employmentGroupLabel = (group: EmploymentGroup, activeFilter: typeof employeeTypeFilter) => {
    if (group === 'contractor') return '1099 contractors';
    if (activeFilter === 'salary') return 'Salary Employees';
    if (activeFilter === 'hourly') return 'Hourly Employees';
    return 'W-2 Employees';
  };
  const employmentGroupTone = (employmentType: string) => (
    employmentType === 'contractor'
      ? { row: 'bg-emerald-50', text: 'text-emerald-700' }
      : { row: 'bg-indigo-50', text: 'text-indigo-700' }
  );
  const employeeNameSortKey = (employee: Pick<Employee, 'first_name' | 'last_name'>) => (
    `${employee.last_name || ''} ${employee.first_name || ''}`.trim()
  );
  const matchesEmployeeFilters = (employmentType: string, searchableValues: string[], departmentId?: number | null) => {
    if (employeeTypeFilter !== 'all' && employmentType !== employeeTypeFilter) return false;
    if (departmentFilter !== 'all' && String(departmentId || '') !== departmentFilter) return false;
    if (!searchTerm.trim()) return true;

    const term = searchTerm.trim().toLowerCase();
    return searchableValues.some((value) => value.toLowerCase().includes(term));
  };

  const compareDirectional = (left: number | string, right: number | string, direction: 'asc' | 'desc') => {
    const multiplier = direction === 'asc' ? 1 : -1;
    if (typeof left === 'string' && typeof right === 'string') {
      return left.localeCompare(right) * multiplier;
    }

    return ((Number(left) || 0) - (Number(right) || 0)) * multiplier;
  };
  const employeeLastNameSortKey = (item: PayrollItem) => {
    const employee = employeeLookup.get(item.employee_id);
    const lastName = item.employee_last_name || employee?.last_name || '';
    const firstName = item.employee_first_name || employee?.first_name || '';
    return `${lastName} ${firstName} ${item.employee_name || ''}`.trim();
  };

  const sortPayrollItems = [...reportablePayrollItems]
    .filter((item) => matchesEmployeeFilters(
      item.employment_type,
      [item.employee_name || '', item.check_number || '', item.department_name || employeeLookup.get(item.employee_id)?.department?.name || ''],
      item.department_id ?? employeeLookup.get(item.employee_id)?.department_id
    ))
    .sort((left, right) => {
      const groupDiff = employeeTypeFilter === 'all'
        ? (employmentGroupOrder[employmentGroupKey(left.employment_type)] ?? 9) - (employmentGroupOrder[employmentGroupKey(right.employment_type)] ?? 9)
        : 0;
      if (groupDiff !== 0) return groupDiff;

      const nameTieBreak = () => employeeLastNameSortKey(left).localeCompare(employeeLastNameSortKey(right));

      switch (resultsSortBy) {
      case 'rate':
        return compareDirectional(toNumber(left.pay_rate), toNumber(right.pay_rate), resultsSortDirection) || nameTieBreak();
      case 'hours':
        return compareDirectional(
          payrollItemDisplayedHours(left),
          payrollItemDisplayedHours(right),
          resultsSortDirection
        ) || nameTieBreak();
      case 'gross':
        return compareDirectional(toNumber(left.gross_pay), toNumber(right.gross_pay), resultsSortDirection) || nameTieBreak();
      case 'net':
        return compareDirectional(toNumber(left.net_pay), toNumber(right.net_pay), resultsSortDirection) || nameTieBreak();
      case 'fit':
        return compareDirectional(toNumber(left.withholding_tax), toNumber(right.withholding_tax), resultsSortDirection) || nameTieBreak();
      case 'name':
      default:
        return compareDirectional(
          employeeLastNameSortKey(left),
          employeeLastNameSortKey(right),
          resultsSortDirection
        );
      }
    });
  const registerTotals = sortPayrollItems.reduce((totals, item) => {
    totals.hours += payrollItemDisplayedHours(item);
    totals.gross += toNumber(item.gross_pay);
    totals.customEarnings += (item.custom_earnings || []).reduce((sum, earning) => sum + toNumber(earning.amount), 0);
    totals.customDeductions += (item.custom_deductions || []).reduce((sum, deduction) => sum + toNumber(deduction.amount), 0);
    totals.payrollAdjustments += (item.payroll_adjustments || [])
      .filter((adjustment) => adjustment.active !== false)
      .reduce((sum, adjustment) => {
        const amount = toNumber(adjustment.amount);
        return sum + (adjustment.treatment === 'pre_tax_deduction' || adjustment.treatment === 'post_tax_deduction' ? -amount : amount);
      }, 0);
    totals.tips += toNumber(item.reported_tips);
    totals.tipsPaidOut += toNumber(item.tips_paid_out);
    totals.loans += effectiveLoanDeduction(item);
    totals.withholding += toNumber(item.withholding_tax);
    totals.additionalWithholding += toNumber(item.additional_withholding);
    totals.socialSecurity += toNumber(item.social_security_tax);
    totals.employeeMedicare += payrollTaxSummary(item).totalMedicare;
    totals.employerMedicare += toNumber(item.employer_medicare_tax);
    totals.deductions += toNumber(item.total_deductions);
    totals.net += toNumber(item.net_pay);
    return totals;
  }, {
    hours: 0,
    gross: 0,
    customEarnings: 0,
    customDeductions: 0,
    payrollAdjustments: 0,
    tips: 0,
    tipsPaidOut: 0,
    loans: 0,
    withholding: 0,
    additionalWithholding: 0,
    socialSecurity: 0,
    employeeMedicare: 0,
    employerMedicare: 0,
    deductions: 0,
    net: 0,
  });
  const registerPayrollFieldTotals = new Map(
    visiblePayrollFields.map((field) => [
      field.id,
      sortPayrollItems.reduce((sum, item) => {
        const entry = (item.payroll_field_entries || []).find(
          (candidate) => candidate.active !== false && candidate.payroll_field_definition_id === field.id
        );
        return sum + toNumber(entry?.amount);
      }, 0),
    ])
  );

  const lifecycle = payPeriod.lifecycle || {};
  const processedAt = payPeriod.processed_at || payPeriod.committed_at || lifecycle.committed?.timestamp;
  const processedBy = payPeriod.processed_by_name || lifecycle.committed?.actor_name;
  const payDateCorrections = payPeriod.pay_date_corrections || [];
  const formatCorrectionPayDate = (date?: string | null) => (
    date ? formatDate(date, { month: 'long', day: 'numeric', year: 'numeric' }) : 'Unknown date'
  );
  const lifecycleActor = (actorName?: string | null) => {
    if (actorName) return `by ${actorName}`;
    return 'Operator not recorded';
  };
  const lifecycleItems = [
    {
      label: 'Created',
      timestamp: lifecycle.created?.timestamp || payPeriod.created_at,
      actor: lifecycleActor(lifecycle.created?.actor_name),
      tone: 'default' as const,
    },
    {
      label: isDraft ? 'Last calculation attempt' : 'Calculated',
      timestamp: lifecycle.calculated?.timestamp,
      actor: lifecycleActor(lifecycle.calculated?.actor_name),
      tone: isDraft ? 'default' as const : 'warning' as const,
    },
    {
      label: 'Approved',
      timestamp: lifecycle.approved?.timestamp,
      actor: lifecycleActor(lifecycle.approved?.actor_name),
      tone: (isApproved || isCommitted) ? 'info' as const : 'default' as const,
    },
    ...(lifecycle.unapproved?.timestamp ? [{
      label: 'Unapproved',
      timestamp: lifecycle.unapproved.timestamp,
      actor: lifecycleActor(lifecycle.unapproved.actor_name),
      tone: 'warning' as const,
    }] : []),
    {
      label: 'Committed / processed',
      timestamp: processedAt,
      actor: processedBy
        ? `by ${processedBy}`
        : lifecycleActor(lifecycle.committed?.actor_name),
      tone: isCommitted ? 'success' as const : 'default' as const,
    },
    ...(syncStatus || payPeriod.tax_synced_at ? [{
      label: 'Tax sync',
      timestamp: lifecycle.tax_synced?.timestamp || payPeriod.tax_synced_at,
      actor: syncConfig?.label || 'Not started',
      tone: syncConfig?.variant || 'default' as const,
    }] : []),
  ].sort((left, right) => {
    if (left.timestamp && right.timestamp) {
      return new Date(left.timestamp).getTime() - new Date(right.timestamp).getTime();
    }

    if (left.timestamp) return -1;
    if (right.timestamp) return 1;
    return 0;
  });



  const displayEmployeesForHours = (() => {
        const payrollEmployeeIds = new Set(payrollItems.map((pi) => pi.employee_id));
        const filtered = isCalculated || payPeriod.run_purpose !== 'regular'
          ? employees.filter((emp) => payrollEmployeeIds.has(emp.id) || additionalEmployeeIds.has(emp.id))
          : employees;
        const displayEmployees = [...filtered]
          .filter((emp) => matchesEmployeeFilters(
            emp.employment_type,
            [`${emp.first_name} ${emp.last_name}`, `${emp.last_name}, ${emp.first_name}`, emp.department?.name || ''],
            emp.department_id
          ))
          .sort((a, b) => {
            const groupDiff = employeeTypeFilter === 'all'
              ? (employmentGroupOrder[employmentGroupKey(a.employment_type)] ?? 9) - (employmentGroupOrder[employmentGroupKey(b.employment_type)] ?? 9)
              : 0;
            if (groupDiff !== 0) return groupDiff;

            const nameTieBreak = () => employeeNameSortKey(a).localeCompare(employeeNameSortKey(b));

            if (hoursSortBy === 'rate') {
              return compareDirectional(toNumber(a.pay_rate), toNumber(b.pay_rate), hoursSortDirection) || nameTieBreak();
            }

            if (hoursSortBy === 'hours') {
              const aHours = toNumber(hoursMap[String(a.id)]?.regular) + toNumber(hoursMap[String(a.id)]?.overtime);
              const bHours = toNumber(hoursMap[String(b.id)]?.regular) + toNumber(hoursMap[String(b.id)]?.overtime);
              return compareDirectional(aHours, bHours, hoursSortDirection) || nameTieBreak();
            }

            if (hoursSortBy === 'gross') {
              const left = estimateWorksheetGross(a);
              const right = estimateWorksheetGross(b);
              if (left == null || right == null) return Number(left == null) - Number(right == null) || nameTieBreak();
              return compareDirectional(left, right, hoursSortDirection) || nameTieBreak();
            }

            return compareDirectional(
              employeeNameSortKey(a),
              employeeNameSortKey(b),
              hoursSortDirection
            );
          });
    return displayEmployees;
  })();

  return { status: 'ready' as const, sections: {
    coverage: { commitRouteGenerationRef, companyId, handleRefreshSetup, handleRunPayroll, payRunId, pendingCoverageActionRef, processing, setSourceCoverageAcknowledged, setSourceCoverageOpen, setSourceCoverageReason, sourceCoverageAcknowledged, sourceCoverageOpen, sourceCoverageReason },
    reviewDialogs: { companyId, currentPath, loadPayPeriod, payPeriod, payRunId, paymentMethodItem, reviewingItem, setPaymentMethodItem, setReviewingItem },
    summary: { contractorItems, hasCorrectionPayBasisHold, payrollItems, totalContractorPay, totalDRTDeposit, totalDeductions, totalGross, totalNet },
    processing: { calculationFailures, canEditPayPeriod, canImportMosa, canImportSpikeIntake, canImportTimeTracking, canLinkAireRecord, companyId, correctionCalculationHeld, financialActionsHeld, handleApprove, handleRunPayroll, handleUnapprove, hasLinkedAireRecord, hasPendingCalculationChanges, hasStagedWorksheetChanges, isApproved, isCalculated, isCommitted, isDraft, isVoided, openPayDateCorrection, payPeriod, payRunId, payrollItems, processing, returnTo, savedImportReloadRequired, setAireRecordsOpen, setCommitPeriodId, setImportModalOpen, setPayrollIntakeImportOpen, setRefreshBaseSalary, setRefreshRecurring, setRefreshSetupOpen, setTimeTrackingAutoPreview, setTimeTrackingImportOpen, standaloneLoanConflicts },
    feedback: { calculationFailures, calculationNotice, calendarRefreshError, companyId, currentPath, employees, error, errorFeedbackAttempt, payPeriod, payrollItems, processing, reloadSavedSourceImport, savedImportReloadRequired, timeTrackingImportOpen, worksheetRefreshWarning },
    blockers: { adoptingConfirmedWorkweek, canImportMosa, canImportSpikeIntake, clientApprovalLoading, handleAdoptConfirmedWorkweek, hasPendingCalculationChanges, openClientApproval, payPeriod, setImportModalOpen, setPayrollIntakeImportOpen },
    source: { aireSourceRefreshToken, currentAireRecord, hoursMap, invalidateAireSource, loadPayPeriod, payPeriod, setTimeTrackingAutoPreview, setTimeTrackingImportOpen },
    metadata: { MAX_SYNC_ATTEMPTS, canRetrySyncTax, formatCorrectionPayDate, handleRetryTaxSync, isApproved, isCalculated, isCommitted, isCorrection, isVoided, payDateCorrections, payPeriod, processedBy, retryingSyncTax, statusConfig, syncConfig, syncStatus },
    refreshDialog: { error, handleRefreshSetup, processing, refreshBaseSalary, refreshRecurring, refreshSetupOpen, setRefreshBaseSalary, setRefreshRecurring, setRefreshSetupOpen, sourceCoverageOpen },
    loans: { additionalEmployeeIds, canEditPayPeriod, employees, isCalculated, isDraft, namedLoanDrafts, namedLoanOptions, payPeriod, payrollItems, setNamedLoanDrafts, standaloneLoanConflicts },
    comparison: { comparison, comparisonError, comparisonFlagTone, comparisonHiddenRows, comparisonHighlights, comparisonLoading, comparisonRows, comparisonTotalRows, isApproved, isCalculated, isCommitted, loadComparison, payPeriod, payrollItems },
    roster: { additionalEmployeeIds, employees, financialActionsHeld, handleRunPayroll, isCalculated, isDraft, payPeriod, payrollItems, processing, setAdditionalEmployeeIds, setBonusEdits, setBonusMap, setHoursMap, setLoansMap, setNamedLoanDrafts, setPayrollFieldDrafts, setSalaryOverrideMap, setTipsMap, setTipsPaidOutMap },
    hours: { additionalEmployeeIds, bonusEdits, bonusMap, companyId, currentPath, departmentFilter, departmentOptions, displayEmployeesForHours, employeeTypeFilter, employees, employmentGroupKey, employmentGroupLabel, employmentGroupTone, estimateWorksheetGross, hoursMap, hoursSortBy, hoursSortDirection, hoursTableOpen, isCalculated, isDraft, loansMap, namedLoanDrafts, namedLoanOptions, payPeriod, payrollFieldAssignmentLookup, payrollFieldDrafts, payrollItemByEmployeeId, payrollItems, resetPayrollFieldDraft, retainedRetirementEntries, salaryOverrideMap, searchTerm, setBonusEdits, setBonusMap, setDepartmentFilter, setEmployeeTypeFilter, setHoursSortBy, setHoursSortDirection, setHoursTableOpen, setNamedLoanDrafts, setSearchTerm, setShowPayrollFields, setShowTipsLoans, showPayrollFields, showTipsLoans, tipsLoansVisibilityModeRef, tipsMap, tipsPaidOutMap, updateHours, updateLoan, updatePayrollFieldDraft, updateSalaryOverride, updateTip, updateTipsPaidOut, updateWageRateHours, worksheetPayrollFields },
    results: { companyId, currentPath, departmentFilter, departmentOptions, employeeLookup, employeeTypeFilter, employmentGroupKey, employmentGroupLabel, employmentGroupTone, isCalculated, isCommitted, isDraft, payPeriod, payrollItemDisplayedHours, payrollItemNameParts, payrollItems, registerPayrollFieldTotals, registerTotals, resultsSortBy, resultsSortDirection, searchTerm, setCorrectingItem, setDepartmentFilter, setEditingItem, setEmployeeTypeFilter, setReplacingItem, setResultsSortBy, setResultsSortDirection, setReviewingItem, setSearchTerm, sortPayrollItems, visiblePayrollFields },
    employerTaxes: { fitDivergence, isDraft, payrollItems, totalDRTDeposit, totalEmployerMedicare, totalEmployerSS, totalMedicare, totalSS, totalWithholding },
    liabilities: { isCommitted, liabilityError, liabilityLoading, liabilityReconciliation },
    empty: { companyId, currentPath, employees, isDraft, payrollItems },
    linkedCorrections: { companyId, currentPath, isCommitted, payPeriod, supplementals, supplementalsLoading },
    checks: { checkPrintRefreshToken, companyId, isCommitted, loadPayPeriod, nonEmployeeChecks, paperCheckCount, payPeriod, returnTo, searchTerm, setCheckPrintOpen },
    supporting: { aireSourceRefreshToken, directDepositCount, invalidateAireSource, isCommitted, isVoided, lifecycleItems, loadPayPeriod, paperCheckCount, payPeriod, payableItems, payrollItems, setPaymentMethodItem },
    ocr: { handlePayrollItemApplied, isDraft, payPeriod },
    nonEmployeeChecks: { checkPrintRefreshToken, handleNonEmployeeChecksChanged, handleNonEmployeeChecksLoaded, isCommitted, isVoided, payPeriod },
    printDialog: { checkPrintOpen, isCommitted, loadPayPeriod, payPeriod, setCheckPrintOpen, setCheckPrintRefreshToken },
    reports: { companyId, finalRecordRefreshToken, isCommitted, isDraft, payPeriod, payRunId, payrollItems },
    timecardHistory: { isDraft, payPeriod },
    corrections: { commitRouteGenerationRef, correctionRouteGeneration, isCommitted, isCorrection, isVoided, loadPayPeriod, payPeriod, payRunId, returnTo, setCheckPrintRefreshToken, setPayPeriod, setPayrollItems },
    dialogs: { activeCompany, aireRecordsOpen, clientApprovalConfirmed, clientApprovalEvidence, clientApprovalLoading, clientApprovalNotes, clientApprovalOpen, clientApproverId, clientApprovers, commitPeriodId, companyId, correctingItem, editingItem, employeeLookup, employees, handleCommit, handleCorrectPayDate, handleImportComplete, handlePayrollItemSaved, importModalOpen, invalidateAireSource, isApproved, isVoided, linkedAireRecords, loadPayPeriod, loadSupplementals, payDateCorrectionDate, payDateCorrectionOpen, payDateCorrectionReason, payDateCorrectionSubmitting, payPeriod, payRunId, payrollIntakeImportOpen, payrollItems, processing, recordClientApproval, reloadSavedSourceImport, replacingItem, reportablePayrollItems, setAdditionalEmployeeIds, setAireRecordsOpen, setClientApprovalConfirmed, setClientApprovalEvidence, setClientApprovalNotes, setClientApprovalOpen, setClientApproverId, setCommitPeriodId, setCorrectingItem, setEditingItem, setEmployees, setHoursMap, setImportModalOpen, setPayDateCorrectionDate, setPayDateCorrectionOpen, setPayDateCorrectionReason, setPayPeriod, setPayrollIntakeImportOpen, setPayrollItems, setReplacingItem, setTimeTrackingAutoPreview, setTimeTrackingImportOpen, timeTrackingAutoPreview, timeTrackingImportOpen, totalNet }
  } };
}

export type PayRunSections = Extract<ReturnType<typeof usePayRunController>, { status: 'ready' }>['sections'];
export type PayRunSectionProps<K extends keyof PayRunSections> = PayRunSections[K];
