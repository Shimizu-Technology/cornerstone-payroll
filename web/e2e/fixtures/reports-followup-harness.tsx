import { createRoot } from 'react-dom/client';
import { MemoryRouter } from 'react-router';
import { ReportsDownloadPanel } from '@/components/reports/ReportsDownloadPanel';
import { AirePayrollRecordsDialog } from '@/components/payroll/AirePayrollRecordsDialog';

export function mountReportsDownloadPanelHarness(): void {
  const container = document.createElement('div');
  Object.assign(container.style, { position: 'fixed', inset: '0', zIndex: '200', overflow: 'auto', background: 'white', padding: '16px' });
  document.body.appendChild(container);
  createRoot(container).render(
    <MemoryRouter>
      <ReportsDownloadPanel payPeriodId={703} payPeriodStatus="committed" payDate="2026-05-01" />
    </MemoryRouter>,
  );
}

export function mountAireRecordsHarness(): void {
  const container = document.createElement('div');
  document.body.appendChild(container);
  createRoot(container).render(
    <AirePayrollRecordsDialog open onClose={() => undefined} records={[{
      id: 1,
      source_name: 'AIRE',
      source_active: false,
      external_batch_id: 'test-batch',
      external_batch_checksum: 'test-checksum',
      contract_version: '1',
      source_cutoff_at: '2026-04-30T20:00:00Z',
      applied_at: '2026-04-30T20:30:00Z',
      reconciled_at: null,
      source_processing_synced_at: null,
    }]} />,
  );
}
