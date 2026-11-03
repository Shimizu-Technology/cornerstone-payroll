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
type Operation = { operation_id: number; status: 'queued' | 'completed' | 'failed'; result: HistoryApprovalSummary | null; error: string | null };

function pause(signal?: AbortSignal) {
  return new Promise<void>((resolve, reject) => {
    if (signal?.aborted) { reject(new DOMException('Aborted', 'AbortError')); return; }
    const abort = () => { clearTimeout(timer); reject(new DOMException('Aborted', 'AbortError')); };
    const timer = setTimeout(() => { signal?.removeEventListener('abort', abort); resolve(); }, 2000);
    signal?.addEventListener('abort', abort, { once: true });
  });
}

async function completed(sourceId: number, companyId: number, operation: Operation, signal?: AbortSignal): Promise<HistoryApprovalSummary> {
  while (operation.status === 'queued') {
    await pause(signal);
    // Only local operation state is polled, never AIRE. Hidden or unmounted
    // screens stop issuing reads; the durable worker keeps its transaction.
    if (typeof document !== 'undefined' && document.visibilityState === 'hidden') continue;
    operation = await api.get<Operation>(`/admin/time_tracking_sources/${sourceId}/history_approval/operations/${operation.operation_id}`, undefined, { companyId, signal });
  }
  if (signal?.aborted) throw new DOMException('Aborted', 'AbortError');
  if (operation.status === 'failed' || !operation.result) throw new Error(operation.error || 'History processing failed. Refresh the summary.');
  return operation.result;
}

export const aireHistoryApprovalApi = {
  preview: async (sourceId: number, companyId: number, mapping_selections: MappingSelection[] = [], signal?: AbortSignal) =>
    completed(sourceId, companyId, await api.post<Operation>(`/admin/time_tracking_sources/${sourceId}/history_approval/preview`, { mapping_selections, background: true }, { companyId }), signal),
  approve: async (sourceId: number, companyId: number, data: { review_id: number; digest: string; attestation: string; confirmed_mapping_uuids: string[]; solo_choices: { employee_id: number; employee_wage_rate_id: number }[] }, signal?: AbortSignal) =>
    completed(sourceId, companyId, await api.post<Operation>(`/admin/time_tracking_sources/${sourceId}/history_approval/approve`, { ...data, background: true }, { companyId }), signal),
};
