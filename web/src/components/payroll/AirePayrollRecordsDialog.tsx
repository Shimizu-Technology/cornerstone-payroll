import { X } from 'lucide-react';
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
        <DialogHeader className="flex-row items-start justify-between space-y-0 text-left">
          <div>
            <DialogTitle>Linked time tracking records</DialogTitle>
            <p className="mt-1 text-sm text-neutral-600">Saved records for this payroll. Reviewing them does not contact time tracking or change payroll.</p>
          </div>
          <button type="button" onClick={onClose} aria-label="Close linked time tracking records" className="-mr-2 -mt-2 rounded-full p-2 text-neutral-500 transition hover:bg-neutral-100 hover:text-neutral-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-300">
            <X className="h-5 w-5" aria-hidden="true" />
          </button>
        </DialogHeader>
        <div className="mt-4 space-y-4">
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
              {record.payable_line_status && (
                <div className="mt-4 rounded-xl border border-neutral-200 bg-neutral-50 p-4">
                  <h4 className="font-semibold text-neutral-950">Exact payable-line status</h4>
                  <p className="mt-1 text-xs leading-5 text-neutral-600">Payment status comes from saved check delivery or deposit settlement events. Preparing or printing a check remains pending.</p>
                  <div className="mt-4 grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
                    {([
                      ['In payroll', record.payable_line_status.in_payroll],
                      ['Prepared', record.payable_line_status.payment_pending],
                      ['Paid', record.payable_line_status.paid],
                      ['Attention', record.payable_line_status.needs_attention],
                    ] as const).map(([label, bucket]) => (
                      <div key={label} className="rounded-lg border border-neutral-200 bg-white p-3">
                        <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">{label}</p>
                        <p className="mt-2 font-semibold text-neutral-950">{Number(bucket.total_hours).toFixed(2)} hrs</p>
                        <p className="mt-1 text-xs text-neutral-500">{bucket.line_count} line{bucket.line_count === 1 ? '' : 's'}</p>
                      </div>
                    ))}
                  </div>
                  <p className="mt-3 text-xs text-neutral-600">
                    Held for later: {Number(record.payable_line_status.held.total_hours).toFixed(2)} hrs across {record.payable_line_status.held.entry_count} entr{record.payable_line_status.held.entry_count === 1 ? 'y' : 'ies'}.
                  </p>
                  {record.payable_line_status.synchronization.failed_event_count > 0 && (
                    <p className="mt-2 text-xs font-medium text-danger-700">
                      {record.payable_line_status.synchronization.failed_event_count} time tracking status update{record.payable_line_status.synchronization.failed_event_count === 1 ? ' is' : 's are'} retrying after a delivery error.
                    </p>
                  )}
                </div>
              )}
              {record.reconciliation_note && <p className="mt-4 whitespace-pre-wrap text-sm text-neutral-700">{record.reconciliation_note}</p>}
              {!!record.reconciliation_exceptions?.length && (
                <div className="mt-4 rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">
                  <h4 className="font-semibold">Recorded rounding differences</h4>
                  <ul className="mt-2 space-y-2">
                    {record.reconciliation_exceptions.map((exception, index) => (
                      <li key={index}>
                        <span className="font-medium">{exception.employee_name}</span>: time tracking regular {exception.aire_regular_hours} / overtime {exception.aire_overtime_hours} hours;
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
