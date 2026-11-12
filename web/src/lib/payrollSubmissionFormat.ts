import type { SubmissionStatus } from '@/services/payrollSubmissions';

export function formatGuam(value?: string | null): string {
  if (!value) return '';
  return new Date(value).toLocaleString('en-US', { timeZone: 'Pacific/Guam', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

export function formatDate(value?: string | null): string {
  if (!value) return '';
  return new Date(`${value}T00:00:00Z`).toLocaleDateString('en-US', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' });
}

export function statusVariant(status: SubmissionStatus): 'default' | 'success' | 'warning' | 'info' | 'danger' {
  if (status === 'paid' || status === 'approved') return 'success';
  if (status === 'changes_requested') return 'warning';
  if (status === 'waiting_for_files') return 'default';
  return 'info';
}
