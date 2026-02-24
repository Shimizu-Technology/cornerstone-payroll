import { useState, useEffect, useCallback } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft, Save, Trash2, AlertCircle } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card, CardHeader, CardTitle, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { employeesApi, departmentsApi, ApiError } from '@/services/api';
import { useAuth } from '@/contexts/AuthContext';
import type { Department, EmployeeFormData, FilingStatus, EmploymentType, PayFrequency } from '@/types';

const initialFormData: EmployeeFormData = {
  first_name: '',
  middle_name: '',
  last_name: '',
  ssn: '',
  date_of_birth: '',
  hire_date: '',
  employment_type: 'hourly',
  pay_rate: 0,
  pay_frequency: 'biweekly',
  filing_status: 'single',
  allowances: 0,
  additional_withholding: 0,
  retirement_rate: 0,
  roth_retirement_rate: 0,
  department_id: undefined,
  address_line1: '',
  address_line2: '',
  city: '',
  state: '',
  zip: '',
};

interface FormErrors {
  [key: string]: string[];
}

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
  const [ssnLastFour, setSsnLastFour] = useState<string | null>(null);
  const [errors, setErrors] = useState<FormErrors>({});
  const [generalError, setGeneralError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);

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
        pay_rate: employee.pay_rate,
        pay_frequency: employee.pay_frequency,
        filing_status: employee.filing_status,
        allowances: employee.allowances,
        additional_withholding: employee.additional_withholding,
        retirement_rate: employee.retirement_rate,
        roth_retirement_rate: employee.roth_retirement_rate,
        department_id: employee.department_id,
        address_line1: employee.address_line1 || '',
        address_line2: employee.address_line2 || '',
        city: employee.city || '',
        state: employee.state || '',
        zip: employee.zip || '',
      });
      
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

  const handleChange = (field: keyof EmployeeFormData, value: string | number): void => {
    setForm((prev) => ({ ...prev, [field]: value }));
    // Clear field error when user starts typing
    if (errors[field]) {
      setErrors((prev) => {
        const newErrors = { ...prev };
        delete newErrors[field];
        return newErrors;
      });
    }
  };

  const validateForm = (): boolean => {
    const newErrors: FormErrors = {};

    if (!form.first_name.trim()) {
      newErrors.first_name = ['First name is required'];
    }
    if (!form.last_name.trim()) {
      newErrors.last_name = ['Last name is required'];
    }
    if (!form.hire_date) {
      newErrors.hire_date = ['Hire date is required'];
    }
    if (form.pay_rate <= 0) {
      newErrors.pay_rate = ['Pay rate must be greater than 0'];
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
    if (((form.retirement_rate || 0) + (form.roth_retirement_rate || 0)) > 1) {
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
      if (isEditing && id) {
        // Don't send SSN if it's empty (user didn't update it)
        const updateData = { ...form };
        if (!updateData.ssn) {
          delete updateData.ssn;
        }
        await employeesApi.update(parseInt(id, 10), updateData);
      } else {
        await employeesApi.create({ ...form, company_id: companyId });
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
    if (!id || !confirm('Are you sure you want to terminate this employee? This action will mark them as terminated.')) {
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
        title={isEditing ? 'Edit Employee' : 'Add Employee'}
        description={isEditing ? 'Update employee information' : 'Add a new employee to your company'}
        actions={
          <Button variant="outline" onClick={() => navigate('/employees')}>
            <ArrowLeft className="w-4 h-4 mr-2" />
            Back
          </Button>
        }
      />

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
                  Social Security Number {!isEditing && <span className="text-danger-600">*</span>}
                </label>
                {isEditing && ssnLastFour ? (
                  <div className="space-y-2">
                    <p className="text-sm text-gray-500">Current: ***-**-{ssnLastFour}</p>
                    <Input
                      placeholder="Enter new SSN to update (XXX-XX-XXXX)"
                      value={form.ssn || ''}
                      onChange={(e) => handleChange('ssn', e.target.value)}
                      error={getFieldError('ssn')}
                    />
                  </div>
                ) : (
                  <Input
                    placeholder="XXX-XX-XXXX"
                    value={form.ssn || ''}
                    onChange={(e) => handleChange('ssn', e.target.value)}
                    error={getFieldError('ssn')}
                  />
                )}
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
                  Hire Date <span className="text-danger-600">*</span>
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

            <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mt-4">
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
                </Select>
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Pay Rate <span className="text-danger-600">*</span>
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
                  {form.employment_type === 'hourly' ? 'Per hour' : 'Annual salary'}
                </p>
              </div>
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
          </CardContent>
        </Card>

        {/* Tax Information */}
        <Card className="mb-6">
          <CardHeader>
            <CardTitle>Tax Information</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Filing Status
                </label>
                <Select
                  value={form.filing_status}
                  onChange={(e) => handleChange('filing_status', e.target.value as FilingStatus)}
                >
                  <option value="single">Single</option>
                  <option value="married">Married Filing Jointly</option>
                  <option value="married_separate">Married Filing Separately</option>
                  <option value="head_of_household">Head of Household</option>
                </Select>
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Allowances
                </label>
                <Input
                  type="number"
                  min="0"
                  value={form.allowances}
                  onChange={(e) => handleChange('allowances', parseInt(e.target.value, 10) || 0)}
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Additional Withholding
                </label>
                <Input
                  type="number"
                  step="0.01"
                  min="0"
                  value={form.additional_withholding}
                  onChange={(e) => handleChange('additional_withholding', parseFloat(e.target.value) || 0)}
                />
              </div>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Retirement Contribution (%)
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
                  Roth Retirement Contribution (%)
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
          </CardContent>
        </Card>

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
            {isEditing && (
              <Button
                type="button"
                variant="danger"
                onClick={handleDelete}
                disabled={isDeleting}
              >
                <Trash2 className="w-4 h-4 mr-2" />
                {isDeleting ? 'Terminating...' : 'Terminate Employee'}
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
              {isSaving ? 'Saving...' : isEditing ? 'Update Employee' : 'Create Employee'}
            </Button>
          </div>
        </div>
      </form>
    </div>
  );
}
