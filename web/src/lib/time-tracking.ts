import type { TimeTrackingSource } from '@/services/api';

export function supportsSourceOperation(source: TimeTrackingSource | undefined | null, capability: string): boolean {
  if (!source) return false;
  if (source.supported_operations) return source.supported_operations.includes(capability);
  return source.source_type === 'aire_services' || Boolean(source.identity_verified && source.source_capabilities?.includes(capability));
}

