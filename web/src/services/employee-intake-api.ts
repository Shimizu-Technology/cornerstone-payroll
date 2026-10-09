import { apiClient } from '@/services/api';
import type { Employee } from '@/types';

export interface EmployeeIntakeSettings {
  enabled: boolean;
  expires_at: string | null;
  reason: string | null;
  enabled_by_name: string | null;
  can_manage: boolean;
}

export interface EmployeeIntakeException {
  reason: string;
  authorized_by_name: string | null;
  created_by_name: string | null;
  follow_up_owner_id: number | null;
  follow_up_owner_name: string | null;
  follow_up_due_on: string | null;
  payroll_eligible_from: string | null;
  payroll_setup_confirmed_at: string | null;
  payroll_setup_confirmed_by_name: string | null;
}

export interface EmployeeIntakeReadiness {
  profile_incomplete: boolean;
  missing_fields: string[];
  exception: EmployeeIntakeException | null;
}

export const employeeIntakeApi = {
  settings: (companyId: number, isClient = false): Promise<{ data: EmployeeIntakeSettings }> => apiClient.get<{ data: EmployeeIntakeSettings }>(
    `/${isClient ? 'client' : 'admin'}/employee_intake_settings`, undefined, { companyId },
  ),
  updateSettings: (companyId: number, employee_intake_settings: { enabled: boolean; reason?: string; expires_at?: string }): Promise<{ data: EmployeeIntakeSettings }> =>
    apiClient.patch<{ data: EmployeeIntakeSettings }>('/admin/employee_intake_settings', { employee_intake_settings }, { companyId }),
  updateException: (companyId: number, employeeId: number, intake_exception: {
    follow_up_due_on?: string;
    payroll_eligible_from?: string;
    confirm_payroll_setup?: boolean;
    acknowledge_default_withholding?: boolean;
    reason?: string;
  }): Promise<{ data: Employee }> => apiClient.patch<{ data: Employee }>(`/admin/employees/${employeeId}/intake_exception`, { intake_exception }, { companyId }),
};
