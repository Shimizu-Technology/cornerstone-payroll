import type { TimeTrackingSource } from '@/services/api';

const legacyAireOperations = new Set([
  'time_summary_v1', 'finalized_batch_v2', 'payroll_calendar_v2', 'exact_line_receipts_v2',
  'employee_directory', 'payroll_cockpit', 'account_linking', 'manual_allocations', 'payment_attestations',
]);

export function supportsSourceOperation(source: TimeTrackingSource | undefined | null, capability: string): boolean {
  if (!source) return false;
  if (source.supported_operations) return source.supported_operations.includes(capability);
  if (source.source_type === 'aire_services') return legacyAireOperations.has(capability);
  return Boolean(source.identity_verified && source.source_protocol === 'shimizu_time_payroll' &&
    source.source_protocol_version === '1.0' && source.source_capabilities?.includes(capability));
}

