import { useState, useEffect, useCallback } from 'react';
import { useNavigate, useParams } from 'react-router';
import { ArrowLeft, Save, Trash2, AlertCircle, Plus, X, RotateCcw, FileText, LockKeyhole, ArrowRightLeft, CheckCircle2, XCircle, Link2 } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card, CardHeader, CardTitle, CardContent, CardDescription } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { NumericInput } from '@/components/ui/numeric-input';
import { Select } from '@/components/ui/select';
import { Dialog, DialogContent } from '@/components/ui/dialog';
import { EmployeeDocumentsPanel } from '@/components/employees/EmployeeDocumentsPanel';
import { EmployeeClassificationTransitionDialog } from '@/components/employees/EmployeeClassificationTransitionDialog';
import { employeesApi, departmentsApi, employeeWageRatesApi, clientEmployeesApi, clientDepartmentsApi, employeePayrollFieldsApi, payrollFieldsApi, ApiError } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';
import type { Department, Employee, EmployeeFormData, FilingStatus, EmploymentType, PayFrequency, ContractorType, ContractorPayType, EmployeeWageRate, PayrollAdjustmentTreatment, EmployeePayrollField, PayrollFieldDefinition, PayrollFieldKind, PayrollFieldTaxTreatment, PayrollFieldCategory, PayrollFieldReportingGroup, PayrollFieldAmountType } from '@/types';

const initialFormData: EmployeeFormData = {
  first_name: '',
  middle_name: '',
  last_name: '',
  ssn: '',
  ssn_confirmation: '',
  date_of_birth: '',
  hire_date: '',
  employment_type: 'hourly',
  salary_type: 'annual',
  pay_rate: 0,
  pay_frequency: 'biweekly',
  filing_status: 'single',
  allowances: 0,
  additional_withholding: 0,
  w4_dependent_credit: 0,
  w4_step2_multiple_jobs: false,
  w4_step4a_other_income: 0,
  w4_step4b_deductions: 0,
  w4_form_version: 2020,
  w4_effective_on: '',
  retirement_rate: 0,
  roth_retirement_rate: 0,
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

interface EmployeePayrollFieldFormRow {
  temp_id: string;
  id?: number;
  payroll_field_definition_id: number | '';
  amount: number;
  percentage: number;
  active: boolean;
  notes: string;
  dirty?: boolean;
}

interface QuickPayrollFieldDraft {
  name: string;
  kind: PayrollFieldKind;
  tax_treatment: PayrollFieldTaxTreatment;
  category: PayrollFieldCategory;
  reporting_group?: PayrollFieldReportingGroup | null;
  amount_type: PayrollFieldAmountType;
  default_amount: number;
  default_percentage: number;
}

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
});

const toCurrencyDraft = (value: number | null | undefined): string =>
  String(roundCurrencyValue(Number(value) || 0));

const reportingGroupOptions: Array<{ value: '' | PayrollFieldReportingGroup; label: string }> = [
  { value: '', label: 'No special report group' },
  { value: '401k_pre_tax', label: '401(k) Pre-Tax' },
  { value: '401k_after_tax', label: '401(k) After Tax / Roth' },
  { value: 'retirement_other', label: 'Other Retirement' },
];

const adjustmentTreatmentOptions: Array<{
  value: PayrollAdjustmentTreatment;
  label: string;
  helper: string;
  caution?: string;
}> = [
  {
    value: 'taxable_addition',
    label: 'Adds taxable pay',
    helper: 'Use for bonuses, allowances, or extra compensation. Increases gross wages and payroll taxes.',
  },
  {
    value: 'non_taxable_addition',
    label: 'Adds non-taxable reimbursement',
    helper: 'Use for true reimbursements or pass-through payments. Increases net pay only.',
    caution: 'If this is compensation for work, it is usually taxable.',
  },
  {
    value: 'post_tax_deduction',
    label: 'Deducts after taxes',
    helper: 'Use for loans, rent repayments, cash tips already paid out, or other after-tax deductions.',
  },
  {
    value: 'pre_tax_deduction',
    label: 'Deducts before taxes',
    helper: 'Reduces taxable wages before withholding is calculated.',
    caution: 'Use only for approved pre-tax deductions confirmed by an accountant or payroll administrator.',
  },
];

const additionAdjustmentOptions = adjustmentTreatmentOptions.filter((option) => option.value.endsWith('_addition'));
const deductionAdjustmentOptions = adjustmentTreatmentOptions.filter((option) => option.value.endsWith('_deduction'));

const adjustmentTreatmentCopy = (treatment: PayrollAdjustmentTreatment) => (
  adjustmentTreatmentOptions.find((option) => option.value === treatment) || adjustmentTreatmentOptions[0]
);

const normalizeEmployeeMonetaryFields = (form: EmployeeFormData): EmployeeFormData => ({
  ...form,
  pay_rate: roundCurrencyValue(form.pay_rate),
  additional_withholding: roundCurrencyValue(form.additional_withholding),
  w4_dependent_credit: roundCurrencyValue(form.w4_dependent_credit),
  w4_step4a_other_income: roundCurrencyValue(form.w4_step4a_other_income),
  w4_step4b_deductions: roundCurrencyValue(form.w4_step4b_deductions),
});

export function EmployeeForm() {
  const navigate = useNavigate();
  const { id } = useParams<{ id: string }>();
  const isEditing = Boolean(id);
  const { user, isClient, isSuperAdmin } = useAuth();
  // Use company_id from auth context, fall back to env var for dev mode
  const DEV_COMPANY_ID = parseInt(import.meta.env.VITE_COMPANY_ID || '1', 10);
  const companyId = user?.company_id ?? DEV_COMPANY_ID;

  const [form, setForm] = useState<EmployeeFormData>(initialFormData);
  const [loadedEmployee, setLoadedEmployee] = useState<Employee | null>(null);
  const [initialSsn, setInitialSsn] = useState('');
  const [initialEmploymentType, setInitialEmploymentType] = useState<EmploymentType>('hourly');
  const [departments, setDepartments] = useState<Department[]>([]);
  const [payrollFields, setPayrollFields] = useState<PayrollFieldDefinition[]>([]);
  const [employeePayrollFields, setEmployeePayrollFields] = useState<EmployeePayrollFieldFormRow[]>([]);
  const [showQuickPayrollField, setShowQuickPayrollField] = useState(false);
  const [quickPayrollField, setQuickPayrollField] = useState<QuickPayrollFieldDraft>(initialQuickPayrollFieldDraft());
  const [quickPayrollFieldSaving, setQuickPayrollFieldSaving] = useState(false);
  const [wageRates, setWageRates] = useState<WageRateFormRow[]>([defaultHourlyWageRate()]);
  const [defaultPayrollAdjustments, setDefaultPayrollAdjustments] = useState<PayrollAdjustmentFormRow[]>([]);
  const [w4CurrencyDrafts, setW4CurrencyDrafts] = useState<Record<W4MonetaryField, string>>({
    additional_withholding: toCurrencyDraft(initialFormData.additional_withholding),
    w4_dependent_credit: toCurrencyDraft(initialFormData.w4_dependent_credit),
    w4_step4a_other_income: toCurrencyDraft(initialFormData.w4_step4a_other_income),
    w4_step4b_deductions: toCurrencyDraft(initialFormData.w4_step4b_deductions),
  });
  const [employeeStatus, setEmployeeStatus] = useState<string>('active');
  const [terminationDate, setTerminationDate] = useState<string | null>(null);
  const [errors, setErrors] = useState<FormErrors>({});
  const [generalError, setGeneralError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);
  const [isReactivating, setIsReactivating] = useState(false);
  const [employeeDocumentsOpen, setEmployeeDocumentsOpen] = useState(false);
  const [classificationTransitionOpen, setClassificationTransitionOpen] = useState(false);

  const supportsMultipleHourlyRates =
    form.employment_type === 'hourly' ||
    (form.employment_type === 'contractor' && form.contractor_pay_type === 'hourly');

  const fetchEmployee = useCallback(async () => {
    if (!id) return;
    
    setIsLoading(true);
    try {
      const response = isClient
        ? await clientEmployeesApi.get(parseInt(id, 10))
        : await employeesApi.get(parseInt(id, 10));
      const employee = response.data;
      setLoadedEmployee(employee);
      
      const nextForm = {
        first_name: employee.first_name,
        middle_name: employee.middle_name || '',
        last_name: employee.last_name,
        ssn: employee.ssn || '',
        ssn_confirmation: '',
        date_of_birth: employee.date_of_birth || '',
        hire_date: employee.hire_date,
        employment_type: employee.employment_type,
        salary_type: employee.salary_type || 'annual',
        pay_rate: toNumberOrZero(employee.pay_rate),
        pay_frequency: employee.pay_frequency,
        filing_status: normalizeFilingStatus(employee.filing_status),
        allowances: toNumberOrZero(employee.allowances),
        additional_withholding: toNumberOrZero(employee.additional_withholding),
        w4_dependent_credit: toNumberOrZero(employee.w4_dependent_credit),
        w4_step2_multiple_jobs: toBoolean(employee.w4_step2_multiple_jobs),
        w4_step4a_other_income: toNumberOrZero(employee.w4_step4a_other_income),
        w4_step4b_deductions: toNumberOrZero(employee.w4_step4b_deductions),
        w4_form_version: toNumberOrZero(employee.w4_form_version) || 2020,
        w4_effective_on: employee.w4_effective_on || '',
        retirement_rate: toNumberOrZero(employee.retirement_rate),
        roth_retirement_rate: toNumberOrZero(employee.roth_retirement_rate),
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
      setInitialSsn(employee.ssn || '');
      setInitialEmploymentType(employee.employment_type);
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
      }
      setDefaultPayrollAdjustments((employee.default_payroll_adjustments || []).map((adjustment) => ({
        temp_id: crypto.randomUUID(),
        label: adjustment.label,
        amount: toNumberOrZero(adjustment.amount),
        treatment: adjustment.treatment,
        notes: adjustment.notes || '',
        active: adjustment.active !== false,
      })));
      
      setEmployeeStatus(employee.status || 'active');
      setTerminationDate(employee.termination_date || null);
    } catch (err) {
      setGeneralError(err instanceof Error ? err.message : 'Failed to load employee');
    } finally {
      setIsLoading(false);
    }
  }, [id, isClient]);

  const fetchPayrollFields = useCallback(async () => {
    if (isClient) return;
    try {
      const response = await payrollFieldsApi.list({ active: true });
      setPayrollFields(response.payroll_fields);
    } catch (err) {
      console.error('Failed to load payroll fields:', err);
    }
  }, [isClient]);

  const fetchEmployeePayrollFields = useCallback(async () => {
    if (!id || isClient) return;
    try {
      const response = await employeePayrollFieldsApi.list(parseInt(id, 10));
      setEmployeePayrollFields(response.employee_payroll_fields.map((assignment: EmployeePayrollField) => ({
        temp_id: crypto.randomUUID(),
        id: assignment.id,
        payroll_field_definition_id: assignment.payroll_field_definition_id,
        amount: toNumberOrZero(assignment.amount),
        percentage: toNumberOrZero(assignment.percentage),
        active: assignment.active !== false,
        notes: assignment.notes || '',
        dirty: false,
      })));
    } catch (err) {
      console.error('Failed to load employee payroll fields:', err);
    }
  }, [id, isClient]);

  const fetchDepartments = useCallback(async () => {
    try {
      const response = isClient
        ? await clientDepartmentsApi.list({ active: true })
        : await departmentsApi.list({ company_id: companyId, active: true });
      setDepartments(response.data);
    } catch (err) {
      console.error('Failed to load departments:', err);
    }
  }, [companyId, isClient]);

  useEffect(() => {
    fetchDepartments();
    fetchPayrollFields();
    if (isEditing) {
      fetchEmployee();
      fetchEmployeePayrollFields();
    }
  }, [fetchDepartments, fetchEmployee, fetchEmployeePayrollFields, fetchPayrollFields, isEditing]);

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

  const addDefaultPayrollAdjustment = (treatment: PayrollAdjustmentTreatment) => {
    setDefaultPayrollAdjustments((prev) => [
      ...prev,
      { temp_id: crypto.randomUUID(), label: '', amount: 0, treatment, notes: '', active: true },
    ]);
  };

  const updateDefaultPayrollAdjustment = (tempId: string, patch: Partial<PayrollAdjustmentFormRow>) => {
    setDefaultPayrollAdjustments((prev) => prev.map((adjustment) => (
      adjustment.temp_id === tempId ? { ...adjustment, ...patch } : adjustment
    )));
  };

  const removeDefaultPayrollAdjustment = (tempId: string) => {
    setDefaultPayrollAdjustments((prev) => prev.filter((adjustment) => adjustment.temp_id !== tempId));
  };

  const availablePayrollFields = payrollFields.filter((field) => !employeePayrollFields.some((row) => row.active !== false && row.payroll_field_definition_id === field.id));

  const defaultAssignmentValuesForField = (field?: PayrollFieldDefinition) => ({
    amount: field?.amount_type === 'fixed' ? toNumberOrZero(field.default_amount) : 0,
    percentage: field?.amount_type === 'percentage' ? toNumberOrZero(field.default_percentage) : 0,
  });

  const addEmployeePayrollField = (fieldOverride?: PayrollFieldDefinition) => {
    const availableField = fieldOverride || availablePayrollFields[0];
    if (!availableField) return;

    setEmployeePayrollFields((prev) => [
      ...prev,
      {
        temp_id: crypto.randomUUID(),
        payroll_field_definition_id: availableField.id,
        ...defaultAssignmentValuesForField(availableField),
        active: true,
        notes: '',
        dirty: true,
      },
    ]);
  };

  const updateEmployeePayrollField = (tempId: string, patch: Partial<EmployeePayrollFieldFormRow>) => {
    setEmployeePayrollFields((prev) => prev.map((row) => {
      if (row.temp_id !== tempId) return row;
      const selectedField = typeof patch.payroll_field_definition_id === 'number'
        ? payrollFields.find((field) => field.id === patch.payroll_field_definition_id)
        : undefined;
      return { ...row, ...(selectedField ? defaultAssignmentValuesForField(selectedField) : {}), ...patch, dirty: true };
    }));
  };

  const removeEmployeePayrollField = (tempId: string) => {
    setEmployeePayrollFields((prev) => prev.map((row) => row.temp_id === tempId ? { ...row, active: false, dirty: true } : row));
  };

  const closeQuickPayrollField = () => {
    setQuickPayrollField(initialQuickPayrollFieldDraft());
    setShowQuickPayrollField(false);
  };

  const updateQuickPayrollFieldKind = (kind: PayrollFieldKind) => {
    const tax_treatment: PayrollFieldTaxTreatment = kind === 'addition'
      ? 'taxable_addition'
      : kind === 'employer_contribution'
        ? 'employer_contribution'
        : 'post_tax_deduction';
    setQuickPayrollField((prev) => ({ ...prev, kind, tax_treatment }));
  };

  const createQuickPayrollField = async () => {
    if (!quickPayrollField.name.trim()) return;

    setQuickPayrollFieldSaving(true);
    try {
      const payload = {
        ...quickPayrollField,
        name: quickPayrollField.name.trim(),
        default_amount: quickPayrollField.amount_type === 'fixed' ? roundCurrencyValue(quickPayrollField.default_amount) : null,
        reporting_group: quickPayrollField.reporting_group || null,
        default_percentage: quickPayrollField.amount_type === 'percentage' ? Number(quickPayrollField.default_percentage) || 0 : null,
        show_in_payroll_grid: true,
      };
      const response = await payrollFieldsApi.create(payload);
      setPayrollFields((prev) => [...prev, response.payroll_field]);
      addEmployeePayrollField(response.payroll_field);
      setQuickPayrollField(initialQuickPayrollFieldDraft());
      setShowQuickPayrollField(false);
    } catch (err) {
      setGeneralError(err instanceof Error ? err.message : 'Failed to create payroll field');
    } finally {
      setQuickPayrollFieldSaving(false);
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
      field?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    });
  };

  const validateForm = (): boolean => {
    const newErrors: FormErrors = {};
    const usesSsn = form.employment_type !== 'contractor' || form.contractor_type !== 'business';
    const ssnChanged = (form.ssn || '') !== initialSsn;

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
    if (usesSsn && !form.ssn?.trim()) {
      newErrors.ssn = ['Social Security Number is required'];
    } else if (usesSsn && form.ssn && !/^\d{3}-\d{2}-\d{4}$/.test(form.ssn)) {
      newErrors.ssn = ['SSN must be in format XXX-XX-XXXX'];
    }
    if (usesSsn && (!isEditing || ssnChanged)) {
      if (!form.ssn_confirmation?.trim()) {
        newErrors.ssn_confirmation = ['Re-enter the Social Security Number'];
      } else if (form.ssn_confirmation !== form.ssn) {
        newErrors.ssn_confirmation = ['Social Security Numbers do not match'];
      }
    }
    if (!form.hire_date) {
      newErrors.hire_date = ['Hire date is required'];
    }
    if (!form.address_line1?.trim()) {
      newErrors.address_line1 = ['Address line 1 is required'];
    }
    if (!form.city?.trim()) {
      newErrors.city = ['City is required'];
    }
    if (!form.state?.trim()) {
      newErrors.state = ['State is required'];
    }
    if (!form.zip?.trim()) {
      newErrors.zip = ['ZIP code is required'];
    }
    if (form.employment_type === 'contractor' && form.contractor_type === 'business') {
      if (!form.business_name?.trim()) newErrors.business_name = ['Legal business name is required'];
      if (!form.contractor_ein?.trim()) {
        newErrors.contractor_ein = ['EIN is required'];
      } else if (!/^\d{2}-\d{7}$/.test(form.contractor_ein)) {
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
    const defaultAdjustments = normalizeDefaultPayrollAdjustments();
    const adjustmentKeys = defaultAdjustments.map((adjustment) => `${adjustment.treatment}:${adjustment.label.toLowerCase()}`);
    if (new Set(adjustmentKeys).size !== adjustmentKeys.length) {
      newErrors.default_payroll_adjustments = ['Recurring adjustment labels must be unique within the same treatment'];
    }
    const activePayrollFieldIds = employeePayrollFields
      .filter((row) => row.active !== false && row.payroll_field_definition_id)
      .map((row) => row.payroll_field_definition_id);
    if (new Set(activePayrollFieldIds).size !== activePayrollFieldIds.length) {
      newErrors.employee_payroll_fields = ['Each assigned payroll field can only appear once per employee'];
    }
    setErrors(newErrors);
    const firstInvalidField = Object.keys(newErrors)[0];
    focusFirstInvalidField(firstInvalidField);
    return !firstInvalidField;
  };

  const handleSubmit = async (e: React.FormEvent): Promise<void> => {
    e.preventDefault();
    
    if (!validateForm()) return;

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
      };

      let savedEmployeeId: number;
      let portalNotice: string | null = null;
      if (isEditing && id) {
        // Don't send SSN if it's empty (user didn't update it)
        const updateData = { ...employeePayload };
        if (!updateData.ssn) {
          delete updateData.ssn;
        }
        if (updateData.ssn === initialSsn) {
          delete updateData.ssn;
          delete updateData.ssn_confirmation;
        }
        if (isClient) {
          const response = await clientEmployeesApi.update(parseInt(id, 10), updateData);
          savedEmployeeId = response.data.id;
          portalNotice = response.message || null;
        } else {
          const response = await employeesApi.update(parseInt(id, 10), updateData);
          savedEmployeeId = response.data.id;
        }
      } else {
        if (isClient) {
          const response = await clientEmployeesApi.create(employeePayload);
          savedEmployeeId = response.data.id;
          portalNotice = response.message || null;
        } else {
          const response = await employeesApi.create({ ...employeePayload, company_id: companyId });
          savedEmployeeId = response.data.id;
        }
      }

      if (!isClient && savedEmployeeId) {
        const payrollFieldPayload: Partial<EmployeePayrollField>[] = employeePayrollFields
          .filter((row): row is EmployeePayrollFieldFormRow & { payroll_field_definition_id: number } =>
            typeof row.payroll_field_definition_id === 'number' && row.payroll_field_definition_id > 0 && (!row.id || row.dirty === true)
          )
          .map((row) => {
            const field = payrollFields.find((candidate) => candidate.id === row.payroll_field_definition_id);
            return {
              id: row.id,
              payroll_field_definition_id: row.payroll_field_definition_id,
              amount: field?.amount_type === 'fixed' ? roundCurrencyValue(Number(row.amount) || 0) : null,
              percentage: field?.amount_type === 'percentage' ? Number(row.percentage) || 0 : null,
              active: row.active !== false,
              notes: row.notes.trim(),
            };
          });

        if (payrollFieldPayload.length > 0) {
          await employeePayrollFieldsApi.bulkUpdate(savedEmployeeId, payrollFieldPayload);
        }
      }

      if (!isClient && supportsMultipleHourlyRates) {
        const existingRatesResponse = await employeeWageRatesApi.list(savedEmployeeId);
        const existingRates = existingRatesResponse.wage_rates;
        const normalizedById = new Map(
          normalizedWageRates
            .filter((rate) => rate.id)
            .map((rate) => [rate.id as number, rate])
        );

        await Promise.all(
          existingRates
            .filter((rate) => !normalizedById.has(rate.id as number))
            .map((rate) => employeeWageRatesApi.delete(rate.id as number))
        );

        for (const rate of normalizedWageRates) {
          const payload = {
            label: rate.label,
            rate: roundCurrencyValue(Number(rate.rate) || 0),
            is_primary: rate.is_primary,
            active: rate.active !== false,
          };

          if (rate.id) {
            await employeeWageRatesApi.update(rate.id, payload);
          } else {
            await employeeWageRatesApi.create({
              employee_id: savedEmployeeId,
              ...payload,
            });
          }
        }
      }

      navigate('/employees', {
        state: portalNotice ? { portalNotice } : null,
      });
    } catch (err) {
      if (err instanceof ApiError && err.details) {
        setErrors(err.details);
        focusFirstInvalidField(Object.keys(err.details)[0]);
      } else {
        setGeneralError(err instanceof Error ? err.message : 'Failed to save employee');
      }
    } finally {
      setIsSaving(false);
    }
  };

  const handleDelete = async (): Promise<void> => {
    if (!id || !confirm(`Are you sure you want to terminate this ${form.employment_type === 'contractor' ? 'contractor' : 'employee'}? This action will mark them as terminated.`)) {
      return;
    }

    setIsDeleting(true);
    try {
      await employeesApi.delete(parseInt(id, 10));
      navigate('/employees');
    } catch (err) {
      setGeneralError(err instanceof Error ? err.message : 'Failed to terminate employee');
    } finally {
      setIsDeleting(false);
    }
  };

  const handleReactivate = async (): Promise<void> => {
    if (!id || !confirm(`Are you sure you want to reactivate this ${form.employment_type === 'contractor' ? 'contractor' : 'employee'}? They will be marked as active again.`)) {
      return;
    }

    setIsReactivating(true);
    try {
      const response = await employeesApi.reactivate(parseInt(id, 10));
      setEmployeeStatus(response.data.status || 'active');
      setTerminationDate(null);
      setGeneralError(null);
    } catch (err) {
      setGeneralError(err instanceof Error ? err.message : 'Failed to reactivate employee');
    } finally {
      setIsReactivating(false);
    }
  };

  const getFieldError = (field: string): string | undefined => {
    return errors[field]?.[0];
  };

  const employeeDisplayName = [form.first_name, form.last_name].filter(Boolean).join(' ') || 'this employee';
  const isW2Employee = form.employment_type !== 'contractor';
  const taxIdUsesSsn = isW2Employee || form.contractor_type !== 'business';
  const ssnConfirmationRequired = taxIdUsesSsn
    && (!isEditing || (form.ssn || '') !== initialSsn);
  const ssnDigits = (form.ssn || '').replace(/\D/g, '');
  const ssnConfirmationDigits = (form.ssn_confirmation || '').replace(/\D/g, '');
  const ssnComparisonReady = ssnDigits.length === 9 && ssnConfirmationDigits.length === 9;
  const ssnsMatch = ssnComparisonReady && ssnDigits === ssnConfirmationDigits;

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
          <Button variant="outline" onClick={() => navigate('/employees')}>
            <ArrowLeft className="w-4 h-4 mr-2" />
            Back
          </Button>
        }
      />

      {isEditing && employeeStatus === 'terminated' && !isClient && (
        <div className="mx-6 lg:mx-8 mt-6 p-4 bg-red-50 border border-red-200 rounded-lg flex items-center justify-between">
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
          <Button
            type="button"
            variant="outline"
            onClick={handleReactivate}
            disabled={isReactivating}
            className="border-red-300 text-red-700 hover:bg-red-100"
          >
            <RotateCcw className="w-4 h-4 mr-2" />
            {isReactivating ? 'Reactivating...' : 'Reactivate'}
          </Button>
        </div>
      )}

      <form id="employee-form" noValidate onSubmit={handleSubmit} className="max-w-4xl p-6 pb-32 lg:p-8 lg:pb-32">
        {generalError && (
          <div className="mb-6 p-4 bg-danger-50 border border-danger-200 rounded-lg flex items-start gap-3">
            <AlertCircle className="w-5 h-5 text-danger-600 shrink-0 mt-0.5" />
            <p className="text-danger-700">{generalError}</p>
          </div>
        )}

        {/* Personal Information */}
        <Card className="mb-6">
          <CardHeader>
            <CardTitle>Personal Information</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  First Name <span className="text-danger-600">*</span>
                </label>
                <Input
                  name="first_name"
                  required
                  value={form.first_name}
                  onChange={(e) => handleChange('first_name', e.target.value)}
                  error={getFieldError('first_name')}
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Middle Name
                </label>
                <Input
                  value={form.middle_name}
                  onChange={(e) => handleChange('middle_name', e.target.value)}
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Last Name <span className="text-danger-600">*</span>
                </label>
                <Input
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
                    <label className="mb-1 block text-sm font-medium text-gray-700">
                      Social Security Number <span className="text-danger-600">*</span>
                    </label>
                    <Input
                      name="ssn"
                      required
                      placeholder="XXX-XX-XXXX"
                      value={form.ssn || ''}
                      onChange={(e) => handleChange('ssn', formatSSN(e.target.value))}
                      error={getFieldError('ssn')}
                      inputMode="numeric"
                      autoComplete="off"
                    />
                  </div>
                  <div>
                    <label className="mb-1 block text-sm font-medium text-gray-700">
                      Re-enter Social Security Number
                      {ssnConfirmationRequired && <span className="text-danger-600"> *</span>}
                    </label>
                    <Input
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
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Date of Birth
                </label>
                <Input
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
        <Card className="mb-6">
          <CardHeader>
            <CardTitle>Employment Information</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Hire Date <span className="text-danger-600">*</span>
                </label>
                <Input
                  name="hire_date"
                  required
                  type="date"
                  value={form.hire_date}
                  onChange={(e) => handleChange('hire_date', e.target.value)}
                  error={getFieldError('hire_date')}
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Department
                </label>
                <Select
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
            </div>

            <div className={`grid grid-cols-1 ${form.employment_type === 'contractor' ? 'md:grid-cols-4' : form.employment_type === 'salary' ? 'md:grid-cols-4' : 'md:grid-cols-3'} gap-4 mt-4`}>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Employment Type <span className="text-danger-600">*</span>
                </label>
                <Select
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
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    Salary Type <span className="text-danger-600">*</span>
                  </label>
                  <Select
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
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    Pay Structure <span className="text-danger-600">*</span>
                  </label>
                  <Select
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
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    {form.employment_type === 'contractor'
                      ? (form.contractor_pay_type === 'hourly' ? 'Hourly Rate' : 'Flat Fee per Period')
                      : 'Pay Rate'} <span className="text-danger-600">*</span>
                  </label>
                  <NumericInput
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
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Pay Frequency <span className="text-danger-600">*</span>
                </label>
                <Select
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
                            <button type="button" className="block w-full rounded-lg px-2 py-1.5 text-left text-xs hover:bg-primary-50" onClick={() => navigate(`/employees/${loadedEmployee.classification_history?.previous_employee?.id}`)}>
                              <span className="font-semibold text-primary-700">Prior {loadedEmployee.classification_history.previous_employee.tax_classification.toUpperCase()} record</span>
                              <span className="ml-2 text-neutral-500">{loadedEmployee.classification_history.previous_employee.hire_date || 'Start unknown'} – {loadedEmployee.classification_history.previous_employee.termination_date || 'End unknown'}</span>
                            </button>
                          )}
                          <div className="rounded-lg bg-neutral-100 px-2 py-1.5 text-xs text-neutral-700">
                            <span className="font-semibold">Current {loadedEmployee.tax_classification?.toUpperCase()} record</span>
                            <span className="ml-2">{loadedEmployee.hire_date || 'Start unknown'} – {loadedEmployee.termination_date || 'Present'}</span>
                          </div>
                          {loadedEmployee.classification_history.next_employee && (
                            <button type="button" className="block w-full rounded-lg px-2 py-1.5 text-left text-xs hover:bg-primary-50" onClick={() => navigate(`/employees/${loadedEmployee.classification_history?.next_employee?.id}`)}>
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
                        <label className="block text-xs font-medium text-gray-600 mb-1">
                          Rate Label <span className="text-danger-600">*</span>
                        </label>
                        <Input
                          name="wage_rates"
                          required
                          value={rate.label}
                          onChange={(e) => updateWageRate(rate.temp_id, { label: e.target.value })}
                          placeholder={index === 0 ? 'Flight Time' : 'Office Time'}
                        />
                      </div>
                      <div>
                        <label className="block text-xs font-medium text-gray-600 mb-1">
                          Hourly Rate <span className="text-danger-600">*</span>
                        </label>
                        <NumericInput
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

        {!isClient && isEditing && (
          <Card className="mb-6 border-blue-200 bg-blue-50/40">
            <CardHeader>
              <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <CardTitle>Assigned Payroll Fields</CardTitle>
                  <CardDescription>
                    Assign reusable client-wide fields for loans, 401(k), insurance, rent, reimbursements, and employer contributions.
                    Field definitions are managed once for the whole client, then assigned to employees here.
                  </CardDescription>
                </div>
                <Button type="button" variant="outline" size="sm" onClick={() => navigate('/payroll-fields')}>
                  Manage client-wide fields
                </Button>
              </div>
            </CardHeader>
            <CardContent>
              {getFieldError('employee_payroll_fields') && (
                <div className="mb-3 rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">
                  {getFieldError('employee_payroll_fields')}
                </div>
              )}
              {payrollFields.length === 0 ? (
                <div className="flex flex-col gap-3 rounded-lg border border-blue-100 bg-white px-4 py-3 text-sm text-blue-800 sm:flex-row sm:items-center sm:justify-between">
                  <span>No client-wide payroll fields exist yet. Create reusable fields first, then assign them here.</span>
                  <Button type="button" variant="outline" size="sm" onClick={() => navigate('/payroll-fields')}>
                    Create payroll fields
                  </Button>
                </div>
              ) : (
                <div className="space-y-3">
                  {employeePayrollFields.filter((row) => row.active !== false).map((row) => {
                    const selectedField = payrollFields.find((field) => field.id === row.payroll_field_definition_id);
                    const rowAvailablePayrollFields = payrollFields.filter((field) =>
                      field.id === row.payroll_field_definition_id ||
                      !employeePayrollFields.some((candidate) => candidate.temp_id !== row.temp_id && candidate.active !== false && candidate.payroll_field_definition_id === field.id)
                    );
                    return (
                      <div key={row.temp_id} className="rounded-xl border border-blue-100 bg-white p-4 shadow-sm">
                        <div className="grid grid-cols-1 items-end gap-3 lg:grid-cols-[minmax(0,1.5fr)_10rem_10rem_auto]">
                          <div>
                            <label className="mb-1 block text-xs font-medium text-gray-600">Payroll field</label>
                            <Select
                              value={row.payroll_field_definition_id || ''}
                              onChange={(event) => updateEmployeePayrollField(row.temp_id, { payroll_field_definition_id: Number(event.target.value) })}
                            >
                              <option value="">Select field</option>
                              {rowAvailablePayrollFields.map((field) => (
                                <option key={field.id} value={field.id}>{field.name} · {field.tax_treatment.replace(/_/g, ' ')}</option>
                              ))}
                            </Select>
                          </div>
                          {selectedField?.amount_type === 'percentage' ? (
                            <div>
                              <label className="mb-1 block text-xs font-medium text-gray-600">Employee %</label>
                              <NumericInput
                                value={row.percentage}
                                onValueChange={(value) => updateEmployeePayrollField(row.temp_id, { percentage: value ?? 0 })}
                                min={0}
                              />
                            </div>
                          ) : selectedField?.amount_type === 'manual' ? (
                            <div className="rounded-lg border border-gray-200 bg-gray-50 px-3 py-2 text-xs text-gray-600">
                              Manual each payroll
                            </div>
                          ) : (
                            <div>
                              <label className="mb-1 block text-xs font-medium text-gray-600">Employee amount</label>
                              <NumericInput
                                value={row.amount}
                                onValueChange={(value) => updateEmployeePayrollField(row.temp_id, { amount: value ?? 0 })}
                                min={0}
                                fixedDecimalsOnBlur={2}
                              />
                            </div>
                          )}
                          <div>
                            <label className="mb-1 block text-xs font-medium text-gray-600">Notes</label>
                            <Input
                              value={row.notes}
                              onChange={(event) => updateEmployeePayrollField(row.temp_id, { notes: event.target.value })}
                              placeholder="Optional source or setup note"
                            />
                          </div>
                          <Button type="button" variant="outline" size="sm" onClick={() => removeEmployeePayrollField(row.temp_id)}>
                            <X className="h-4 w-4" />
                          </Button>
                        </div>
                        {selectedField && (
                          <p className="mt-2 text-xs text-blue-800">
                            {selectedField.kind.replace(/_/g, ' ')} · {selectedField.tax_treatment.replace(/_/g, ' ')} · {selectedField.category.replace(/_/g, ' ')}
                          </p>
                        )}
                      </div>
                    );
                  })}
                </div>
              )}
              <div className="mt-3 flex flex-wrap gap-2">
                <Button type="button" variant="outline" size="sm" onClick={() => addEmployeePayrollField()} disabled={availablePayrollFields.length === 0}>
                  <Plus className="mr-1 h-4 w-4" />
                  Assign Payroll Field
                </Button>
                <Button type="button" variant="secondary" size="sm" onClick={() => setShowQuickPayrollField(true)}>
                  <Plus className="mr-1 h-4 w-4" />
                  Create client-wide field
                </Button>
              </div>

              {showQuickPayrollField && (
                <div className="mt-4 rounded-2xl border border-blue-200 bg-white p-4 shadow-sm">
                  <div className="mb-4 flex items-start justify-between gap-3">
                    <div>
                      <h3 className="text-base font-semibold text-slate-950">Create reusable client-wide payroll field</h3>
                      <p className="mt-1 text-sm leading-6 text-slate-600">
                        This creates a field for the whole client and immediately assigns it to this employee.
                      </p>
                    </div>
                    <Button type="button" variant="ghost" size="sm" onClick={closeQuickPayrollField}>
                      <X className="h-4 w-4" />
                    </Button>
                  </div>
                  <div className="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
                    <div className="md:col-span-2 xl:col-span-1">
                      <label className="mb-1 block text-xs font-medium text-gray-600">Field name</label>
                      <Input value={quickPayrollField.name} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, name: event.target.value }))} placeholder="Auto loan, 401(k), phone allowance" />
                    </div>
                    <div>
                      <label className="mb-1 block text-xs font-medium text-gray-600">Type</label>
                      <Select value={quickPayrollField.kind} onChange={(event) => updateQuickPayrollFieldKind(event.target.value as PayrollFieldKind)}>
                        <option value="addition">Addition</option>
                        <option value="deduction">Deduction</option>
                        <option value="employer_contribution">Employer contribution</option>
                      </Select>
                    </div>
                    <div>
                      <label className="mb-1 block text-xs font-medium text-gray-600">Treatment</label>
                      <Select value={quickPayrollField.tax_treatment} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, tax_treatment: event.target.value as PayrollFieldTaxTreatment }))}>
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
                      <label className="mb-1 block text-xs font-medium text-gray-600">Category</label>
                      <Select value={quickPayrollField.category} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, category: event.target.value as PayrollFieldCategory }))}>
                        {['loan', 'retirement', 'insurance', 'rent', 'allotment', 'reimbursement', 'garnishment', 'child_support', 'phone', 'benefit', 'other'].map((category) => (
                          <option key={category} value={category}>{category.replace(/_/g, ' ')}</option>
                        ))}
                      </Select>
                    </div>
                    <div>
                      <label className="mb-1 block text-xs font-medium text-gray-600">Report group</label>
                      <Select value={quickPayrollField.reporting_group || ''} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, reporting_group: event.target.value ? event.target.value as PayrollFieldReportingGroup : null }))}>
                        {reportingGroupOptions.map((option) => (
                          <option key={option.value || 'none'} value={option.value}>{option.label}</option>
                        ))}
                      </Select>
                    </div>
                    <div>
                      <label className="mb-1 block text-xs font-medium text-gray-600">Default</label>
                      <Select value={quickPayrollField.amount_type} onChange={(event) => setQuickPayrollField((prev) => ({ ...prev, amount_type: event.target.value as PayrollFieldAmountType }))}>
                        <option value="fixed">Fixed amount</option>
                        <option value="percentage">Percentage</option>
                        <option value="manual">Set during payroll</option>
                      </Select>
                    </div>
                    {quickPayrollField.amount_type === 'percentage' ? (
                      <div>
                        <label className="mb-1 block text-xs font-medium text-gray-600">Default %</label>
                        <NumericInput value={quickPayrollField.default_percentage} onValueChange={(value) => setQuickPayrollField((prev) => ({ ...prev, default_percentage: value ?? 0 }))} min={0} />
                      </div>
                    ) : quickPayrollField.amount_type === 'fixed' ? (
                      <div>
                        <label className="mb-1 block text-xs font-medium text-gray-600">Default amount</label>
                        <NumericInput value={quickPayrollField.default_amount} onValueChange={(value) => setQuickPayrollField((prev) => ({ ...prev, default_amount: value ?? 0 }))} min={0} fixedDecimalsOnBlur={2} />
                      </div>
                    ) : (
                      <div className="rounded-xl border border-dashed border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600">
                        Amount starts blank/zero and is filled during payroll review.
                      </div>
                    )}
                  </div>
                  <div className="mt-4 flex flex-wrap gap-2">
                    <Button type="button" size="sm" onClick={createQuickPayrollField} disabled={quickPayrollFieldSaving || !quickPayrollField.name.trim()}>
                      Create and assign
                    </Button>
                    <Button type="button" variant="outline" size="sm" onClick={closeQuickPayrollField}>
                      Cancel
                    </Button>
                  </div>
                </div>
              )}
            </CardContent>
          </Card>
        )}

        <Card className="mb-6 border-slate-200 bg-slate-50/60">
          <CardHeader>
            <CardTitle>Employee-Specific Recurring Adjustments</CardTitle>
            <CardDescription>
              Use these for recurring additions, reimbursements, or deductions. Each item is copied into new payroll runs and can be reviewed before finalizing.
            </CardDescription>
          </CardHeader>
          <CardContent>
            {getFieldError('default_payroll_adjustments') && (
              <div className="mb-4 rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                {getFieldError('default_payroll_adjustments')}
              </div>
            )}

            <div className="grid gap-5 2xl:grid-cols-2">
              <section className="rounded-2xl border border-emerald-100 bg-emerald-50/50 p-4">
                <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                  <div>
                    <h3 className="text-base font-semibold text-emerald-950">Recurring additions</h3>
                    <p className="mt-1 text-sm leading-6 text-emerald-800">
                      Use this side when money should be added to the employee's check.
                    </p>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    <Button type="button" variant="outline" size="sm" onClick={() => addDefaultPayrollAdjustment('taxable_addition')}>
                      <Plus className="mr-1 h-4 w-4" />
                      Taxable
                    </Button>
                    <Button type="button" variant="outline" size="sm" onClick={() => addDefaultPayrollAdjustment('non_taxable_addition')}>
                      <Plus className="mr-1 h-4 w-4" />
                      Non-taxable
                    </Button>
                  </div>
                </div>
                <div className="mb-4 grid gap-3 md:grid-cols-2">
                  {additionAdjustmentOptions.map((option) => (
                    <div key={option.value} className="rounded-xl border border-emerald-100 bg-white p-3 shadow-sm">
                      <div className="text-sm font-semibold text-slate-900">{option.label}</div>
                      <p className="mt-1 text-xs leading-5 text-slate-600">{option.helper}</p>
                      {option.caution && <p className="mt-2 text-xs font-medium text-amber-700">{option.caution}</p>}
                    </div>
                  ))}
                </div>
                <div className="space-y-3">
                  {defaultPayrollAdjustments.filter((adjustment) => adjustment.treatment.endsWith('_addition')).map((adjustment) => {
                    const treatment = adjustmentTreatmentCopy(adjustment.treatment);
                    return (
                      <div key={adjustment.temp_id} className="rounded-xl border border-emerald-100 bg-white p-4 shadow-sm">
                        <div className="grid grid-cols-1 items-end gap-3 md:grid-cols-2">
                          <div>
                            <label className="mb-1 block text-xs font-medium text-gray-600">Label</label>
                            <Input value={adjustment.label} onChange={(event) => updateDefaultPayrollAdjustment(adjustment.temp_id, { label: event.target.value })} placeholder="Bonus, stipend, reimbursement" />
                          </div>
                          <div>
                            <label className="mb-1 block text-xs font-medium text-gray-600">Amount</label>
                            <NumericInput value={adjustment.amount} onValueChange={(value) => updateDefaultPayrollAdjustment(adjustment.temp_id, { amount: value ?? 0 })} min={0} fixedDecimalsOnBlur={2} />
                          </div>
                          <div className="min-w-0">
                            <label className="mb-1 block text-xs font-medium text-gray-600">Addition type</label>
                            <Select value={adjustment.treatment} onChange={(event) => updateDefaultPayrollAdjustment(adjustment.temp_id, { treatment: event.target.value as PayrollAdjustmentTreatment })}>
                              {additionAdjustmentOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
                            </Select>
                          </div>
                          <Button type="button" variant="outline" size="sm" className="justify-self-start md:justify-self-end md:self-end" onClick={() => removeDefaultPayrollAdjustment(adjustment.temp_id)}>
                            <X className="h-4 w-4" />
                          </Button>
                        </div>
                        <p className="mt-2 text-xs leading-5 text-slate-600">{treatment.helper} {treatment.caution && <span className="font-medium text-amber-700">{treatment.caution}</span>}</p>
                        <div className="mt-3">
                          <label className="mb-1 block text-xs font-medium text-gray-600">Source / notes</label>
                          <Input value={adjustment.notes} onChange={(event) => updateDefaultPayrollAdjustment(adjustment.temp_id, { notes: event.target.value })} placeholder="Per accountant or client recurring setup" />
                        </div>
                      </div>
                    );
                  })}
                  {defaultPayrollAdjustments.every((adjustment) => !adjustment.treatment.endsWith('_addition')) && (
                    <div className="rounded-xl border border-dashed border-emerald-200 bg-white/70 px-4 py-6 text-sm text-emerald-800">No recurring additions set.</div>
                  )}
                </div>
              </section>

              <section className="rounded-2xl border border-rose-100 bg-rose-50/50 p-4">
                <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                  <div>
                    <h3 className="text-base font-semibold text-rose-950">Recurring deductions</h3>
                    <p className="mt-1 text-sm leading-6 text-rose-800">
                      Use this side only when money should be subtracted from the employee's check.
                    </p>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    <Button type="button" variant="outline" size="sm" onClick={() => addDefaultPayrollAdjustment('post_tax_deduction')}>
                      <Plus className="mr-1 h-4 w-4" />
                      After tax
                    </Button>
                    <Button type="button" variant="outline" size="sm" onClick={() => addDefaultPayrollAdjustment('pre_tax_deduction')}>
                      <Plus className="mr-1 h-4 w-4" />
                      Before tax
                    </Button>
                  </div>
                </div>
                <div className="mb-4 grid gap-3 md:grid-cols-2">
                  {deductionAdjustmentOptions.map((option) => (
                    <div key={option.value} className="rounded-xl border border-rose-100 bg-white p-3 shadow-sm">
                      <div className="text-sm font-semibold text-slate-900">{option.label}</div>
                      <p className="mt-1 text-xs leading-5 text-slate-600">{option.helper}</p>
                      {option.caution && <p className="mt-2 text-xs font-medium text-amber-700">{option.caution}</p>}
                    </div>
                  ))}
                </div>
                <div className="space-y-3">
                  {defaultPayrollAdjustments.filter((adjustment) => adjustment.treatment.endsWith('_deduction')).map((adjustment) => {
                    const treatment = adjustmentTreatmentCopy(adjustment.treatment);
                    return (
                      <div key={adjustment.temp_id} className="rounded-xl border border-rose-100 bg-white p-4 shadow-sm">
                        <div className="grid grid-cols-1 items-end gap-3 md:grid-cols-2">
                          <div>
                            <label className="mb-1 block text-xs font-medium text-gray-600">Label</label>
                            <Input value={adjustment.label} onChange={(event) => updateDefaultPayrollAdjustment(adjustment.temp_id, { label: event.target.value })} placeholder="Loan, rent, cash tips, garnishment" />
                          </div>
                          <div>
                            <label className="mb-1 block text-xs font-medium text-gray-600">Amount</label>
                            <NumericInput value={adjustment.amount} onValueChange={(value) => updateDefaultPayrollAdjustment(adjustment.temp_id, { amount: value ?? 0 })} min={0} fixedDecimalsOnBlur={2} />
                          </div>
                          <div className="min-w-0">
                            <label className="mb-1 block text-xs font-medium text-gray-600">Deduction type</label>
                            <Select value={adjustment.treatment} onChange={(event) => updateDefaultPayrollAdjustment(adjustment.temp_id, { treatment: event.target.value as PayrollAdjustmentTreatment })}>
                              {deductionAdjustmentOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
                            </Select>
                          </div>
                          <Button type="button" variant="outline" size="sm" className="justify-self-start md:justify-self-end md:self-end" onClick={() => removeDefaultPayrollAdjustment(adjustment.temp_id)}>
                            <X className="h-4 w-4" />
                          </Button>
                        </div>
                        <p className="mt-2 text-xs leading-5 text-slate-600">{treatment.helper} {treatment.caution && <span className="font-medium text-amber-700">{treatment.caution}</span>}</p>
                        <div className="mt-3">
                          <label className="mb-1 block text-xs font-medium text-gray-600">Source / notes</label>
                          <Input value={adjustment.notes} onChange={(event) => updateDefaultPayrollAdjustment(adjustment.temp_id, { notes: event.target.value })} placeholder="Per accountant or client recurring setup" />
                        </div>
                      </div>
                    );
                  })}
                  {defaultPayrollAdjustments.every((adjustment) => !adjustment.treatment.endsWith('_deduction')) && (
                    <div className="rounded-xl border border-dashed border-rose-200 bg-white/70 px-4 py-6 text-sm text-rose-800">No recurring deductions set.</div>
                  )}
                </div>
              </section>
            </div>
          </CardContent>
        </Card>

        {/* Contractor Information — only shown for 1099 contractors */}
        {form.employment_type === 'contractor' && (
          <Card className="mb-6">
            <CardHeader>
              <CardTitle>1099 Contractor Information</CardTitle>
              <p className="text-sm text-gray-500 mt-1">
                Based on IRS Form W-9. Contractors are not subject to tax withholding.
              </p>
            </CardHeader>
            <CardContent>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    Contractor Type <span className="text-danger-600">*</span>
                  </label>
                  <Select
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
                    <label className="block text-sm font-medium text-gray-700 mb-1">
                      Legal Business Name <span className="text-danger-600">*</span>
                    </label>
                    <Input
                      name="business_name"
                      required
                      value={form.business_name || ''}
                      onChange={(e) => handleChange('business_name', e.target.value)}
                      placeholder="DBA or legal entity name"
                      error={getFieldError('business_name')}
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1">
                      EIN (Employer Identification Number) <span className="text-danger-600">*</span>
                    </label>
                    <Input
                      name="contractor_ein"
                      required
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
          <Card className="mb-6">
            <CardHeader>
              <CardTitle>W-4 Tax Withholding</CardTitle>
              <p className="text-sm text-gray-500 mt-1">
                Based on IRS Form W-4 (2020+). Enter values from the employee&apos;s submitted W-4.
              </p>
            </CardHeader>
            <CardContent>
              {/* Step 1: Filing Status */}
              <div className="mb-4">
                <h4 className="text-sm font-semibold text-gray-800 mb-2">Step 1: Filing Status</h4>
                <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1">
                      Filing Status <span className="text-danger-600">*</span>
                    </label>
                    <Select
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
                    <label className="block text-sm font-medium text-gray-700 mb-1">
                      Form revision year
                    </label>
                    <Input
                      type="number"
                      min="1987"
                      max={new Date().getFullYear() + 1}
                      value={form.w4_form_version}
                      onChange={(e) => handleChange('w4_form_version', Number(e.target.value) || 2020)}
                    />
                    <p className="mt-1 text-xs text-gray-500">Pre-2020 forms are recorded but blocked from the 2020+ calculation engine.</p>
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1">
                      Effective date
                    </label>
                    <Input
                      type="date"
                      value={form.w4_effective_on || ''}
                      onChange={(e) => handleChange('w4_effective_on', e.target.value || null)}
                    />
                    <p className="mt-1 text-xs text-gray-500">Record the date this withholding election became effective.</p>
                  </div>
                </div>
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
                <h4 className="text-sm font-semibold text-gray-800 mb-2">Step 3: Claim Dependents</h4>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1">
                      Total Annual Dependent Credit ($)
                    </label>
                    <Input
                      type="text"
                      inputMode="decimal"
                      value={w4CurrencyDrafts.w4_dependent_credit}
                      onChange={(e) => handleW4CurrencyDraftChange('w4_dependent_credit', e.target.value)}
                      onBlur={() => commitW4CurrencyDraft('w4_dependent_credit')}
                    />
                    <p className="mt-1 text-xs text-gray-500">
                      $2,000 per qualifying child under 17 + $500 per other dependent
                    </p>
                  </div>
                </div>
              </div>

              {/* Step 4: Other Adjustments */}
              <div className="mb-4">
                <h4 className="text-sm font-semibold text-gray-800 mb-2">Step 4: Other Adjustments (optional)</h4>
                <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1">
                      4(a) Other Income ($)
                    </label>
                    <Input
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
                    <label className="block text-sm font-medium text-gray-700 mb-1">
                      4(b) Deductions ($)
                    </label>
                    <Input
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
                    <label className="block text-sm font-medium text-gray-700 mb-1">
                      4(c) Extra Withholding ($)
                    </label>
                    <Input
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

              {/* Retirement Contributions */}
              <div className="mt-6 pt-4 border-t border-gray-200">
                <h4 className="text-sm font-semibold text-gray-800 mb-2">Retirement Contributions</h4>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1">
                      Pre-Tax 401(k) (%)
                    </label>
                    <NumericInput
                      value={form.retirement_rate * 100}
                      onValueChange={(value) => handleChange('retirement_rate', (value ?? 0) / 100)}
                      min={0}
                      max={100}
                      fixedDecimalsOnBlur={2}
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1">
                      Roth 401(k) (%)
                    </label>
                    <NumericInput
                      value={form.roth_retirement_rate * 100}
                      onValueChange={(value) => handleChange('roth_retirement_rate', (value ?? 0) / 100)}
                      min={0}
                      max={100}
                      fixedDecimalsOnBlur={2}
                    />
                  </div>
                </div>
              </div>
            </CardContent>
          </Card>
        )}

        {/* Address */}
        <Card className="mb-6">
          <CardHeader>
            <CardTitle>Address</CardTitle>
            <CardDescription>
              Required for payroll checks and W-2/1099 filing. Address line 2 remains optional.
            </CardDescription>
          </CardHeader>
          <CardContent>
            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Address Line 1 <span className="text-danger-600">*</span>
                </label>
                <Input
                  name="address_line1"
                  required
                  value={form.address_line1 || ''}
                  onChange={(e) => handleChange('address_line1', e.target.value)}
                  placeholder="Street address"
                  error={getFieldError('address_line1')}
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Address Line 2
                </label>
                <Input
                  value={form.address_line2 || ''}
                  onChange={(e) => handleChange('address_line2', e.target.value)}
                  placeholder="Apt, suite, etc."
                />
              </div>
              <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
                <div className="col-span-2">
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    City <span className="text-danger-600">*</span>
                  </label>
                  <Input
                    name="city"
                    required
                    value={form.city || ''}
                    onChange={(e) => handleChange('city', e.target.value)}
                    error={getFieldError('city')}
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    State <span className="text-danger-600">*</span>
                  </label>
                  <Input
                    name="state"
                    required
                    value={form.state || ''}
                    onChange={(e) => handleChange('state', e.target.value)}
                    maxLength={2}
                    placeholder="GU"
                    error={getFieldError('state')}
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    ZIP Code <span className="text-danger-600">*</span>
                  </label>
                  <Input
                    name="zip"
                    required
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

        {isEditing && employeeStatus !== 'terminated' && !isClient && (
          <div className="flex justify-start">
            <Button
              type="button"
              variant="danger"
              onClick={handleDelete}
              disabled={isDeleting}
            >
              <Trash2 className="mr-2 h-4 w-4" />
              {isDeleting ? 'Terminating...' : `Terminate ${form.employment_type === 'contractor' ? 'Contractor' : 'Employee'}`}
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
            <Button type="button" variant="outline" className="h-11 w-full sm:w-auto" onClick={() => navigate('/employees')} disabled={isSaving}>
              Cancel
            </Button>
            <Button type="submit" form="employee-form" className="h-11 w-full sm:w-auto" disabled={isSaving}>
              <Save className="mr-2 h-4 w-4" />
              {isSaving ? 'Saving...' : isEditing ? `Update ${form.employment_type === 'contractor' ? 'Contractor' : 'Employee'}` : `Create ${form.employment_type === 'contractor' ? 'Contractor' : 'Employee'}`}
            </Button>
          </div>
        </div>
      </div>

      {isEditing && id && (
        <div className="px-6 pb-8 lg:px-8">
          <Card className="max-w-4xl border-neutral-200/80 bg-white/95">
            <CardHeader>
              <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
                <div className="flex gap-3">
                  <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-primary-50 text-primary-700 ring-1 ring-primary-100">
                    <FileText className="h-5 w-5" />
                  </div>
                  <div>
                    <CardTitle>Employee Documents</CardTitle>
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
          onOpenChange={setClassificationTransitionOpen}
          onTransitioned={(newEmployee) => {
            setLoadedEmployee(newEmployee);
            navigate(`/employees/${newEmployee.id}`, { replace: true });
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
