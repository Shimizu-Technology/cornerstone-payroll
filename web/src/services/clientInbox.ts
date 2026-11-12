import api from './api';

export type InboxKind = 'message' | 'document' | 'employee_change' | 'payroll_submission' | 'file_request';
export type InboxRow = { id: number; key: string; company_id: number; company_name: string; sender_name?: string | null; kind: InboxKind; title: string; activity_at: string; unread: boolean; waiting: boolean; thread_id?: number; state?: string; state_label?: string };
export type InboxFilters = { company_id?: number; kind?: string; status?: string };
export type InboxCounts = { unread_count: number; waiting_count: number; unread_messages: number; unread_documents: number; pending_changes: number; waiting_payroll?: number; waiting_file_requests?: number };
export const clientInboxApi = {
  list: (params: InboxFilters & { cursor?: string; per_page?: number } = {}) => api.get<{ data: InboxRow[]; meta: { next_cursor: string | null; per_page: number } }>('/admin/client_inbox', params, { companyId: null }),
  counts: (params: InboxFilters = {}) => api.get<{ data: InboxCounts }>('/admin/client_inbox/counts', params, { companyId: null }),
};

// Refreshes replace the whole visible window; seek pages append by compound
// identity. A document and a conversation may have the same numeric id.
export function mergeInboxRows(current: InboxRow[], incoming: InboxRow[]): InboxRow[] {
  const rows = new Map(current.map(row => [row.key, row]));
  incoming.forEach(row => rows.set(row.key, row));
  return [...rows.values()];
}
