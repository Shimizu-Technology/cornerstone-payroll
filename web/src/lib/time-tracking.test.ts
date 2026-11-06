import { describe, expect, it } from 'vitest';
import { supportsSourceOperation } from './time-tracking';
import type { TimeTrackingSource } from '@/services/api';

const source = { id: 1, source_type: 'aire_services' } as TimeTrackingSource;

describe('time tracking operation availability', () => {
  it('uses explicit server support even when an AIRE operation was previously available', () => {
    expect(supportsSourceOperation({ ...source, supported_operations: [] }, 'finalized_batch_v2')).toBe(false);
  });
  it('preserves deployed AIRE operations without granting a new contract capability', () => {
    expect(supportsSourceOperation(source, 'account_linking')).toBe(true);
    expect(supportsSourceOperation(source, 'employee_period_evidence_v1')).toBe(false);
  });
  it('requires a verified supported protocol for custom operation discovery', () => {
    const custom = { ...source, source_type: 'custom', source_capabilities: ['account_linking'], identity_verified: true,
      source_protocol: 'shimizu_time_payroll', source_protocol_version: '1.0' } as TimeTrackingSource;
    expect(supportsSourceOperation(custom, 'account_linking')).toBe(true);
    expect(supportsSourceOperation({ ...custom, identity_verified: false }, 'account_linking')).toBe(false);
    expect(supportsSourceOperation({ ...custom, source_protocol_version: '2.0' }, 'account_linking')).toBe(false);
  });
});
