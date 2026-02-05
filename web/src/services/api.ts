// ========================================
// API Client for Cornerstone Payroll
// ========================================

const API_BASE_URL = import.meta.env.VITE_API_URL || 'http://localhost:3000/api/v1';

interface RequestOptions extends RequestInit {
  params?: Record<string, string | number | boolean | undefined>;
}

class ApiClient {
  private baseUrl: string;
  private authToken: string | null = null;

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl;
  }

  setAuthToken(token: string | null) {
    this.authToken = token;
  }

  getAuthToken(): string | null {
    return this.authToken;
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

    if (this.authToken) {
      (headers as Record<string, string>)['Authorization'] = `Bearer ${this.authToken}`;
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
        errorData.details
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

  async delete<T>(endpoint: string): Promise<T> {
    return this.request<T>(endpoint, { method: 'DELETE' });
  }
}

export class ApiError extends Error {
  status: number;
  details?: Record<string, string[]>;

  constructor(message: string, status: number, details?: Record<string, string[]>) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.details = details;
  }
}

// Create singleton instance
const api = new ApiClient(API_BASE_URL);

export default api;

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
};

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

// Dashboard
export const dashboardApi = {
  stats: (companyId: number) => api.get<DashboardStats>(`/companies/${companyId}/dashboard`),
};

// Auth
export const authApi = {
  login: (token: string) => {
    api.setAuthToken(token);
    return api.get<{ user: { id: number; email: string; role: string } }>('/auth/me');
  },
  logout: () => {
    api.setAuthToken(null);
  },
};
