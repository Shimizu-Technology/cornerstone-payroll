import { createRoot } from 'react-dom/client';
import { FilingEvidencePanel } from '@/components/reports/FilingEvidencePanel';
import { reportsApi, type PayrollFilingRecord } from '@/services/api';

// Browser-only fictional transport. Request specs separately verify persistence.
export function mountFilingEvidenceHarness() {
  const records: Record<string, PayrollFilingRecord> = {};
  reportsApi.payrollFilingRecord = async (_type, _year, _quarter, _company, agency) => ({
    filing: records[agency!] || null,
    downloads: [{ id: 91, created_at: '2026-11-20T01:00:00Z', actor_name: 'Dana Example', sha256: 'b'.repeat(64) }],
  });
  reportsApi.recordPayrollFilingEvent = async (data) => {
    await new Promise((resolve) => setTimeout(resolve, 250));
    const agency = String(data.get('agency'));
    const type = String(data.get('event_type'));
    const previous = records[agency];
    const status = type === 'resubmitted' ? 'submitted' : type === 'correction_needed' ? 'needs_correction' : type;
    const record = {
      id: agency === 'ssa' ? 1 : 2, filing_type: 'w2_gu_w3_ss', display_name: 'W-2GU', agency,
      tax_year: 2026, quarter: null, status,
      submitted_at: previous?.submitted_at || String(data.get('occurred_at')),
      resolved_at: status === 'submitted' ? null : String(data.get('occurred_at')),
      confirmation_number: String(data.get('reference_number')),
      source_fingerprint: 'a'.repeat(64), current_source_fingerprint: 'a'.repeat(64), source_changed: false,
      events: [...(previous?.events || []), {
        id: (previous?.events.length || 0) + 1, event_type: type, from_status: previous?.status || null, to_status: status,
        occurred_at: String(data.get('occurred_at')), reference_number: String(data.get('reference_number')),
        preparer_name: String(data.get('preparer_name')), signer_name: null, signer_title: null, notes: String(data.get('notes')),
        source_fingerprint: 'a'.repeat(64), recorded_by: 'Dana Example', evidence_document: null,
        download_audit_id: type === 'submitted' || type === 'resubmitted' ? 91 : null,
        file_sha256: type === 'submitted' || type === 'resubmitted' ? 'b'.repeat(64) : null,
      }],
    } as PayrollFilingRecord;
    records[agency] = record;
    return { filing: record };
  };
  const container = document.createElement('main');
  Object.assign(container.style, { position: 'fixed', inset: '0', zIndex: '200', overflow: 'auto', background: 'white', padding: '16px' });
  document.body.appendChild(container);
  createRoot(container).render(<><h1>File and confirm · Fictional client</h1>{['ssa', 'drt'].map((agency) => <section key={agency} data-agency={agency}><FilingEvidencePanel filingType="w2_gu_w3_ss" taxYear={2026} companyId={3} agency={agency} preparationReady readinessMessage="Ready" /></section>)}</>);
}

export function mountConnectedFilingEvidenceHarness(companyId: number) {
  const container = document.createElement('main');
  Object.assign(container.style, { position: 'fixed', inset: '0', zIndex: '200', overflow: 'auto', background: 'white', padding: '16px' });
  document.body.appendChild(container);
  createRoot(container).render(<><h1>File and confirm · Fictional client (local API)</h1>{['ssa', 'drt'].map((agency) => <section key={agency} data-agency={agency}><FilingEvidencePanel filingType="w2_gu_w3_ss" taxYear={2026} companyId={companyId} agency={agency} preparationReady readinessMessage="Ready" /></section>)}</>);
}
