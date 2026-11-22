import { apiClient } from '@/services/api';

export const EMPLOYEE_NOTE_MAX_LENGTH = 2000;
export const EMPLOYEE_NOTE_HIDE_REASON_MAX_LENGTH = 500;

export interface EmployeeNote {
  id: number;
  company_id: number;
  employee_id: number;
  body: string;
  created_by_id: number;
  created_by_name: string;
  created_at: string;
  hidden: boolean;
  hidden_at: string | null;
  hidden_by_id: number | null;
  hidden_by_name: string | null;
  hidden_reason: string | null;
}

export const employeeNotesApi = {
  list: (companyId: number, employeeId: number): Promise<{ data: EmployeeNote[] }> =>
    apiClient.get<{ data: EmployeeNote[] }>(`/admin/employees/${employeeId}/notes`, undefined, { companyId }),

  create: (companyId: number, employeeId: number, body: string): Promise<{ data: EmployeeNote }> =>
    apiClient.post<{ data: EmployeeNote }>(
      `/admin/employees/${employeeId}/notes`,
      { note: { body } },
      { companyId },
    ),

  hide: (companyId: number, employeeId: number, noteId: number, reason: string): Promise<{ data: EmployeeNote }> =>
    apiClient.patch<{ data: EmployeeNote }>(
      `/admin/employees/${employeeId}/notes/${noteId}/hide`,
      { note: { reason } },
      { companyId },
    ),
};
