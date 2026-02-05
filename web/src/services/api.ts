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
  PaginatedResponse,
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

// Pay Periods
export const payPeriodsApi = {
  list: (companyId: number, params?: { status?: string; page?: number }) =>
    api.get<PaginatedResponse<PayPeriod>>(`/companies/${companyId}/pay_periods`, params),
  get: (companyId: number, id: number) =>
    api.get<PayPeriod>(`/companies/${companyId}/pay_periods/${id}`),
  create: (companyId: number, data: { start_date: string; end_date: string; pay_date: string }) =>
    api.post<PayPeriod>(`/companies/${companyId}/pay_periods`, { pay_period: data }),
  calculate: (companyId: number, id: number) =>
    api.post<PayPeriod>(`/companies/${companyId}/pay_periods/${id}/calculate`),
  approve: (companyId: number, id: number) =>
    api.post<PayPeriod>(`/companies/${companyId}/pay_periods/${id}/approve`),
  commit: (companyId: number, id: number) =>
    api.post<PayPeriod>(`/companies/${companyId}/pay_periods/${id}/commit`),
  delete: (companyId: number, id: number) =>
    api.delete<void>(`/companies/${companyId}/pay_periods/${id}`),
};

// Payroll Items
export const payrollItemsApi = {
  list: (companyId: number, payPeriodId: number) =>
    api.get<PayrollItem[]>(`/companies/${companyId}/pay_periods/${payPeriodId}/payroll_items`),
  get: (companyId: number, payPeriodId: number, id: number) =>
    api.get<PayrollItem>(`/companies/${companyId}/pay_periods/${payPeriodId}/payroll_items/${id}`),
  update: (companyId: number, payPeriodId: number, id: number, data: Partial<PayrollItem>) =>
    api.patch<PayrollItem>(`/companies/${companyId}/pay_periods/${payPeriodId}/payroll_items/${id}`, { payroll_item: data }),
  bulkCreate: (companyId: number, payPeriodId: number, data: { records: Partial<PayrollItem>[] }) =>
    api.post<PayrollItem[]>(`/companies/${companyId}/pay_periods/${payPeriodId}/payroll_items/bulk`, data),
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
