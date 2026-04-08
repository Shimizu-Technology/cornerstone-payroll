import { useState, useEffect, useCallback } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, Save, Trash2, AlertCircle, Plus, X, RotateCcw } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card, CardHeader, CardTitle, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { employeesApi, departmentsApi, employeeWageRatesApi, ApiError } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';
import type { Department, EmployeeFormData, FilingStatus, EmploymentType, PayFrequency, ContractorType, ContractorPayType, EmployeeWageRate } from '@/types';

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
};

interface FormErrors {
  [key: string]: string[];
}

interface WageRateFormRow extends EmployeeWageRate {
  temp_id: string;
}

const defaultHourlyWageRate = (): WageRateFormRow => ({
  temp_id: crypto.randomUUID(),
  label: 'Regular',
  rate: 0,
  is_primary: true,
  active: true,
});

export function EmployeeForm() {
  const navigate = useNavigate();
  const { id } = useParams<{ id: string }>();
  const isEditing = Boolean(id);
  const { user } = useAuth();
  // Use company_id from auth context, fall back to env var for dev mode
  const DEV_COMPANY_ID = parseInt(import.meta.env.VITE_COMPANY_ID || '1', 10);
  const companyId = user?.company_id ?? DEV_COMPANY_ID;

  const [form, setForm] = useState<EmployeeFormData>(initialFormData);
  const [departments, setDepartments] = useState<Department[]>([]);
  const [wageRates, setWageRates] = useState<WageRateFormRow[]>([defaultHourlyWageRate()]);
  const [ssnLastFour, setSsnLastFour] = useState<string | null>(null);
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
      const response = await employeesApi.get(parseInt(id, 10));
      const employee = response.data;
      
      setForm({
        first_name: employee.first_name,
        middle_name: employee.middle_name || '',
        last_name: employee.last_name,
        date_of_birth: employee.date_of_birth || '',
        hire_date: employee.hire_date,
        employment_type: employee.employment_type,
        salary_type: employee.salary_type || 'annual',
        pay_rate: employee.pay_rate,
        pay_frequency: employee.pay_frequency,
        filing_status: employee.filing_status,
        allowances: employee.allowances,
        additional_withholding: employee.additional_withholding,
        w4_dependent_credit: employee.w4_dependent_credit || 0,
        w4_step2_multiple_jobs: employee.w4_step2_multiple_jobs || false,
        w4_step4a_other_income: employee.w4_step4a_other_income || 0,
        w4_step4b_deductions: employee.w4_step4b_deductions || 0,
        retirement_rate: employee.retirement_rate,
        roth_retirement_rate: employee.roth_retirement_rate,
        department_id: employee.department_id,
        business_name: employee.business_name || '',
        contractor_ein: employee.contractor_ein || '',
        contractor_type: employee.contractor_type || 'individual',
        contractor_pay_type: employee.contractor_pay_type || 'flat_fee',
        w9_on_file: employee.w9_on_file || false,
        address_line1: employee.address_line1 || '',
        address_line2: employee.address_line2 || '',
        city: employee.city || '',
        state: employee.state || '',
        zip: employee.zip || '',
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
      
      setEmployeeStatus(employee.status || 'active');
      setTerminationDate(employee.termination_date || null);

      if (employee.ssn_last_four) {
        setSsnLastFour(employee.ssn_last_four);
      }
    } catch (err) {
      setGeneralError(err instanceof Error ? err.message : 'Failed to load employee');
    } finally {
      setIsLoading(false);
    }
  }, [id]);

  const fetchDepartments = useCallback(async () => {
    try {
      const response = await departmentsApi.list({ company_id: companyId, active: true });
      setDepartments(response.data);
    } catch (err) {
      console.error('Failed to load departments:', err);
    }
  }, [companyId]);

  useEffect(() => {
    fetchDepartments();
    if (isEditing) {
      fetchEmployee();
    }
  }, [fetchDepartments, fetchEmployee, isEditing]);

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
      setForm((prev) => ({ ...prev, pay_rate: Number(primaryRate.rate) || 0 }));
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

  const normalizeWageRates = (): WageRateFormRow[] => {
    const activeRates = wageRates
      .map((rate) => ({
        ...rate,
        label: rate.label.trim(),
        rate: Number(rate.rate) || 0,
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
      const employeePayload = {
        ...form,
        pay_rate: supportsMultipleHourlyRates
          ? (primaryRate ? Number(primaryRate.rate) || 0 : form.pay_rate)
          : form.pay_rate,
      };

      let savedEmployeeId: number;
      if (isEditing && id) {
        // Don't send SSN if it's empty (user didn't update it)
        const updateData = { ...employeePayload };
        if (!updateData.ssn) {
          delete updateData.ssn;
        }
        const response = await employeesApi.update(parseInt(id, 10), updateData);
        savedEmployeeId = response.data.id;
      } else {
        const response = await employeesApi.create({ ...employeePayload, company_id: companyId });
        savedEmployeeId = response.data.id;
      }

      if (supportsMultipleHourlyRates) {
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
            rate: Number(rate.rate) || 0,
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

      navigate('/employees');
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

      {isEditing && employeeStatus === 'terminated' && (
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
                  placeholder={isEditing && ssnLastFour ? 'Enter new SSN to update' : 'XXX-XX-XXXX'}
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
                  <Input
                    type="number"
                    step="0.01"
                    min="0"
                    value={form.pay_rate}
                    onChange={(e) => handleChange('pay_rate', parseFloat(e.target.value) || 0)}
                    error={getFieldError('pay_rate')}
                  />
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
                        <Input
                          type="number"
                          step="0.01"
                          min="0"
                          value={rate.rate}
                          onChange={(e) => updateWageRate(rate.temp_id, { rate: parseFloat(e.target.value) || 0 })}
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
                    onChange={(e) => handleChange('w4_step2_multiple_jobs', e.target.checked ? 1 : 0)}
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
                      type="number"
                      step="0.01"
                      min="0"
                      value={form.w4_dependent_credit}
                      onChange={(e) => handleChange('w4_dependent_credit', parseFloat(e.target.value) || 0)}
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
                      type="number"
                      step="0.01"
                      min="0"
                      value={form.w4_step4a_other_income}
                      onChange={(e) => handleChange('w4_step4a_other_income', parseFloat(e.target.value) || 0)}
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
                      type="number"
                      step="0.01"
                      min="0"
                      value={form.w4_step4b_deductions}
                      onChange={(e) => handleChange('w4_step4b_deductions', parseFloat(e.target.value) || 0)}
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
                      type="number"
                      step="0.01"
                      min="0"
                      value={form.additional_withholding}
                      onChange={(e) => handleChange('additional_withholding', parseFloat(e.target.value) || 0)}
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
                    <Input
                      type="number"
                      step="0.01"
                      min="0"
                      max="100"
                      value={(form.retirement_rate * 100).toFixed(2)}
                      onChange={(e) => handleChange('retirement_rate', (parseFloat(e.target.value) || 0) / 100)}
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 mb-1">
                      Roth 401(k) (%)
                    </label>
                    <Input
                      type="number"
                      step="0.01"
                      min="0"
                      max="100"
                      value={(form.roth_retirement_rate * 100).toFixed(2)}
                      onChange={(e) => handleChange('roth_retirement_rate', (parseFloat(e.target.value) || 0) / 100)}
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
          </CardHeader>
          <CardContent>
            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Address Line 1
                </label>
                <Input
                  value={form.address_line1 || ''}
                  onChange={(e) => handleChange('address_line1', e.target.value)}
                  placeholder="Street address"
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
                    City
                  </label>
                  <Input
                    value={form.city || ''}
                    onChange={(e) => handleChange('city', e.target.value)}
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    State
                  </label>
                  <Input
                    value={form.state || ''}
                    onChange={(e) => handleChange('state', e.target.value)}
                    maxLength={2}
                    placeholder="GU"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-1">
                    ZIP Code
                  </label>
                  <Input
                    value={form.zip || ''}
                    onChange={(e) => handleChange('zip', e.target.value)}
                    placeholder="96910"
                  />
                </div>
              </div>
            </div>
          </CardContent>
        </Card>

        {/* Actions */}
        <div className="flex items-center justify-between">
          <div>
            {isEditing && employeeStatus !== 'terminated' && (
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
