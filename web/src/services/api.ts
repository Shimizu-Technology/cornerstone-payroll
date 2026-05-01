// ========================================
// API Client for Cornerstone Payroll
// ========================================

const API_BASE_URL = import.meta.env.VITE_API_URL || 'http://localhost:3000/api/v1';

interface RequestOptions extends RequestInit {
  params?: Record<string, string | number | boolean | undefined>;
}

export interface BlobDownload {
  blob: Blob;
  filename?: string;
}

function parseContentDispositionFilename(header: string | null): string | undefined {
  if (!header) return undefined;
  // RFC 5987: filename*=UTF-8''encoded_name
  const rfc5987 = header.match(/filename\*\s*=\s*(?:UTF-8|utf-8)''(.+?)(?:;|$)/i);
  if (rfc5987) return decodeURIComponent(rfc5987[1].trim());
  // Standard: filename="name" or filename=name
  const standard = header.match(/filename\s*=\s*"?([^";\n]+)"?/i);
  if (standard) return standard[1].trim();
  return undefined;
}

class ApiClient {
  private baseUrl: string;
  private authToken: string | null = null;
  private authTokenProvider: (() => Promise<string | null>) | null = null;
  private activeCompanyId: number | null = null;

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl;
  }

  setAuthToken(token: string | null) {
    this.authToken = token;
  }

  setAuthTokenProvider(provider: (() => Promise<string | null>) | null) {
    this.authTokenProvider = provider;
  }

  setActiveCompanyId(companyId: number | null) {
    this.activeCompanyId = companyId;
  }

  getActiveCompanyId(): number | null {
    return this.activeCompanyId;
  }

  getAuthToken(): string | null {
    return this.authToken;
  }

  async getResolvedAuthToken(): Promise<string | null> {
    return this.resolveAuthToken();
  }

  private async resolveAuthToken(): Promise<string | null> {
    if (!this.authTokenProvider) return this.authToken;

    try {
      const freshToken = await this.authTokenProvider();
      if (freshToken) {
        this.authToken = freshToken;
      }
      return freshToken || this.authToken;
    } catch {
      return this.authToken;
    }
  }

  private buildUrl(endpoint: string, params?: Record<string, string | number | boolean | undefined>): string {
    const url = new URL(`${this.baseUrl}${endpoint}`);
    if (params) {
      Object.entries(params).forEach(([key, value]) => {
        if (value !== undefined) {
          url.searchParams.append(key, String(value));
        }
      });
    }
    return url.toString();
  }

  private async request<T>(endpoint: string, options: RequestOptions = {}): Promise<T> {
    const { params, ...fetchOptions } = options;
    const url = this.buildUrl(endpoint, params);

    const headers: HeadersInit = {
      'Content-Type': 'application/json',
      ...options.headers,
    };

    const token = await this.resolveAuthToken();
    if (token) {
      (headers as Record<string, string>)['Authorization'] = `Bearer ${token}`;
    }

    if (this.activeCompanyId) {
      (headers as Record<string, string>)['X-Company-Id'] = String(this.activeCompanyId);
    }

    const response = await fetch(url, {
      ...fetchOptions,
      headers,
    });

    if (!response.ok) {
      const errorData = await response.json().catch(() => ({}));
      throw new ApiError(
        errorData.error || `HTTP ${response.status}`,
        response.status,
        errorData.details,
        errorData
      );
    }

    // Handle 204 No Content
    if (response.status === 204) {
      return undefined as T;
    }

    return response.json();
  }

  async get<T>(endpoint: string, params?: Record<string, string | number | boolean | undefined>): Promise<T> {
    return this.request<T>(endpoint, { method: 'GET', params });
  }

  async post<T>(endpoint: string, data?: unknown): Promise<T> {
    return this.request<T>(endpoint, {
      method: 'POST',
      body: data ? JSON.stringify(data) : undefined,
    });
  }

  async postForm<T>(endpoint: string, formData: FormData): Promise<T> {
    const token = await this.resolveAuthToken();
    const headers: HeadersInit = {};
    if (token) {
      (headers as Record<string, string>)['Authorization'] = `Bearer ${token}`;
    }
    if (this.activeCompanyId) {
      (headers as Record<string, string>)['X-Company-Id'] = String(this.activeCompanyId);
    }

    const response = await fetch(this.buildUrl(endpoint), {
      method: 'POST',
      headers,
      body: formData,
    });

    if (!response.ok) {
      const errorData = await response.json().catch(() => ({}));
      throw new ApiError(
        errorData.error || `HTTP ${response.status}`,
        response.status,
        errorData.details,
        errorData
      );
    }

    return response.json() as Promise<T>;
  }

  // CPR-66: GET raw Blob (for authenticated PDF download)
  async getBlob(endpoint: string, params?: Record<string, string | number | boolean | undefined>): Promise<Blob> {
    const token = await this.resolveAuthToken();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (this.activeCompanyId) headers['X-Company-Id'] = String(this.activeCompanyId);

    const response = await fetch(this.buildUrl(endpoint, params), {
      method: 'GET',
      headers,
    });

    if (!response.ok) {
      const errorData = await response.json().catch(() => ({}));
      throw new ApiError(
        errorData.error || `HTTP ${response.status}`,
        response.status,
        errorData.details,
        errorData
      );
    }

    return response.blob();
  }

  // POST with JSON body returning a Blob (for reports with complex params like arrays)
  async postBlob(endpoint: string, body?: Record<string, unknown>): Promise<BlobDownload> {
    const token = await this.resolveAuthToken();
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (this.activeCompanyId) headers['X-Company-Id'] = String(this.activeCompanyId);

    const response = await fetch(this.buildUrl(endpoint), {
      method: 'POST',
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });

    if (!response.ok) {
      const errorData = await response.json().catch(() => ({}));
      throw new ApiError(
        errorData.error || `HTTP ${response.status}`,
        response.status,
        errorData.details,
        errorData
      );
    }

    const filename = parseContentDispositionFilename(response.headers.get('Content-Disposition'));
    const blob = await response.blob();
    return { blob, filename };
  }

  // GET raw Blob with query params (for authenticated file downloads with year/filters)
  async getBlobWithParams(
    endpoint: string,
    params?: Record<string, string | number | boolean | undefined>
  ): Promise<BlobDownload> {
    const token = await this.resolveAuthToken();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (this.activeCompanyId) headers['X-Company-Id'] = String(this.activeCompanyId);

    const response = await fetch(this.buildUrl(endpoint, params), {
      method: 'GET',
      headers,
    });

    if (!response.ok) {
      const errorData = await response.json().catch(() => ({}));
      throw new ApiError(
        errorData.error || `HTTP ${response.status}`,
        response.status,
        errorData.details,
        errorData
      );
    }

    const filename = parseContentDispositionFilename(response.headers.get('content-disposition'));
    return { blob: await response.blob(), filename };
  }

  // (postBlob is defined above — unified for all POST-to-Blob calls)

  async put<T>(endpoint: string, data?: unknown): Promise<T> {
    return this.request<T>(endpoint, {
      method: 'PUT',
      body: data ? JSON.stringify(data) : undefined,
    });
  }

  async patch<T>(endpoint: string, data?: unknown): Promise<T> {
    return this.request<T>(endpoint, {
      method: 'PATCH',
      body: data ? JSON.stringify(data) : undefined,
    });
  }

  async delete<T>(endpoint: string, options?: { data?: unknown }): Promise<T> {
    return this.request<T>(endpoint, {
      method: 'DELETE',
      body: options?.data ? JSON.stringify(options.data) : undefined,
    });
  }
}

export class ApiError extends Error {
  status: number;
  details?: Record<string, string[]>;
  data?: unknown;

  constructor(message: string, status: number, details?: Record<string, string[]>, data?: unknown) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.details = details;
    this.data = data;
  }
}

// Create singleton instance
const api = new ApiClient(API_BASE_URL);

export default api;
export { api as apiClient };
export const setAuthToken = (token: string | null) => api.setAuthToken(token);
export const setAuthTokenProvider = (provider: (() => Promise<string | null>) | null) =>
  api.setAuthTokenProvider(provider);
export const getAuthToken = () => api.getResolvedAuthToken();
export const getActiveCompanyId = () => api.getActiveCompanyId();
export const getApiBaseUrl = () => API_BASE_URL;

// ========================================
// API Endpoints
// ========================================

import type {
  Department,
  Employee,
  EmployeeFormData,
  EmployeeWageRate,
  PayPeriod,
  PayrollItem,
  PayrollItemWageRateHours,
  TimeEntry,
  DashboardStats,
  PaginationMeta,
  User,
  CheckListResponse,
  CheckItem,
  CheckSettings,
  W2GuReportResponse,
  W2GuPreflightResponse,
  W2GuFilingReadinessResponse,
  W2GuMarkReadyResponse,
  CorrectivePaycheckInputs,
  CorrectivePaycheckPreview,
  SupplementalPayPeriodSummary,
  ReplaceCheckPreview,
  ReplaceCheckResult,
} from '@/types';

// Employees (Admin API)
export const employeesApi = {
  list: (params?: { 
    company_id?: number; 
    status?: string; 
    department_id?: number;
    employment_type?: string;
    search?: string;
    sort_by?: 'name' | 'department' | 'rate' | 'status';
    sort_direction?: 'asc' | 'desc';
    page?: number; 
    per_page?: number;
    group_by?: string;
  }) =>
    api.get<{ data: Employee[]; meta: PaginationMeta }>('/admin/employees', params),
  get: (id: number) =>
    api.get<{ data: Employee & { ssn_last_four?: string; department?: { id: number; name: string } } }>(`/admin/employees/${id}`),
  create: (data: EmployeeFormData & { company_id: number }) =>
    api.post<{ data: Employee }>('/admin/employees', { employee: data }),
  update: (id: number, data: Partial<EmployeeFormData>) =>
    api.patch<{ data: Employee }>(`/admin/employees/${id}`, { employee: data }),
  delete: (id: number) =>
    api.delete<void>(`/admin/employees/${id}`),
  reactivate: (id: number) =>
    api.post<{ data: Employee }>(`/admin/employees/${id}/reactivate`),
};

// Employee Bulk Import
export interface BulkImportEmployeeData {
  first_name: string;
  last_name: string;
  middle_name: string | null;
  email: string | null;
  ssn: string | null;
  _ssn_token?: string | null;
  date_of_birth: string | null;
  hire_date: string | null;
  employment_type: string;
  salary_type?: string | null;
  pay_rate: string;
  pay_frequency: string | null;
  filing_status: string | null;
  allowances: string | null;
  additional_withholding: string | null;
  w4_dependent_credit: string | null;
  w4_step2_multiple_jobs: string | null;
  w4_step4a_other_income: string | null;
  w4_step4b_deductions: string | null;
  retirement_rate: string | null;
  roth_retirement_rate: string | null;
  department: string | null;
  address_line1: string | null;
  address_line2: string | null;
  city: string | null;
  state: string | null;
  zip: string | null;
  phone: string | null;
  contractor_type: string | null;
  contractor_pay_type: string | null;
  business_name: string | null;
  contractor_ein: string | null;
  w9_on_file: string | null;
}

export interface BulkImportPreviewRow {
  row_number: number;
  data: BulkImportEmployeeData;
  valid: boolean;
  duplicate: boolean;
  new_department: boolean;
  errors: string[];
}

export interface BulkImportPreviewResult {
  preview_id: string;
  rows: BulkImportPreviewRow[];
  summary: {
    total: number;
    valid: number;
    invalid: number;
    duplicates: number;
    new_departments?: string[];
  };
}

export interface BulkImportApplyResult {
  created: number;
  failed: number;
  errors: { row: number; messages: string[] }[];
}

export const employeeBulkImportApi = {
  downloadTemplate: async (): Promise<void> => {
    const data = await api.getBlobWithParams('/admin/employee_bulk_imports/template');
    const url = URL.createObjectURL(data.blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = data.filename || 'employee_import_template.csv';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  },
  preview: (file: File): Promise<BulkImportPreviewResult> => {
    const formData = new FormData();
    formData.append('file', file);
    return api.postForm<BulkImportPreviewResult>('/admin/employee_bulk_imports/preview', formData);
  },
  applyJson: (employees: Record<string, unknown>[], previewId?: string): Promise<BulkImportApplyResult> =>
    api.post<BulkImportApplyResult>('/admin/employee_bulk_imports/apply_json', { employees, preview_id: previewId }),
};

export const employeeWageRatesApi = {
  list: (employeeId: number) =>
    api.get<{ wage_rates: EmployeeWageRate[] }>('/admin/employee_wage_rates', { employee_id: employeeId }),
  create: (data: EmployeeWageRate & { employee_id: number }) =>
    api.post<{ wage_rate: EmployeeWageRate }>('/admin/employee_wage_rates', { employee_wage_rate: data }),
  update: (id: number, data: Partial<EmployeeWageRate>) =>
    api.patch<{ wage_rate: EmployeeWageRate }>(`/admin/employee_wage_rates/${id}`, { employee_wage_rate: data }),
  delete: (id: number) =>
    api.delete<{ message: string }>(`/admin/employee_wage_rates/${id}`),
};

// Departments (Admin API)
export const departmentsApi = {
  list: (params?: { company_id?: number; active?: boolean }) =>
    api.get<{ data: (Department & { employee_count: number })[] }>('/admin/departments', params),
  create: (data: { name: string; company_id: number }) =>
    api.post<{ data: Department }>('/admin/departments', { department: data }),
  update: (id: number, data: { name?: string; active?: boolean }) =>
    api.patch<{ data: Department }>(`/admin/departments/${id}`, { department: data }),
};

export const clientEmployeesApi = {
  list: (params?: {
    status?: string;
    department_id?: number;
    employment_type?: string;
    search?: string;
    sort_by?: 'name' | 'department' | 'rate' | 'status';
    sort_direction?: 'asc' | 'desc';
    page?: number;
    per_page?: number;
    group_by?: string;
  }) => api.get<{ data: Employee[]; meta: PaginationMeta }>('/client/employees', params),
  get: (id: number) =>
    api.get<{ data: Employee & { ssn_last_four?: string; department?: { id: number; name: string } } }>(`/client/employees/${id}`),
  create: (data: EmployeeFormData) =>
    api.post<ClientEmployeeUpdateResponse>('/client/employees', { employee: data }),
  update: (id: number, data: Partial<EmployeeFormData>) =>
    api.patch<ClientEmployeeUpdateResponse>(`/client/employees/${id}`, { employee: data }),
};

export const clientDepartmentsApi = {
  list: (params?: { active?: boolean }) =>
    api.get<{ data: (Department & { employee_count: number })[] }>('/client/departments', params),
  create: (data: { name: string }) =>
    api.post<{ data: Department }>('/client/departments', { department: data }),
  update: (id: number, data: { name?: string; active?: boolean }) =>
    api.patch<{ data: Department }>(`/client/departments/${id}`, { department: data }),
};

// Users (Admin API)
interface UserCreateResponse {
  data: User;
  invitation_sent: boolean;
  invitation_error?: string | null;
}

export const usersApi = {
  list: (params?: { search?: string }) =>
    api.get<{ data: User[] }>('/admin/users', params),
  get: (id: number) =>
    api.get<{ data: User }>(`/admin/users/${id}`),
  create: (data: { email: string; name: string; role: User['role']; company_ids?: number[] }) =>
    api.post<UserCreateResponse>('/admin/users', { user: data }),
  update: (id: number, data: Partial<Pick<User, 'name' | 'role' | 'active'>> & { company_ids?: number[] }) =>
    api.patch<{ data: User }>(`/admin/users/${id}`, { user: data }),
  activate: (id: number) =>
    api.post<{ data: User }>(`/admin/users/${id}/activate`),
  deactivate: (id: number) =>
    api.post<{ data: User }>(`/admin/users/${id}/deactivate`),
  resendInvitation: (id: number) =>
    api.post<UserCreateResponse>(`/admin/users/${id}/resend_invitation`),
  delete: (id: number) =>
    api.delete(`/admin/users/${id}`),
};

export interface UserInvitationResponse {
  id: number;
  email: string;
  name?: string | null;
  role: User['role'];
  invited_at: string;
  expires_at: string;
  invite_url: string;
}

export const userInvitationsApi = {
  create: (data: { email: string; name?: string; role: User['role'] }) =>
    api.post<{ data: UserInvitationResponse }>('/admin/user_invitations', { invitation: data }),
};

// Audit Logs (Admin API)
export interface AuditLogEntry {
  id: number;
  action: string;
  record_type: string | null;
  record_id: number | null;
  user_id: number | null;
  user_name: string | null;
  metadata: Record<string, unknown>;
  ip_address: string | null;
  user_agent: string | null;
  created_at: string;
}

export const auditLogsApi = {
  list: (params?: {
    user_id?: number;
    action_filter?: string;
    record_type?: string;
    record_id?: number;
    from?: string;
    to?: string;
    limit?: number;
  }) =>
    api.get<{ data: AuditLogEntry[] }>('/admin/audit_logs', params),
};

// Tax Configs (Admin API)
export interface TaxConfigBracket {
  id: number;
  bracket_order: number;
  min_income: number;
  max_income: number | null;
  rate: number;
  rate_percent: number;
}

export interface TaxConfigFilingStatus {
  id: number;
  filing_status: string;
  standard_deduction: number;
  brackets?: TaxConfigBracket[];
}

export interface TaxConfig {
  id: number;
  tax_year: number;
  ss_wage_base: number;
  ss_rate: number;
  medicare_rate: number;
  additional_medicare_rate: number;
  additional_medicare_threshold: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  filing_statuses: TaxConfigFilingStatus[];
}

export interface TaxConfigAuditLog {
  id: number;
  action: string;
  field_name: string | null;
  old_value: string | null;
  new_value: string | null;
  user_id: number | null;
  ip_address: string | null;
  created_at: string;
}

export const taxConfigsApi = {
  list: () =>
    api.get<{ tax_configs: TaxConfig[] }>('/admin/tax_configs'),
  get: (id: number) =>
    api.get<{ tax_config: TaxConfig }>(`/admin/tax_configs/${id}`),
  auditLogs: (id: number) =>
    api.get<{ audit_logs: TaxConfigAuditLog[] }>(`/admin/tax_configs/${id}/audit_logs`),
  create: (data: { tax_year: number; copy_from_year?: number | null }) =>
    api.post<{ tax_config: TaxConfig; message: string }>('/admin/tax_configs', data),
  activate: (id: number) =>
    api.post<{ tax_config: TaxConfig; message: string }>(`/admin/tax_configs/${id}/activate`),
  update: (id: number, data: Partial<Pick<TaxConfig, "ss_wage_base" | "ss_rate" | "medicare_rate" | "additional_medicare_rate" | "additional_medicare_threshold">>) =>
    api.patch<{ tax_config: TaxConfig; message: string }>(`/admin/tax_configs/${id}`, data),
  updateFilingStatus: (id: number, filingStatus: string, data: { standard_deduction: number }) =>
    api.patch<{ filing_status_config: TaxConfigFilingStatus; message: string }>(
      `/admin/tax_configs/${id}/filing_status/${filingStatus}`,
      data
    ),
  updateBrackets: (
    id: number,
    filingStatus: string,
    data: { brackets: Array<Pick<TaxConfigBracket, "bracket_order" | "min_income" | "max_income" | "rate">> }
  ) =>
    api.patch<{ filing_status_config: TaxConfigFilingStatus; message: string }>(
      `/admin/tax_configs/${id}/brackets/${filingStatus}`,
      data
    ),
  delete: (id: number) =>
    api.delete<{ message: string }>(`/admin/tax_configs/${id}`),
};

// Pay Periods (Admin API)
export interface PayPeriodListResponse {
  pay_periods: PayPeriod[];
  meta: {
    total: number;
    statuses: Record<string, number>;
  };
}

export interface PayPeriodResponse {
  pay_period: PayPeriod & { payroll_items?: PayrollItem[] };
}

export interface RunPayrollResponse {
  pay_period: PayPeriod & { payroll_items?: PayrollItem[] };
  results: {
    success: { employee_id: number; name: string }[];
    errors: { employee_id: number; error: string }[];
  };
}

export interface RunPayrollHoursEntry {
  regular?: number;
  overtime?: number;
  holiday?: number;
  pto?: number;
  wage_rates?: PayrollItemWageRateHours[];
}

export interface RunPayrollCustomEarningEntry {
  label: string;
  amount: number;
}

export const payPeriodsApi = {
  list: (params?: { status?: string; year?: number }) =>
    api.get<PayPeriodListResponse>('/admin/pay_periods', params),
  get: (id: number) =>
    api.get<PayPeriodResponse>(`/admin/pay_periods/${id}`),
  create: (data: { start_date: string; end_date: string; pay_date: string; notes?: string }) =>
    api.post<PayPeriodResponse>('/admin/pay_periods', { pay_period: data }),
  update: (id: number, data: { start_date?: string; end_date?: string; pay_date?: string; notes?: string }) =>
    api.patch<PayPeriodResponse>(`/admin/pay_periods/${id}`, { pay_period: data }),
  delete: (id: number) =>
    api.delete<void>(`/admin/pay_periods/${id}`),
  runPayroll: (id: number, data?: { employee_ids?: number[]; hours?: Record<string, RunPayrollHoursEntry>; salary_overrides?: Record<string, number>; tips?: Record<string, { amount: number; pool: string }>; tips_paid_out?: Record<string, number>; loan_deductions?: Record<string, number>; custom_earnings?: Record<string, RunPayrollCustomEarningEntry[]> }) =>
    api.post<RunPayrollResponse>(`/admin/pay_periods/${id}/run_payroll`, data),
  approve: (id: number) =>
    api.post<PayPeriodResponse>(`/admin/pay_periods/${id}/approve`),
  unapprove: (id: number) =>
    api.post<PayPeriodResponse>(`/admin/pay_periods/${id}/unapprove`),
  commit: (id: number) =>
    api.post<PayPeriodResponse>(`/admin/pay_periods/${id}/commit`),
  retryTaxSync: (id: number) =>
    api.post<PayPeriodResponse>(`/admin/pay_periods/${id}/retry_tax_sync`),
  generateFitCheck: (id: number) =>
    api.post<{ message: string; check_id: number }>(`/admin/pay_periods/${id}/generate_fit_check`),
  previewImport: async (id: number, pdfFile: File, excelFile?: File) => {
    const formData = new FormData();
    formData.append('pdf_file', pdfFile);
    if (excelFile) formData.append('excel_file', excelFile);
    return api.postForm<ImportPreviewResponse>(`/admin/pay_periods/${id}/preview_import`, formData);
  },
  applyImport: (id: number, data: { import_id: number; matched?: ImportPreviewRow[] }) =>
    api.post<ImportApplyResponse>(`/admin/pay_periods/${id}/apply_import`, data),

  // CPR-71: Payroll correction workflow
  void: (id: number, data: { reason: string }) =>
    api.post<VoidPayPeriodResponse>(`/admin/pay_periods/${id}/void`, data),
  createCorrectionRun: (
    id: number,
    data: {
      reason: string;
      start_date?: string;
      end_date?: string;
      pay_date?: string;
      notes?: string;
    }
  ) =>
    api.post<CorrectionRunResponse>(`/admin/pay_periods/${id}/create_correction_run`, data),
  correctionHistory: (id: number) =>
    api.get<CorrectionHistoryResponse>(`/admin/pay_periods/${id}/correction_history`),
  // CPR-73: Delete a draft correction run (undoes correction run creation without voiding).
  deleteDraftCorrectionRun: (id: number, data: { reason: string }) =>
    api.delete<DeleteDraftCorrectionRunResponse>(`/admin/pay_periods/${id}`, { data }),

  // Per-employee corrective paycheck (off-cycle supplemental period).
  // Preview is read-only — used to drive the modal's delta display.
  correctivePaycheckPreview: (
    id: number,
    data: { employee_id: number; corrected_inputs: CorrectivePaycheckInputs }
  ) =>
    api.post<CorrectivePaycheckPreview>(
      `/admin/pay_periods/${id}/corrective_paycheck_preview`,
      data
    ),
  issueCorrectivePaycheck: (
    id: number,
    data: {
      employee_id: number;
      corrected_inputs: CorrectivePaycheckInputs;
      pay_date: string;
      reason: string;
      notes?: string;
    }
  ) =>
    api.post<{
      supplemental_pay_period: PayPeriod;
      corrective_payroll_item: PayrollItem;
      original_pay_period_id: number;
    }>(`/admin/pay_periods/${id}/corrective_paychecks`, data),
  supplementalPayPeriods: (id: number) =>
    api.get<{ supplemental_pay_periods: SupplementalPayPeriodSummary[] }>(
      `/admin/pay_periods/${id}/supplemental_pay_periods`
    ),

  // Timecard OCR import
  previewTimecardImport: async (id: number, csvFile: File) => {
    const formData = new FormData();
    formData.append('file', csvFile);
    return api.postForm<TimecardImportPreviewResponse>(`/admin/pay_periods/${id}/preview_timecard_import`, formData);
  },
  applyTimecardImport: (id: number, mappings: TimecardImportMapping[]) =>
    api.post<TimecardImportApplyResponse>(`/admin/pay_periods/${id}/apply_timecard_import`, { mappings }),
};

export const clientPayPeriodsApi = {
  list: (params?: { status?: string; year?: number }) =>
    api.get<PayPeriodListResponse>('/client/pay_periods', params),
  get: (id: number) =>
    api.get<PayPeriodResponse>(`/client/pay_periods/${id}`),
};

// Timecard OCR import types
export interface TimecardImportPreviewRow {
  csv_name: string;
  regular_hours: string;
  overtime_hours: string;
  total_hours: string;
  flags: string;
  employee_id: number | null;
  employee_name: string | null;
  match_score: number;
}

export interface TimecardImportPreviewResponse {
  preview: TimecardImportPreviewRow[];
  all_employees: { id: number; name: string }[];
  total_rows: number;
  matched: number;
  unmatched: number;
}

export interface TimecardImportMapping {
  employee_id: number;
  regular_hours: number;
  overtime_hours: number;
}

export interface TimecardImportApplyResponse {
  applied: { employee_id: number; employee_name: string; hours_worked: number; overtime_hours: number }[];
  skipped: unknown[];
  errors: { employee_id: number; error: string }[];
}

// ──── Full Timecard OCR types ────────────────────────────────
export interface PunchEntryData {
  id: number;
  card_day: number | null;
  date: string | null;
  day_of_week: string | null;
  clock_in: string | null;
  lunch_out: string | null;
  lunch_in: string | null;
  clock_out: string | null;
  in3: string | null;
  out3: string | null;
  hours_worked: number | null;
  confidence: number | null;
  notes: string | null;
  manually_edited: boolean;
  review_state: 'unresolved' | 'approved';
  reviewed_by_name: string | null;
  reviewed_at: string | null;
  needs_attention: boolean;
  blank_day: boolean;
}

export interface ReviewSummary {
  severity: 'critical' | 'warning' | 'info' | 'ok';
  priority_rank: number;
  attention_count: number;
  approved_attention_count: number;
  low_confidence_count: number;
  noted_entry_count: number;
  missing_punch_count: number;
  manual_edit_count: number;
  reason_codes: string[];
}

export interface TimecardData {
  id: number;
  company_id: number;
  pay_period_id: number | null;
  employee_name: string | null;
  period_start: string | null;
  period_end: string | null;
  image_url: string | null;
  preprocessed_image_url: string | null;
  ocr_status: 'pending' | 'processing' | 'complete' | 'failed' | 'reviewed';
  overall_confidence: number | null;
  ocr_error: string | null;
  reviewed_by_name: string | null;
  reviewed_at: string | null;
  applied_employee_id: number | null;
  applied_employee_name: string | null;
  applied_payroll_item_id: number | null;
  applied_to_payroll_at: string | null;
  review_summary: ReviewSummary;
  created_at: string;
  punch_entries: PunchEntryData[];
}

export interface ApplyToPayrollResponse {
  employee_id: number;
  employee_name: string;
  hours_worked: number;
  overtime_hours: number;
  timecard_id: number;
  payroll_item?: import('@/types').PayrollItem;
  timecard?: TimecardData;
}

export interface TimecardListMeta {
  page: number;
  per_page: number;
  total_count: number;
  total_pages: number;
}

export interface TimecardListResponse {
  timecards: TimecardData[];
  meta: TimecardListMeta;
}

export const timecardsApi = {
  list: (payPeriodId?: number) => {
    const params = payPeriodId ? `?pay_period_id=${payPeriodId}` : '';
    return api.get<TimecardData[]>(`/admin/timecards${params}`);
  },
  listPaginated: (opts: { page?: number; perPage?: number; search?: string; status?: string; payPeriodId?: number }) => {
    const params = new URLSearchParams();
    params.set('page', String(opts.page || 1));
    params.set('per_page', String(opts.perPage || 20));
    if (opts.search) params.set('search', opts.search);
    if (opts.status) params.set('status', opts.status);
    if (opts.payPeriodId) params.set('pay_period_id', String(opts.payPeriodId));
    return api.get<TimecardListResponse>(`/admin/timecards?${params.toString()}`);
  },
  show: (id: number) => api.get<TimecardData>(`/admin/timecards/${id}`),
  upload: async (file: File, payPeriodId?: number) => {
    const formData = new FormData();
    formData.append('image', file);
    if (payPeriodId) formData.append('pay_period_id', String(payPeriodId));
    return api.postForm<TimecardData[]>(`/admin/timecards`, formData);
  },
  update: (id: number, data: Partial<Pick<TimecardData, 'employee_name' | 'period_start' | 'period_end' | 'pay_period_id'>>) =>
    api.patch<TimecardData>(`/admin/timecards/${id}`, { timecard: data }),
  review: (id: number, reviewedByName: string) =>
    api.patch<TimecardData>(`/admin/timecards/${id}/review`, { review: { reviewed_by_name: reviewedByName } }),
  reprocess: (id: number) => api.patch<TimecardData>(`/admin/timecards/${id}/reprocess`),
  delete: (id: number) => api.delete(`/admin/timecards/${id}`),
  applyToPayroll: (id: number, payPeriodId: number, employeeId?: number, wageRateId?: number) =>
    api.post<ApplyToPayrollResponse>(`/admin/timecards/${id}/apply_to_payroll`, {
      pay_period_id: payPeriodId,
      ...(employeeId ? { employee_id: employeeId } : {}),
      ...(wageRateId ? { wage_rate_id: wageRateId } : {}),
    }),
};

export const punchEntriesApi = {
  create: (timecardId: number, data: Partial<PunchEntryData>) =>
    api.post<PunchEntryData>(`/admin/punch_entries`, { timecard_id: timecardId, punch_entry: data }),
  update: (id: number, data: Partial<PunchEntryData>) =>
    api.patch<PunchEntryData>(`/admin/punch_entries/${id}`, { punch_entry: data }),
};

// CPR-71: Correction response types
export interface VoidPayPeriodResponse {
  pay_period: import('@/types').PayPeriod;
  correction_event: import('@/types').PayPeriodCorrectionEvent;
}

export interface CorrectionRunResponse {
  source_pay_period: import('@/types').PayPeriod;
  correction_run: import('@/types').PayPeriod;
}

export interface CorrectionHistoryResponse {
  pay_period: {
    id: number;
    period_description: string;
    status: string;
    correction_status: string | null;
    voided_at: string | null;
    void_reason: string | null;
    source_pay_period_id: number | null;
    superseded_by_id: number | null;
  };
  correction_events: import('@/types').PayPeriodCorrectionEvent[];
}

// CPR-73: Delete draft correction run response
export interface DeleteDraftCorrectionRunResponse {
  source_pay_period: import('@/types').PayPeriod;
  deleted_correction_run_id: number;
  correction_event: import('@/types').PayPeriodCorrectionEvent;
}

// Import types
export interface ImportPreviewRow {
  employee_id: number;
  employee_name: string;
  employment_type: string;
  pay_rate: number;
  confidence: number;
  matched_name: string;
  regular_hours: number;
  overtime_hours: number;
  regular_pay: number;
  overtime_pay: number;
  total_hours: number;
  total_pay: number;
  pdf_employee_name: string | null;
  total_tips: number;
  tip_pool: string | null;
  loan_deduction: number;
}

export interface ImportPreviewResponse {
  import_id: number;
  preview: {
    matched: ImportPreviewRow[];
    unmatched_pdf_names: string[];
    pdf_count: number;
    excel_count: number;
    matched_count: number;
  };
}

export interface ImportApplyResponse {
  results: {
    success: { employee_id: number; name: string }[];
    errors: { employee_id: number; name: string; error: string }[];
  };
  pay_period: PayPeriod & { payroll_items?: PayrollItem[] };
}

// Payroll Items (Admin API)
export interface PayrollItemsListResponse {
  payroll_items: PayrollItem[];
  summary: {
    total_gross: number;
    total_federal: number;
    total_social_security: number;
    total_medicare: number;
    total_guam: number;
    total_deductions: number;
    total_net: number;
    employee_count: number;
  };
}

export const payrollItemsApi = {
  list: (payPeriodId: number) =>
    api.get<PayrollItemsListResponse>(`/admin/pay_periods/${payPeriodId}/payroll_items`),
  get: (payPeriodId: number, id: number) =>
    api.get<{ payroll_item: PayrollItem }>(`/admin/pay_periods/${payPeriodId}/payroll_items/${id}`),
  create: (payPeriodId: number, data: Partial<PayrollItem> & { employee_id: number; auto_calculate?: boolean }) =>
    api.post<{ payroll_item: PayrollItem }>(`/admin/pay_periods/${payPeriodId}/payroll_items`, { payroll_item: data, auto_calculate: data.auto_calculate }),
  update: (payPeriodId: number, id: number, data: Partial<PayrollItem> & { auto_calculate?: boolean; wage_rate_hours?: PayrollItemWageRateHours[] }) =>
    api.patch<{ payroll_item: PayrollItem }>(`/admin/pay_periods/${payPeriodId}/payroll_items/${id}`, { payroll_item: data, auto_calculate: data.auto_calculate }),
  delete: (payPeriodId: number, id: number) =>
    api.delete<void>(`/admin/pay_periods/${payPeriodId}/payroll_items/${id}`),
  recalculate: (payPeriodId: number, id: number) =>
    api.post<{ payroll_item: PayrollItem }>(`/admin/pay_periods/${payPeriodId}/payroll_items/${id}/recalculate`),
};

// Time Entries
export const timeEntriesApi = {
  list: (companyId: number, employeeId: number, payPeriodId?: number) =>
    api.get<TimeEntry[]>(`/companies/${companyId}/employees/${employeeId}/time_entries`, { pay_period_id: payPeriodId }),
  create: (companyId: number, employeeId: number, data: Partial<TimeEntry>) =>
    api.post<TimeEntry>(`/companies/${companyId}/employees/${employeeId}/time_entries`, { time_entry: data }),
  update: (companyId: number, employeeId: number, id: number, data: Partial<TimeEntry>) =>
    api.patch<TimeEntry>(`/companies/${companyId}/employees/${employeeId}/time_entries/${id}`, { time_entry: data }),
  delete: (companyId: number, employeeId: number, id: number) =>
    api.delete<void>(`/companies/${companyId}/employees/${employeeId}/time_entries/${id}`),
};

// Dashboard & Reports (Admin API)
export interface DashboardResponse {
  stats: {
    total_employees: number;
    active_employees: number;
    current_pay_period: {
      id: number;
      period_description: string;
      pay_date: string;
      status: string;
      employee_count: number;
      total_gross: number;
      total_net: number;
    } | null;
    ytd_totals: {
      year: number;
      gross_pay: number;
      withholding_tax: number;
      social_security_tax: number;
      medicare_tax: number;
      retirement: number;
      net_pay: number;
      payroll_count: number;
    };
    recent_payrolls: {
      id: number;
      period_description: string;
      pay_date: string;
      employee_count: number;
      total_net: number;
    }[];
  };
}

export interface PayrollRegisterReport {
  report: {
    type: string;
    pay_period: {
      id: number;
      start_date: string;
      end_date: string;
      pay_date: string;
      status: string;
    };
    summary: {
      employee_count: number;
      total_gross: number;
      total_withholding: number;
      total_social_security: number;
      total_medicare: number;
      total_retirement: number;
      total_deductions: number;
      total_net: number;
    };
    employees: Array<PayrollItem & { total_retirement_payment?: number }>;
  };
}

export interface TaxSummaryReport {
  report: {
    type: string;
    period: {
      year: number;
      quarter?: number;
      start_date: string | null;
      end_date: string | null;
    };
    totals: {
      gross_wages: number;
      withholding_tax: number;
      social_security_employee: number;
      social_security_employer: number;
      medicare_employee: number;
      medicare_employer: number;
      total_employment_taxes: number;
    };
    pay_periods_included: number;
    employee_count: number;
  };
}

export interface YtdSummaryReport {
  report: {
    type: string;
    year: number;
    employees: {
      employee_id: number;
      name: string;
      employment_type: string;
      status: string;
      gross_pay: number;
      withholding_tax: number;
      social_security_tax: number;
      medicare_tax: number;
      retirement: number;
      net_pay: number;
    }[];
    company_totals: null | {
      year: number;
      gross_pay: number;
      withholding_tax: number;
      social_security_tax: number;
      medicare_tax: number;
      retirement: number;
      net_pay: number;
      payroll_count: number;
    };
  };
}

export interface Form941GuReport {
  meta: {
    report_type: string;
    company_name: string;
    ein: string;
    year: number;
    quarter: number;
    quarter_label: string;
    quarter_start: string;
    quarter_end: string;
    generated_at: string;
    pay_periods_included: number;
    caveats: string[];
  };
  employer_info: {
    name: string;
    ein: string;
    address: string;
  };
  lines: {
    line1_employee_count: number;
    line2_wages_tips_other: number;
    line3_fit_withheld: number;
    line5a_ss_wages: number;
    line5a_ss_combined_tax: number;
    line5b_ss_tips: number;
    line5b_ss_tips_combined_tax: number;
    line5c_medicare_wages: number;
    line5c_medicare_combined_tax: number;
    line5d_add_medicare_wages: number;
    line5d_add_medicare_tax: number;
    line5e_total_ss_medicare: number;
    line6_total_taxes_before_adj: number;
    line7_adj_fractions_cents: number | null;
    line8_adj_sick_pay: number | null;
    line9_adj_tips_group_life: number | null;
    line10_total_taxes_after_adj: number;
    line11_nonrefundable_credits: number | null;
    line12_total_after_credits: number;
    line13_total_deposits: number | null;
    line14_balance_due_or_overpayment: number | null;
  };
  tax_detail: {
    gross_wages: number;
    reported_tips: number;
    fit_withheld: number;
    ss_employee: number;
    ss_employer: number;
    ss_wages_combined: number;
    ss_tips_combined: number;
    ss_combined: number;
    medicare_employee: number;
    medicare_employer: number;
    medicare_combined: number;
    additional_medicare_employee: number;
    total_employee_taxes: number;
    total_employer_taxes: number;
  };
  monthly_liability: {
    month: string;
    month_start: string;
    month_end: string;
    fit_withheld: number;
    ss_combined: number;
    ss_tips_combined: number;
    medicare_combined: number;
    add_medicare_tax: number;
    total_liability: number;
  }[];
}

export const reportsApi = {
  dashboard: () =>
    api.get<DashboardResponse>('/admin/reports/dashboard'),
  payrollRegister: (payPeriodId: number) =>
    api.get<PayrollRegisterReport>('/admin/reports/payroll_register', { pay_period_id: payPeriodId }),
  // CPR-70: Payroll Register exports
  payrollRegisterCsv: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/payroll_register_csv', { pay_period_id: payPeriodId }),
  payrollRegisterPdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/payroll_register_pdf', { pay_period_id: payPeriodId }),
  payrollRegisterXlsx: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/payroll_register_xlsx', { pay_period_id: payPeriodId }),
  employeePayHistory: (employeeId: number, limit?: number) =>
    api.get<{ report: {
      employee: { id: number; name: string; employment_type: string; pay_rate: number };
      history: {
        pay_period_id: number;
        pay_date: string;
        period_description: string;
        hours_worked: number | null;
        overtime_hours: number | null;
        gross_pay: number;
        total_deductions: number;
        net_pay: number;
        check_number: string | null;
      }[];
      ytd: Record<string, number>;
    } }>('/admin/reports/employee_pay_history', { employee_id: employeeId, limit }),
  employeePayHistoryXlsx: (employeeId: number, limit?: number) =>
    api.getBlobWithParams('/admin/reports/employee_pay_history_xlsx', { employee_id: employeeId, limit }),
  taxSummary: (year?: number, quarter?: number) =>
    api.get<TaxSummaryReport>('/admin/reports/tax_summary', { year, quarter }),
  // CPR-70: Tax Summary exports
  taxSummaryCsv: (year: number, quarter?: number) =>
    api.getBlobWithParams('/admin/reports/tax_summary_csv', { year, quarter }),
  taxSummaryPdf: (year: number, quarter?: number) =>
    api.getBlobWithParams('/admin/reports/tax_summary_pdf', { year, quarter }),
  taxSummaryXlsx: (year: number, quarter?: number) =>
    api.getBlobWithParams('/admin/reports/tax_summary_xlsx', { year, quarter }),
  ytdSummary: (year?: number) =>
    api.get<YtdSummaryReport>('/admin/reports/ytd_summary', { year }),
  ytdSummaryXlsx: (year?: number) =>
    api.getBlobWithParams('/admin/reports/ytd_summary_xlsx', { year }),
  // CPR-68: W-2GU Annual Report
  w2Gu: (year: number) =>
    api.get<W2GuReportResponse>('/admin/reports/w2_gu', { year }),
  w2GuCsv: (year: number) =>
    api.getBlobWithParams('/admin/reports/w2_gu_csv', { year }),
  w2GuPdf: (year: number) =>
    api.getBlobWithParams('/admin/reports/w2_gu_pdf', { year }),
  w2GuXlsx: (year: number) =>
    api.getBlobWithParams('/admin/reports/w2_gu_xlsx', { year }),
  // CPR-74: W-2 filing operationalization
  w2GuPreflight: (year: number) =>
    api.post<W2GuPreflightResponse>('/admin/reports/w2_gu_preflight', { year }),
  w2GuFilingReadiness: (year: number) =>
    api.get<W2GuFilingReadinessResponse>('/admin/reports/w2_gu_filing_readiness', { year }),
  w2GuMarkReady: (year: number, notes?: string) =>
    api.post<W2GuMarkReadyResponse>('/admin/reports/w2_gu_mark_ready', { year, notes }),
  // Form 941-GU Quarterly Report
  form941Gu: (year: number, quarter: number) =>
    api.get<{ report: Form941GuReport }>('/admin/reports/form_941_gu', { year, quarter }),
  form941GuXlsx: (year: number, quarter: number) =>
    api.getBlobWithParams('/admin/reports/form_941_gu_xlsx', { year, quarter }),
  // 1099-NEC Annual Report
  form1099Nec: (year: number) =>
    api.get('/admin/reports/form_1099_nec', { year }),
  form1099NecPdf: (year: number) =>
    api.getBlobWithParams('/admin/reports/form_1099_nec_pdf', { year }),
  form1099NecXlsx: (year: number) =>
    api.getBlobWithParams('/admin/reports/form_1099_nec_xlsx', { year }),
  // Payroll parity reports
  payrollSummaryByEmployeePdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/payroll_summary_by_employee_pdf', { pay_period_id: payPeriodId }),
  payrollSummaryByEmployeeXlsx: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/payroll_summary_by_employee_xlsx', { pay_period_id: payPeriodId }),
  deductionsContributionsPdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/deductions_contributions_pdf', { pay_period_id: payPeriodId }),
  deductionsContributionsXlsx: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/deductions_contributions_xlsx', { pay_period_id: payPeriodId }),
  paycheckHistoryPdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/paycheck_history_pdf', { pay_period_id: payPeriodId }),
  paycheckHistoryXlsx: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/paycheck_history_xlsx', { pay_period_id: payPeriodId }),
  retirementPlansPdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/retirement_plans_pdf', { pay_period_id: payPeriodId }),
  retirementPlansXlsx: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/retirement_plans_xlsx', { pay_period_id: payPeriodId }),
  installmentLoansPdf: (asOfDate?: string) =>
    api.getBlobWithParams('/admin/reports/installment_loans_pdf', { as_of_date: asOfDate }),
  installmentLoansXlsx: (asOfDate?: string) =>
    api.getBlobWithParams('/admin/reports/installment_loans_xlsx', { as_of_date: asOfDate }),
  transmittalLogPdf: (payPeriodId: number, options?: TransmittalOptions) =>
    api.postBlob('/admin/reports/transmittal_log_pdf', {
      pay_period_id: payPeriodId,
      preparer_name: options?.preparerName,
      notes: options?.notes,
      report_list: options?.reportList,
      check_number_first: options?.checkNumberFirst,
      check_number_last: options?.checkNumberLast,
      non_employee_check_numbers: options?.nonEmployeeCheckNumbers,
      custom_entries: options?.customEntries,
    }),
  fullPrintPackagePdf: (payPeriodId: number, options?: TransmittalOptions) =>
    api.postBlob('/admin/reports/full_print_package_pdf', {
      pay_period_id: payPeriodId,
      preparer_name: options?.preparerName,
      notes: options?.notes,
      report_list: options?.reportList,
      check_number_first: options?.checkNumberFirst,
      check_number_last: options?.checkNumberLast,
      non_employee_check_numbers: options?.nonEmployeeCheckNumbers,
      custom_entries: options?.customEntries,
    }),
  checkSignoffSheet: (payPeriodId: number, notes?: string[], entries?: { name: string; check_number: string }[]) =>
    api.postBlob('/admin/reports/check_signoff_sheet', {
      pay_period_id: payPeriodId,
      ...(notes && notes.length > 0 ? { notes } : {}),
      ...(entries && entries.length > 0 ? { entries } : {}),
    }),
  checkSignoffPdf: (payPeriodId: number, notes?: string[], entries?: { name: string; check_number: string }[]) =>
    api.postBlob('/admin/reports/check_signoff_pdf', {
      pay_period_id: payPeriodId,
      ...(notes && notes.length > 0 ? { notes } : {}),
      ...(entries && entries.length > 0 ? { entries } : {}),
    }),
  checkSignoffPreview: (payPeriodId: number) =>
    api.get<{
      company_name: string;
      period_start: string;
      period_end: string;
      entries: { id: number; employee_id: number; name: string; check_number: string }[];
      saved_signoff: {
        entries: { name: string; check_number: string }[];
        notes: string[];
        generated_at: string;
        updated_at: string;
      } | null;
    }>(`/admin/reports/check_signoff_preview?pay_period_id=${payPeriodId}`),
};

export const clientReportsApi = {
  dashboard: () =>
    api.get<DashboardResponse>('/client/reports/dashboard'),
  payrollRegister: (payPeriodId: number) =>
    api.get<PayrollRegisterReport>('/client/reports/payroll_register', { pay_period_id: payPeriodId }),
  payrollRegisterPdf: (payPeriodId: number) =>
    api.getBlobWithParams('/client/reports/payroll_register_pdf', { pay_period_id: payPeriodId }),
  ytdSummary: (year?: number) =>
    api.get<YtdSummaryReport>('/client/reports/ytd_summary', { year }),
};

export interface TransmittalCustomEntry {
  title: string;
  details: string[];
}

export interface TransmittalOptions {
  preparerName?: string;
  notes?: string[];
  reportList?: string[];
  checkNumberFirst?: string;
  checkNumberLast?: string;
  nonEmployeeCheckNumbers?: Record<number, string>;
  customEntries?: TransmittalCustomEntry[];
}

export interface SavedTransmittal {
  preparer_name: string | null;
  notes: string[];
  report_list: string[];
  check_number_first: string | null;
  check_number_last: string | null;
  non_employee_check_numbers: Record<string, string>;
  custom_entries: TransmittalCustomEntry[];
  generated_at: string | null;
  updated_by_id: number | null;
  created_at: string;
  updated_at: string;
}

export interface TransmittalPreview {
  payroll_checks: {
    count: number;
    first: string | null;
    last: string | null;
  };
  non_employee_checks: {
    id: number;
    check_number: string | null;
    payable_to: string;
    amount: number;
    check_type: string;
    memo: string | null;
    description: string | null;
  }[];
  tax_totals: {
    fit: number;
    employee_ss: number;
    employer_ss: number;
    employee_medicare: number;
    employer_medicare: number;
    total_fica: number;
    total_drt_deposit: number;
  };
  saved_transmittal: SavedTransmittal | null;
}

export const transmittalApi = {
  preview: (payPeriodId: number): Promise<TransmittalPreview> =>
    api.get('/admin/reports/transmittal_preview', { pay_period_id: payPeriodId }),
};

// Pay Stubs (Admin API)
export interface PayStubInfo {
  payroll_item_id: number;
  employee_name: string;
  pay_period?: string;
  pay_date: string;
  net_pay: number;
  generated?: boolean;
  storage_key?: string;
}

export const payStubsApi = {
  get: (payrollItemId: number) =>
    api.get<{ pay_stub: PayStubInfo }>(`/admin/pay_stubs/${payrollItemId}`),
  generate: (payrollItemId: number) =>
    api.post<{ pay_stub: PayStubInfo }>(`/admin/pay_stubs/${payrollItemId}/generate`),
  downloadUrl: (payrollItemId: number) =>
    `${API_BASE_URL}/admin/pay_stubs/${payrollItemId}/download`,
  batchGenerate: (payPeriodId: number) =>
    api.post<{ pay_period_id: number; total: number; generated: number; errors: number }>('/admin/pay_stubs/batch_generate', { pay_period_id: payPeriodId }),
  batchPdf: (payPeriodId: number, payrollItemIds?: number[]) =>
    api.postBlob('/admin/pay_stubs/batch_pdf', {
      pay_period_id: payPeriodId,
      payroll_item_ids: payrollItemIds && payrollItemIds.length > 0 ? payrollItemIds : undefined,
    }),
  employeeStubs: (employeeId: number, limit?: number) =>
    api.get<{ employee: { id: number; name: string }; pay_stubs: PayStubInfo[] }>(`/admin/pay_stubs/employee/${employeeId}`, { limit }),
};

// ============================================================
// CPR-66: Check Printing API
// ============================================================
export const checksApi = {
  // List all checks for a committed pay period
  list: (payPeriodId: number) =>
    api.get<CheckListResponse>(`/admin/pay_periods/${payPeriodId}/checks`),


  // POST to generate batch PDF (returns blob)
  batchPdf: (payPeriodId: number, options?: { startingSlot?: number }) =>
    api.postBlob(`/admin/pay_periods/${payPeriodId}/checks/batch_pdf`, {
      starting_slot: options?.startingSlot,
    }),

  // Mark all unprinted checks in a period as printed
  markAllPrinted: (payPeriodId: number) =>
    api.post<{ marked_printed: number }>(`/admin/pay_periods/${payPeriodId}/checks/mark_all_printed`),

  // Download a single check PDF through authenticated API client
  checkPdf: (payrollItemId: number, options?: { startingSlot?: number }) =>
    api.getBlob(`/admin/payroll_items/${payrollItemId}/check`, {
      starting_slot: options?.startingSlot,
    }),

  // Mark a single check as printed
  markPrinted: (payrollItemId: number) =>
    api.post<{ payroll_item: CheckItem; already_printed: boolean }>(`/admin/payroll_items/${payrollItemId}/check/mark_printed`),

  // Correct an assigned check number without changing payroll values
  updateCheckNumber: (payrollItemId: number, checkNumber: string, reason?: string) =>
    api.patch<{ payroll_item: CheckItem }>(`/admin/payroll_items/${payrollItemId}/check_number`, {
      check_number: checkNumber,
      reason,
    }),

  // Void a check
  void: (payrollItemId: number, reason: string) =>
    api.post<{ payroll_item: CheckItem }>(`/admin/payroll_items/${payrollItemId}/void`, { reason }),

  // Reprint a check (in-place reassignment)
  reprint: (payrollItemId: number, reason?: string) =>
    api.post<{ original_check_number: string; reprint: CheckItem }>(`/admin/payroll_items/${payrollItemId}/reprint`, { reason }),

  // Replace check (uncashed) — preview the corrected snapshot + delta.
  // Used when the original physical check has not been distributed or has
  // been returned uncashed AND the financial values need to change.
  replaceCheckPreview: (
    payrollItemId: number,
    data: { corrected_inputs: Record<string, unknown> }
  ) =>
    api.post<ReplaceCheckPreview>(
      `/admin/payroll_items/${payrollItemId}/replace_check_preview`,
      data
    ),

  // Replace check (uncashed) — commit the change. For unprinted items the
  // check # is reused (in_place); for printed items the old # is voided
  // and a new one assigned (void_and_reissue).
  replaceCheck: (
    payrollItemId: number,
    data: { corrected_inputs: Record<string, unknown>; reason: string }
  ) =>
    api.post<ReplaceCheckResult>(
      `/admin/payroll_items/${payrollItemId}/replace_check`,
      data
    ),

  // Company check settings
  getSettings: () =>
    api.get<{ check_settings: CheckSettings }>('/admin/companies/check_settings'),

  updateSettings: (settings: Partial<CheckSettings>) =>
    api.patch<{ check_settings: CheckSettings }>('/admin/companies/check_settings', settings),

  updateNextCheckNumber: (next_check_number: number) =>
    api.patch<{ check_settings: CheckSettings }>('/admin/companies/next_check_number', { next_check_number }),

  // Download alignment test PDF through authenticated API client
  alignmentTestPdf: () =>
    api.getBlob('/admin/companies/alignment_test_pdf'),
};

// ============================================================
// Printer Profiles API
// ============================================================
export interface PrinterProfile {
  id: number;
  name: string;
  description: string | null;
  notes: string | null;
  check_stock_type: 'bottom_check' | 'top_check' | 'first_hawaiian_4up';
  check_offset_x: number;
  check_offset_y: number;
  check_layout_config: Record<string, unknown>;
  is_default: boolean;
  created_at: string;
  updated_at: string;
}

export const printerProfilesApi = {
  list: () =>
    api.get<{ printer_profiles: PrinterProfile[] }>('/admin/printer_profiles'),
  get: (id: number) =>
    api.get<{ printer_profile: PrinterProfile }>(`/admin/printer_profiles/${id}`),
  create: (data: Partial<PrinterProfile>) =>
    api.post<{ printer_profile: PrinterProfile }>('/admin/printer_profiles', { printer_profile: data }),
  update: (id: number, data: Partial<PrinterProfile>) =>
    api.patch<{ printer_profile: PrinterProfile }>(`/admin/printer_profiles/${id}`, { printer_profile: data }),
  delete: (id: number) =>
    api.delete<void>(`/admin/printer_profiles/${id}`),
  apply: (id: number) =>
    api.post<{ printer_profile: PrinterProfile; check_settings: Pick<CheckSettings, 'check_stock_type' | 'check_offset_x' | 'check_offset_y' | 'check_layout_config'> }>(`/admin/printer_profiles/${id}/apply`),
};

// ============================================================
// Companies API (Multi-tenant company switching)
// ============================================================
export interface CompanyListItem {
  id: number;
  name: string;
  active: boolean;
  active_employees: number;
  total_employees: number;
  pay_frequency: string;
}

export interface CompanyDetail extends CompanyListItem {
  address_line1?: string;
  address_line2?: string;
  city?: string;
  state?: string;
  zip?: string;
  ein?: string;
  phone?: string;
  email?: string;
  bank_name?: string;
  bank_address?: string;
  check_stock_type?: string;
  check_offset_x?: number;
  check_offset_y?: number;
  check_layout_config?: Record<string, unknown>;
  next_check_number?: number;
  can_update?: boolean;
  editable_fields?: string[];
}

export interface CompanyFormData {
  name: string;
  ein?: string;
  pay_frequency: string;
  active?: boolean;
  address_line1?: string;
  address_line2?: string;
  city?: string;
  state?: string;
  zip?: string;
  phone?: string;
  email?: string;
  bank_name?: string;
  bank_address?: string;
  check_stock_type?: string;
  check_layout_config?: Record<string, unknown>;
  next_check_number?: number;
}

interface CompanyListResponse {
  companies: CompanyListItem[];
  can_manage_clients: boolean;
  can_view_client_management?: boolean;
  can_switch_company: boolean;
  current_company_id: number;
}

interface AuthApiUser {
  id: number;
  email: string;
  name: string;
  role: string;
  company_id: number;
  company_name: string;
  home_company_id: number;
  assigned_company_ids: number[];
}

export const companiesApi = {
  list: (params?: { active?: boolean }) => {
    const query = params?.active !== undefined ? `?active=${params.active}` : '';
    return api.get<CompanyListResponse>(`/companies${query}`);
  },
  get: (id: number) =>
    api.get<{ company: CompanyDetail }>(`/admin/companies/${id}`),
  create: (data: CompanyFormData) =>
    api.post<{ company: CompanyDetail }>('/admin/companies', { company: data }),
  update: (id: number, data: Partial<CompanyFormData>) =>
    api.put<{ company: CompanyDetail }>(`/admin/companies/${id}`, { company: data }),
  switchCompany: (companyId: number) => {
    api.setActiveCompanyId(companyId);
    localStorage.setItem('activeCompanyId', String(companyId));
  },
  clearActiveCompanyId: () => {
    api.setActiveCompanyId(null);
    localStorage.removeItem('activeCompanyId');
  },
  getActiveCompanyId: (): number | null => {
    const stored = localStorage.getItem('activeCompanyId');
    return stored ? parseInt(stored, 10) : null;
  },
  initFromStorage: () => {
    const stored = localStorage.getItem('activeCompanyId');
    if (stored) {
      api.setActiveCompanyId(parseInt(stored, 10));
    }
  },
};

// Initialize from localStorage on module load
companiesApi.initFromStorage();

export interface ClientEmployeeUpdateResponse {
  data: Employee;
  change_request?: EmployeeChangeRequest | null;
  applied_direct_fields?: string[];
  message?: string;
}

export interface ClientDocument {
  id: number;
  title: string;
  category: string;
  file_name: string;
  content_type: string;
  file_size: number;
  notes?: string | null;
  employee_id?: number | null;
  employee_name?: string | null;
  uploaded_by_id: number;
  uploaded_by_name?: string | null;
  visible_to_client: boolean;
  shared_by_staff: boolean;
  created_at: string;
  preview_status: 'pending' | 'processing' | 'ready' | 'failed' | 'not_required';
  preview_available: boolean;
  preview_generated_at?: string | null;
  preview_content_type?: string | null;
  preview_error?: string | null;
}

export interface ClientDocumentsUploadResponse {
  data: ClientDocument[];
  message?: string;
}

export interface ClientPortalMessage {
  id: number;
  thread_id: number;
  body?: string | null;
  author_id?: number | null;
  author_name?: string | null;
  author_role?: string | null;
  created_at: string;
  document?: ClientDocument | null;
}

export interface ClientPortalThread {
  id: number;
  company_id: number;
  subject: string;
  status: 'open' | 'resolved';
  created_by_id?: number | null;
  created_by_name?: string | null;
  resolved_by_id?: number | null;
  resolved_by_name?: string | null;
  resolved_at?: string | null;
  last_message_at?: string | null;
  unread: boolean;
  created_at: string;
  updated_at: string;
  latest_message?: ClientPortalMessage | null;
  messages?: ClientPortalMessage[];
}

export interface EmployeeChangeRequest {
  id: number;
  status: 'pending' | 'approved' | 'rejected';
  employee_id: number;
  employee_name: string;
  requested_by_id: number;
  requested_by_name?: string | null;
  reviewed_by_id?: number | null;
  reviewed_by_name?: string | null;
  request_notes?: string | null;
  review_notes?: string | null;
  proposed_changes?: Record<string, unknown>;
  original_values?: Record<string, unknown>;
  direct_changes_applied?: Record<string, unknown>;
  created_at: string;
  reviewed_at?: string | null;
}

export interface Form500Fields {
  pay_period_id?: number | null;
  company_name: string;
  company_address_line1: string;
  company_address_line2: string;
  company_city: string;
  company_state: string;
  company_zip: string;
  employer_identification_number: string;
  total_taxes_dollars: string;
  total_taxes_cents: string;
  tax_year: string;
  tax_period_quarter: number;
  notes?: string;
  pay_date?: string | null;
  period_label?: string | null;
  income_tax_withholding_on_wages: boolean;
  tax_withholding_30_percent: boolean;
  corporate_estimated_tax: boolean;
  income_tax_withholding_1099: boolean;
}

// ============================================================
// Company Assignments (RBAC)
// ============================================================
export interface CompanyAssignment {
  id: number;
  user_id: number;
  user_name: string;
  user_email: string;
  company_id: number;
  company_name: string;
  created_at: string;
}

export const companyAssignmentsApi = {
  list: (userId?: number) =>
    api.get<{ data: CompanyAssignment[] }>(`/admin/company_assignments${userId ? `?user_id=${userId}` : ''}`),
  create: (data: { user_id: number; company_id: number }) =>
    api.post<{ data: CompanyAssignment }>('/admin/company_assignments', { company_assignment: data }),
  remove: (id: number) =>
    api.delete(`/admin/company_assignments/${id}`),
  bulkUpdate: (userId: number, companyIds: number[]) =>
    api.put<{ data: CompanyAssignment[] }>('/admin/company_assignments/bulk_update', {
      user_id: userId,
      company_ids: companyIds,
    }),
};

// ============================================================
// Payroll Parity Reports (PDF Downloads)
// ============================================================
export const payrollReportsApi = {
  payrollSummaryByEmployeePdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/payroll_summary_by_employee_pdf', { pay_period_id: payPeriodId }),
  payrollSummaryByEmployeeXlsx: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/payroll_summary_by_employee_xlsx', { pay_period_id: payPeriodId }),
  deductionsContributionsPdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/deductions_contributions_pdf', { pay_period_id: payPeriodId }),
  deductionsContributionsXlsx: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/deductions_contributions_xlsx', { pay_period_id: payPeriodId }),
  paycheckHistoryPdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/paycheck_history_pdf', { pay_period_id: payPeriodId }),
  paycheckHistoryXlsx: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/paycheck_history_xlsx', { pay_period_id: payPeriodId }),
  retirementPlansPdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/retirement_plans_pdf', { pay_period_id: payPeriodId }),
  retirementPlansXlsx: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/retirement_plans_xlsx', { pay_period_id: payPeriodId }),
  installmentLoansPdf: (asOfDate?: string) =>
    api.getBlobWithParams('/admin/reports/installment_loans_pdf', { as_of_date: asOfDate }),
  installmentLoansXlsx: (asOfDate?: string) =>
    api.getBlobWithParams('/admin/reports/installment_loans_xlsx', { as_of_date: asOfDate }),
  transmittalLogPdf: (payPeriodId: number, options?: TransmittalOptions) =>
    api.postBlob('/admin/reports/transmittal_log_pdf', {
      pay_period_id: payPeriodId,
      preparer_name: options?.preparerName,
      notes: options?.notes,
      report_list: options?.reportList,
      check_number_first: options?.checkNumberFirst,
      check_number_last: options?.checkNumberLast,
      non_employee_check_numbers: options?.nonEmployeeCheckNumbers,
      custom_entries: options?.customEntries,
    }),
  fullPrintPackagePdf: (payPeriodId: number, options?: TransmittalOptions) =>
    api.postBlob('/admin/reports/full_print_package_pdf', {
      pay_period_id: payPeriodId,
      preparer_name: options?.preparerName,
      notes: options?.notes,
      report_list: options?.reportList,
      check_number_first: options?.checkNumberFirst,
      check_number_last: options?.checkNumberLast,
      non_employee_check_numbers: options?.nonEmployeeCheckNumbers,
      custom_entries: options?.customEntries,
    }),
};

// ============================================================
// Employee Loans API
// ============================================================
import type { EmployeeLoan, NonEmployeeCheck } from '../types';

export const employeeLoansApi = {
  list: (params?: { employee_id?: number; status?: string }) =>
    api.get<{ loans: EmployeeLoan[] }>('/admin/employee_loans', params),
  get: (id: number) =>
    api.get<{ loan: EmployeeLoan }>(`/admin/employee_loans/${id}`),
  create: (data: {
    employee_id: number; name: string; original_amount: number;
    payment_amount?: number; start_date?: string; deduction_type_id?: number; notes?: string;
  }) =>
    api.post<{ loan: EmployeeLoan }>('/admin/employee_loans', { employee_loan: data }),
  update: (id: number, data: Partial<{ name: string; payment_amount: number; status: string; notes: string; deduction_type_id: number }>) =>
    api.patch<{ loan: EmployeeLoan }>(`/admin/employee_loans/${id}`, { employee_loan: data }),
  delete: (id: number) =>
    api.delete<{ message: string }>(`/admin/employee_loans/${id}`),
  recordPayment: (id: number, amount: number, date?: string) =>
    api.post<{ loan: EmployeeLoan; amount_applied: number }>(`/admin/employee_loans/${id}/record_payment`, { amount, date }),
  recordAddition: (id: number, amount: number, date?: string, notes?: string) =>
    api.post<{ loan: EmployeeLoan }>(`/admin/employee_loans/${id}/record_addition`, { amount, date, notes }),
};

export const clientDocumentsApi = {
  list: (params?: { category?: string; employee_id?: number }) =>
    api.get<{ data: ClientDocument[] }>('/client/documents', params),
  upload: (formData: FormData) =>
    api.postForm<ClientDocumentsUploadResponse>('/client/documents', formData),
  preview: (id: number) =>
    api.getBlobWithParams(`/client/documents/${id}/preview`),
  download: (id: number) =>
    api.getBlobWithParams(`/client/documents/${id}/download`),
  delete: (id: number) =>
    api.delete<void>(`/client/documents/${id}`),
};

export const clientPortalThreadsApi = {
  list: (params?: { status?: string }) =>
    api.get<{ data: ClientPortalThread[] }>('/client/portal_threads', params),
  get: (id: number) =>
    api.get<{ data: ClientPortalThread }>(`/client/portal_threads/${id}`),
  create: (data: { subject: string; body?: string; document_id?: number }) =>
    api.post<{ data: ClientPortalThread }>('/client/portal_threads', data),
  update: (id: number, data: { subject?: string; status?: 'open' | 'resolved' }) =>
    api.patch<{ data: ClientPortalThread }>(`/client/portal_threads/${id}`, data),
  markRead: (id: number) =>
    api.post<{ data: ClientPortalThread }>(`/client/portal_threads/${id}/mark_read`),
  createMessage: (threadId: number, data: { body?: string; document_id?: number }) =>
    api.post<{ data: ClientPortalMessage }>(`/client/portal_threads/${threadId}/messages`, data),
};

export const adminClientDocumentsApi = {
  list: (params?: { category?: string; employee_id?: number; uploaded_by_id?: number }) =>
    api.get<{ data: ClientDocument[] }>('/admin/client_documents', params),
  upload: (formData: FormData) =>
    api.postForm<ClientDocumentsUploadResponse>('/admin/client_documents', formData),
  preview: (id: number) =>
    api.getBlobWithParams(`/admin/client_documents/${id}/preview`),
  download: (id: number) =>
    api.getBlobWithParams(`/admin/client_documents/${id}/download`),
  delete: (id: number) =>
    api.delete<void>(`/admin/client_documents/${id}`),
};

export const adminPortalThreadsApi = {
  list: (params?: { status?: string }) =>
    api.get<{ data: ClientPortalThread[] }>('/admin/portal_threads', params),
  get: (id: number) =>
    api.get<{ data: ClientPortalThread }>(`/admin/portal_threads/${id}`),
  create: (data: { subject: string; body?: string; document_id?: number }) =>
    api.post<{ data: ClientPortalThread }>('/admin/portal_threads', data),
  update: (id: number, data: { subject?: string; status?: 'open' | 'resolved' }) =>
    api.patch<{ data: ClientPortalThread }>(`/admin/portal_threads/${id}`, data),
  markRead: (id: number) =>
    api.post<{ data: ClientPortalThread }>(`/admin/portal_threads/${id}/mark_read`),
  createMessage: (threadId: number, data: { body?: string; document_id?: number }) =>
    api.post<{ data: ClientPortalMessage }>(`/admin/portal_threads/${threadId}/messages`, data),
};

export const clientEmployeeChangeRequestsApi = {
  list: (params?: { status?: string; search?: string }) =>
    api.get<{ data: EmployeeChangeRequest[] }>('/client/employee_change_requests', params),
  get: (id: number) =>
    api.get<{ data: EmployeeChangeRequest }>(`/client/employee_change_requests/${id}`),
};

export const adminEmployeeChangeRequestsApi = {
  list: (params?: { status?: string }) =>
    api.get<{ data: EmployeeChangeRequest[] }>('/admin/employee_change_requests', params),
  get: (id: number) =>
    api.get<{ data: EmployeeChangeRequest }>(`/admin/employee_change_requests/${id}`),
  approve: (id: number, reviewNotes?: string) =>
    api.patch<{ data: EmployeeChangeRequest }>(`/admin/employee_change_requests/${id}/approve`, { review_notes: reviewNotes }),
  reject: (id: number, reviewNotes?: string) =>
    api.patch<{ data: EmployeeChangeRequest }>(`/admin/employee_change_requests/${id}/reject`, { review_notes: reviewNotes }),
};

export const form500Api = {
  defaults: (payPeriodId?: number) =>
    api.get<{ data: Form500Fields; saved_at?: string | null }>('/form_500s/defaults', { pay_period_id: payPeriodId }),
  save: (form: Form500Fields) =>
    api.post<{ data: Form500Fields; saved_at?: string | null }>('/form_500s/save', { form_500: form }),
  preview: (form: Form500Fields) =>
    api.postBlob('/form_500s/preview', { form_500: form }),
  download: (form: Form500Fields) =>
    api.postBlob('/form_500s/download', { form_500: form }),
};

// ============================================================
// Non-Employee Checks API
// ============================================================
export const nonEmployeeChecksApi = {
  list: (params?: {
    pay_period_id?: number;
    check_type?: string;
    active?: string;
    standalone?: string;
    payment_period_type?: string;
    tax_year?: number;
    tax_quarter?: number;
    tax_month?: number;
    from?: string;
    to?: string;
  }) =>
    api.get<{ non_employee_checks: NonEmployeeCheck[] }>('/admin/non_employee_checks', params),
  get: (id: number) =>
    api.get<{ non_employee_check: NonEmployeeCheck }>(`/admin/non_employee_checks/${id}`),
  create: (data: {
    pay_period_id?: number | null; payable_to: string; amount: number; check_type: string;
    memo?: string; description?: string; reference_number?: string; check_number?: string;
    payment_period_type?: string; tax_year?: number | null; tax_quarter?: number | null;
    tax_month?: number | null; due_date?: string | null; payment_date?: string | null;
    confirmation_number?: string | null;
    line_items_attributes?: Array<{
      description: string; reference_number?: string | null; service_period?: string | null;
      amount: number; position: number;
    }>;
  }) =>
    api.post<{ non_employee_check: NonEmployeeCheck }>('/admin/non_employee_checks', { non_employee_check: data }),
  update: (id: number, data: Partial<{
    pay_period_id: number | null; payable_to: string; amount: number; check_type: string;
    memo: string; description: string; reference_number: string;
    payment_period_type: string; tax_year: number | null; tax_quarter: number | null;
    tax_month: number | null; due_date: string | null; payment_date: string | null;
    confirmation_number: string | null;
    line_items_attributes: Array<{
      id?: number; description?: string; reference_number?: string | null;
      service_period?: string | null; amount?: number; position?: number; _destroy?: boolean;
    }>;
    // `check_number` is nullable so the modal can clear an existing one.
    // Sending `null` (or omitting the key) keeps the partial unique index
    // on (company_id, check_number) WHERE check_number IS NOT NULL from
    // tripping when multiple checks in the same company have no number.
    check_number: string | null;
  }>, reason?: string) =>
    api.patch<{ non_employee_check: NonEmployeeCheck }>(
      `/admin/non_employee_checks/${id}`,
      { non_employee_check: data, ...(reason ? { reason } : {}) }
    ),
  updateCheckNumber: (id: number, checkNumber: string | null, reason?: string) =>
    api.patch<{ non_employee_check: NonEmployeeCheck }>(
      `/admin/non_employee_checks/${id}`,
      {
        non_employee_check: { check_number: checkNumber },
        ...(reason ? { reason } : {}),
      }
    ),
  history: (id: number) =>
    api.get<{ history: import('@/types').NonEmployeeCheckEdit[] }>(`/admin/non_employee_checks/${id}/history`),
  delete: (id: number) =>
    api.delete<{ message: string }>(`/admin/non_employee_checks/${id}`),
  markPrinted: (id: number) =>
    api.post<{ non_employee_check: NonEmployeeCheck }>(`/admin/non_employee_checks/${id}/mark_printed`),
  voidCheck: (id: number, reason: string) =>
    api.post<{ non_employee_check: NonEmployeeCheck }>(`/admin/non_employee_checks/${id}/void_check`, { reason }),
  checkPdf: (id: number, options?: { startingSlot?: number }) =>
    api.getBlob(`/admin/non_employee_checks/${id}/check_pdf`, {
      starting_slot: options?.startingSlot,
    }),
  voucherPdf: (id: number) =>
    api.getBlob(`/admin/non_employee_checks/${id}/voucher_pdf`),
};

// ============================================================
// Payroll Reminder Config API
// ============================================================
export interface PayrollReminderConfig {
  id: number | null;
  enabled: boolean;
  recipients: string[];
  days_before_due: number;
  send_overdue_alerts: boolean;
  created_at: string | null;
  updated_at: string | null;
}

export interface PayrollReminderLog {
  id: number;
  reminder_type: string;
  sent_at: string;
  recipients_snapshot: string[];
  expected_pay_date: string | null;
  pay_period?: {
    id: number;
    start_date: string;
    end_date: string;
    pay_date: string;
    status: string;
  };
}

export const payrollReminderApi = {
  getConfig: () =>
    api.get<{ payroll_reminder_config: PayrollReminderConfig }>('/admin/payroll_reminder_config'),
  updateConfig: (config: Partial<PayrollReminderConfig>) =>
    api.put<{ payroll_reminder_config: PayrollReminderConfig }>('/admin/payroll_reminder_config', { payroll_reminder_config: config }),
  sendTest: () =>
    api.post<{ message: string }>('/admin/payroll_reminder_config/test'),
  getLogs: () =>
    api.get<{ logs: PayrollReminderLog[] }>('/admin/payroll_reminder_config/logs'),
};

// Legacy dashboard (for migration)
export const dashboardApi = {
  stats: (companyId: number) => api.get<DashboardStats>(`/companies/${companyId}/dashboard`),
};

// Auth
export const authApi = {
  me: () => api.get<{ user: AuthApiUser }>('/auth/me'),
  createCableTicket: () => api.post<{ ticket: string; expires_in: number }>('/cable_ticket'),
  login: (token: string) => {
    api.setAuthToken(token);
    return api.get<{ user: AuthApiUser }>('/auth/me');
  },
  logout: () => {
    api.setAuthToken(null);
    companiesApi.clearActiveCompanyId();
  },
};
