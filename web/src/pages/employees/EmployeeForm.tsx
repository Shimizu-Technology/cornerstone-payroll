import { useState, useEffect, useCallback } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, Save, Trash2, AlertCircle, Plus, X, RotateCcw } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card, CardHeader, CardTitle, CardContent, CardDescription } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { NumericInput } from '@/components/ui/numeric-input';
import { Select } from '@/components/ui/select';
import { employeesApi, departmentsApi, employeeWageRatesApi, clientEmployeesApi, clientDepartmentsApi, employeePayrollFieldsApi, payrollFieldsApi, ApiError } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';
import type { Department, EmployeeFormData, FilingStatus, EmploymentType, PayFrequency, ContractorType, ContractorPayType, EmployeeWageRate, PayrollAdjustmentTreatment, EmployeePayrollField, PayrollFieldDefinition } from '@/types';

const initialFormData: EmployeeFormData = {
  first_name: '',
  middle_name: '',
  last_name: '',
  ssn: '',
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

const toCurrencyDraft = (value: number | null | undefined): string =>
  String(roundCurrencyValue(Number(value) || 0));

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
  const { user, isClient } = useAuth();
  // Use company_id from auth context, fall back to env var for dev mode
  const DEV_COMPANY_ID = parseInt(import.meta.env.VITE_COMPANY_ID || '1', 10);
  const companyId = user?.company_id ?? DEV_COMPANY_ID;

  const [form, setForm] = useState<EmployeeFormData>(initialFormData);
  const [departments, setDepartments] = useState<Department[]>([]);
  const [payrollFields, setPayrollFields] = useState<PayrollFieldDefinition[]>([]);
  const [employeePayrollFields, setEmployeePayrollFields] = useState<EmployeePayrollFieldFormRow[]>([]);
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
      
      const nextForm = {
        first_name: employee.first_name,
        middle_name: employee.middle_name || '',
        last_name: employee.last_name,
        ssn: employee.ssn || '',
        date_of_birth: employee.date_of_birth || '',
        hire_date: employee.hire_date,
        employment_type: employee.employment_type,
        salary_type: employee.salary_type || 'annual',
        pay_rate: toNumberOrZero(employee.pay_rate),
        pay_frequency: employee.pay_frequency,
        filing_status: employee.filing_status,
        allowances: toNumberOrZero(employee.allowances),
        additional_withholding: toNumberOrZero(employee.additional_withholding),
        w4_dependent_credit: toNumberOrZero(employee.w4_dependent_credit),
        w4_step2_multiple_jobs: toBoolean(employee.w4_step2_multiple_jobs),
        w4_step4a_other_income: toNumberOrZero(employee.w4_step4a_other_income),
        w4_step4b_deductions: toNumberOrZero(employee.w4_step4b_deductions),
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

  const handleChange = (field: keyof EmployeeFormData, value: string | number | boolean): void => {
    setForm((prev) => ({ ...prev, [field]: value }));
    if (errors[field]) {
      setErrors((prev) => {
        const newErrors = { ...prev };
        delete newErrors[field];
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

  const addDefaultPayrollAdjustment = () => {
    setDefaultPayrollAdjustments((prev) => [
      ...prev,
      { temp_id: crypto.randomUUID(), label: '', amount: 0, treatment: 'post_tax_deduction', notes: '', active: true },
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

  const addEmployeePayrollField = () => {
    const availableField = payrollFields.find((field) => !employeePayrollFields.some((row) => row.payroll_field_definition_id === field.id));
    setEmployeePayrollFields((prev) => [
      ...prev,
      {
        temp_id: crypto.randomUUID(),
        payroll_field_definition_id: availableField?.id || '',
        amount: 0,
        percentage: 0,
        active: true,
        notes: '',
        dirty: true,
      },
    ]);
  };

  const updateEmployeePayrollField = (tempId: string, patch: Partial<EmployeePayrollFieldFormRow>) => {
    setEmployeePayrollFields((prev) => prev.map((row) => row.temp_id === tempId ? { ...row, ...patch, dirty: true } : row));
  };

  const removeEmployeePayrollField = (tempId: string) => {
    setEmployeePayrollFields((prev) => prev.map((row) => row.temp_id === tempId ? { ...row, active: false, dirty: true } : row));
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

  const validateForm = (): boolean => {
    const newErrors: FormErrors = {};

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
    if (form.ssn && !/^\d{3}-\d{2}-\d{4}$/.test(form.ssn)) {
      newErrors.ssn = ['SSN must be in format XXX-XX-XXXX'];
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
    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
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
        for (const row of employeePayrollFields) {
          if (!row.payroll_field_definition_id || (row.id && !row.dirty)) continue;
          const field = payrollFields.find((candidate) => candidate.id === row.payroll_field_definition_id);
          const payload = {
            payroll_field_definition_id: row.payroll_field_definition_id,
            amount: field?.amount_type === 'fixed' ? roundCurrencyValue(Number(row.amount) || 0) : null,
            percentage: field?.amount_type === 'percentage' ? Number(row.percentage) || 0 : null,
            active: row.active !== false,
            notes: row.notes.trim(),
          };

          if (row.id) {
            await employeePayrollFieldsApi.update(savedEmployeeId, row.id, payload);
          } else if (row.active !== false) {
            await employeePayrollFieldsApi.create(savedEmployeeId, payload);
          }
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

  if (isLoading) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-600" />
      </div>
    );
  }

  return (
    <div>
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

      <form onSubmit={handleSubmit} className="p-6 lg:p-8 max-w-4xl">
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
                  value={form.last_name}
                  onChange={(e) => handleChange('last_name', e.target.value)}
                  error={getFieldError('last_name')}
                />
              </div>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  {form.employment_type === 'contractor' ? 'SSN / TIN' : 'Social Security Number'}
                </label>
                <Input
                  placeholder="XXX-XX-XXXX"
                  value={form.ssn || ''}
                  onChange={(e) => handleChange('ssn', formatSSN(e.target.value))}
                  error={getFieldError('ssn')}
                />
              </div>
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
                  Hire Date
                </label>
                <Input
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
                  value={form.employment_type}
                  onChange={(e) => handleChange('employment_type', e.target.value as EmploymentType)}
                >
                  <option value="hourly">Hourly</option>
                  <option value="salary">Salary</option>
                  <option value="contractor">1099 Contractor</option>
                </Select>
              </div>
              {form.employment_type === 'salary' && (
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    Salary Type
                  </label>
                  <Select
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
                  Pay Frequency
                </label>
                <Select
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
                          Rate Label
                        </label>
                        <Input
                          value={rate.label}
                          onChange={(e) => updateWageRate(rate.temp_id, { label: e.target.value })}
                          placeholder={index === 0 ? 'Flight Time' : 'Office Time'}
                        />
                      </div>
                      <div>
                        <label className="block text-xs font-medium text-gray-600 mb-1">
                          Hourly Rate
                        </label>
                        <NumericInput
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
              <CardTitle>Assigned Payroll Fields</CardTitle>
              <CardDescription>
                Use reusable client-wide fields for loans, 401(k), insurance, rent, reimbursements, and employer contributions.
                These defaults snapshot into payroll runs and can be reviewed before finalizing.
              </CardDescription>
            </CardHeader>
            <CardContent>
              {payrollFields.length === 0 ? (
                <div className="rounded-lg border border-blue-100 bg-white px-4 py-3 text-sm text-blue-800">
                  No company payroll fields exist yet. Create them from Payroll Fields, then assign them here.
                </div>
              ) : (
                <div className="space-y-3">
                  {employeePayrollFields.filter((row) => row.active !== false).map((row) => {
                    const selectedField = payrollFields.find((field) => field.id === row.payroll_field_definition_id);
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
                              {payrollFields.map((field) => (
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
              <Button type="button" variant="outline" size="sm" className="mt-3" onClick={addEmployeePayrollField} disabled={payrollFields.length === 0}>
                <Plus className="mr-1 h-4 w-4" />
                Assign Payroll Field
              </Button>
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
            <div className="mb-4 grid gap-3 md:grid-cols-2 xl:grid-cols-5">
              {adjustmentTreatmentOptions.map((option) => (
                <div key={option.value} className="rounded-xl border border-slate-200 bg-white p-3 shadow-sm">
                  <div className="text-sm font-semibold text-slate-900">{option.label}</div>
                  <p className="mt-1 text-xs leading-5 text-slate-600">{option.helper}</p>
                  {option.caution && <p className="mt-2 text-xs font-medium text-amber-700">{option.caution}</p>}
                </div>
              ))}
            </div>

            {getFieldError('default_payroll_adjustments') && (
              <div className="mb-3 rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                {getFieldError('default_payroll_adjustments')}
              </div>
            )}

            <div className="space-y-3">
              {defaultPayrollAdjustments.map((adjustment) => {
                const treatment = adjustmentTreatmentCopy(adjustment.treatment);
                return (
                  <div key={adjustment.temp_id} className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
                    <div className="grid grid-cols-1 items-end gap-3 lg:grid-cols-[minmax(0,1fr)_11rem_17rem_auto]">
                      <div>
                        <label className="mb-1 block text-xs font-medium text-gray-600">Label</label>
                        <Input
                          value={adjustment.label}
                          onChange={(event) => updateDefaultPayrollAdjustment(adjustment.temp_id, { label: event.target.value })}
                          placeholder="Adjustment label"
                        />
                      </div>
                      <div>
                        <label className="mb-1 block text-xs font-medium text-gray-600">Amount</label>
                        <NumericInput
                          value={adjustment.amount}
                          onValueChange={(value) => updateDefaultPayrollAdjustment(adjustment.temp_id, { amount: value ?? 0 })}
                          min={0}
                          fixedDecimalsOnBlur={2}
                        />
                      </div>
                      <div>
                        <label className="mb-1 block text-xs font-medium text-gray-600">What should this do?</label>
                        <Select
                          value={adjustment.treatment}
                          onChange={(event) => updateDefaultPayrollAdjustment(adjustment.temp_id, { treatment: event.target.value as PayrollAdjustmentTreatment })}
                        >
                          {adjustmentTreatmentOptions.map((option) => (
                            <option key={option.value} value={option.value}>{option.label}</option>
                          ))}
                        </Select>
                      </div>
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        onClick={() => removeDefaultPayrollAdjustment(adjustment.temp_id)}
                      >
                        <X className="h-4 w-4" />
                      </Button>
                    </div>
                    <p className="mt-2 text-xs leading-5 text-slate-600">
                      {treatment.helper} {treatment.caution && <span className="font-medium text-amber-700">{treatment.caution}</span>}
                    </p>
                    <div className="mt-3">
                      <label className="mb-1 block text-xs font-medium text-gray-600">Source / notes</label>
                      <Input
                        value={adjustment.notes}
                        onChange={(event) => updateDefaultPayrollAdjustment(adjustment.temp_id, { notes: event.target.value })}
                        placeholder="Per accountant or client recurring setup"
                      />
                    </div>
                  </div>
                );
              })}
            </div>

            <Button type="button" variant="outline" size="sm" className="mt-3" onClick={addDefaultPayrollAdjustment}>
              <Plus className="mr-1 h-4 w-4" />
              Add Recurring Adjustment
            </Button>
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
                    Contractor Type
                  </label>
                  <Select
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
                      Business Name
                    </label>
                    <Input
                      value={form.business_name || ''}
                      onChange={(e) => handleChange('business_name', e.target.value)}
                      placeholder="DBA or legal entity name"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1">
                      EIN (Employer Identification Number)
                    </label>
                    <Input
                      value={form.contractor_ein || ''}
                      onChange={(e) => handleChange('contractor_ein', formatEIN(e.target.value))}
                      placeholder="XX-XXXXXXX"
                    />
                  </div>
                </div>
              )}

              <div className="mt-4 p-3 bg-amber-50 border border-amber-200 rounded-lg">
                <p className="text-sm text-amber-800">
                  1099 contractors are not subject to income tax withholding, Social Security, or Medicare taxes.
                  A 1099-NEC will be generated at year-end for total compensation of $600 or more.
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
                <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1">
                      Filing Status
                    </label>
                    <Select
                      value={form.filing_status}
                      onChange={(e) => handleChange('filing_status', e.target.value as FilingStatus)}
                    >
                      <option value="single">Single or Married Filing Separately</option>
                      <option value="married">Married Filing Jointly</option>
                      <option value="head_of_household">Head of Household</option>
                    </Select>
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
            {form.employment_type !== 'contractor' && (
              <CardDescription>Mailing address is recommended for W-2 employees and needed before check printing or SWICA/W-2 filing, but it will not block saving an employee record.</CardDescription>
            )}
          </CardHeader>
          <CardContent>
            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Address Line 1 {form.employment_type !== 'contractor' ? <span className="text-xs font-normal text-amber-700">Recommended</span> : ''}
                </label>
                <Input
                  value={form.address_line1 || ''}
                  onChange={(e) => handleChange('address_line1', e.target.value)}
                  placeholder="Street address"
                />
                {errors.address_line1 && <p className="mt-1 text-sm text-red-600">{errors.address_line1[0]}</p>}
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
                    City {form.employment_type !== 'contractor' ? <span className="text-xs font-normal text-amber-700">Recommended</span> : ''}
                  </label>
                  <Input
                    value={form.city || ''}
                    onChange={(e) => handleChange('city', e.target.value)}
                  />
                  {errors.city && <p className="mt-1 text-sm text-red-600">{errors.city[0]}</p>}
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    State {form.employment_type !== 'contractor' ? <span className="text-xs font-normal text-amber-700">Recommended</span> : ''}
                  </label>
                  <Input
                    value={form.state || ''}
                    onChange={(e) => handleChange('state', e.target.value)}
                    maxLength={2}
                    placeholder="GU"
                  />
                  {errors.state && <p className="mt-1 text-sm text-red-600">{errors.state[0]}</p>}
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    ZIP Code {form.employment_type !== 'contractor' ? <span className="text-xs font-normal text-amber-700">Recommended</span> : ''}
                  </label>
                  <Input
                    value={form.zip || ''}
                    onChange={(e) => handleChange('zip', e.target.value)}
                    placeholder="96910"
                  />
                  {errors.zip && <p className="mt-1 text-sm text-red-600">{errors.zip[0]}</p>}
                </div>
              </div>
            </div>
          </CardContent>
        </Card>

        {/* Actions */}
        <div className="flex items-center justify-between">
          <div>
            {isEditing && employeeStatus !== 'terminated' && !isClient && (
              <Button
                type="button"
                variant="danger"
                onClick={handleDelete}
                disabled={isDeleting}
              >
                <Trash2 className="w-4 h-4 mr-2" />
                {isDeleting ? 'Terminating...' : `Terminate ${form.employment_type === 'contractor' ? 'Contractor' : 'Employee'}`}
              </Button>
            )}
          </div>
          <div className="flex gap-3">
            <Button
              type="button"
              variant="outline"
              onClick={() => navigate('/employees')}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={isSaving}>
              <Save className="w-4 h-4 mr-2" />
              {isSaving ? 'Saving...' : isEditing ? `Update ${form.employment_type === 'contractor' ? 'Contractor' : 'Employee'}` : `Create ${form.employment_type === 'contractor' ? 'Contractor' : 'Employee'}`}
            </Button>
          </div>
        </div>
      </form>
    </div>
  );
}
