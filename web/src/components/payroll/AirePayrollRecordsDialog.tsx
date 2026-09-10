import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import type { AirePayrollRecord } from '@/types';
import { formatGuamDateTime } from '@/lib/utils';

function timestamp(value?: string | null) {
  return formatGuamDateTime(value);
}

export function AirePayrollRecordsDialog({ open, onClose, records }: {
  open: boolean;
  onClose: () => void;
  records: AirePayrollRecord[];
}) {
  return (
    <Dialog open={open} onOpenChange={(next) => { if (!next) onClose(); }}>
      <DialogContent className="dialog-wide">
        <DialogHeader><DialogTitle>Linked AIRE records</DialogTitle></DialogHeader>
        <p className="mb-4 text-sm text-neutral-600">Saved records for this payroll. Reviewing them does not contact AIRE or change payroll.</p>
        <div className="space-y-4">
          {records.map((record) => (
            <section key={record.id} className="rounded-xl border border-neutral-200 p-4">
              <h3 className="font-semibold text-neutral-950">{record.source_name} · {record.external_batch_id}</h3>
              <p className="mt-1 text-sm text-neutral-600">Integration {record.source_active ? 'enabled' : 'disabled'} for this client</p>
              <dl className="mt-4 grid gap-3 text-sm sm:grid-cols-2">
                <div><dt className="text-neutral-500">Source cutoff</dt><dd>{timestamp(record.source_cutoff_at)}</dd></div>
                <div><dt className="text-neutral-500">Imported</dt><dd>{timestamp(record.applied_at)}</dd></div>
                <div><dt className="text-neutral-500">Reconciled</dt><dd>{timestamp(record.reconciled_at)}</dd></div>
                <div><dt className="text-neutral-500">Last confirmed source status</dt><dd>{record.source_processing_status?.replaceAll('_', ' ') || 'Not yet confirmed'}</dd></div>
                <div><dt className="text-neutral-500">Status confirmed at</dt><dd>{timestamp(record.source_processing_synced_at)}</dd></div>
              </dl>
              {record.reconciliation_note && <p className="mt-4 whitespace-pre-wrap text-sm text-neutral-700">{record.reconciliation_note}</p>}
              {!!record.reconciliation_exceptions?.length && (
                <div className="mt-4 rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">
                  <h4 className="font-semibold">Recorded rounding differences</h4>
                  <ul className="mt-2 space-y-2">
                    {record.reconciliation_exceptions.map((exception, index) => (
                      <li key={index}>
                        <span className="font-medium">{exception.employee_name}</span>: AIRE regular {exception.aire_regular_hours} / overtime {exception.aire_overtime_hours} hours;
                        {' '}Cornerstone regular {exception.cornerstone_regular_hours} / overtime {exception.cornerstone_overtime_hours} hours.
                        {' '}Total difference: {exception.total_difference_hours} hours.
                      </li>
                    ))}
                  </ul>
                </div>
              )}
              <details className="mt-4 text-sm text-neutral-600">
                <summary className="cursor-pointer font-medium">Batch verification details</summary>
                <p className="mt-2">Contract version: {record.contract_version}</p>
                <p className="mt-1 break-all">Checksum: {record.external_batch_checksum}</p>
              </details>
            </section>
          ))}
        </div>
        <div className="mt-4 flex justify-end"><Button variant="outline" onClick={onClose}>Close</Button></div>
      </DialogContent>
    </Dialog>
  );
}
