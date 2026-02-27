// ========================================
// Cornerstone Payroll TypeScript Types
// Based on PRD.md schema definitions
// ========================================

// ----------------
// Company & Organization
// ----------------

export interface Company {
  id: number;
  name: string;
  address_line1: string;
  address_line2?: string;
  city: string;
  state: string;
  zip: string;
  phone?: string;
  created_at: string;
  updated_at: string;
}

export interface Department {
  id: number;
  company_id: number;
  name: string;
  active: boolean;
  created_at: string;
  updated_at: string;
}

// ----------------
// User & Auth
// ----------------

export type UserRole = 'admin' | 'manager' | 'employee';

export interface User {
  id: number;
  workos_id?: string;
  email: string;
  name: string;
  role: UserRole;
  company_id?: number;
  active?: boolean;
  last_login_at?: string | null;
  created_at: string;
  updated_at: string;
}

// ----------------
// Employee
// ----------------

export type EmploymentType = 'hourly' | 'salary';
export type PayFrequency = 'weekly' | 'biweekly' | 'semimonthly' | 'monthly';
export type FilingStatus = 'single' | 'married' | 'married_separate' | 'head_of_household';
export type EmployeeStatus = 'active' | 'inactive' | 'terminated';

export interface Employee {
  id: number;
  company_id: number;
  department_id?: number;
  user_id?: number;
  first_name: string;
  middle_name?: string;
  last_name: string;
  email?: string;
  // SSN is never sent to frontend for security
  date_of_birth?: string;
  hire_date: string;
  termination_date?: string;
  employment_type: EmploymentType;
  pay_rate: number; // hourly rate or annual salary
  pay_frequency: PayFrequency;
  filing_status: FilingStatus;
  allowances: number;
  additional_withholding: number;
  retirement_rate: number; // percentage as decimal (0.04 = 4%)
  roth_retirement_rate: number;
  status: EmployeeStatus;
  address_line1?: string;
  address_line2?: string;
  city?: string;
  state?: string;
  zip?: string;
  created_at: string;
  updated_at: string;
}

export interface EmployeeFormData {
  first_name: string;
  middle_name?: string;
  last_name: string;
  email?: string;
  ssn?: string; // Only for create/update, never returned
  date_of_birth?: string;
  hire_date: string;
  employment_type: EmploymentType;
  pay_rate: number;
  pay_frequency: PayFrequency;
  filing_status: FilingStatus;
  allowances: number;
  additional_withholding: number;
  retirement_rate: number;
  roth_retirement_rate: number;
  department_id?: number;
  address_line1?: string;
  address_line2?: string;
  city?: string;
  state?: string;
  zip?: string;
}

// ----------------
// Pay Period
// ----------------

export type PayPeriodStatus = 'draft' | 'calculated' | 'approved' | 'committed';
export type TaxSyncStatus = 'pending' | 'syncing' | 'synced' | 'failed';

export interface PayPeriod {
  id: number;
  company_id?: number;
  start_date: string;
  end_date: string;
  pay_date: string;
  status: PayPeriodStatus;
  notes?: string;
  period_description?: string;
  created_by_id?: number;
  approved_by_id?: number;
  committed_at?: string;
  created_at?: string;
  updated_at?: string;
  // Tax sync fields (CPR-53)
  tax_sync_status?: TaxSyncStatus | null;
  tax_sync_attempts?: number;
  tax_sync_last_error?: string | null;
  tax_synced_at?: string | null;
  // Computed/included
  employee_count?: number;
  payroll_items_count?: number;
  total_gross?: number;
  total_net?: number;
  // Nested payroll items (when requested)
  payroll_items?: PayrollItem[];
}

// ----------------
// Payroll Item (one per employee per pay period)
// ----------------

export interface PayrollItem {
  id: number;
  pay_period_id?: number;
  employee_id: number;
  employee_name?: string;
  employment_type: EmploymentType;
  pay_rate: number;
  // Hours (for hourly employees)
  hours_worked?: number;
  overtime_hours?: number;
  holiday_hours?: number;
  pto_hours?: number;
  total_hours?: number;
  // Additional earnings
  reported_tips?: number;
  bonus?: number;
  // Calculated pay
  gross_pay?: number;
  net_pay?: number;
  employer_social_security_tax?: number;
  employer_medicare_tax?: number;
  // Tax withholdings
  withholding_tax?: number; // Guam Territorial Income Tax (same as federal)
  social_security_tax?: number;
  medicare_tax?: number;
  additional_withholding?: number;
  // Deductions
  retirement_payment?: number;
  roth_retirement_payment?: number;
  loan_payment?: number;
  insurance_payment?: number;
  total_deductions?: number;
  // Custom/flexible deductions
  custom_columns_data?: Record<string, number>;
  // YTD totals (snapshot at time of calculation)
  ytd_gross?: number;
  ytd_net?: number;
  ytd_withholding_tax?: number;
  ytd_social_security_tax?: number;
  ytd_medicare_tax?: number;
  ytd_retirement?: number;
  // Check info
  check_number?: string;
  check_printed_at?: string;
  created_at?: string;
  updated_at?: string;
  // Included relations
  employee?: Employee;
}

// ----------------
// Time Entry
// ----------------

export interface TimeEntry {
  id: number;
  employee_id: number;
  pay_period_id: number;
  date: string;
  regular_hours: number;
  overtime_hours: number;
  holiday_hours: number;
  pto_hours: number;
  notes?: string;
  created_at: string;
  updated_at: string;
}

// ----------------
// Deductions
// ----------------

export type DeductionCategory = 'pre_tax' | 'post_tax';

export interface DeductionType {
  id: number;
  company_id: number;
  name: string;
  category: DeductionCategory;
  default_amount: number;
  is_percentage: boolean;
  created_at: string;
  updated_at: string;
}

export interface EmployeeDeduction {
  id: number;
  employee_id: number;
  deduction_type_id: number;
  amount: number;
  is_percentage: boolean;
  deduction_type?: DeductionType;
}

// ----------------
// Tax Tables
// ----------------

export interface TaxBracket {
  min_income: number;
  max_income: number;
  base_tax: number;
  rate: number;
  threshold: number;
}

export interface TaxTable {
  id: number;
  tax_year: number;
  filing_status: FilingStatus;
  pay_frequency: PayFrequency;
  bracket_data: TaxBracket[];
  ss_rate: number;
  ss_wage_base: number;
  medicare_rate: number;
  additional_medicare_rate: number;
  additional_medicare_threshold: number;
  created_at: string;
  updated_at: string;
}

// ----------------
// API Response Types
// ----------------

export interface PaginationMeta {
  current_page: number;
  total_pages: number;
  total_count: number;
  per_page: number;
}

export interface PaginatedResponse<T> {
  data: T[];
  meta: PaginationMeta;
}

export interface ApiError {
  error: string;
  details?: Record<string, string[]>;
}

// ----------------
// Dashboard Stats
// ----------------

export interface DashboardStats {
  total_employees: number;
  active_employees: number;
  current_pay_period?: PayPeriod;
  last_payroll_total?: number;
  ytd_payroll_total: number;
  pending_approvals: number;
}
