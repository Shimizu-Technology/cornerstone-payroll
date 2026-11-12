import type { BlobDownload, ClientDocument, ClientPortalMessage } from '@/services/api';
import type { ResourceActivityApi } from './ResourceActivity';

// The document endpoints both audiences already use. Preview and download go
// through the authorized API, which records each access in Activity History.
export type PortalDocumentsApi = ResourceActivityApi & {
  list: (params?: { search?: string; attachable?: boolean; page?: number; per_page?: number }) => Promise<{ data: ClientDocument[]; meta?: { total_pages?: number; current_page?: number; total_count?: number } }>;
  upload: (formData: FormData, companyId?: number) => Promise<{ data: ClientDocument[] }>;
  preview: (id: number) => Promise<BlobDownload>;
  download: (id: number) => Promise<BlobDownload>;
  opened: (id: number) => Promise<void>;
};

export function formatFileSize(bytes?: number | null): string {
  if (!bytes) return '';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function fileTypeLabel(fileName: string): string {
  const extension = fileName.split('.').pop()?.toUpperCase();
  return extension && extension !== fileName.toUpperCase() ? extension : 'File';
}

export async function saveDocument(api: PortalDocumentsApi, document: ClientDocument): Promise<void> {
  const file = await api.download(document.id);
  const url = URL.createObjectURL(file.blob);
  const link = window.document.createElement('a');
  link.href = url;
  link.download = file.filename || document.file_name;
  window.document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

export const CATEGORY_LABELS: Record<string, string> = {
  payroll_source: 'Payroll file or timesheet',
  employee_onboarding: 'New-hire form',
  tax_notice: 'Tax or agency notice',
  direct_deposit: 'Direct deposit form',
  identity: 'ID or work authorization',
  insurance: 'Insurance',
  filing_evidence: 'Filing record',
  payroll_review: 'Payroll review',
  misc: 'Other',
};

const STEP_TEXT: Record<string, (title: string) => string> = {
  file_response: title => `Sent a file for “${title}”`,
  file_request_accepted: title => `Accepted the file for “${title}”`,
  file_request_asked_again: title => `Asked again for “${title}”`,
  file_request_withdrawn: title => `Withdrew the request for “${title}”`,
};

export function stepLabel(message: ClientPortalMessage): string | null {
  if (!message.file_request || !message.kind || message.kind === 'message' || message.kind === 'file_request') return null;
  return STEP_TEXT[message.kind]?.(message.file_request.title) ?? null;
}
