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

export type UserRole = 'admin' | 'manager' | 'employee' | 'accountant' | 'client';

export interface AssignedCompanySummary {
  id: number;
  name: string;
}

export interface User {
  id: number;
  workos_id?: string;
  email: string;
  name: string;
  role: UserRole;
  company_id?: number;
  active?: boolean;
  assigned_company_ids?: number[];
  assigned_companies?: AssignedCompanySummary[];
  invitation_status?: 'pending' | 'accepted';
  invitation_pending?: boolean;
  invited_at?: string | null;
  last_login_at?: string | null;
  created_at: string;
  updated_at: string;
}

// ----------------
// Employee
// ----------------

export type EmploymentType = 'hourly' | 'salary' | 'contractor';
export type PayFrequency = 'weekly' | 'biweekly' | 'semimonthly' | 'monthly';
export type FilingStatus = 'single' | 'married' | 'married_separate' | 'head_of_household';
export type EmployeeStatus = 'active' | 'inactive' | 'terminated';
export type ContractorType = 'individual' | 'business';
export type ContractorPayType = 'hourly' | 'flat_fee';

export interface EmployeeWageRate {
  id?: number;
  employee_id?: number;
  label: string;
  rate: number;
  is_primary: boolean;
  active: boolean;
  created_at?: string;
  updated_at?: string;
}

export interface CustomEarning {
  label: string;
  amount: number;
}

export interface Employee {
  id: number;
  company_id: number;
  department_id?: number;
  department?: { id: number; name: string };
  user_id?: number;
  first_name: string;
  middle_name?: string;
  last_name: string;
  email?: string;
  ssn?: string | null;
  date_of_birth?: string;
  hire_date: string;
  termination_date?: string;
  employment_type: EmploymentType;
  salary_type?: 'annual' | 'per_period' | 'variable';
  pay_rate: number;
  pay_frequency: PayFrequency;
  filing_status: FilingStatus;
  allowances: number;
  additional_withholding: number;
  w4_dependent_credit: number;
  w4_step2_multiple_jobs: boolean;
  w4_step4a_other_income: number;
  w4_step4b_deductions: number;
  retirement_rate: number;
  roth_retirement_rate: number;
  employer_retirement_match_rate?: number;
  employer_roth_match_rate?: number;
  status: EmployeeStatus;
  // Contractor-specific fields
  business_name?: string;
  contractor_ein?: string;
  contractor_type?: ContractorType;
  contractor_pay_type?: ContractorPayType;
  w9_on_file?: boolean;
  address_line1?: string;
  address_line2?: string;
  city?: string;
  state?: string;
  zip?: string;
  wage_rates?: EmployeeWageRate[];
  default_custom_earnings?: CustomEarning[];
  created_at: string;
  updated_at: string;
}

export interface EmployeeFormData {
  first_name: string;
  middle_name?: string;
  last_name: string;
  email?: string;
  ssn?: string;
  date_of_birth?: string;
  hire_date: string;
  employment_type: EmploymentType;
  salary_type?: 'annual' | 'per_period' | 'variable';
  pay_rate: number;
  pay_frequency: PayFrequency;
  filing_status: FilingStatus;
  allowances: number;
  additional_withholding: number;
  w4_dependent_credit: number;
  w4_step2_multiple_jobs: boolean;
  w4_step4a_other_income: number;
  w4_step4b_deductions: number;
  retirement_rate: number;
  roth_retirement_rate: number;
  department_id?: number;
  // Contractor-specific fields
  business_name?: string;
  contractor_ein?: string;
  contractor_type?: ContractorType;
  contractor_pay_type?: ContractorPayType;
  w9_on_file?: boolean;
  address_line1?: string;
  address_line2?: string;
  city?: string;
  state?: string;
  zip?: string;
  wage_rates?: EmployeeWageRate[];
  default_custom_earnings?: CustomEarning[];
}

// ----------------
// Pay Period
// ----------------

export type PayPeriodStatus = 'draft' | 'calculated' | 'approved' | 'committed';
export type TaxSyncStatus = 'pending' | 'syncing' | 'synced' | 'failed';

// CPR-71: Payroll correction lifecycle
export type CorrectionStatus = 'voided' | 'correction';

export interface PayPeriodCorrectionEvent {
  id: number;
  action_type: 'void_initiated' | 'correction_run_created' | 'correction_run_committed' | 'correction_run_deleted';
  pay_period_id: number;
  resulting_pay_period_id?: number | null;
  actor_id?: number | null;
  actor_name?: string | null;
  reason: string;
  financial_snapshot: {
    gross_pay?: number;
    net_pay?: number;
    employee_count?: number;
    total_withholding?: number;
    total_social_security?: number;
    total_medicare?: number;
    total_employer_ss?: number;
    total_employer_medicare?: number;
  };
  metadata?: Record<string, unknown>;
  created_at: string;
}

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
  calculated_at?: string | null;
  calculated_by_id?: number | null;
  approved_at?: string | null;
  unapproved_at?: string | null;
  unapproved_by_id?: number | null;
  committed_by_id?: number | null;
  committed_at?: string;
  processed_at?: string | null;
  processed_by_name?: string | null;
  created_at?: string;
  updated_at?: string;
  lifecycle?: {
    created?: PayPeriodLifecycleEvent;
    calculated?: PayPeriodLifecycleEvent;
    approved?: PayPeriodLifecycleEvent;
    unapproved?: PayPeriodLifecycleEvent;
    committed?: PayPeriodLifecycleEvent;
    tax_synced?: PayPeriodLifecycleEvent;
  };
  // Tax sync fields (CPR-53)
  tax_sync_status?: TaxSyncStatus | null;
  tax_sync_attempts?: number;
  tax_sync_last_error?: string | null;
  tax_synced_at?: string | null;
  // CPR-71: correction lifecycle fields
  correction_status?: CorrectionStatus | null;
  voided_at?: string | null;
  voided_by_id?: number | null;
  voided_by_name?: string | null;
  void_reason?: string | null;
  source_pay_period_id?: number | null;
  superseded_by_id?: number | null;
  can_void?: boolean;
  can_create_correction_run?: boolean;
  can_delete_draft_correction_run?: boolean;
  // Per-employee corrective paycheck (off-cycle supplemental period)
  cycle?: 'regular' | 'supplemental';
  corrects_pay_period_id?: number | null;
  can_issue_corrective_paycheck?: boolean;
  supplemental_pay_periods_count?: number;
  // Computed/included
  employee_count?: number;
  payroll_items_count?: number;
  total_gross?: number;
  total_net?: number;
  // Nested payroll items (when requested)
  payroll_items?: PayrollItem[];
}

export interface PayPeriodLifecycleEvent {
  timestamp?: string | null;
  actor_name?: string | null;
}

// ----------------
// Payroll Item (one per employee per pay period)
// ----------------

export interface PayrollItem {
  id: number;
  pay_period_id?: number;
  employee_id: number;
  employee_first_name?: string | null;
  employee_last_name?: string | null;
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
  tips_paid_out?: number;
  bonus?: number;
  salary_override?: number | null;
  non_taxable_pay?: number;
  // Calculated pay
  gross_pay?: number;
  net_pay?: number;
  employer_social_security_tax?: number;
  employer_medicare_tax?: number;
  // Tax withholdings
  withholding_tax?: number; // Guam Territorial Income Tax (same as federal)
  social_security_tax?: number;
  medicare_tax?: number;
  state_withheld?: number | null;
  additional_withholding?: number;
  additional_withholding_override?: number | null;
  withholding_tax_adjustment?: number | null;
  withholding_tax_override?: number | null;
  // Deductions
  retirement_payment?: number;
  roth_retirement_payment?: number;
  loan_payment?: number;
  insurance_payment?: number;
  total_deductions?: number;
  // Import fields (MoSa)
  tips?: number;
  loan_deduction?: number;
  tip_pool?: 'boh' | 'foh' | 'mixed' | null;
  import_source?: string | null;
  // Custom/flexible deductions
  custom_columns_data?: Record<string, number>;
  // YTD totals (snapshot at time of calculation)
  ytd_gross?: number;
  ytd_net?: number;
  ytd_withholding_tax?: number;
  ytd_social_security_tax?: number;
  ytd_medicare_tax?: number;
  ytd_retirement?: number;
  // Custom earnings (e.g., Chief Stipend, Asst Chief Stipend)
  custom_earnings?: { label: string; amount: number }[];
  department_id?: number | null;
  department_name?: string | null;
  // Check info
  // CPR-66: Check printing lifecycle
  check_number?: string | null;
  check_date?: string | null;
  check_memo?: string | null;
  check_printed_at?: string | null;
  check_print_count?: number;
  check_status?: 'unprinted' | 'printed' | 'voided' | null;
  voided?: boolean;
  voided_at?: string | null;
  void_reason?: string | null;
  reprint_of_check_number?: string | null;
  events?: CheckEvent[];
  // Per-employee corrective paycheck linkage
  correction_for_payroll_item_id?: number | null;
  correction_reason?: string | null;
  created_at?: string;
  updated_at?: string;
  // Included relations
  employee?: Employee;
  wage_rate_hours?: PayrollItemWageRateHours[];
}

// ----------------
// Corrective paycheck (off-cycle supplemental period)
// ----------------

export interface CorrectivePaycheckInputs {
  pay_rate?: number;
  hours_worked?: number;
  overtime_hours?: number;
  holiday_hours?: number;
  pto_hours?: number;
  bonus?: number;
  reported_tips?: number;
  tips_paid_out?: number;
  tip_pool?: 'boh' | 'foh' | 'mixed' | null;
  additional_withholding?: number;
  additional_withholding_override?: number | null;
  withholding_tax_adjustment?: number | null;
  custom_earnings?: { label: string; amount: number }[];
  custom_columns_data?: Record<string, number>;
  non_taxable_pay?: number;
}

export interface CorrectivePaycheckSnapshot {
  gross_pay: number;
  withholding_tax: number;
  social_security_tax: number;
  medicare_tax: number;
  employer_social_security_tax: number;
  employer_medicare_tax: number;
  additional_withholding: number;
  retirement_payment: number;
  roth_retirement_payment: number;
  employer_retirement_match: number;
  employer_roth_retirement_match: number;
  total_additions: number;
  total_deductions: number;
  net_pay: number;
  hours_worked: number;
  overtime_hours: number;
  holiday_hours: number;
  pto_hours: number;
  bonus: number;
  reported_tips: number;
  tips_paid_out: number;
  pay_rate: number;
  custom_earnings: { label: string; amount: number }[];
  custom_columns_data: Record<string, number>;
}

export interface CorrectivePaycheckPreview {
  original: CorrectivePaycheckSnapshot;
  corrected: CorrectivePaycheckSnapshot;
  deltas: Record<string, number>;
  meta: {
    original_pay_period_id: number;
    original_payroll_item_id: number;
    employee_id: number;
    employee_name: string;
    will_generate_check: boolean;
    is_zero_change: boolean;
  };
}

// ---------------------------------------------------------------------------
// Replace check (uncashed) — single-check void+reissue or in-place edit when
// the original physical check has not been distributed or has been returned.
// Distinct from CorrectivePaycheck (which cuts a separate supplemental check
// for the delta when the original is already cashed).
// ---------------------------------------------------------------------------
export interface ReplaceCheckSnapshot {
  hours_worked: number;
  overtime_hours: number;
  pay_rate: number;
  bonus: number;
  tips_paid_out: number;
  gross_pay: number;
  withholding_tax: number;
  social_security_tax: number;
  medicare_tax: number;
  net_pay: number;
}

export type ReplaceCheckMode = 'in_place' | 'void_and_reissue';

export interface ReplaceCheckPreview {
  original: ReplaceCheckSnapshot;
  corrected: ReplaceCheckSnapshot;
  mode: ReplaceCheckMode;
  meta: {
    payroll_item_id: number;
    employee_id: number;
    employee_name: string;
    will_assign_new_check_number: boolean;
    original_check_number: string | null;
    is_zero_change: boolean;
  };
}

export interface ReplaceCheckResult {
  payroll_item: {
    id: number;
    check_number: string | null;
    replaced_check_number: string | null;
    voided: boolean;
    gross_pay: number;
    net_pay: number;
    events: Array<{
      id: number;
      event_type: string;
      check_number: string;
      reason: string | null;
      created_at: string;
    }>;
  };
}

export interface SupplementalPayPeriodSummary {
  id: number;
  pay_date: string;
  committed_at: string | null;
  status: PayPeriodStatus;
  cycle: 'supplemental';
  notes: string | null;
  tax_sync_status: TaxSyncStatus | null;
  payroll_items: Array<{
    id: number;
    employee_id: number;
    employee_name: string;
    correction_for_payroll_item_id: number | null;
    correction_reason: string | null;
    gross_pay: number;
    withholding_tax: number;
    social_security_tax: number;
    medicare_tax: number;
    net_pay: number;
    check_number: string | null;
    check_status: 'unprinted' | 'printed' | 'voided' | null;
  }>;
  totals: {
    gross_delta: number;
    fit_delta: number;
    ss_delta: number;
    med_delta: number;
    net_delta: number;
  };
}

export interface PayrollItemWageRateHours {
  employee_wage_rate_id?: number;
  label: string;
  rate: number;
  regular_hours: number;
  overtime_hours: number;
  holiday_hours: number;
  pto_hours: number;
  is_primary?: boolean;
  active?: boolean;
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
// Check Printing (CPR-66)
// ----------------

export interface CheckEvent {
  id: number;
  event_type: 'printed' | 'voided' | 'reprinted' | 'batch_downloaded';
  check_number: string | null;
  reason: string | null;
  user_id: number | null;
  ip_address: string | null;
  created_at: string;
}

export interface CheckItem {
  id: number;
  pay_period_id: number;
  employee_id: number;
  employee_name: string;
  check_number: string | null;
  net_pay: number;
  gross_pay: number;
  check_status: 'unprinted' | 'printed' | 'voided' | null;
  check_printed_at: string | null;
  check_print_count: number;
  voided: boolean;
  voided_at: string | null;
  void_reason: string | null;
  reprint_of_check_number: string | null;
  events: CheckEvent[];
}

export interface CheckListMeta {
  total: number;
  printed: number;
  unprinted: number;
  voided: number;
  check_stock_type: CheckStockType;
}

export interface CheckListResponse {
  checks: CheckItem[];
  meta: CheckListMeta;
}

export type CheckStockType = 'bottom_check' | 'top_check' | 'first_hawaiian_4up';

export interface CheckSettings {
  next_check_number: number;
  check_stock_type: CheckStockType;
  check_offset_x: number;
  check_offset_y: number;
  bank_name: string | null;
  bank_address: string | null;
  check_memo_template: string | null;
  auto_create_fit_check: boolean;
  check_layout_config: Record<string, unknown>;
}

// ----------------
// W-2GU Report (CPR-68)
// ----------------

export interface W2GuEmployeeRow {
  employee_id: number;
  employee_name: string;
  employee_ssn_last4: string | null;
  employee_address: string | null;
  box1_wages_tips_other_comp: number;
  box2_federal_income_tax_withheld: number;
  box3_social_security_wages: number;
  box4_social_security_tax_withheld: number;
  box5_medicare_wages_tips: number;
  box6_medicare_tax_withheld: number;
  box7_social_security_tips: number;
  reported_tips_total: number;
  box7_limited_by_wage_base: boolean;
  has_missing_ssn: boolean;
  has_missing_address: boolean;
}

export interface W2GuReport {
  meta: {
    report_type: string;
    company_id: number;
    company_name: string;
    year: number;
    generated_at: string;
    employee_count: number;
    caveats: string[];
  };
  employer: {
    name: string;
    ein: string | null;
    address: string | null;
  };
  totals: {
    box1_wages_tips_other_comp: number;
    box2_federal_income_tax_withheld: number;
    box3_social_security_wages: number;
    box4_social_security_tax_withheld: number;
    box5_medicare_wages_tips: number;
    box6_medicare_tax_withheld: number;
    box7_social_security_tips: number;
    reported_tips_total: number;
  };
  compliance_issues: string[];
  employees: W2GuEmployeeRow[];
}

export interface W2GuReportResponse {
  report: W2GuReport;
}

export interface W2GuPreflightFinding {
  severity: 'blocking' | 'warning';
  code: string;
  message: string;
  employee_id?: number | null;
}

export interface W2GuPreflightResult {
  year: number;
  company_id: number;
  company_name: string;
  run_at: string;
  blocking_count: number;
  warning_count: number;
  findings: W2GuPreflightFinding[];
}

export interface W2GuFilingReadiness {
  year: number;
  status: 'draft' | 'preflight_passed' | 'filing_ready';
  blocking_count: number;
  warning_count: number;
  preflight_run_at?: string | null;
  marked_ready_at?: string | null;
  marked_ready_by_id?: number | null;
  notes?: string | null;
  findings?: W2GuPreflightFinding[];
  findings_source?: 'persisted' | 'revalidation';
}

export interface W2GuPreflightResponse {
  preflight: W2GuPreflightResult;
  filing: W2GuFilingReadiness;
}

export interface W2GuRevalidationResult {
  year: number;
  company_id: number;
  company_name: string;
  run_at: string;
  blocking_count: number;
  warning_count: number;
  findings: W2GuPreflightFinding[];
  findings_source: 'revalidation';
}

export interface W2GuFilingReadinessResponse {
  filing: W2GuFilingReadiness | null;
}

export interface W2GuMarkReadyResponse {
  filing: W2GuFilingReadiness;
  revalidation?: W2GuRevalidationResult;
}


// ----------------
// Employee Loans
// ----------------

export type LoanStatus = 'active' | 'paid_off' | 'suspended';

export interface EmployeeLoan {
  id: number;
  employee_id: number;
  employee_name: string;
  name: string;
  original_amount: number;
  current_balance: number;
  payment_amount?: number;
  start_date?: string;
  paid_off_date?: string;
  status: LoanStatus;
  deduction_type_id?: number;
  notes?: string;
  created_at: string;
  updated_at: string;
  transactions?: LoanTransaction[];
}

export interface LoanTransaction {
  id: number;
  transaction_type: 'payment' | 'addition' | 'adjustment';
  amount: number;
  balance_before: number;
  balance_after: number;
  transaction_date: string;
  notes?: string;
  pay_period_id?: number;
  created_at: string;
}

// ----------------
// Non-Employee Checks
// ----------------

export type NonEmployeeCheckType =
  | 'contractor'
  | 'tax_deposit'
  | 'grt'
  | 'estimated_tax'
  | 'w1_balance'
  | 'swica'
  | 'child_support'
  | 'garnishment'
  | 'vendor'
  | 'reimbursement'
  | 'other';

export type PaymentPeriodType = 'none' | 'pay_period' | 'month' | 'quarter' | 'year';

export interface NonEmployeeCheck {
  id: number;
  pay_period_id: number | null;
  company_id: number;
  check_number?: string | null;
  payable_to: string;
  amount: number;
  check_type: NonEmployeeCheckType;
  auto_generated_type?: string | null;
  memo?: string;
  description?: string;
  reference_number?: string;
  payment_period_type: PaymentPeriodType;
  tax_year?: number | null;
  tax_quarter?: number | null;
  tax_month?: number | null;
  due_date?: string | null;
  payment_date?: string | null;
  confirmation_number?: string | null;
  line_items: NonEmployeeCheckLineItem[];
  print_count: number;
  printed_at?: string;
  voided: boolean;
  void_reason?: string;
  voided_at?: string;
  check_status: string;
  edit_count?: number;
  created_by_id?: number;
  created_at: string;
  updated_at: string;
}

export interface NonEmployeeCheckLineItem {
  id?: number;
  description: string;
  reference_number?: string | null;
  service_period?: string | null;
  amount: number;
  position: number;
}

export interface NonEmployeeCheckEdit {
  id: number;
  edited_by_id?: number | null;
  edited_by_name?: string | null;
  before: Record<string, string | number | null>;
  after: Record<string, string | number | null>;
  changed_fields: string[];
  reason?: string | null;
  created_at: string;
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
