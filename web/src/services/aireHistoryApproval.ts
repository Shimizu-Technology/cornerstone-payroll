import api from './api';

export type HistoryEntry = { id: string; employee: string | null; work_date: string; hours: string; disposition: string; approval_status: string | null; category: string | null };
export type EmployeeMatch = { source_user_uuid: string; source_name: string; employee_id: number | null; employee_name: string | null; existing: boolean; confirmation_required: boolean; options: { id: number; name: string }[] };
export type HistoryApprovalSummary = {
  review_id: number; digest: string; source_name: string; through_work_date: string; attestation: string;
  history_coverage_verified: boolean; approved_at: string | null; approved_by: string | null;
  mappings: EmployeeMatch[]; blockers: string[];
  dispositions: { type: string; label: string; count: number; hours: string }[];
  rounding_variances: { employee: string; employee_id: number; run_id: number; category: string; source_category: { name: string }; source_total: string; paid_total: string; signed_difference: string; within_limit: boolean }[];
  owed: HistoryEntry[]; pending_review: HistoryEntry[];
  solo_decisions: { employee_id: number | null; employee: string | null; hours: string; options: { id: number; label: string; rate: string }[] }[];
};
export type MappingSelection = { source_user_uuid: string; employee_id: number | null };
export const aireHistoryApprovalApi = {
  preview: (sourceId: number, companyId: number, mapping_selections: MappingSelection[] = []) =>
    api.post<HistoryApprovalSummary>(`/admin/time_tracking_sources/${sourceId}/history_approval/preview`, { mapping_selections }, { companyId }),
  approve: (sourceId: number, companyId: number, data: { review_id: number; digest: string; attestation: string; confirmed_mapping_uuids: string[]; solo_choices: { employee_id: number; employee_wage_rate_id: number }[] }) =>
    api.post<HistoryApprovalSummary>(`/admin/time_tracking_sources/${sourceId}/history_approval/approve`, data, { companyId }),
};
