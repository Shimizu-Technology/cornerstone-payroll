import { describe, expect, it } from 'vitest';
import type { AuditLogEntry } from '@/services/api';
import { auditBusinessFacts, displayAuditGroupAction, groupAuditEntries, meaningfulAuditChanges } from './audit-display';

function audit(overrides: Partial<AuditLogEntry> = {}): AuditLogEntry {
  return {
    id: 1,
    action: 'reports#payroll_register_pdf',
    display_action: 'Chelsey downloaded the payroll register for Sep 1 – 15, 2026',
    display_subject: 'Payroll Register · Sep 1 – 15, 2026',
    summary: '',
    record_type: 'reports',
    record_id: 18,
    user_id: 4,
    user_name: 'Chelsey',
    actor_email: 'chelsey@example.com',
    actor_role: 'accountant',
    event_category: 'export',
    subject_name: 'Sep 1 – 15, 2026',
    organization_id: 1,
    organization_name: 'Firm',
    company_id: 7,
    company_name: 'AIRE Services',
    metadata: { pay_period_id: 18, report_name: 'Payroll Register', report_format: 'PDF' },
    ip_address: '192.0.2.10',
    user_agent: 'Test browser',
    request_id: 'request-1',
    created_at: '2026-09-23T04:18:42Z',
    ...overrides,
  };
}

describe('audit display', () => {
  it('keeps real and redacted changes while dropping request-only fields', () => {
    const changes = meaningfulAuditChanges(audit({
      metadata: {
        changed_fields: ['hours.104', 'pay_rate', 'active', 'ssn'],
        before_values: { pay_rate: '18.00', active: false },
        after_values: { pay_rate: '20.00', active: true },
        redacted_fields: ['ssn'],
      },
    }));

    expect(changes.map((change) => change.field)).toEqual(['pay_rate', 'active', 'ssn']);
    expect(changes.find((change) => change.field === 'active')).toMatchObject({ before: false, after: true });
    expect(changes.find((change) => change.field === 'ssn')?.redacted).toBe(true);
  });

  it('groups only matching document access inside the inactivity window', () => {
    const second = audit({ id: 2, request_id: 'request-2', created_at: '2026-09-23T04:15:11Z' });
    const otherTarget = audit({ id: 3, record_id: 19, metadata: { pay_period_id: 19 }, created_at: '2026-09-23T04:14:50Z' });
    const old = audit({ id: 4, created_at: '2026-09-23T03:50:00Z' });

    const groups = groupAuditEntries([audit(), second, otherTarget, old]);

    expect(groups.map((group) => group.entries.map((entry) => entry.id))).toEqual([[1, 2], [3], [4]]);
    expect(displayAuditGroupAction(groups[0])).toContain('2 access records');
  });

  it('groups a short burst of similar legacy access while retaining every raw record', () => {
    const first = audit({ id: 20, record_id: null, metadata: {}, display_subject: 'Payroll Register' });
    const second = audit({ id: 21, record_id: null, metadata: {}, display_subject: 'Payroll Register' });

    const groups = groupAuditEntries([first, second]);

    expect(groups).toHaveLength(1);
    expect(groups[0].entries.map((entry) => entry.id)).toEqual([20, 21]);
  });

  it('never groups payroll lifecycle changes', () => {
    const first = audit({ id: 10, action: 'pay_periods#run_payroll', event_category: 'activity', record_type: 'pay_periods' });
    const second = audit({ id: 11, action: 'pay_periods#run_payroll', event_category: 'activity', record_type: 'pay_periods' });

    expect(groupAuditEntries([first, second])).toHaveLength(2);
  });

  it('does not treat report workflow mutations as document access', () => {
    const first = audit({ id: 30, action: 'reports#update_quarterly_compliance_packet_task', event_category: 'activity' });
    const second = audit({ id: 31, action: 'reports#update_quarterly_compliance_packet_task', event_category: 'activity' });

    expect(groupAuditEntries([first, second])).toHaveLength(2);
  });

  it('does not display NaN for malformed legacy payroll totals', () => {
    const facts = auditBusinessFacts(audit({
      metadata: { business_summary: { total_gross: 'not-a-number' } },
    }));

    expect(facts).toEqual([{ label: 'Gross payroll', value: 'not-a-number' }]);
  });
});
