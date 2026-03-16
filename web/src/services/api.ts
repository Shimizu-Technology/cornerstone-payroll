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

class ApiClient {
  private baseUrl: string;
  private authToken: string | null = null;
  private authTokenProvider: (() => Promise<string | null>) | null = null;

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl;
  }

  setAuthToken(token: string | null) {
    this.authToken = token;
  }

  setAuthTokenProvider(provider: (() => Promise<string | null>) | null) {
    this.authTokenProvider = provider;
  }

  getAuthToken(): string | null {
    return this.authToken;
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
  async getBlob(endpoint: string): Promise<Blob> {
    const token = await this.resolveAuthToken();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;

    const response = await fetch(this.buildUrl(endpoint), {
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

  // GET raw Blob with query params (for authenticated file downloads with year/filters)
  async getBlobWithParams(
    endpoint: string,
    params?: Record<string, string | number | boolean | undefined>
  ): Promise<BlobDownload> {
    const token = await this.resolveAuthToken();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;

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

    const contentDisposition = response.headers.get('content-disposition') || '';
    const match = contentDisposition.match(/filename\*?=(?:UTF-8''|")?([^";]+)/i);
    const filename = match ? decodeURIComponent(match[1].replace(/"/g, '').trim()) : undefined;

    return { blob: await response.blob(), filename };
  }

  // CPR-66: Post and receive a raw Blob (for PDF download)
  async postBlob(endpoint: string, data?: unknown): Promise<Blob> {
    const token = await this.resolveAuthToken();
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = `Bearer ${token}`;

    const response = await fetch(this.buildUrl(endpoint), {
      method: 'POST',
      headers,
      body: data ? JSON.stringify(data) : undefined,
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

// ========================================
// API Endpoints
// ========================================

import type {
  Company,
  Department,
  Employee,
  EmployeeFormData,
  PayPeriod,
  PayrollItem,
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
} from '@/types';

// Companies
export const companiesApi = {
  list: () => api.get<Company[]>('/companies'),
  get: (id: number) => api.get<Company>(`/companies/${id}`),
  create: (data: Partial<Company>) => api.post<Company>('/companies', { company: data }),
  update: (id: number, data: Partial<Company>) => api.patch<Company>(`/companies/${id}`, { company: data }),
  delete: (id: number) => api.delete<void>(`/companies/${id}`),
};

// Employees (Admin API)
export const employeesApi = {
  list: (params?: { 
    company_id?: number; 
    status?: string; 
    department_id?: number;
    search?: string;
    page?: number; 
    per_page?: number;
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

// Users (Admin API)
export const usersApi = {
  list: (params?: { search?: string }) =>
    api.get<{ data: User[] }>('/admin/users', params),
  get: (id: number) =>
    api.get<{ data: User }>(`/admin/users/${id}`),
  create: (data: { email: string; name: string; role: User['role'] }) =>
    api.post<{ data: User }>('/admin/users', { user: data }),
  update: (id: number, data: Partial<Pick<User, 'name' | 'role' | 'active'>>) =>
    api.patch<{ data: User }>(`/admin/users/${id}`, { user: data }),
  activate: (id: number) =>
    api.post<{ data: User }>(`/admin/users/${id}/activate`),
  deactivate: (id: number) =>
    api.post<{ data: User }>(`/admin/users/${id}/deactivate`),
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
    action?: string;
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
  runPayroll: (id: number, data?: { employee_ids?: number[]; hours?: Record<string, { regular?: number; overtime?: number; holiday?: number; pto?: number }> }) =>
    api.post<RunPayrollResponse>(`/admin/pay_periods/${id}/run_payroll`, data),
  approve: (id: number) =>
    api.post<PayPeriodResponse>(`/admin/pay_periods/${id}/approve`),
  commit: (id: number) =>
    api.post<PayPeriodResponse>(`/admin/pay_periods/${id}/commit`),
  retryTaxSync: (id: number) =>
    api.post<PayPeriodResponse>(`/admin/pay_periods/${id}/retry_tax_sync`),
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
  update: (payPeriodId: number, id: number, data: Partial<PayrollItem> & { auto_calculate?: boolean }) =>
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
    employees: PayrollItem[];
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
    company_totals: {
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
  employeePayHistory: (employeeId: number, limit?: number) =>
    api.get<{ report: { employee: Employee; history: PayrollItem[]; ytd: Record<string, number> } }>('/admin/reports/employee_pay_history', { employee_id: employeeId, limit }),
  taxSummary: (year?: number, quarter?: number) =>
    api.get<TaxSummaryReport>('/admin/reports/tax_summary', { year, quarter }),
  // CPR-70: Tax Summary exports
  taxSummaryCsv: (year: number, quarter?: number) =>
    api.getBlobWithParams('/admin/reports/tax_summary_csv', { year, quarter }),
  taxSummaryPdf: (year: number, quarter?: number) =>
    api.getBlobWithParams('/admin/reports/tax_summary_pdf', { year, quarter }),
  ytdSummary: (year?: number) =>
    api.get<YtdSummaryReport>('/admin/reports/ytd_summary', { year }),
  // CPR-68: W-2GU Annual Report
  w2Gu: (year: number) =>
    api.get<W2GuReportResponse>('/admin/reports/w2_gu', { year }),
  w2GuCsv: (year: number) =>
    api.getBlobWithParams('/admin/reports/w2_gu_csv', { year }),
  w2GuPdf: (year: number) =>
    api.getBlobWithParams('/admin/reports/w2_gu_pdf', { year }),
  // CPR-74: W-2 filing operationalization
  w2GuPreflight: (year: number) =>
    api.post<W2GuPreflightResponse>('/admin/reports/w2_gu_preflight', { year }),
  w2GuFilingReadiness: (year: number) =>
    api.get<W2GuFilingReadinessResponse>('/admin/reports/w2_gu_filing_readiness', { year }),
  w2GuMarkReady: (year: number, notes?: string) =>
    api.post<W2GuMarkReadyResponse>('/admin/reports/w2_gu_mark_ready', { year, notes }),
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
  batchPdf: (payPeriodId: number) =>
    api.postBlob(`/admin/pay_periods/${payPeriodId}/checks/batch_pdf`),

  // Mark all unprinted checks in a period as printed
  markAllPrinted: (payPeriodId: number) =>
    api.post<{ marked_printed: number }>(`/admin/pay_periods/${payPeriodId}/checks/mark_all_printed`),

  // Download a single check PDF through authenticated API client
  checkPdf: (payrollItemId: number) =>
    api.getBlob(`/admin/payroll_items/${payrollItemId}/check`),

  // Mark a single check as printed
  markPrinted: (payrollItemId: number) =>
    api.post<{ payroll_item: CheckItem; already_printed: boolean }>(`/admin/payroll_items/${payrollItemId}/check/mark_printed`),

  // Void a check
  void: (payrollItemId: number, reason: string) =>
    api.post<{ payroll_item: CheckItem }>(`/admin/payroll_items/${payrollItemId}/void`, { reason }),

  // Reprint a check (in-place reassignment)
  reprint: (payrollItemId: number, reason?: string) =>
    api.post<{ original_check_number: string; reprint: CheckItem }>(`/admin/payroll_items/${payrollItemId}/reprint`, { reason }),

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

// Legacy dashboard (for migration)
export const dashboardApi = {
  stats: (companyId: number) => api.get<DashboardStats>(`/companies/${companyId}/dashboard`),
};

// Auth
export const authApi = {
  me: () => api.get<{ user: { id: number; email: string; name: string; role: string; company_id: number; company_name: string } }>('/auth/me'),
  login: (token: string) => {
    api.setAuthToken(token);
    return api.get<{ user: { id: number; email: string; name: string; role: string; company_id: number; company_name: string } }>('/auth/me');
  },
  logout: () => {
    api.setAuthToken(null);
  },
};
