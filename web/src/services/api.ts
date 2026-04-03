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
  async getBlob(endpoint: string): Promise<Blob> {
    const token = await this.resolveAuthToken();
    const headers: Record<string, string> = {};
    if (token) headers['Authorization'] = `Bearer ${token}`;
    if (this.activeCompanyId) headers['X-Company-Id'] = String(this.activeCompanyId);

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
} from '@/types';

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
  create: (data: { email: string; name: string; role: User['role'] }) =>
    api.post<UserCreateResponse>('/admin/users', { user: data }),
  update: (id: number, data: Partial<Pick<User, 'name' | 'role' | 'active'>>) =>
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
  runPayroll: (id: number, data?: { employee_ids?: number[]; hours?: Record<string, RunPayrollHoursEntry> }) =>
    api.post<RunPayrollResponse>(`/admin/pay_periods/${id}/run_payroll`, data),
  approve: (id: number) =>
    api.post<PayPeriodResponse>(`/admin/pay_periods/${id}/approve`),
  unapprove: (id: number) =>
    api.post<PayPeriodResponse>(`/admin/pay_periods/${id}/unapprove`),
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

  // Timecard OCR import
  previewTimecardImport: async (id: number, csvFile: File) => {
    const formData = new FormData();
    formData.append('file', csvFile);
    return api.postForm<TimecardImportPreviewResponse>(`/admin/pay_periods/${id}/preview_timecard_import`, formData);
  },
  applyTimecardImport: (id: number, mappings: TimecardImportMapping[]) =>
    api.post<TimecardImportApplyResponse>(`/admin/pay_periods/${id}/apply_timecard_import`, { mappings }),
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
  applyToPayroll: (id: number, payPeriodId: number, employeeId?: number) =>
    api.post<ApplyToPayrollResponse>(`/admin/timecards/${id}/apply_to_payroll`, {
      pay_period_id: payPeriodId,
      ...(employeeId ? { employee_id: employeeId } : {}),
    }),
};

export const punchEntriesApi = {
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
  // 1099-NEC Annual Report
  form1099Nec: (year: number) =>
    api.get('/admin/reports/form_1099_nec', { year }),
  form1099NecPdf: (year: number) =>
    api.getBlobWithParams('/admin/reports/form_1099_nec_pdf', { year }),
  // Payroll parity reports
  payrollSummaryByEmployeePdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/payroll_summary_by_employee_pdf', { pay_period_id: payPeriodId }),
  deductionsContributionsPdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/deductions_contributions_pdf', { pay_period_id: payPeriodId }),
  paycheckHistoryPdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/paycheck_history_pdf', { pay_period_id: payPeriodId }),
  retirementPlansPdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/retirement_plans_pdf', { pay_period_id: payPeriodId }),
  installmentLoansPdf: (asOfDate?: string) =>
    api.getBlobWithParams('/admin/reports/installment_loans_pdf', { as_of_date: asOfDate }),
  transmittalLogPdf: (payPeriodId: number, options?: TransmittalOptions) =>
    api.postBlob('/admin/reports/transmittal_log_pdf', {
      pay_period_id: payPeriodId,
      preparer_name: options?.preparerName,
      notes: options?.notes,
      report_list: options?.reportList,
      check_number_first: options?.checkNumberFirst,
      check_number_last: options?.checkNumberLast,
      non_employee_check_numbers: options?.nonEmployeeCheckNumbers,
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
    }),
};

export interface TransmittalOptions {
  preparerName?: string;
  notes?: string[];
  reportList?: string[];
  checkNumberFirst?: string;
  checkNumberLast?: string;
  nonEmployeeCheckNumbers?: Record<number, string>;
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
}

export interface PersistedTransmittalState {
  id: number;
  pay_period_id: number;
  preparer_name?: string;
  notes: string[];
  report_list: string[];
  check_number_first?: string;
  check_number_last?: string;
  non_employee_check_numbers: Record<string, string>;
  updated_at: string;
  last_generated_at?: string;
}

export interface TransmittalStateResponse {
  transmittal_state: PersistedTransmittalState | null;
  defaults: {
    preparer_name?: string;
    notes: string[];
    report_list: string[];
    check_number_first?: string;
    check_number_last?: string;
    non_employee_check_numbers: Record<string, string>;
  };
}

export interface TransmittalVersionSummary {
  id: number;
  version_number: number;
  generated_at: string;
  generated_from: string;
  generated_by_id?: number;
  preparer_name?: string;
  notes_count: number;
  report_count: number;
  updated_check_range?: string;
}

export const transmittalApi = {
  preview: (payPeriodId: number): Promise<TransmittalPreview> =>
    api.get('/admin/reports/transmittal_preview', { pay_period_id: payPeriodId }),
  state: (payPeriodId: number): Promise<TransmittalStateResponse> =>
    api.get('/admin/reports/transmittal_state', { pay_period_id: payPeriodId }),
  saveState: (payPeriodId: number, options: TransmittalOptions): Promise<{ transmittal_state: PersistedTransmittalState }> =>
    api.patch('/admin/reports/transmittal_state', {
      pay_period_id: payPeriodId,
      preparer_name: options.preparerName,
      notes: options.notes ?? [],
      report_list: options.reportList ?? [],
      check_number_first: options.checkNumberFirst,
      check_number_last: options.checkNumberLast,
      non_employee_check_numbers: options.nonEmployeeCheckNumbers ?? {},
    }),
  versions: (payPeriodId: number): Promise<{ versions: TransmittalVersionSummary[] }> =>
    api.get('/admin/reports/transmittal_versions', { pay_period_id: payPeriodId }),
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

export const companiesApi = {
  list: (params?: { active?: boolean }) => {
    const query = params?.active !== undefined ? `?active=${params.active}` : '';
    return api.get<{ companies: CompanyListItem[]; is_super_admin: boolean; can_switch_company: boolean; current_company_id: number }>(`/admin/companies${query}`);
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
  deductionsContributionsPdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/deductions_contributions_pdf', { pay_period_id: payPeriodId }),
  paycheckHistoryPdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/paycheck_history_pdf', { pay_period_id: payPeriodId }),
  retirementPlansPdf: (payPeriodId: number) =>
    api.getBlobWithParams('/admin/reports/retirement_plans_pdf', { pay_period_id: payPeriodId }),
  installmentLoansPdf: (asOfDate?: string) =>
    api.getBlobWithParams('/admin/reports/installment_loans_pdf', { as_of_date: asOfDate }),
  transmittalLogPdf: (payPeriodId: number, options?: TransmittalOptions) =>
    api.postBlob('/admin/reports/transmittal_log_pdf', {
      pay_period_id: payPeriodId,
      preparer_name: options?.preparerName,
      notes: options?.notes,
      report_list: options?.reportList,
      check_number_first: options?.checkNumberFirst,
      check_number_last: options?.checkNumberLast,
      non_employee_check_numbers: options?.nonEmployeeCheckNumbers,
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

// ============================================================
// Non-Employee Checks API
// ============================================================
export const nonEmployeeChecksApi = {
  list: (params?: { pay_period_id?: number; check_type?: string; active?: string }) =>
    api.get<{ non_employee_checks: NonEmployeeCheck[] }>('/admin/non_employee_checks', params),
  get: (id: number) =>
    api.get<{ non_employee_check: NonEmployeeCheck }>(`/admin/non_employee_checks/${id}`),
  create: (data: {
    pay_period_id: number; payable_to: string; amount: number; check_type: string;
    memo?: string; description?: string; reference_number?: string; check_number?: string;
  }) =>
    api.post<{ non_employee_check: NonEmployeeCheck }>('/admin/non_employee_checks', { non_employee_check: data }),
  update: (id: number, data: Partial<{
    payable_to: string; amount: number; check_type: string;
    memo: string; description: string; reference_number: string;
  }>) =>
    api.patch<{ non_employee_check: NonEmployeeCheck }>(`/admin/non_employee_checks/${id}`, { non_employee_check: data }),
  delete: (id: number) =>
    api.delete<{ message: string }>(`/admin/non_employee_checks/${id}`),
  markPrinted: (id: number) =>
    api.post<{ non_employee_check: NonEmployeeCheck }>(`/admin/non_employee_checks/${id}/mark_printed`),
  voidCheck: (id: number, reason: string) =>
    api.post<{ non_employee_check: NonEmployeeCheck }>(`/admin/non_employee_checks/${id}/void_check`, { reason }),
  checkPdf: (id: number) =>
    api.getBlob(`/admin/non_employee_checks/${id}/check_pdf`),
};

// Legacy dashboard (for migration)
export const dashboardApi = {
  stats: (companyId: number) => api.get<DashboardStats>(`/companies/${companyId}/dashboard`),
};

// Auth
export const authApi = {
  me: () => api.get<{ user: { id: number; email: string; name: string; role: string; company_id: number; company_name: string; super_admin: boolean; home_company_id: number } }>('/auth/me'),
  login: (token: string) => {
    api.setAuthToken(token);
    return api.get<{ user: { id: number; email: string; name: string; role: string; company_id: number; company_name: string; super_admin: boolean; home_company_id: number } }>('/auth/me');
  },
  logout: () => {
    api.setAuthToken(null);
  },
};
