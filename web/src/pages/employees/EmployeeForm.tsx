import { useFeedbackState, ActionFeedback, useFeedback } from '@/components/ui/action-feedback';
import { useState, useEffect, useLayoutEffect, useCallback, useRef } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router';
import { ArrowLeft, Save, Trash2, AlertCircle, Plus, X, RotateCcw, FileText, LockKeyhole, ArrowRightLeft, CheckCircle2, XCircle, Link2 } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card, CardHeader, CardTitle, CardContent, CardDescription } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { NumericInput } from '@/components/ui/numeric-input';
import { Select } from '@/components/ui/select';
import { Dialog, DialogContent } from '@/components/ui/dialog';
import { EmployeePayItemsPanel } from '@/components/employees/EmployeePayItemsPanel';
import { EmployeeDocumentsPanel } from '@/components/employees/EmployeeDocumentsPanel';
import { EmployeeClassificationTransitionDialog } from '@/components/employees/EmployeeClassificationTransitionDialog';
import { EmployeeStatusTransitionDialog } from '@/components/employees/EmployeeStatusTransitionDialog';
import { EmployeeWorkProfilePanel } from '@/components/employees/EmployeeWorkProfilePanel';
import { canonicalSsn, importedProfileAllowsBlank, validateHireDate, withDocumentReadiness } from '@/lib/employee-profile';
import { canWriteCompany, companyReadOnlyMessage } from '@/lib/company-write-access';
import { employeesApi, departmentsApi, employeeWageRatesApi, clientEmployeesApi, clientDepartmentsApi, employeePayrollFieldsApi, payPeriodsApi, ApiError, type EmployeeDocumentReadinessResponse } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';
import { useCompany } from '@/contexts/CompanyContext';
import { useEmployeeIntakeSettings } from '@/hooks/useEmployeeIntakeSettings';
import { intakeAllowsBlank, intakeFieldLabels } from '@/lib/employee-intake';
import { employeeEditPath, employeePath, employeesPath, safeInternalReturnPath } from '@/lib/routes';
import { filingStatusLabels, formatCurrency } from '@/lib/utils';
import type { Department, Employee, EmployeeFormData, FilingStatus, EmploymentType, PayFrequency, PaymentDeliveryMethod, ContractorType, ContractorPayType, EmployeeWageRate, PayrollAdjustmentTreatment, EmployeePayrollField, PayrollFieldDefinition, PayrollFieldKind, PayrollFieldTaxTreatment, PayrollFieldCategory, PayrollFieldReportingGroup, PayrollFieldAmountType } from '@/types';

const initialFormData: EmployeeFormData = {
  first_name: '',
  middle_name: '',
  last_name: '',
  job_title: '',
  ssn: '',
  ssn_confirmation: '',
  date_of_birth: '',
  hire_date: '',
  employment_type: 'hourly',
  salary_type: 'annual',
  pay_rate: 0,
  pay_frequency: 'biweekly',
  payment_delivery_method: null,
  filing_status: 'single',
  allowances: 0,
  additional_withholding: 0,
  w4_dependent_credit: 0,
  w4_step2_multiple_jobs: false,
  w4_step4a_other_income: 0,
  w4_step4b_deductions: 0,
  w4_form_version: 2020,
  w4_effective_on: '',
  w4_signed_on: null,
  w4_source_reference: '',
  retirement_rate: 0,
  roth_retirement_rate: 0,
  employer_retirement_match_rate: 0,
  employer_roth_match_rate: 0,
  department_id: undefined,
  business_name: '',
  contractor_ein: '',
  contractor_type: 'individual',
  contractor_pay_type: 'flat_fee',
  w9_on_file: false,
  address_line1: '',
  address_line2: '',
  city: '',
  state: '',
  zip: '',
  default_payroll_adjustments: [],
};

interface FormErrors {
  [key: string]: string[];
}

interface WageRateFormRow extends EmployeeWageRate {
  temp_id: string;
}

interface PayrollAdjustmentFormRow {
  temp_id: string;
  label: string;
  amount: number;
  treatment: PayrollAdjustmentTreatment;
  notes: string;
  active: boolean;
}

interface LegacyCustomEarningFormRow {
  temp_id: string;
  label: string;
  amount: number;
}

interface QuickPayrollFieldDraft {
  name: string;
  kind: PayrollFieldKind;
  tax_treatment: PayrollFieldTaxTreatment;
  category: PayrollFieldCategory | '';
  reporting_group?: PayrollFieldReportingGroup | null;
  amount_type: PayrollFieldAmountType;
  default_amount: number;
  default_percentage: number;
  payee_name: string;
  reference_number: string;
  start_date: string;
  end_date: string;
  notes: string;
}

type LegacyPayItemSource =
  | { kind: 'adjustment'; row: PayrollAdjustmentFormRow }
  | { kind: 'custom_earning'; row: LegacyCustomEarningFormRow };

type W4MonetaryField =
  | 'additional_withholding'
  | 'w4_dependent_credit'
  | 'w4_step4a_other_income'
  | 'w4_step4b_deductions';

const defaultHourlyWageRate = (): WageRateFormRow => ({
  temp_id: crypto.randomUUID(),
  label: 'Regular',
  rate: 0,
  is_primary: true,
  active: true,
});

const roundCurrencyValue = (value: number): number => {
  if (!Number.isFinite(value)) return 0;
  return Math.round(value * 100) / 100;
};

const toNumberOrZero = (value: unknown): number => {
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};

const toBoolean = (value: unknown): boolean => value === true || value === 1 || value === '1';

const normalizeFilingStatus = (value: string): FilingStatus => {
  const aliases: Record<string, FilingStatus> = {
    married_separate: 'single',
    single_or_married_filing_separately: 'single',
    married_filing_jointly: 'married',
  };

  return aliases[value] || (value as FilingStatus);
};

const initialQuickPayrollFieldDraft = (): QuickPayrollFieldDraft => ({
  name: '',
  kind: 'deduction',
  tax_treatment: 'post_tax_deduction',
  category: 'other',
  reporting_group: null,
  amount_type: 'fixed',
  default_amount: 0,
  default_percentage: 0,
  payee_name: '',
  reference_number: '',
  start_date: '',
  end_date: '',
  notes: '',
});

const toCurrencyDraft = (value: number | null | undefined): string =>
  String(roundCurrencyValue(Number(value) || 0));

const reportingGroupOptions: Array<{ value: '' | PayrollFieldReportingGroup; label: string }> = [
  { value: '', label: 'No special report group' },
  { value: '401k_pre_tax', label: '401(k) Pre-Tax' },
  { value: '401k_after_tax', label: 'Roth 401(k)' },
  { value: '401k_non_roth_after_tax', label: '401(k) non-Roth after-tax' },
  { value: 'retirement_other', label: 'Other Retirement' },
];

const normalizeEmployeeMonetaryFields = (form: EmployeeFormData): EmployeeFormData => ({
  ...form,
  pay_rate: roundCurrencyValue(form.pay_rate),
  additional_withholding: roundCurrencyValue(form.additional_withholding),
  w4_dependent_credit: roundCurrencyValue(form.w4_dependent_credit),
  w4_step4a_other_income: roundCurrencyValue(form.w4_step4a_other_income),
  w4_step4b_deductions: roundCurrencyValue(form.w4_step4b_deductions),
});

export function EmployeeForm() {
  const { notify } = useFeedback();
  const navigate = useNavigate();
  const { id } = useParams<{ id: string }>();
  const [searchParams] = useSearchParams();
  const isEditing = Boolean(id);
  const { user, isClient, isSuperAdmin, isManager } = useAuth();
  const { activeCompanyId, activeCompany } = useCompany();
  // Use company_id from auth context, fall back to env var for dev mode
  const DEV_COMPANY_ID = parseInt(import.meta.env.VITE_COMPANY_ID || '1', 10);
  const companyId = activeCompanyId ?? user?.company_id ?? DEV_COMPANY_ID;
  const intake = useEmployeeIntakeSettings(companyId, isClient);
  const returnTo = safeInternalReturnPath(searchParams.get('return_to'), employeesPath(companyId));
  const airePayPeriodId = searchParams.get('aire_pay_period_id') || '';
  const aireSourceUserId = searchParams.get('aire_source_user_id') || '';
  const aireSourceUserUuid = searchParams.get('aire_source_user_uuid') || '';
  const aireFirstName = searchParams.get('first_name') || '';
  const aireLastName = searchParams.get('last_name') || '';

  const [form, setForm] = useState<EmployeeFormData>(initialFormData);
  const [loadedEmployee, setLoadedEmployee] = useState<Employee | null>(null);
  const [initialSsn, setInitialSsn] = useState('');
  const [storedSsnLastFour, setStoredSsnLastFour] = useState<string | null>(null);
  const [initialEmploymentType, setInitialEmploymentType] = useState<EmploymentType>('hourly');
  const [departments, setDepartments] = useState<Department[]>([]);
  const [payItemPending, setPayItemPending] = useState(false);
  const [payItemRefreshVersion, setPayItemRefreshVersion] = useState(0);
  const [showQuickPayrollField, setShowQuickPayrollField] = useState(false);
  const [quickPayrollField, setQuickPayrollField] = useState<QuickPayrollFieldDraft>(initialQuickPayrollFieldDraft());
  const [quickPayrollFieldError, setQuickPayrollFieldError, quickPayrollFieldErrorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [legacyPayItemSource, setLegacyPayItemSource] = useState<LegacyPayItemSource | null>(null);
  const [quickPayrollFieldSaving, setQuickPayrollFieldSaving] = useState(false);
  const [wageRates, setWageRates] = useState<WageRateFormRow[]>([defaultHourlyWageRate()]);
  const [defaultPayrollAdjustments, setDefaultPayrollAdjustments] = useState<PayrollAdjustmentFormRow[]>([]);
  const [legacyCustomEarnings, setLegacyCustomEarnings] = useState<LegacyCustomEarningFormRow[]>([]);
  const [w4CurrencyDrafts, setW4CurrencyDrafts] = useState<Record<W4MonetaryField, string>>({
    additional_withholding: toCurrencyDraft(initialFormData.additional_withholding),
    w4_dependent_credit: toCurrencyDraft(initialFormData.w4_dependent_credit),
    w4_step4a_other_income: toCurrencyDraft(initialFormData.w4_step4a_other_income),
    w4_step4b_deductions: toCurrencyDraft(initialFormData.w4_step4b_deductions),
  });
  const [w4ChangeReason, setW4ChangeReason] = useState('');
  const [w4ElectionReceived, setW4ElectionReceived] = useState(false);
  const [employeeStatus, setEmployeeStatus] = useState<string>('active');
  const [terminationDate, setTerminationDate] = useState<string | null>(null);
  const [errors, setErrors] = useState<FormErrors>({});
  const [generalError, setGeneralError, generalErrorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [statusTransitionMode, setStatusTransitionMode] = useState<'terminate' | 'reactivate' | null>(null);
  const [employeeDocumentsOpen, setEmployeeDocumentsOpen] = useState(false);
  const [classificationTransitionOpen, setClassificationTransitionOpen] = useState(false);
  const employeeRequestIdRef = useRef(0);
  const departmentsRequestIdRef = useRef(0);
  const quickPayrollFieldRequestIdRef = useRef(0);
  const quickPayrollFieldRef = useRef<HTMLDivElement>(null);
  const submissionGenerationRef = useRef(0);
  const companyIdRef = useRef<number | null>(companyId);
  const payFrequencyTouchedRef = useRef(false);

  useLayoutEffect((): (() => void) => {
    companyIdRef.current = companyId;
    submissionGenerationRef.current += 1;
    setIsSaving(false);
    return (): void => {
      companyIdRef.current = null;
      submissionGenerationRef.current += 1;
    };
  }, [companyId, id]);

  const supportsMultipleHourlyRates =
    form.employment_type === 'hourly' ||
    (form.employment_type === 'contractor' && form.contractor_pay_type === 'hourly');

  const w4HasChanged = Boolean(loadedEmployee && (
    normalizeFilingStatus(loadedEmployee.filing_status) !== form.filing_status
    || toNumberOrZero(loadedEmployee.allowances) !== toNumberOrZero(form.allowances)
    || roundCurrencyValue(toNumberOrZero(loadedEmployee.additional_withholding)) !== roundCurrencyValue(parseFloat(w4CurrencyDrafts.additional_withholding) || 0)
    || roundCurrencyValue(toNumberOrZero(loadedEmployee.w4_dependent_credit)) !== roundCurrencyValue(parseFloat(w4CurrencyDrafts.w4_dependent_credit) || 0)
    || toBoolean(loadedEmployee.w4_step2_multiple_jobs) !== form.w4_step2_multiple_jobs
    || roundCurrencyValue(toNumberOrZero(loadedEmployee.w4_step4a_other_income)) !== roundCurrencyValue(parseFloat(w4CurrencyDrafts.w4_step4a_other_income) || 0)
    || roundCurrencyValue(toNumberOrZero(loadedEmployee.w4_step4b_deductions)) !== roundCurrencyValue(parseFloat(w4CurrencyDrafts.w4_step4b_deductions) || 0)
    || toNumberOrZero(loadedEmployee.w4_form_version) !== toNumberOrZero(form.w4_form_version)
    || (loadedEmployee.w4_effective_on || '') !== (form.w4_effective_on || '')
    || (loadedEmployee.w4_signed_on || '') !== (form.w4_signed_on || '')
    || (loadedEmployee.w4_source_reference || '') !== (form.w4_source_reference || '')
  ));

  const fetchEmployee = useCallback(async () => {
    if (!id) return;

    const requestId = ++employeeRequestIdRef.current;
    const requestedCompanyId = companyId;
    const isCurrentRequest = (): boolean => (
      employeeRequestIdRef.current === requestId && companyIdRef.current === requestedCompanyId
    );

    setIsLoading(true);
    try {
      const response = isClient
        ? await clientEmployeesApi.get(parseInt(id, 10))
        : await employeesApi.get(parseInt(id, 10));
      if (!isCurrentRequest()) return;
      const employee = response.data;
      setLoadedEmployee(employee);

      const loadedSsn = isClient ? '' : formatSSN(employee.ssn || '');
      const nextForm = {
        first_name: employee.first_name,
        middle_name: employee.middle_name || '',
        last_name: employee.last_name,
        job_title: employee.job_title || '',
        ssn: loadedSsn,
        ssn_confirmation: '',
        date_of_birth: employee.date_of_birth || '',
        hire_date: employee.hire_date || '',
        employment_type: employee.employment_type,
        salary_type: employee.salary_type || 'annual',
        pay_rate: toNumberOrZero(employee.pay_rate),
        pay_frequency: employee.pay_frequency,
        payment_delivery_method: employee.payment_delivery_method || null,
        filing_status: normalizeFilingStatus(employee.filing_status),
        allowances: toNumberOrZero(employee.allowances),
        additional_withholding: toNumberOrZero(employee.additional_withholding),
        w4_dependent_credit: toNumberOrZero(employee.w4_dependent_credit),
        w4_step2_multiple_jobs: toBoolean(employee.w4_step2_multiple_jobs),
        w4_step4a_other_income: toNumberOrZero(employee.w4_step4a_other_income),
        w4_step4b_deductions: toNumberOrZero(employee.w4_step4b_deductions),
        w4_form_version: toNumberOrZero(employee.w4_form_version) || 2020,
        w4_effective_on: employee.w4_effective_on || '',
        w4_signed_on: employee.w4_signed_on || null,
        w4_source_reference: employee.w4_source_reference || '',
        retirement_rate: toNumberOrZero(employee.retirement_rate),
        roth_retirement_rate: toNumberOrZero(employee.roth_retirement_rate),
        employer_retirement_match_rate: toNumberOrZero(employee.employer_retirement_match_rate),
        employer_roth_match_rate: toNumberOrZero(employee.employer_roth_match_rate),
        department_id: employee.department_id ?? undefined,
        business_name: employee.business_name || '',
        contractor_ein: employee.contractor_ein || '',
        contractor_type: employee.contractor_type || 'individual',
        contractor_pay_type: employee.contractor_pay_type || 'flat_fee',
        w9_on_file: toBoolean(employee.w9_on_file),
        address_line1: employee.address_line1 || '',
        address_line2: employee.address_line2 || '',
        city: employee.city || '',
        state: employee.state || '',
        zip: employee.zip || '',
        default_payroll_adjustments: employee.default_payroll_adjustments || [],
      };
      setForm(normalizeEmployeeMonetaryFields(nextForm));
      setInitialSsn(loadedSsn);
      setStoredSsnLastFour(employee.ssn_last_four || null);
      setInitialEmploymentType(employee.employment_type);
      setW4ChangeReason('');
      setW4ElectionReceived(false);
      setW4CurrencyDrafts({
        additional_withholding: toCurrencyDraft(nextForm.additional_withholding),
        w4_dependent_credit: toCurrencyDraft(nextForm.w4_dependent_credit),
        w4_step4a_other_income: toCurrencyDraft(nextForm.w4_step4a_other_income),
        w4_step4b_deductions: toCurrencyDraft(nextForm.w4_step4b_deductions),
      });

      const fetchedWageRates = (employee.wage_rates || []).map((rate) => ({
        ...rate,
        temp_id: crypto.randomUUID(),
      }));
      if (employee.employment_type === 'hourly' || (employee.employment_type === 'contractor' && employee.contractor_pay_type === 'hourly')) {
        replaceWageRates(
          fetchedWageRates.length > 0
            ? fetchedWageRates
            : [{
                ...defaultHourlyWageRate(),
                label: 'Regular',
                rate: employee.pay_rate,
              }]
        );
      } else {
        // Retain hourly definitions for a later basis change without replacing
        // the current salary or flat fee with the hidden primary hourly rate.
        setWageRates(fetchedWageRates.length > 0 ? fetchedWageRates : [defaultHourlyWageRate()]);
      }
      setDefaultPayrollAdjustments((employee.default_payroll_adjustments || []).map((adjustment) => ({
        temp_id: crypto.randomUUID(),
        label: adjustment.label,
        amount: toNumberOrZero(adjustment.amount),
        treatment: adjustment.treatment,
        notes: adjustment.notes || '',
        active: adjustment.active !== false,
      })));
      setLegacyCustomEarnings((employee.default_custom_earnings || []).map((earning) => ({
        temp_id: crypto.randomUUID(),
        label: earning.label,
        amount: toNumberOrZero(earning.amount),
      })));

      setEmployeeStatus(employee.status || 'active');
      setTerminationDate(employee.termination_date || null);
    } catch (err) {
      if (isCurrentRequest()) {
        setGeneralError(err instanceof Error ? err.message : 'Failed to load employee');
      }
    } finally {
      if (isCurrentRequest()) setIsLoading(false);
    }
  }, [companyId, id, isClient, setGeneralError]);

  const handleDocumentReadinessChange = useCallback((readiness: EmployeeDocumentReadinessResponse['readiness'] | undefined): void => {
    if (companyIdRef.current !== companyId) return;

    const expectedEmployeeId = Number(id);
    setLoadedEmployee((current) => withDocumentReadiness(current, expectedEmployeeId, readiness));
  }, [companyId, id]);

  const fetchDepartments = useCallback(async () => {
    const requestId = ++departmentsRequestIdRef.current;
    const requestedCompanyId = companyId;
    const isCurrentRequest = (): boolean => (
      departmentsRequestIdRef.current === requestId && companyIdRef.current === requestedCompanyId
    );

    try {
      const response = isClient
        ? await clientDepartmentsApi.list({ active: true })
        : await departmentsApi.list({ company_id: companyId, active: true });
      if (isCurrentRequest()) setDepartments(response.data);
    } catch (err) {
      if (isCurrentRequest()) setGeneralError((current) => current || `Could not load departments. Refresh before choosing a department. ${err instanceof Error ? err.message : ''}`);
    }
  }, [companyId, isClient, setGeneralError]);

  useEffect(() => {
    payFrequencyTouchedRef.current = false;
    setLoadedEmployee(null);
    setForm({
      ...initialFormData,
      ...(!isEditing ? { first_name: aireFirstName, last_name: aireLastName } : {}),
    });
    setInitialSsn('');
    setStoredSsnLastFour(null);
    setInitialEmploymentType('hourly');
    setPayItemPending(false);
    setPayItemRefreshVersion(0);
    setDepartments([]);
    setWageRates([defaultHourlyWageRate()]);
    setDefaultPayrollAdjustments([]);
    setLegacyCustomEarnings([]);
    setW4CurrencyDrafts({
      additional_withholding: toCurrencyDraft(initialFormData.additional_withholding),
      w4_dependent_credit: toCurrencyDraft(initialFormData.w4_dependent_credit),
      w4_step4a_other_income: toCurrencyDraft(initialFormData.w4_step4a_other_income),
      w4_step4b_deductions: toCurrencyDraft(initialFormData.w4_step4b_deductions),
    });
    setEmployeeStatus('active');
    setTerminationDate(null);
    setErrors({});
    setGeneralError(null);
    setIsLoading(false);
    setShowQuickPayrollField(false);
    setQuickPayrollField(initialQuickPayrollFieldDraft());
    setQuickPayrollFieldError(null);
    setLegacyPayItemSource(null);
    setQuickPayrollFieldSaving(false);
    setClassificationTransitionOpen(false);
    setStatusTransitionMode(null);
    setEmployeeDocumentsOpen(false);
    fetchDepartments();
    if (isEditing) {
      fetchEmployee();
    }
    return (): void => {
      employeeRequestIdRef.current += 1;
      departmentsRequestIdRef.current += 1;
      quickPayrollFieldRequestIdRef.current += 1;
    };
  }, [aireFirstName, aireLastName, fetchDepartments, fetchEmployee, isEditing, setGeneralError, setQuickPayrollFieldError]);

  useEffect(() => {
    const companyFrequency = activeCompany?.pay_frequency;
    if (isEditing || payFrequencyTouchedRef.current || activeCompany?.id !== companyId) return;
    if (!companyFrequency || !['weekly', 'biweekly', 'semimonthly', 'monthly'].includes(companyFrequency)) return;
    setForm((previous) => ({ ...previous, pay_frequency: companyFrequency as PayFrequency }));
  }, [activeCompany?.id, activeCompany?.pay_frequency, companyId, isEditing]);

  useEffect(() => {
    if (supportsMultipleHourlyRates && wageRates.length === 0) {
      replaceWageRates([defaultHourlyWageRate()]);
    }
  }, [supportsMultipleHourlyRates, wageRates.length]);

  const formatSSN = (raw: string): string => {
    const digits = raw.replace(/\D/g, '').slice(0, 9);
    if (digits.length <= 3) return digits;
    if (digits.length <= 5) return `${digits.slice(0, 3)}-${digits.slice(3)}`;
    return `${digits.slice(0, 3)}-${digits.slice(3, 5)}-${digits.slice(5)}`;
  };

  const formatEIN = (raw: string): string => {
    const digits = raw.replace(/\D/g, '').slice(0, 9);
    if (digits.length <= 2) return digits;
    return `${digits.slice(0, 2)}-${digits.slice(2)}`;
  };

  const handleChange = (field: keyof EmployeeFormData, value: string | number | boolean | null): void => {
    if (field === 'pay_frequency') payFrequencyTouchedRef.current = true;
    setForm((prev) => ({ ...prev, [field]: value }));
    const linkedSsnField = field === 'ssn' ? 'ssn_confirmation' : field === 'ssn_confirmation' ? 'ssn' : null;
    if (errors[field] || (linkedSsnField && errors[linkedSsnField])) {
      setErrors((prev) => {
        const newErrors = { ...prev };
        delete newErrors[field];
        if (linkedSsnField) delete newErrors[linkedSsnField];
        return newErrors;
      });
    }
  };

  const handleW4CurrencyDraftChange = (field: W4MonetaryField, value: string): void => {
    setW4CurrencyDrafts((prev) => ({ ...prev, [field]: value }));
  };

  const commitW4CurrencyDraft = (field: W4MonetaryField): void => {
    const normalized = roundCurrencyValue(parseFloat(w4CurrencyDrafts[field]) || 0);
    handleChange(field, normalized);
    setW4CurrencyDrafts((prev) => ({ ...prev, [field]: toCurrencyDraft(normalized) }));
  };

  const replaceWageRates = (nextRates: WageRateFormRow[]) => {
    const cleaned = nextRates.length > 0 ? nextRates : [defaultHourlyWageRate()];
    const primaryId = cleaned.find((rate) => rate.is_primary)?.temp_id || cleaned[0].temp_id;
    const normalized = cleaned.map((rate) => ({
      ...rate,
      is_primary: rate.temp_id === primaryId,
      active: rate.active !== false,
    }));

    setWageRates(normalized);

    const primaryRate = normalized.find((rate) => rate.is_primary) || normalized[0];
    if (primaryRate) {
      setForm((prev) => ({ ...prev, pay_rate: roundCurrencyValue(Number(primaryRate.rate) || 0) }));
    }
  };

  const updateWageRate = (tempId: string, patch: Partial<WageRateFormRow>) => {
    replaceWageRates(
      wageRates.map((rate) => (rate.temp_id === tempId ? { ...rate, ...patch } : rate))
    );
  };

  const addWageRate = () => {
    replaceWageRates([
      ...wageRates,
      {
        temp_id: crypto.randomUUID(),
        label: '',
        rate: 0,
        is_primary: false,
        active: true,
      },
    ]);
  };

  const removeWageRate = (tempId: string) => {
    replaceWageRates(wageRates.filter((rate) => rate.temp_id !== tempId));
  };

  const closeQuickPayrollField = () => {
    setQuickPayrollField(initialQuickPayrollFieldDraft());
    setQuickPayrollFieldError(null);
    setLegacyPayItemSource(null);
    setShowQuickPayrollField(false);
  };

  const startLegacyPayItemMove = (source: LegacyPayItemSource) => {
    const treatment: PayrollFieldTaxTreatment = source.kind === 'custom_earning' ? 'taxable_addition' : source.row.treatment;
    setLegacyPayItemSource(source);
    setQuickPayrollFieldError(null);
    setQuickPayrollField({
      ...initialQuickPayrollFieldDraft(),
      name: source.row.label,
      kind: treatment.endsWith('_addition') ? 'addition' : 'deduction',
      tax_treatment: treatment,
      category: '',
      default_amount: source.row.amount,
      notes: source.kind === 'adjustment' ? source.row.notes : '',
    });
    setShowQuickPayrollField(true);
    window.requestAnimationFrame(() => quickPayrollFieldRef.current?.scrollIntoView?.({ block: 'center' }));
  };

  const updateQuickPayrollFieldKind = (kind: PayrollFieldKind) => {
    const tax_treatment: PayrollFieldTaxTreatment = kind === 'addition'
      ? 'taxable_addition'
      : kind === 'employer_contribution'
        ? 'employer_contribution'
        : 'post_tax_deduction';
    setQuickPayrollField((prev) => ({ ...prev, kind, tax_treatment }));
  };

  const createQuickPayrollField = async (): Promise<void> => {
    if (!quickPayrollField.name.trim() || !id) return;
    if (!quickPayrollField.category) {
      setQuickPayrollFieldError('Choose a category for this pay item.');
      return;
    }
    if (quickPayrollField.start_date && quickPayrollField.end_date && quickPayrollField.end_date < quickPayrollField.start_date) {
      setQuickPayrollFieldError('Last payday must be on or after first payday.');
      return;
    }

    const requestId = ++quickPayrollFieldRequestIdRef.current;
    const requestedCompanyId = companyId;
    const isCurrentRequest = (): boolean => (
      requestId === quickPayrollFieldRequestIdRef.current
      && requestedCompanyId === companyIdRef.current
    );
    setQuickPayrollFieldSaving(true);
    setQuickPayrollFieldError(null);
    try {
      const payload: Partial<PayrollFieldDefinition> = {
        ...quickPayrollField,
        name: quickPayrollField.name.trim(),
        category: quickPayrollField.category,
        default_amount: null,
        reporting_group: quickPayrollField.category === 'retirement' ? quickPayrollField.reporting_group || null : null,
        default_percentage: null,
        show_in_payroll_grid: true,
      };
      const assignment: Partial<EmployeePayrollField> = {
        amount: quickPayrollField.amount_type === 'fixed' ? roundCurrencyValue(quickPayrollField.default_amount) : null,
        percentage: quickPayrollField.amount_type === 'percentage' ? Number(quickPayrollField.default_percentage) || 0 : null,
        start_date: quickPayrollField.start_date || null,
        end_date: quickPayrollField.end_date || null,
        notes: quickPayrollField.notes.trim(),
      };
      await (legacyPayItemSource
        ? employeePayrollFieldsApi.convertLegacy(Number(id), {
          kind: legacyPayItemSource.kind,
          label: legacyPayItemSource.row.label,
          amount: legacyPayItemSource.row.amount,
          ...(legacyPayItemSource.kind === 'adjustment' ? {
            treatment: legacyPayItemSource.row.treatment,
            notes: legacyPayItemSource.row.notes,
          } : {}),
        }, payload, assignment, requestedCompanyId)
        : employeePayrollFieldsApi.createPersonal(Number(id), payload, assignment, requestedCompanyId));
      if (!isCurrentRequest()) return;
      setPayItemRefreshVersion((version) => version + 1);
      if (legacyPayItemSource?.kind === 'adjustment') {
        setDefaultPayrollAdjustments((prev) => prev.filter((row) => row.temp_id !== legacyPayItemSource.row.temp_id));
      } else if (legacyPayItemSource?.kind === 'custom_earning') {
        setLegacyCustomEarnings((prev) => prev.filter((row) => row.temp_id !== legacyPayItemSource.row.temp_id));
      }
      setQuickPayrollField(initialQuickPayrollFieldDraft());
      setQuickPayrollFieldError(null);
      setLegacyPayItemSource(null);
      setShowQuickPayrollField(false);
    } catch (err) {
      if (isCurrentRequest()) setQuickPayrollFieldError(err instanceof Error ? err.message : 'Failed to create payroll field');
    } finally {
      if (isCurrentRequest()) setQuickPayrollFieldSaving(false);
    }
  };

  const normalizeDefaultPayrollAdjustments = () => defaultPayrollAdjustments
    .map((adjustment) => ({
      label: adjustment.label.trim(),
      amount: roundCurrencyValue(Number(adjustment.amount) || 0),
      treatment: adjustment.treatment,
      notes: adjustment.notes.trim(),
      active: adjustment.active !== false,
    }))
    .filter((adjustment) => adjustment.label !== '' && adjustment.amount > 0);

  const normalizeWageRates = (): WageRateFormRow[] => {
    const activeRates = wageRates
      .map((rate) => ({
        ...rate,
        label: rate.label.trim(),
        rate: roundCurrencyValue(Number(rate.rate) || 0),
      }))
      .filter((rate) => rate.active !== false && rate.label !== '');

    if (activeRates.length === 0) {
      return [];
    }

    const primaryId = activeRates.find((rate) => rate.is_primary)?.temp_id || activeRates[0].temp_id;
    return activeRates.map((rate) => ({ ...rate, is_primary: rate.temp_id === primaryId }));
  };

  const focusFirstInvalidField = (fieldName: string | undefined) => {
    if (!fieldName) return;
    requestAnimationFrame(() => {
      const field = document.querySelector<HTMLElement>(`[name="${fieldName}"]`);
      field?.focus();
      field?.scrollIntoView({ behavior: window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth', block: 'center' });
    });
  };

  const toggleReceivedWithholding = (received: boolean) => {
    setW4ElectionReceived(received);
    if (received) {
      setForm((previous) => ({ ...previous, w4_effective_on: '', w4_signed_on: null, w4_source_reference: '' }));
      return;
    }
    if (!loadedEmployee) return;
    setForm((previous) => ({ ...previous,
      w4_effective_on: loadedEmployee.w4_effective_on || '',
      w4_signed_on: loadedEmployee.w4_signed_on || null,
      w4_source_reference: loadedEmployee.w4_source_reference || '',
    }));
  };

  const allowsUnverifiedBlank = (field: string) => importedProfileAllowsBlank(loadedEmployee, field)
    || intakeAllowsBlank(loadedEmployee, field, !isEditing && Boolean(intake.settings?.enabled));

  const validateForm = (): boolean => {
    const newErrors: FormErrors = {};
    const usesSsn = form.employment_type !== 'contractor' || form.contractor_type !== 'business';
    const ssnChanged = canonicalSsn(form.ssn) !== canonicalSsn(initialSsn);
    const storedSsnCanRemain = isClient && isEditing && Boolean(storedSsnLastFour) && !form.ssn?.trim();

    if (!form.first_name.trim()) {
      newErrors.first_name = ['First name is required'];
    }
    if (!form.last_name.trim()) {
      newErrors.last_name = ['Last name is required'];
    }
    const isVariableSalary = form.employment_type === 'salary' && form.salary_type === 'variable';
    if (!isVariableSalary && form.pay_rate <= 0) {
      newErrors.pay_rate = ['Pay rate must be greater than 0'];
    }
    if (supportsMultipleHourlyRates) {
      const normalizedRates = normalizeWageRates();
      if (normalizedRates.length === 0) {
        newErrors.wage_rates = ['Add at least one hourly pay rate'];
      } else if (normalizedRates.some((rate) => rate.rate <= 0)) {
        newErrors.wage_rates = ['Each hourly pay rate must be greater than 0'];
      } else {
        const labels = normalizedRates.map((rate) => rate.label.toLowerCase());
        if (new Set(labels).size !== labels.length) {
          newErrors.wage_rates = ['Hourly pay rate labels must be unique'];
        }
      }
    }
    if (usesSsn && !form.ssn?.trim() && !storedSsnCanRemain && !allowsUnverifiedBlank('ssn')) {
      newErrors.ssn = ['Social Security Number is required'];
    } else if (usesSsn && form.ssn && !/^\d{3}-\d{2}-\d{4}$/.test(form.ssn)) {
      newErrors.ssn = ['SSN must be in format XXX-XX-XXXX'];
    }
    if (usesSsn && Boolean(form.ssn?.trim()) && (!isEditing || ssnChanged)) {
      if (!form.ssn_confirmation?.trim()) {
        newErrors.ssn_confirmation = ['Re-enter the Social Security Number'];
      } else if (canonicalSsn(form.ssn_confirmation) !== canonicalSsn(form.ssn)) {
        newErrors.ssn_confirmation = ['Social Security Numbers do not match'];
      }
    }
    if (!allowsUnverifiedBlank('hire_date') && !form.hire_date) {
      newErrors.hire_date = ['Hire date is required'];
    }
    if (!allowsUnverifiedBlank('address_line1') && !form.address_line1?.trim()) {
      newErrors.address_line1 = ['Address line 1 is required'];
    }
    if (!allowsUnverifiedBlank('city') && !form.city?.trim()) {
      newErrors.city = ['City is required'];
    }
    if (!allowsUnverifiedBlank('state') && !form.state?.trim()) {
      newErrors.state = ['State is required'];
    }
    if (!allowsUnverifiedBlank('zip') && !form.zip?.trim()) {
      newErrors.zip = ['ZIP code is required'];
    }
    const hireDateError = !isEditing || form.hire_date !== (loadedEmployee?.hire_date || '') ? validateHireDate(form.hire_date) : null;
    if (hireDateError) newErrors.hire_date = [hireDateError];
    if (form.employment_type === 'contractor' && form.contractor_type === 'business') {
      if (!form.business_name?.trim()) newErrors.business_name = ['Legal business name is required'];
      if (!form.contractor_ein?.trim() && !allowsUnverifiedBlank('contractor_ein')) {
        newErrors.contractor_ein = ['EIN is required'];
      } else if (form.contractor_ein?.trim() && !/^\d{2}-\d{7}$/.test(form.contractor_ein)) {
        newErrors.contractor_ein = ['EIN must be in format XX-XXXXXXX'];
      }
    }
    if (form.date_of_birth) {
      const dob = new Date(form.date_of_birth);
      const today = new Date();
      if (dob >= today) {
        newErrors.date_of_birth = ['Date of birth must be in the past'];
      }
    }
    if (form.employment_type !== 'contractor' && ((form.retirement_rate || 0) + (form.roth_retirement_rate || 0)) > 1) {
      newErrors.retirement_rate = ['Combined retirement contributions cannot exceed 100%'];
    }
    if (form.employment_type !== 'contractor' && !form.w4_effective_on && !allowsUnverifiedBlank('withholding_election')) {
      newErrors.w4_effective_on = ['Enter the date this W-4 became effective'];
    }
    if (isEditing && !isClient && form.employment_type !== 'contractor' && (w4HasChanged || w4ElectionReceived) && !w4ChangeReason.trim()) {
      newErrors.w4_change_reason = ['Explain why this W-4 election is changing'];
    }
    if (loadedEmployee?.current_w4_election?.source === 'default_withholding' && w4HasChanged && !w4ElectionReceived) newErrors.w4_election_received = ['Confirm that the employee withholding election was received before replacing the approved default.'];
    if (w4ElectionReceived && (!form.w4_effective_on || (!form.w4_signed_on && !form.w4_source_reference?.trim()))) newErrors.w4_election_received = ['Enter the received election effective date and its signed date or source reference.'];
    const employerPreTaxMatch = form.employer_retirement_match_rate ?? 0;
    const employerRothMatch = form.employer_roth_match_rate ?? 0;
    if (form.employment_type !== 'contractor' && (!Number.isFinite(employerPreTaxMatch) || employerPreTaxMatch < 0 || employerPreTaxMatch > 1)) {
      newErrors.employer_retirement_match_rate = ['Employer pre-tax match must be between 0% and 100%'];
    }
    if (form.employment_type !== 'contractor' && (!Number.isFinite(employerRothMatch) || employerRothMatch < 0 || employerRothMatch > 1)) {
      newErrors.employer_roth_match_rate = ['Employer Roth match must be between 0% and 100%'];
    }
    const defaultAdjustments = normalizeDefaultPayrollAdjustments();
    const adjustmentKeys = defaultAdjustments.map((adjustment) => `${adjustment.treatment}:${adjustment.label.toLowerCase()}`);
    if (new Set(adjustmentKeys).size !== adjustmentKeys.length) {
      newErrors.default_payroll_adjustments = ['Recurring adjustment labels must be unique within the same treatment'];
    }
    setErrors(newErrors);
    const firstInvalidField = Object.keys(newErrors)[0];
    focusFirstInvalidField(firstInvalidField);
    return !firstInvalidField;
  };

  const handleSubmit = async (e: React.FormEvent): Promise<void> => {
    e.preventDefault();
    if (payItemPending || showQuickPayrollField || quickPayrollFieldSaving) {
      setGeneralError('Finish saving or cancel the open pay item before saving the employee profile.');
      return;
    }
    if (!validateForm()) return;

    const requestedCompanyId = companyId;
    const submissionGeneration = ++submissionGenerationRef.current;
    const isCurrentSubmission = (): boolean => (
      requestedCompanyId === companyIdRef.current
      && submissionGeneration === submissionGenerationRef.current
    );
    setIsSaving(true);
    setGeneralError(null);

    try {
      const normalizedWageRates = supportsMultipleHourlyRates ? normalizeWageRates() : [];
      const primaryRate = normalizedWageRates.find((rate) => rate.is_primary) || normalizedWageRates[0];
      const normalizedW4Values = {
        additional_withholding: roundCurrencyValue(parseFloat(w4CurrencyDrafts.additional_withholding) || 0),
        w4_dependent_credit: roundCurrencyValue(parseFloat(w4CurrencyDrafts.w4_dependent_credit) || 0),
        w4_step4a_other_income: roundCurrencyValue(parseFloat(w4CurrencyDrafts.w4_step4a_other_income) || 0),
        w4_step4b_deductions: roundCurrencyValue(parseFloat(w4CurrencyDrafts.w4_step4b_deductions) || 0),
      };
      const employeePayload = {
        ...normalizeEmployeeMonetaryFields({ ...form, ...normalizedW4Values }),
        ...(form.employment_type === 'contractor'
          ? {
              retirement_rate: 0,
              roth_retirement_rate: 0,
              employer_retirement_match_rate: 0,
              employer_roth_match_rate: 0,
            }
          : {}),
        ...(form.employment_type === 'contractor' && form.contractor_type === 'business'
          ? { ssn: undefined, ssn_confirmation: undefined }
          : {}),
        pay_rate: supportsMultipleHourlyRates
          ? (primaryRate ? roundCurrencyValue(Number(primaryRate.rate) || 0) : roundCurrencyValue(form.pay_rate))
          : roundCurrencyValue(form.pay_rate),
        wage_rates: supportsMultipleHourlyRates
          ? normalizedWageRates.map((rate) => ({
              id: rate.id,
              label: rate.label,
              rate: roundCurrencyValue(Number(rate.rate) || 0),
              is_primary: rate.is_primary,
              active: rate.active !== false,
            }))
          : undefined,
        default_payroll_adjustments: normalizeDefaultPayrollAdjustments(),
        default_custom_earnings: legacyCustomEarnings.map((earning) => ({
          label: earning.label.trim(),
          amount: roundCurrencyValue(Number(earning.amount) || 0),
        })),
        w4_election_received: w4ElectionReceived || undefined,
        w4_change_reason: (w4HasChanged || w4ElectionReceived) ? w4ChangeReason.trim() : undefined,
        w4_source_reference: form.w4_source_reference?.trim() || null,
      };

      let savedEmployeeId: number;
      let portalNotice: string | null = null;
      let portalChangeRequestId: number | null = null;
      let aireMappingNotice: string | null = null;
      if (isEditing && id) {
        // Don't send SSN if it's empty (user didn't update it)
        // Recurring items save through their own endpoints. A stale profile must
        // not restore a legacy allowance another operator has already converted.
        const updateData = { ...employeePayload, default_payroll_adjustments: undefined, default_custom_earnings: undefined };
        if (!updateData.ssn) {
          delete updateData.ssn;
        }
        if (canonicalSsn(updateData.ssn) === canonicalSsn(initialSsn)) {
          delete updateData.ssn;
          delete updateData.ssn_confirmation;
        }
        if (isClient) {
          const response = await clientEmployeesApi.update(parseInt(id, 10), updateData);
          savedEmployeeId = response.data.id;
          portalNotice = response.message || null;
          portalChangeRequestId = response.change_request?.id || null;
        } else {
          const response = await employeesApi.update(parseInt(id, 10), updateData);
          savedEmployeeId = response.data.id;
        }
      } else {
        if (isClient) {
          const response = await clientEmployeesApi.create(employeePayload);
          savedEmployeeId = response.data.id;
          portalNotice = response.message || null;
          portalChangeRequestId = response.change_request?.id || null;
        } else {
          const response = await employeesApi.create({ ...employeePayload, company_id: companyId });
          savedEmployeeId = response.data.id;
        }
      }
      if (!isCurrentSubmission()) return;

      if (!isClient && supportsMultipleHourlyRates) {
        const existingRatesResponse = await employeeWageRatesApi.list(savedEmployeeId, requestedCompanyId);
        if (!isCurrentSubmission()) return;
        const existingRates = existingRatesResponse.wage_rates;
        const displayedSavedRateIds = new Set(
          (loadedEmployee?.wage_rates || [])
            .filter((rate) => rate.active !== false && rate.id)
            .map((rate) => rate.id as number)
        );
        const normalizedById = new Map(
          normalizedWageRates
            .filter((rate) => rate.id)
            .map((rate) => [rate.id as number, rate])
        );

        await Promise.all(
          existingRates
            // Removing a displayed row must not delete hidden or newly added definitions.
            .filter((rate) => rate.active !== false && displayedSavedRateIds.has(rate.id as number) && !normalizedById.has(rate.id as number))
            .map((rate) => employeeWageRatesApi.delete(rate.id as number, requestedCompanyId))
        );
        if (!isCurrentSubmission()) return;

        for (const rate of normalizedWageRates) {
          const payload = {
            label: rate.label,
            rate: roundCurrencyValue(Number(rate.rate) || 0),
            is_primary: rate.is_primary,
            active: rate.active !== false,
          };

          if (rate.id) {
            await employeeWageRatesApi.update(rate.id, payload, requestedCompanyId);
          } else {
            await employeeWageRatesApi.create({
              employee_id: savedEmployeeId,
              ...payload,
            }, requestedCompanyId);
          }
          if (!isCurrentSubmission()) return;
        }
      }

      if (!isClient && !isEditing && airePayPeriodId && aireSourceUserId && aireSourceUserUuid) {
        const parsedPayPeriodId = Number(airePayPeriodId);
        if (!Number.isInteger(parsedPayPeriodId) || parsedPayPeriodId <= 0) {
          aireMappingNotice = 'The payroll profile was created, but the AIRE link expired. Link the new employee from the payroll team list.';
        } else {
          try {
            await payPeriodsApi.confirmAireEmployeeMapping(parsedPayPeriodId, {
              source_user_id: aireSourceUserId,
              source_user_uuid: aireSourceUserUuid,
              employee_id: savedEmployeeId,
            });
          } catch {
            aireMappingNotice = 'The payroll profile was created, but AIRE could not be linked. Link the new employee from the payroll team list.';
          }
          if (!isCurrentSubmission()) return;
        }
      }

      if (!isCurrentSubmission()) return;
      notify({ tone: 'success', message: portalNotice || (isEditing ? 'Employee updated.' : 'Employee created.') });
      const saveDestination = isClient && portalChangeRequestId
        ? '/change-requests'
        : !isEditing && airePayPeriodId && aireSourceUserId && aireSourceUserUuid
          ? returnTo
        : isEditing
          ? returnTo
          : isClient
            ? employeeEditPath(companyId, savedEmployeeId, { returnTo })
            : employeePath(companyId, savedEmployeeId, 'overview', { returnTo });
      navigate(saveDestination, {
        state: portalNotice
          ? { portalNotice, selectedRequestId: portalChangeRequestId }
          : aireMappingNotice
            ? { aireMappingNotice }
            : null,
      });
    } catch (err) {
      if (!isCurrentSubmission()) return;
      if (err instanceof ApiError && Object.keys(err.fieldErrors).length > 0) {
        setErrors(err.fieldErrors);
        const fieldMessages = Object.entries(err.fieldErrors).map(([field, messages]) =>
          `${field.replaceAll('_', ' ')}: ${messages.join(' ')}`
        ).join('; ');
        setGeneralError(`${err.message}. ${fieldMessages}`);
        if ((err.data as { code?: string } | undefined)?.code === 'employee_intake_expired') void intake.reload();
        focusFirstInvalidField(Object.keys(err.fieldErrors)[0]);
      } else {
        setGeneralError(err instanceof Error ? err.message : 'Failed to save employee');
      }
    } finally {
      if (isCurrentSubmission()) setIsSaving(false);
    }
  };

  const getFieldError = (field: string): string | undefined => {
    return errors[field]?.[0];
  };

  const employeeDisplayName = [form.first_name, form.last_name].filter(Boolean).join(' ') || 'this employee';
  const isW2Employee = form.employment_type !== 'contractor';
  const taxIdUsesSsn = isW2Employee || form.contractor_type !== 'business';
  const ssnConfirmationRequired = taxIdUsesSsn && Boolean(form.ssn?.trim())
    && (!isEditing || canonicalSsn(form.ssn) !== canonicalSsn(initialSsn));
  const ssnDigits = (form.ssn || '').replace(/\D/g, '');
  const ssnConfirmationDigits = (form.ssn_confirmation || '').replace(/\D/g, '');
  const ssnComparisonReady = ssnDigits.length === 9 && ssnConfirmationDigits.length === 9;
  const ssnsMatch = ssnComparisonReady && ssnDigits === ssnConfirmationDigits;

  if (!canWriteCompany(activeCompany)) {
    return <section className="space-y-4 rounded-xl border border-neutral-200 bg-white p-6" aria-label="Read-only employee access">
      <h1 className="text-xl font-semibold text-neutral-900">Employee details are read-only</h1>
      <p className="text-sm leading-6 text-neutral-700">{companyReadOnlyMessage(activeCompany)}</p>
      <p className="text-sm text-neutral-600">Any current draft is retained here while access is unavailable.</p>
      <Link className="inline-flex min-h-11 items-center font-semibold text-primary-700 underline" to={returnTo}>Back to employee records</Link>
    </section>;
  }

  if (isLoading) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-600" />
      </div>
    );
  }

  return (
    <div className="pb-28">
      <Header
        title={isEditing ? `Edit ${form.employment_type === 'contractor' ? 'Contractor' : 'Employee'}` : 'Add Employee / Contractor'}
        description={isEditing ? `Update ${form.employment_type === 'contractor' ? 'contractor' : 'employee'} information` : 'Add a new employee or 1099 contractor'}
        actions={
          <Button variant="outline" onClick={() => navigate(returnTo)} disabled={payItemPending || showQuickPayrollField}>
            <ArrowLeft className="w-4 h-4 mr-2" />
            Back
          </Button>
        }
      />

      {(intake.settings?.enabled && !isEditing) && <div role="status" className="mx-4 mt-4 rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm leading-6 text-warning-900 sm:mx-6 lg:mx-8"><p className="font-semibold">Incomplete employee entry is enabled for this client.</p><p>Enter the name and valid pay setup. Unknown personal details may stay blank and will remain on a follow-up checklist. Payroll setup and documents need separate review.</p></div>}
      {loadedEmployee?.intake_readiness?.profile_incomplete && <div role="status" className="mx-4 mt-4 rounded-xl border border-warning-200 bg-warning-50 p-4 text-sm leading-6 text-warning-900 sm:mx-6 lg:mx-8"><p className="font-semibold">Complete this profile as information arrives</p><p>Still missing: {loadedEmployee.intake_readiness.missing_fields.map((field) => intakeFieldLabels[field] || field).join(', ')}. You can save the approved missing fields incrementally.</p></div>}
      {intake.error && <div className="mx-4 mt-4 sm:mx-6 lg:mx-8"><ActionFeedback tone="error" message="Employee entry settings could not be loaded. Full details are required for new entries." /><Button variant="outline" onClick={() => void intake.reload()}>Retry entry settings</Button></div>}

      <nav aria-label="Employee form sections" className="overflow-x-auto border-b border-neutral-200 bg-white px-4 py-2 sm:hidden">
        <div className="flex w-max gap-2 text-xs font-semibold">
          <a className="rounded-full bg-neutral-100 px-3 py-2 text-neutral-700" href="#employee-personal">Personal</a>
          <a className="rounded-full bg-neutral-100 px-3 py-2 text-neutral-700" href="#employee-employment">Employment</a>
          {!isClient && <a className="rounded-full bg-neutral-100 px-3 py-2 text-neutral-700" href="#employee-pay-items">Pay items</a>}
          <a className="rounded-full bg-neutral-100 px-3 py-2 text-neutral-700" href="#employee-tax">{form.employment_type === 'contractor' ? 'Contractor tax' : 'W-4'}</a>
          <a className="rounded-full bg-neutral-100 px-3 py-2 text-neutral-700" href="#employee-address">Address</a>
          {isEditing && <a className="rounded-full bg-neutral-100 px-3 py-2 text-neutral-700" href="#employee-documents">Documents</a>}
        </div>
      </nav>

      {isEditing && employeeStatus === 'terminated' && !isClient && (
        <div className="mx-4 mt-6 flex flex-col gap-3 rounded-lg border border-red-200 bg-red-50 p-4 sm:mx-6 sm:flex-row sm:items-center sm:justify-between lg:mx-8">
          <div className="flex items-center gap-3">
            <AlertCircle className="w-5 h-5 text-red-600 shrink-0" />
            <div>
              <p className="text-red-800 font-medium">
                This {form.employment_type === 'contractor' ? 'contractor' : 'employee'} is terminated
              </p>
              {terminationDate && (
                <p className="text-red-600 text-sm">
                  Terminated on {new Date(terminationDate + 'T00:00:00').toLocaleDateString()}
                </p>
              )}
            </div>
          </div>
          {isManager && <Button
            type="button"
            variant="outline"
            onClick={() => setStatusTransitionMode('reactivate')}
            className="border-red-300 text-red-700 hover:bg-red-100"
          >
            <RotateCcw className="w-4 h-4 mr-2" />
            Reactivate
          </Button>}
        </div>
      )}

      <form id="employee-form" noValidate onSubmit={handleSubmit} className="max-w-4xl p-4 pb-32 sm:p-6 sm:pb-32 lg:p-8 lg:pb-32">
        {generalError && (
          <ActionFeedback retryKey={generalErrorFeedbackAttempt} tone="error" message={generalError}><AlertCircle className="w-5 h-5 text-danger-600 shrink-0 mt-0.5" />
            <p className="text-danger-700">{generalError}</p></ActionFeedback>
        )}

        {isEditing && !isClient && loadedEmployee?.configuration_review_status === 'needs_review' && (
          <div className="mb-6 rounded-2xl border border-warning-200 bg-warning-50 p-4 text-warning-900">
            <div className="flex items-start gap-4">
              <AlertCircle className="mt-0 h-5 w-5 shrink-0 text-warning-700" />
              <div>
                <p className="font-semibold">QuickBooks setup needs review</p>
                <p className="mt-2 text-sm leading-6 text-warning-800">These items were not safe to guess during migration. Correct the fields here, then return to the employee workspace to document what was verified and mark each item reviewed.</p>
                <ul className="mt-4 space-y-2 text-sm leading-6">
                  {(loadedEmployee.configuration_review_items || []).map((item) => (
                    <li key={item.code}>• {item.message}</li>
                  ))}
                </ul>
              </div>
            </div>
          </div>
        )}

        {/* Personal Information */}
        <Card id="employee-personal" className="mb-6 scroll-mt-28">
          <CardHeader>
            <CardTitle>Personal Information</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-1">
                  First Name <span className="text-danger-600">*</span>
                </label>
                <Input id="employee-field-1"
                  name="first_name"
                  required
                  value={form.first_name}
                  onChange={(e) => handleChange('first_name', e.target.value)}
                  error={getFieldError('first_name')}
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-2">
                  Middle Name
                </label>
                <Input id="employee-field-2"
                  value={form.middle_name}
                  onChange={(e) => handleChange('middle_name', e.target.value)}
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-3">
                  Last Name <span className="text-danger-600">*</span>
                </label>
                <Input id="employee-field-3"
                  name="last_name"
                  required
                  value={form.last_name}
                  onChange={(e) => handleChange('last_name', e.target.value)}
                  error={getFieldError('last_name')}
                />
              </div>
            </div>

            <div className={`mt-4 grid grid-cols-1 gap-4 ${taxIdUsesSsn ? 'md:grid-cols-3' : ''}`}>
              {taxIdUsesSsn && (
                <>
                  <div>
                    <label className="mb-1 block text-sm font-medium text-gray-700" htmlFor="employee-field-4">
                      Social Security Number {!allowsUnverifiedBlank('ssn') && <span className="text-danger-600">*</span>}
                    </label>
                    <Input id="employee-field-4"
                      name="ssn"
                      required={!allowsUnverifiedBlank('ssn') && !(isClient && storedSsnLastFour && !form.ssn)}
                      placeholder={isClient && storedSsnLastFour ? `Saved ending in ${storedSsnLastFour} — enter replacement` : 'XXX-XX-XXXX'}
                      value={form.ssn || ''}
                      onChange={(e) => handleChange('ssn', formatSSN(e.target.value))}
                      error={getFieldError('ssn')}
                      inputMode="numeric"
                      autoComplete="off"
                    />
                    {isClient && storedSsnLastFour && !form.ssn && (
                      <p className="mt-1 text-xs text-gray-500">
                        Saved SSN ending in {storedSsnLastFour}. Enter the full number only to submit a replacement for approval.
                      </p>
                    )}
                  </div>
                  <div>
                    <label className="mb-1 block text-sm font-medium text-gray-700" htmlFor="employee-field-5">
                      Re-enter Social Security Number
                      {ssnConfirmationRequired && <span className="text-danger-600"> *</span>}
                    </label>
                    <Input id="employee-field-5"
                      name="ssn_confirmation"
                      required={ssnConfirmationRequired}
                      placeholder="XXX-XX-XXXX"
                      value={form.ssn_confirmation || ''}
                      onChange={(e) => handleChange('ssn_confirmation', formatSSN(e.target.value))}
                      error={getFieldError('ssn_confirmation') || (ssnComparisonReady && !ssnsMatch ? 'Social Security Numbers do not match' : undefined)}
                      inputMode="numeric"
                      autoComplete="off"
                    />
                    {form.ssn_confirmation && (
                      <div
                        className={`mt-1 flex items-center gap-1.5 text-xs font-medium ${ssnsMatch ? 'text-emerald-700' : 'text-danger-700'}`}
                        role="status"
                        aria-live="polite"
                      >
                        {ssnsMatch ? <CheckCircle2 className="h-4 w-4" /> : <XCircle className="h-4 w-4" />}
                        {ssnsMatch ? 'Social Security Numbers match' : 'Social Security Numbers do not match yet'}
                      </div>
                    )}
                    {isEditing && !ssnConfirmationRequired && !form.ssn_confirmation && (
                      <p className="mt-1 text-xs text-gray-500">Re-enter only when changing the saved Social Security Number.</p>
                    )}
                  </div>
                </>
              )}
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-6">
                  Date of Birth
                </label>
                <Input id="employee-field-6"
                  type="date"
                  value={form.date_of_birth || ''}
                  onChange={(e) => handleChange('date_of_birth', e.target.value)}
                />
              </div>
              {!taxIdUsesSsn && (
                <div>
                  <p className="rounded-xl border border-blue-200 bg-blue-50 px-4 py-3 text-sm leading-6 text-blue-900">
                    This business contractor uses its legal business name and EIN as the filing identity. Those required fields appear in the 1099 section below.
                  </p>
                </div>
              )}
            </div>
          </CardContent>
        </Card>

        {/* Employment Information */}
        <Card id="employee-employment" className="mb-6 scroll-mt-28">
          <CardHeader>
            <CardTitle>Employment Information</CardTitle>
            {loadedEmployee?.configuration_review_status === 'needs_review' && <p className="mt-1 text-sm text-gray-600">Save verified details as you receive them. Missing imported details remain in Setup Review until confirmed.</p>}
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-7">
                  Hire Date {!allowsUnverifiedBlank('hire_date') && <span className="text-danger-600">*</span>}
                </label>
                <Input id="employee-field-7"
                  name="hire_date"
                  required={!allowsUnverifiedBlank('hire_date')}
                  type="date"
                  value={form.hire_date}
                  onChange={(e) => handleChange('hire_date', e.target.value)}
                  error={getFieldError('hire_date')}
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-29">
                  Department
                </label>
                <Select id="employee-field-29"
                  value={form.department_id?.toString() || ''}
                  onChange={(e) => handleChange('department_id', e.target.value ? parseInt(e.target.value, 10) : '')}
                >
                  <option value="">No Department</option>
                  {departments.map((dept) => (
                    <option key={dept.id} value={dept.id}>
                      {dept.name}
                    </option>
                  ))}
                </Select>
              </div>
              <div>
                <label htmlFor="job_title" className="mb-2 block text-sm font-medium text-gray-700">
                  Job Title
                </label>
                <Input
                  id="job_title"
                  name="job_title"
                  value={form.job_title || ''}
                  onChange={(e) => handleChange('job_title', e.target.value)}
                  placeholder="e.g. Payroll Specialist"
                />
              </div>
            </div>

            <div className={`grid grid-cols-1 ${form.employment_type === 'contractor' ? 'md:grid-cols-4' : form.employment_type === 'salary' ? 'md:grid-cols-4' : 'md:grid-cols-3'} gap-4 mt-4`}>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-30">
                  Employment Type <span className="text-danger-600">*</span>
                </label>
                <Select id="employee-field-30"
                  name="employment_type"
                  required
                  value={form.employment_type}
                  onChange={(e) => handleChange('employment_type', e.target.value as EmploymentType)}
                  disabled={isEditing && initialEmploymentType === 'contractor'}
                >
                  {(!isEditing || initialEmploymentType !== 'contractor') && (
                    <>
                      <option value="hourly">Hourly</option>
                      <option value="salary">Salary</option>
                    </>
                  )}
                  {(!isEditing || initialEmploymentType === 'contractor') && (
                    <option value="contractor">1099 Contractor</option>
                  )}
                </Select>
              </div>
              {form.employment_type === 'salary' && (
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-31">
                    Salary Type <span className="text-danger-600">*</span>
                  </label>
                  <Select id="employee-field-31"
                    name="salary_type"
                    required
                    value={form.salary_type || 'annual'}
                    onChange={(e) => handleChange('salary_type', e.target.value)}
                  >
                    <option value="annual">Fixed Annual Salary</option>
                    <option value="per_period">Fixed Per Pay Period</option>
                    <option value="variable">Variable (set each period)</option>
                  </Select>
                </div>
              )}
              {form.employment_type === 'contractor' && (
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-32">
                    Pay Structure <span className="text-danger-600">*</span>
                  </label>
                  <Select id="employee-field-32"
                    name="contractor_pay_type"
                    required
                    value={form.contractor_pay_type || 'flat_fee'}
                    onChange={(e) => handleChange('contractor_pay_type', e.target.value as ContractorPayType)}
                  >
                    <option value="flat_fee">Flat Fee per Period</option>
                    <option value="hourly">Hourly Rate</option>
                  </Select>
                </div>
              )}
              {!supportsMultipleHourlyRates && !(form.employment_type === 'salary' && form.salary_type === 'variable') && (
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-8">
                    {form.employment_type === 'contractor'
                      ? (form.contractor_pay_type === 'hourly' ? 'Hourly Rate' : 'Flat Fee per Period')
                      : 'Pay Rate'} <span className="text-danger-600">*</span>
                  </label>
                  <NumericInput id="employee-field-8"
                    name="pay_rate"
                    required
                    aria-invalid={Boolean(getFieldError('pay_rate'))}
                    value={form.pay_rate}
                    onValueChange={(value) => handleChange('pay_rate', value ?? 0)}
                    min={0}
                    fixedDecimalsOnBlur={2}
                    className={getFieldError('pay_rate') ? 'border-danger-300 focus-visible:border-danger-500 focus-visible:ring-danger-200' : undefined}
                  />
                  {getFieldError('pay_rate') && <p className="mt-1 text-sm text-red-600">{getFieldError('pay_rate')}</p>}
                  <p className="mt-1 text-xs text-gray-500">
                    {form.employment_type === 'salary'
                      ? form.salary_type === 'per_period' ? 'Amount paid each pay period' : 'Annual salary'
                      : form.contractor_pay_type === 'hourly' ? 'Per hour worked' : 'Amount paid each pay period'}
                  </p>
                </div>
              )}
              {form.employment_type === 'salary' && form.salary_type === 'variable' && (
                <div className="flex items-center">
                  <p className="text-sm text-gray-500 bg-gray-50 rounded-lg px-3 py-2 border border-gray-200">
                    Pay is set each pay period using the salary override field when running payroll.
                  </p>
                </div>
              )}
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-33">
                  Pay Frequency <span className="text-danger-600">*</span>
                </label>
                <Select id="employee-field-33"
                  name="pay_frequency"
                  required
                  value={form.pay_frequency}
                  onChange={(e) => handleChange('pay_frequency', e.target.value as PayFrequency)}
                >
                  <option value="weekly">Weekly</option>
                  <option value="biweekly">Biweekly</option>
                  <option value="semimonthly">Semi-monthly</option>
                  <option value="monthly">Monthly</option>
                </Select>
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="payment_delivery_method">
                  How this employee is paid
                </label>
                <Select
                  id="payment_delivery_method"
                  name="payment_delivery_method"
                  value={form.payment_delivery_method || ''}
                  disabled={isClient}
                  onChange={(event) => handleChange('payment_delivery_method', (event.target.value || null) as PaymentDeliveryMethod | null)}
                >
                  <option value="">Paper check (default; not reviewed)</option>
                  <option value="paper_check">Paper check</option>
                  <option value="direct_deposit">Direct deposit — print earnings stub</option>
                </Select>
                <p className="mt-1 text-xs leading-5 text-neutral-600">
                  {isClient ? 'Ask the payroll team to verify or change this setting.' : 'This is the default for future runs. Existing runs keep their own method. Printing a stub does not send a bank transfer.'}
                </p>
              </div>
            </div>

            {isEditing && (
              <div className="mt-4 flex flex-col gap-4 rounded-2xl border border-neutral-200 bg-neutral-50 px-4 py-4 sm:flex-row sm:items-start sm:justify-between">
                <div className="flex min-w-0 gap-3">
                  <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-white text-neutral-700 shadow-sm ring-1 ring-neutral-200">
                    <LockKeyhole className="h-4 w-4" />
                  </div>
                  <div>
                    <p className="text-sm font-semibold text-neutral-900">W-2 / 1099 classification is locked</p>
                    <p className="mt-1 max-w-2xl text-xs leading-5 text-neutral-600">
                      Hourly and salary may change within W-2 treatment. Moving across the W-2/1099 boundary creates a second payroll record for the same person—not a second login—so prior payroll and tax reporting remain intact.
                    </p>
                    {(loadedEmployee?.classification_history?.previous_employee || loadedEmployee?.classification_history?.next_employee) && (
                      <div className="mt-3 rounded-xl border border-neutral-200 bg-white p-3">
                        <div className="mb-2 flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-neutral-500">
                          <Link2 className="h-3.5 w-3.5" /> Classification history
                        </div>
                        <div className="space-y-2">
                          {loadedEmployee.classification_history.previous_employee && (
                            <button type="button" className="block w-full rounded-lg px-2 py-1.5 text-left text-xs hover:bg-primary-50" onClick={() => navigate(employeePath(companyId, loadedEmployee.classification_history?.previous_employee?.id || 0, 'activity', { returnTo }))}>
                              <span className="font-semibold text-primary-700">Prior {loadedEmployee.classification_history.previous_employee.tax_classification.toUpperCase()} record</span>
                              <span className="ml-2 text-neutral-500">{loadedEmployee.classification_history.previous_employee.hire_date || 'Start unknown'} – {loadedEmployee.classification_history.previous_employee.termination_date || 'End unknown'}</span>
                            </button>
                          )}
                          <div className="rounded-lg bg-neutral-100 px-2 py-1.5 text-xs text-neutral-700">
                            <span className="font-semibold">Current {loadedEmployee.tax_classification?.toUpperCase()} record</span>
                            <span className="ml-2">{loadedEmployee.hire_date || 'Start unknown'} – {loadedEmployee.termination_date || 'Present'}</span>
                          </div>
                          {loadedEmployee.classification_history.next_employee && (
                            <button type="button" className="block w-full rounded-lg px-2 py-1.5 text-left text-xs hover:bg-primary-50" onClick={() => navigate(employeePath(companyId, loadedEmployee.classification_history?.next_employee?.id || 0, 'activity', { returnTo }))}>
                              <span className="font-semibold text-primary-700">Successor {loadedEmployee.classification_history.next_employee.tax_classification.toUpperCase()} record</span>
                              <span className="ml-2 text-neutral-500">Starts {loadedEmployee.classification_history.next_employee.hire_date || 'unknown'}</span>
                            </button>
                          )}
                        </div>
                      </div>
                    )}
                  </div>
                </div>
                {isSuperAdmin && employeeStatus === 'active' && !loadedEmployee?.classification_history?.next_employee && (
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    className="shrink-0"
                    onClick={() => setClassificationTransitionOpen(true)}
                  >
                    <ArrowRightLeft className="mr-2 h-4 w-4" />
                    Create new classification record
                  </Button>
                )}
              </div>
            )}

            {supportsMultipleHourlyRates && (
              <div className="mt-6 pt-4 border-t border-gray-200">
                <div className="flex items-center justify-between gap-3 mb-3">
                  <div>
                    <h4 className="text-sm font-semibold text-gray-900">Hourly Pay Rates</h4>
                    <p className="text-xs text-gray-500 mt-0.5">
                      Add one or more labeled rates. The primary rate remains the default rate for imports and single-rate payroll.
                    </p>
                  </div>
                  <Button type="button" variant="outline" size="sm" onClick={addWageRate}>
                    <Plus className="w-4 h-4 mr-1" />
                    Add Rate
                  </Button>
                </div>

                {getFieldError('wage_rates') && (
                  <div className="mb-3 rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                    {getFieldError('wage_rates')}
                  </div>
                )}

                <div className="space-y-3">
                  {wageRates.map((rate, index) => (
                    <div key={rate.temp_id} className="grid grid-cols-1 md:grid-cols-[minmax(0,1.5fr)_minmax(0,1fr)_auto_auto] gap-3 items-end rounded-lg border border-gray-200 p-3">
                      <div>
                        <label className="block text-xs font-medium text-gray-600 mb-1" htmlFor={`employee-field-9-${rate.temp_id}`}>
                          Rate Label <span className="text-danger-600">*</span>
                        </label>
                        <Input id={`employee-field-9-${rate.temp_id}`}
                          name="wage_rates"
                          required
                          value={rate.label}
                          onChange={(e) => updateWageRate(rate.temp_id, { label: e.target.value })}
                          placeholder={index === 0 ? 'Flight Time' : 'Office Time'}
                        />
                      </div>
                      <div>
                        <label className="block text-xs font-medium text-gray-600 mb-1" htmlFor={`employee-field-10-${rate.temp_id}`}>
                          Hourly Rate <span className="text-danger-600">*</span>
                        </label>
                        <NumericInput id={`employee-field-10-${rate.temp_id}`}
                          required
                          value={rate.rate}
                          onValueChange={(value) => updateWageRate(rate.temp_id, { rate: value ?? 0 })}
                          min={0}
                          fixedDecimalsOnBlur={2}
                        />
                      </div>
                      <label className="flex items-center gap-2 text-sm text-gray-700 h-10">
                        <input
                          type="radio"
                          name="primary-hourly-rate"
                          checked={rate.is_primary}
                          onChange={() => replaceWageRates(wageRates.map((row) => ({ ...row, is_primary: row.temp_id === rate.temp_id })))}
                        />
                        Primary
                      </label>
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        onClick={() => removeWageRate(rate.temp_id)}
                        aria-label={`Remove hourly rate ${rate.label.trim() || index + 1}`}
                        disabled={wageRates.length === 1}
                      >
                        <X className="w-4 h-4" />
                      </Button>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </CardContent>
        </Card>

        {isEditing && form.employment_type === 'salary' && loadedEmployee && !isClient && (
          <EmployeeWorkProfilePanel
            employee={loadedEmployee}
            canManage={isManager}
            onUpdated={(profile) => setLoadedEmployee((current) => current ? { ...current, current_work_profile: profile } : current)}
          />
        )}

        {isEditing && loadedEmployee?.status_history && loadedEmployee.status_history.length > 0 && !isClient && (
          <Card className="mb-6">
            <CardHeader>
              <CardTitle>Employment status history</CardTitle>
              <CardDescription>Effective dates are preserved separately from the date a staff member entered the change.</CardDescription>
            </CardHeader>
            <CardContent>
              <div className="space-y-3">
                {loadedEmployee.status_history.map((event) => (
                  <div key={event.id} className="flex flex-col gap-2 rounded-2xl border border-neutral-200 bg-neutral-50 p-4 sm:flex-row sm:items-start sm:justify-between">
                    <div>
                      <p className="text-sm font-semibold capitalize text-neutral-900">{event.event_type} effective {event.effective_date}</p>
                      <p className="mt-1 text-xs text-neutral-600">
                        {event.last_worked_on ? `Last worked ${event.last_worked_on} · ` : ''}{event.reason_category ? `${event.reason_category.replaceAll('_', ' ')} · ` : ''}Recorded by {event.actor_name || 'system'}
                      </p>
                      {event.internal_notes && <p className="mt-2 text-sm leading-6 text-neutral-700">{event.internal_notes}</p>}
                    </div>
                    <span className="text-xs text-neutral-500">Entered {new Date(event.created_at).toLocaleString()}</span>
                  </div>
                ))}
              </div>
            </CardContent>
          </Card>
        )}

        {!isClient && !isEditing && (
          <Card id="employee-pay-items" className="mb-6 scroll-mt-28 border-neutral-200">
            <CardHeader>
              <CardTitle>Additions and deductions</CardTitle>
              <CardDescription>Every employee can have their own additions, deductions, and employer contributions. Save the employee first, then add items on their pay setup page.</CardDescription>
            </CardHeader>
          </Card>
        )}

        {!isClient && isEditing && loadedEmployee && (
          <EmployeePayItemsPanel
            key={`${companyId}:${id}`}
            employeeId={Number(id)} companyId={companyId}
            employeeName={`${loadedEmployee.first_name} ${loadedEmployee.last_name}`.trim()}
            companyName={activeCompany?.name || user?.company_name || 'this client'}
            refreshVersion={payItemRefreshVersion} onPendingChange={setPayItemPending} disabled={isSaving || showQuickPayrollField || quickPayrollFieldSaving}
            existingRecurringItems={[
              ...defaultPayrollAdjustments.map((row) => ({ name: row.label, kind: row.treatment.endsWith('_addition') ? 'addition' as const : 'deduction' as const, amount: row.amount, treatment: row.treatment, active: row.active, notes: row.notes, onUpdateSetup: row.active ? () => startLegacyPayItemMove({ kind: 'adjustment', row }) : undefined })),
              ...legacyCustomEarnings.map((row) => ({ name: row.label, kind: 'addition' as const, amount: row.amount, treatment: 'taxable_addition' as const, active: true, onUpdateSetup: () => startLegacyPayItemMove({ kind: 'custom_earning', row }) })),
            ]}
          />
        )}
        {!isClient && isEditing && showQuickPayrollField && (
          <Card className="mb-6"><CardContent>
              {showQuickPayrollField && (
                <div ref={quickPayrollFieldRef} className="mt-4 rounded-2xl border border-blue-200 bg-white p-4 shadow-sm">
                  <div className="mb-4 flex items-start justify-between gap-3">
                    <div>
                      <h3 className="text-base font-semibold text-slate-950">{legacyPayItemSource ? 'Update recurring item setup' : 'Add an employee-only pay item'}</h3>
                      <p className="mt-1 text-sm leading-6 text-slate-600">
                        {legacyPayItemSource
                          ? 'This updates one existing item without adding it twice. Its amount and tax treatment stay the same. Choose its category and payday dates; you can edit the saved item afterward.'
                          : 'This item belongs only to this employee. It saves immediately; save the employee form separately for any other changes.'}
                      </p>
                    </div>
                    <Button type="button" variant="ghost" size="sm" onClick={closeQuickPayrollField}>
                      <X className="h-4 w-4" />
                    </Button>
                  </div>
                  <div className="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
                    <div className="md:col-span-2 xl:col-span-1">
                      <label className="mb-1 block text-xs font-medium text-gray-600" htmlFor="employee-field-11">Field name</label>
                      <Input id="employee-field-11" value={quickPayrollField.name} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, name: event.target.value }))} placeholder="Auto loan, 401(k), phone allowance" />
                    </div>
                    <div>
                      <label className="mb-1 block text-xs font-medium text-gray-600" htmlFor="employee-field-34">Type</label>
                      <Select id="employee-field-34" value={quickPayrollField.kind} disabled={Boolean(legacyPayItemSource)} onChange={(event) => updateQuickPayrollFieldKind(event.target.value as PayrollFieldKind)}>
                        <option value="addition">Addition</option>
                        <option value="deduction">Deduction</option>
                        <option value="employer_contribution">Employer contribution</option>
                      </Select>
                    </div>
                    <div>
                      <label className="mb-1 block text-xs font-medium text-gray-600" htmlFor="employee-field-35">Treatment</label>
                      <Select id="employee-field-35" value={quickPayrollField.tax_treatment} disabled={Boolean(legacyPayItemSource)} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, tax_treatment: event.target.value as PayrollFieldTaxTreatment }))}>
                        {quickPayrollField.kind === 'addition' && <>
                          <option value="taxable_addition">Taxable addition</option>
                          <option value="non_taxable_addition">Non-taxable addition</option>
                        </>}
                        {quickPayrollField.kind === 'deduction' && <>
                          <option value="post_tax_deduction">Post-tax deduction</option>
                          <option value="pre_tax_deduction">Pre-tax deduction</option>
                        </>}
                        {quickPayrollField.kind === 'employer_contribution' && <option value="employer_contribution">Employer contribution</option>}
                      </Select>
                    </div>
                    <div>
                      <label className="mb-1 block text-xs font-medium text-gray-600" htmlFor="employee-field-36">Category</label>
                      <Select id="employee-field-36" value={quickPayrollField.category} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, category: event.target.value as PayrollFieldCategory, reporting_group: null }))}>
                        {legacyPayItemSource && <option value="">Choose a category</option>}
                        {['loan', 'retirement', 'insurance', 'rent', 'allotment', 'reimbursement', 'garnishment', 'child_support', 'phone', 'benefit', 'other'].map((category) => (
                          <option key={category} value={category}>{category.replace(/_/g, ' ')}</option>
                        ))}
                      </Select>
                    </div>
                    {quickPayrollField.category === 'retirement' && <div>
                      <label className="mb-1 block text-xs font-medium text-gray-600" htmlFor="employee-field-37">Report group</label>
                      <Select id="employee-field-37" value={quickPayrollField.reporting_group || ''} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, reporting_group: event.target.value ? event.target.value as PayrollFieldReportingGroup : null }))}>
                        {reportingGroupOptions.map((option) => (
                          <option key={option.value || 'none'} value={option.value}>{option.label}</option>
                        ))}
                      </Select>
                      <p className="mt-3 rounded-xl bg-primary-50 p-3 text-sm leading-6 text-primary-900">Enable catch-up in Pay setup → Retirement plan. Adding a field creates another contribution; it does not split or replace an existing deduction. Confirm existing manual paycheck entries before adding a replacement.</p>
                    </div>}
                    <div>
                      <label className="mb-1 block text-xs font-medium text-gray-600" htmlFor="employee-field-38">Default</label>
                      <Select id="employee-field-38" value={quickPayrollField.amount_type} disabled={Boolean(legacyPayItemSource)} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, amount_type: event.target.value as PayrollFieldAmountType }))}>
                        <option value="fixed">Fixed amount</option>
                        <option value="percentage">Percentage</option>
                        <option value="manual">Set during payroll</option>
                      </Select>
                    </div>
                    {quickPayrollField.amount_type === 'percentage' ? (
                      <div>
                        <label className="mb-1 block text-xs font-medium text-gray-600" htmlFor="employee-field-12">Default %</label>
                        <NumericInput id="employee-field-12" value={quickPayrollField.default_percentage} onValueChange={(value) => setQuickPayrollField((prev) => ({ ...prev, default_percentage: value ?? 0 }))} min={0} />
                      </div>
                    ) : quickPayrollField.amount_type === 'fixed' ? (
                      <div>
                        <label className="mb-1 block text-xs font-medium text-gray-600" htmlFor="employee-field-13">Default amount</label>
                        <NumericInput id="employee-field-13" value={quickPayrollField.default_amount} disabled={Boolean(legacyPayItemSource)} onValueChange={(value) => setQuickPayrollField((prev) => ({ ...prev, default_amount: value ?? 0 }))} min={0} fixedDecimalsOnBlur={2} />
                      </div>
                    ) : (
                      <div className="rounded-xl border border-dashed border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600">
                        Amount starts blank/zero and is filled during payroll review.
                      </div>
                    )}
                  </div>
                  <div className="mt-4 grid gap-4 md:grid-cols-2">
                    <label className="text-xs font-medium text-gray-600">Payee (optional)
                      <Input value={quickPayrollField.payee_name} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, payee_name: event.target.value }))} placeholder="Who receives this deduction or contribution?" />
                    </label>
                    <label className="text-xs font-medium text-gray-600">Reference number (optional)
                      <Input value={quickPayrollField.reference_number} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, reference_number: event.target.value }))} placeholder="Account or case reference" />
                    </label>
                  </div>
                  <div className="mt-4 grid gap-4 md:grid-cols-2">
                    <label className="text-xs font-medium text-gray-600">First payday (optional)
                      <Input type="date" value={quickPayrollField.start_date} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, start_date: event.target.value }))} />
                    </label>
                    <label className="text-xs font-medium text-gray-600">Last payday (optional)
                      <Input type="date" min={quickPayrollField.start_date || undefined} value={quickPayrollField.end_date} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, end_date: event.target.value }))} />
                    </label>
                    <label className="text-xs font-medium text-gray-600 md:col-span-2">Source or setup notes (optional)
                      <Input value={quickPayrollField.notes} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, notes: event.target.value }))} placeholder="Why this item applies" />
                    </label>
                  </div>
                  {legacyPayItemSource && <p role="note" className="mt-3 text-xs leading-5 text-amber-800">Old notes are reference only; dates mentioned there never controlled the old calculation. Set first and last payday above if the replacement needs limits. For a loan balance that should stop at payoff, connect a verified loan in Loans after this move.</p>}
                  {quickPayrollFieldError && <ActionFeedback retryKey={quickPayrollFieldErrorFeedbackAttempt} tone="error" message={quickPayrollFieldError} />}
                  <div className="mt-4 flex flex-wrap gap-2">
                    <Button type="button" size="sm" onClick={createQuickPayrollField} disabled={quickPayrollFieldSaving || !quickPayrollField.name.trim() || !quickPayrollField.category}>
                      {quickPayrollFieldSaving ? 'Saving…' : legacyPayItemSource ? 'Save setup' : 'Create and assign'}
                    </Button>
                    <Button type="button" variant="outline" size="sm" onClick={closeQuickPayrollField}>
                      Cancel
                    </Button>
                  </div>
                </div>
              )}
          </CardContent></Card>
        )}

        {/* Contractor Information — only shown for 1099 contractors */}
        {form.employment_type === 'contractor' && (
          <Card id="employee-tax" className="mb-6 scroll-mt-28">
            <CardHeader>
              <CardTitle>1099 Contractor Information</CardTitle>
              <p className="text-sm text-gray-500 mt-1">
                Based on IRS Form W-9. Contractors are not subject to tax withholding.
              </p>
            </CardHeader>
            <CardContent>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-39">
                    Contractor Type <span className="text-danger-600">*</span>
                  </label>
                  <Select id="employee-field-39"
                    name="contractor_type"
                    required
                    value={form.contractor_type || 'individual'}
                    onChange={(e) => handleChange('contractor_type', e.target.value as ContractorType)}
                  >
                    <option value="individual">Individual / Sole Proprietor</option>
                    <option value="business">Business Entity (LLC, Corp, etc.)</option>
                  </Select>
                </div>
                <div>
                  <label className="flex items-center gap-3 h-10 mt-6 cursor-pointer">
                    <input
                      type="checkbox"
                      checked={form.w9_on_file || false}
                      onChange={(e) => handleChange('w9_on_file', e.target.checked)}
                      className="h-4 w-4 text-primary-600 rounded border-gray-300 focus:ring-primary-500"
                    />
                    <span className="text-sm text-gray-700">W-9 on file</span>
                  </label>
                </div>
              </div>

              {form.contractor_type === 'business' && (
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-14">
                      Legal Business Name <span className="text-danger-600">*</span>
                    </label>
                    <Input id="employee-field-14"
                      name="business_name"
                      required
                      value={form.business_name || ''}
                      onChange={(e) => handleChange('business_name', e.target.value)}
                      placeholder="DBA or legal entity name"
                      error={getFieldError('business_name')}
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-15">
                      EIN (Employer Identification Number) {!allowsUnverifiedBlank('contractor_ein') && <span className="text-danger-600">*</span>}
                    </label>
                    <Input id="employee-field-15"
                      name="contractor_ein"
                      required={!allowsUnverifiedBlank('contractor_ein')}
                      value={form.contractor_ein || ''}
                      onChange={(e) => handleChange('contractor_ein', formatEIN(e.target.value))}
                      placeholder="XX-XXXXXXX"
                      error={getFieldError('contractor_ein')}
                    />
                  </div>
                </div>
              )}

              <div className="mt-4 p-3 bg-amber-50 border border-amber-200 rounded-lg">
                <p className="text-sm text-amber-800">
                  1099 contractors are not subject to income tax withholding, Social Security, or Medicare taxes.
                  1099-NEC filing eligibility uses the configured threshold for the payment year and is reviewed at year-end.
                </p>
              </div>
            </CardContent>
          </Card>
        )}

        {/* W-4 Tax Withholding — only shown for W-2 employees */}
        {form.employment_type !== 'contractor' && (
          <Card id="employee-tax" className="mb-6 scroll-mt-28">
            <CardHeader>
              <CardTitle>W-4 Tax Withholding</CardTitle>
              <p className="text-sm text-gray-500 mt-1">
                {allowsUnverifiedBlank('withholding_election') ? 'The employee withholding election is outstanding. Payroll requires an explicitly reviewed withholding decision.' : <>Based on IRS Form W-4 (2020+). Each saved change becomes a dated, read-only election in the employee&apos;s history.</>}
              </p>
            </CardHeader>
            <CardContent>
              {isEditing && loadedEmployee?.current_w4_election && (
                <div className="mb-5 rounded-2xl border border-primary-100 bg-primary-50/60 p-4">
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div>
                      <p className="text-sm font-semibold text-primary-950">{loadedEmployee.current_w4_election.source === 'default_withholding' ? 'Approved default withholding' : 'Current employee election'}</p>
                      <p className="mt-1 text-sm text-primary-800">
                        Effective {new Date(`${loadedEmployee.current_w4_election.effective_on}T00:00:00`).toLocaleDateString()} · Form {loadedEmployee.current_w4_election.w4_form_version}
                      </p>
                    </div>
                    <Badge variant="default">{loadedEmployee.w4_elections?.length || 1} recorded</Badge>
                  </div>
                  <p className="mt-3 text-xs leading-5 text-primary-800">Future payroll uses the election effective on its pay date. Previously committed and imported checks remain unchanged.</p>
                </div>
              )}

              {/* Step 1: Filing Status */}
              {loadedEmployee?.intake_readiness?.missing_fields.includes('withholding_election') && <div className="mb-4 rounded-lg border border-warning-200 bg-warning-50 p-3">
                <label className="flex items-start gap-2 text-sm leading-6 text-warning-900"><input name="w4_election_received" type="checkbox" checked={w4ElectionReceived} onChange={(event) => toggleReceivedWithholding(event.target.checked)} className="mt-1 h-4 w-4" />Record a received employee withholding election</label>
                <p className="mt-1 text-xs leading-5 text-warning-900">Use the received form's effective date and signed date or source reference. Ordinary profile edits preserve the approved default treatment.</p>
                {getFieldError('w4_election_received') && <p className="mt-2 text-sm text-danger-700">{getFieldError('w4_election_received')}</p>}
              </div>}
              <div className="mb-4">
                <h4 className="text-sm font-semibold text-gray-800 mb-2">Step 1: Filing Status</h4>
                <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-40">
                      Filing Status <span className="text-danger-600">*</span>
                    </label>
                    <Select id="employee-field-40"
                      required
                      value={form.filing_status}
                      onChange={(e) => handleChange('filing_status', e.target.value as FilingStatus)}
                    >
                      <option value="single">Single or Married Filing Separately</option>
                      <option value="married">Married Filing Jointly</option>
                      <option value="head_of_household">Head of Household</option>
                    </Select>
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-16">
                      Form revision year
                    </label>
                    <Input id="employee-field-16"
                      type="number"
                      min="1987"
                      max={new Date().getFullYear() + 1}
                      value={form.w4_form_version}
                      onChange={(e) => handleChange('w4_form_version', Number(e.target.value) || 2020)}
                    />
                    <p className="mt-1 text-xs text-gray-500">Pre-2020 forms are recorded but blocked from the 2020+ calculation engine.</p>
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-17">
                      Effective date
                    </label>
                    <Input id="employee-field-17"
                      name="w4_effective_on"
                      type="date"
                      value={form.w4_effective_on || ''}
                      onChange={(e) => handleChange('w4_effective_on', e.target.value || null)}
                      aria-invalid={Boolean(getFieldError('w4_effective_on'))}
                    />
                    <p className="mt-1 text-xs text-gray-500">{allowsUnverifiedBlank('withholding_election') ? 'Leave blank if the employee withholding election has not been received. Payroll needs a separate reviewed withholding decision.' : 'Record the date this withholding election became effective.'}</p>
                    {getFieldError('w4_effective_on') && <p className="mt-1 text-sm text-danger-600">{getFieldError('w4_effective_on')}</p>}
                  </div>
                </div>
              </div>

              <div className="mb-4 grid gap-4 md:grid-cols-2">
                <label className="text-sm font-medium text-gray-700">Signed date on source W-4 (optional)
                  <Input type="date" value={form.w4_signed_on || ''} onChange={(event) => handleChange('w4_signed_on', event.target.value || null)} />
                </label>
                <label className="text-sm font-medium text-gray-700">Source document / reference (optional)
                  <Input maxLength={255} value={form.w4_source_reference || ''} onChange={(event) => handleChange('w4_source_reference', event.target.value)} placeholder="Signed W-4 filename or verified source reference" />
                </label>
                <p className="text-xs text-gray-500 md:col-span-2">The signed date identifies the source document. The effective date controls which paychecks use this election. Recorded dates show when it was entered here; importing a record does not establish when a form was signed.</p>
              </div>

              {/* Step 2: Multiple Jobs */}
              <div className="mb-4 p-3 bg-gray-50 rounded-lg border border-gray-200">
                <h4 className="text-sm font-semibold text-gray-800 mb-2">Step 2: Multiple Jobs or Spouse Works</h4>
                <label className="flex items-center gap-3 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={form.w4_step2_multiple_jobs}
                    onChange={(e) => handleChange('w4_step2_multiple_jobs', e.target.checked)}
                    className="h-4 w-4 text-primary-600 rounded border-gray-300 focus:ring-primary-500"
                  />
                  <span className="text-sm text-gray-700">
                    Employee checked the Step 2(c) box (multiple jobs or spouse also works)
                  </span>
                </label>
                <p className="mt-1 text-xs text-gray-500 ml-7">
                  When checked, withholding uses the higher rate schedule to account for multiple income sources.
                </p>
              </div>

              {/* Step 3: Dependents */}
              <div className="mb-4">
                <h4 className="text-sm font-semibold text-gray-800 mb-2">Step 3: Dependent and Other Credits</h4>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-18">
                      Total Annual Step 3 Credit ($)
                    </label>
                    <Input id="employee-field-18"
                      type="text"
                      inputMode="decimal"
                      value={w4CurrencyDrafts.w4_dependent_credit}
                      onChange={(e) => handleW4CurrencyDraftChange('w4_dependent_credit', e.target.value)}
                      onBlur={() => commitW4CurrencyDraft('w4_dependent_credit')}
                    />
                    <p className="mt-1 text-xs text-gray-500">
                      Enter the total annual amount from Step 3 of the employee’s signed W-4, including any other credits.
                    </p>
                  </div>
                </div>
              </div>

              {/* Step 4: Other Adjustments */}
              <div className="mb-4">
                <h4 className="text-sm font-semibold text-gray-800 mb-2">Step 4: Other Adjustments (optional)</h4>
                <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-19">
                      4(a) Other Income ($)
                    </label>
                    <Input id="employee-field-19"
                      type="text"
                      inputMode="decimal"
                      value={w4CurrencyDrafts.w4_step4a_other_income}
                      onChange={(e) => handleW4CurrencyDraftChange('w4_step4a_other_income', e.target.value)}
                      onBlur={() => commitW4CurrencyDraft('w4_step4a_other_income')}
                    />
                    <p className="mt-1 text-xs text-gray-500">
                      Annual estimate of non-job income (interest, dividends, etc.)
                    </p>
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-20">
                      4(b) Deductions ($)
                    </label>
                    <Input id="employee-field-20"
                      type="text"
                      inputMode="decimal"
                      value={w4CurrencyDrafts.w4_step4b_deductions}
                      onChange={(e) => handleW4CurrencyDraftChange('w4_step4b_deductions', e.target.value)}
                      onBlur={() => commitW4CurrencyDraft('w4_step4b_deductions')}
                    />
                    <p className="mt-1 text-xs text-gray-500">
                      Annual amount if deductions exceed the standard deduction
                    </p>
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-21">
                      4(c) Extra Withholding ($)
                    </label>
                    <Input id="employee-field-21"
                      type="text"
                      inputMode="decimal"
                      value={w4CurrencyDrafts.additional_withholding}
                      onChange={(e) => handleW4CurrencyDraftChange('additional_withholding', e.target.value)}
                      onBlur={() => commitW4CurrencyDraft('additional_withholding')}
                    />
                    <p className="mt-1 text-xs text-gray-500">
                      Extra amount to withhold each pay period
                    </p>
                  </div>
                </div>
              </div>

              {isEditing && !isClient && (w4HasChanged || w4ElectionReceived) && (
                <div className="mb-5 rounded-2xl border border-amber-200 bg-amber-50 p-4">
                  <label htmlFor="w4-change-reason" className="block text-sm font-semibold text-amber-950">
                    Reason for this W-4 change <span className="text-danger-600">*</span>
                  </label>
                  <p className="mt-1 text-xs leading-5 text-amber-800">This note and the effective date will be preserved with the new election. The prior election will stay in history.</p>
                  <Input
                    id="w4-change-reason"
                    name="w4_change_reason"
                    className="mt-3 bg-white"
                    value={w4ChangeReason}
                    onChange={(event) => setW4ChangeReason(event.target.value)}
                    placeholder="Example: New signed W-4 received from employee"
                    aria-invalid={Boolean(getFieldError('w4_change_reason'))}
                  />
                  {getFieldError('w4_change_reason') && <p className="mt-1 text-sm text-danger-600">{getFieldError('w4_change_reason')}</p>}
                </div>
              )}

              {isEditing && loadedEmployee?.w4_elections && loadedEmployee.w4_elections.length > 0 && (
                <details className="mb-5 rounded-2xl border border-neutral-200 bg-neutral-50 p-4">
                  <summary className="cursor-pointer text-sm font-semibold text-neutral-900">View W-4 election history</summary>
                  <div className="mt-4 space-y-3">
                    {loadedEmployee.w4_elections.map((election) => (
                      <div key={election.id} className="rounded-xl border border-neutral-200 bg-white px-4 py-3 text-sm">
                        <div className="flex flex-wrap items-center justify-between gap-2">
                          <span className="font-semibold text-neutral-900">Effective {new Date(`${election.effective_on}T00:00:00`).toLocaleDateString()}</span>
                          <span className="text-xs font-medium uppercase tracking-wide text-neutral-500">{election.source.replace('_', ' ')}</span>
                        </div>
                        <p className="mt-1 text-neutral-600">Signed: {election.w4_signed_on || 'not recorded'} · Source: {election.w4_source_reference || 'not recorded'}</p>
                        <p className="mt-1 text-neutral-600">{filingStatusLabels[election.filing_status] || election.filing_status} · Form {election.w4_form_version} · {formatCurrency(Number(election.additional_withholding) || 0)} extra per pay period</p>
                        <p className="mt-2 text-xs leading-5 text-neutral-500">{election.reason}{election.created_by_name ? ` · Recorded by ${election.created_by_name}` : ''}</p>
                      </div>
                    ))}
                  </div>
                </details>
              )}

              {/* Retirement Contributions */}
              <div className="mt-6 pt-4 border-t border-gray-200">
                <h4 className="text-sm font-semibold text-gray-800 mb-1">Retirement Contributions</h4>
                {isEditing && loadedEmployee?.current_retirement_election ? (
                  <div className="rounded-2xl border border-primary-100 bg-primary-50/60 p-4">
                    <p className="text-sm font-semibold text-neutral-900">Managed as a dated retirement election</p>
                    <p className="mt-1 text-xs leading-5 text-neutral-600">Use the employee Pay setup workspace to change contribution amounts, annual limits, eligible pay, or employer match. This keeps prior elections intact.</p>
                    <Link className="mt-3 inline-flex min-h-10 items-center gap-2 rounded-full bg-primary-700 px-4 text-sm font-semibold text-white hover:bg-primary-800" to={employeePath(companyId, Number(id), 'pay-setup', { returnTo })}>Open retirement setup</Link>
                  </div>
                ) : <>
                <p className="mb-3 text-xs leading-5 text-gray-500">Basic percentage setup for a new employee. After saving, use Pay setup for fixed amounts, catch-up rules, caps, and employer match formulas.</p>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-22">
                      Pre-Tax 401(k) (%)
                    </label>
                    <NumericInput id="employee-field-22"
                      value={form.retirement_rate * 100}
                      onValueChange={(value) => handleChange('retirement_rate', (value ?? 0) / 100)}
                      min={0}
                      max={100}
                      fixedDecimalsOnBlur={2}
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-23">
                      Roth 401(k) (%)
                    </label>
                    <NumericInput id="employee-field-23"
                      value={form.roth_retirement_rate * 100}
                      onValueChange={(value) => handleChange('roth_retirement_rate', (value ?? 0) / 100)}
                      min={0}
                      max={100}
                      fixedDecimalsOnBlur={2}
                    />
                  </div>
                </div>
                <div className="mt-4 grid grid-cols-1 md:grid-cols-2 gap-4 rounded-xl border border-gray-200 bg-gray-50 p-4">
                  <div>
                    <label htmlFor="employer-retirement-match-rate" className="block text-sm font-medium text-gray-700 mb-1">
                      Employer Pre-Tax Match (%)
                    </label>
                    <NumericInput
                      id="employer-retirement-match-rate"
                      name="employer_retirement_match_rate"
                      value={(form.employer_retirement_match_rate || 0) * 100}
                      onValueChange={(value) => handleChange('employer_retirement_match_rate', (value ?? 0) / 100)}
                      min={0}
                      max={100}
                      fixedDecimalsOnBlur={2}
                      aria-invalid={Boolean(getFieldError('employer_retirement_match_rate'))}
                      className={getFieldError('employer_retirement_match_rate') ? 'border-danger-300 focus-visible:border-danger-500 focus-visible:ring-danger-200' : undefined}
                    />
                    {getFieldError('employer_retirement_match_rate') && <p className="mt-1 text-sm text-red-600">{getFieldError('employer_retirement_match_rate')}</p>}
                  </div>
                  <div>
                    <label htmlFor="employer-roth-match-rate" className="block text-sm font-medium text-gray-700 mb-1">
                      Employer Roth Match (%)
                    </label>
                    <NumericInput
                      id="employer-roth-match-rate"
                      name="employer_roth_match_rate"
                      value={(form.employer_roth_match_rate || 0) * 100}
                      onValueChange={(value) => handleChange('employer_roth_match_rate', (value ?? 0) / 100)}
                      min={0}
                      max={100}
                      fixedDecimalsOnBlur={2}
                      aria-invalid={Boolean(getFieldError('employer_roth_match_rate'))}
                      className={getFieldError('employer_roth_match_rate') ? 'border-danger-300 focus-visible:border-danger-500 focus-visible:ring-danger-200' : undefined}
                    />
                    {getFieldError('employer_roth_match_rate') && <p className="mt-1 text-sm text-red-600">{getFieldError('employer_roth_match_rate')}</p>}
                  </div>
                </div>
                </>}
              </div>
            </CardContent>
          </Card>
        )}

        {/* Address */}
        <Card id="employee-address" className="mb-6 scroll-mt-28">
          <CardHeader>
            <CardTitle>Address</CardTitle>
            <CardDescription>
              Used on payroll checks and required for W-2/1099 filing. Missing address lines are omitted from checks when incomplete entry is authorized.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-24">
                  Address Line 1 {!allowsUnverifiedBlank('address_line1') && <span className="text-danger-600">*</span>}
                </label>
                <Input id="employee-field-24"
                  name="address_line1"
                  required={!allowsUnverifiedBlank('address_line1')}
                  value={form.address_line1 || ''}
                  onChange={(e) => handleChange('address_line1', e.target.value)}
                  placeholder="Street address"
                  error={getFieldError('address_line1')}
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-25">
                  Address Line 2
                </label>
                <Input id="employee-field-25"
                  value={form.address_line2 || ''}
                  onChange={(e) => handleChange('address_line2', e.target.value)}
                  placeholder="Apt, suite, etc."
                />
              </div>
              <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
                <div className="col-span-2">
                  <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-26">
                    City {!allowsUnverifiedBlank('city') && <span className="text-danger-600">*</span>}
                  </label>
                  <Input id="employee-field-26"
                    name="city"
                    required={!allowsUnverifiedBlank('city')}
                    value={form.city || ''}
                    onChange={(e) => handleChange('city', e.target.value)}
                    error={getFieldError('city')}
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-27">
                    State {!allowsUnverifiedBlank('state') && <span className="text-danger-600">*</span>}
                  </label>
                  <Input id="employee-field-27"
                    name="state"
                    required={!allowsUnverifiedBlank('state')}
                    value={form.state || ''}
                    onChange={(e) => handleChange('state', e.target.value)}
                    maxLength={2}
                    placeholder="GU"
                    error={getFieldError('state')}
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1" htmlFor="employee-field-28">
                    ZIP Code {!allowsUnverifiedBlank('zip') && <span className="text-danger-600">*</span>}
                  </label>
                  <Input id="employee-field-28"
                    name="zip"
                    required={!allowsUnverifiedBlank('zip')}
                    value={form.zip || ''}
                    onChange={(e) => handleChange('zip', e.target.value)}
                    placeholder="96910"
                    error={getFieldError('zip')}
                  />
                </div>
              </div>
            </div>

          </CardContent>
        </Card>

        {isEditing && employeeStatus !== 'terminated' && !isClient && isManager && (
          <div className="flex justify-start">
            <Button
              type="button"
              variant="danger"
              onClick={() => setStatusTransitionMode('terminate')}
            >
              <Trash2 className="mr-2 h-4 w-4" />
              {`Terminate ${form.employment_type === 'contractor' ? 'Contractor' : 'Employee'}`}
            </Button>
          </div>
        )}
      </form>

      <div
        className="fixed inset-x-0 bottom-0 z-30 border-t border-neutral-200 bg-white/95 shadow-[0_-12px_35px_rgba(15,23,42,0.12)] backdrop-blur-md lg:left-[var(--sidebar-width)]"
        role="region"
        aria-label="Employee form actions"
      >
        <div className="mx-auto flex max-w-4xl flex-col gap-3 px-4 pt-3 [padding-bottom:max(0.75rem,env(safe-area-inset-bottom))] sm:flex-row sm:items-center sm:justify-between lg:px-8">
          <p className="hidden text-sm text-neutral-600 sm:block">
            Required fields are marked <span className="font-semibold text-danger-600">*</span>
          </p>
          <div className="grid grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)] gap-3 sm:flex sm:justify-end">
            <Button type="button" variant="outline" className="h-11 w-full sm:w-auto" onClick={() => navigate(returnTo)} disabled={isSaving || payItemPending || showQuickPayrollField}>
              Cancel
            </Button>
            <Button type="submit" form="employee-form" className="h-11 w-full sm:w-auto" disabled={isSaving || payItemPending || showQuickPayrollField || quickPayrollFieldSaving}>
              <Save className="mr-2 h-4 w-4" />
              {isSaving ? 'Saving...' : isEditing ? `Update ${form.employment_type === 'contractor' ? 'Contractor' : 'Employee'}` : `Create ${form.employment_type === 'contractor' ? 'Contractor' : 'Employee'}`}
            </Button>
          </div>
        </div>
      </div>

      {isEditing && id && (
        <div className="px-6 pb-8 lg:px-8">
          <Card id="employee-documents" className="max-w-4xl scroll-mt-28 border-neutral-200/80 bg-white/95">
            <CardHeader>
              <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
                <div className="flex gap-3">
                  <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-primary-50 text-primary-700 ring-1 ring-primary-100">
                    <FileText className="h-5 w-5" />
                  </div>
                  <div>
                    <div className="flex flex-wrap items-center gap-2">
                      <CardTitle>Employee Documents</CardTitle>
                      {loadedEmployee?.document_readiness && loadedEmployee.document_readiness.required > 0 && (
                        <span className={`rounded-full px-4 py-2 text-xs font-semibold ${loadedEmployee.document_readiness.ready_for_payroll ? 'bg-success-50 text-success-800' : 'bg-warning-50 text-warning-900'}`}>
                          {loadedEmployee.document_readiness.ready_for_payroll ? 'Payroll ready' : `${loadedEmployee.document_readiness.required - loadedEmployee.document_readiness.satisfied} item${loadedEmployee.document_readiness.required - loadedEmployee.document_readiness.satisfied === 1 ? '' : 's'} blocking approval`}
                        </span>
                      )}
                    </div>
                    <CardDescription>
                      W-4s, W-9s, direct deposit forms, IDs, and supporting files for {employeeDisplayName}.
                    </CardDescription>
                  </div>
                </div>
                <Button type="button" variant="outline" onClick={() => setEmployeeDocumentsOpen(true)}>
                  Manage documents
                </Button>
              </div>
            </CardHeader>
            <CardContent>
              <p className="text-sm leading-6 text-neutral-600">
                Documents are tucked away here so the employee profile stays focused on payroll setup. Open the manager when you need to upload, preview, download, or remove employee files.
              </p>
            </CardContent>
          </Card>
        </div>
      )}

      {isEditing && id && loadedEmployee && (
        <EmployeeClassificationTransitionDialog
          employee={loadedEmployee}
          open={classificationTransitionOpen}
          onOpenChange={(open): void => {
            if (companyIdRef.current === companyId) setClassificationTransitionOpen(open);
          }}
          onTransitioned={(newEmployee): void => {
            if (companyIdRef.current !== companyId) return;
            setLoadedEmployee(newEmployee);
            navigate(employeePath(companyId, newEmployee.id, 'activity', { returnTo }), { replace: true });
          }}
        />
      )}

      {isEditing && loadedEmployee && statusTransitionMode && (
        <EmployeeStatusTransitionDialog
          employee={loadedEmployee}
          mode={statusTransitionMode}
          open
          onOpenChange={(open): void => {
            if (companyIdRef.current === companyId && !open) setStatusTransitionMode(null);
          }}
          onCompleted={(employee): void => {
            if (companyIdRef.current !== companyId) return;
            setLoadedEmployee(employee);
            setEmployeeStatus(employee.status);
            setTerminationDate(employee.termination_date || null);
            setGeneralError(null);
          }}
        />
      )}

      {isEditing && id && (
        <Dialog open={employeeDocumentsOpen} onOpenChange={setEmployeeDocumentsOpen}>
          <DialogContent className="dialog-wide dialog-top mx-auto max-h-[calc(100vh-4rem)] max-w-5xl overflow-y-auto p-0">
            <EmployeeDocumentsPanel
              employeeId={parseInt(id, 10)}
              employeeName={employeeDisplayName}
              isClient={isClient}
              className="mb-0 border-0 shadow-none ring-0"
              onReadinessChange={handleDocumentReadinessChange}
              headerAction={
                <Button type="button" variant="outline" size="sm" onClick={() => setEmployeeDocumentsOpen(false)}>
                  Close
                </Button>
              }
            />
          </DialogContent>
        </Dialog>
      )}
    </div>
  );
}
