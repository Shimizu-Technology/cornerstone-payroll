import { useCallback, useEffect, useMemo, useState } from 'react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { checksApi } from '@/services/api';
import type { CheckPrintQueueItem, CheckPrintQueueResponse, CheckPrintRun } from '@/types';
import { formatCurrency } from '@/lib/utils';

interface UnifiedCheckPrintDialogProps {
  open: boolean;
  payPeriodId: number;
  onOpenChange: (open: boolean) => void;
  onConfirmed: () => void;
}

type SourceFilter = 'all' | 'employee' | 'non_employee';
type StatusFilter = 'all' | 'unprinted' | 'printed';

function statusBadge(item: CheckPrintQueueItem) {
  if (item.status === 'voided') return <Badge variant="danger">Voided</Badge>;
  if (item.status === 'printed') return <Badge variant="success">Printed ×{item.print_count}</Badge>;
  return <Badge variant="warning">Unprinted</Badge>;
}

export function UnifiedCheckPrintDialog({ open, payPeriodId, onOpenChange, onConfirmed }: UnifiedCheckPrintDialogProps) {
  const [queue, setQueue] = useState<CheckPrintQueueResponse | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [sourceFilter, setSourceFilter] = useState<SourceFilter>('all');
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('unprinted');
  const [startingSlot, setStartingSlot] = useState(1);
  const [run, setRun] = useState<CheckPrintRun | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [artifactVerified, setArtifactVerified] = useState(false);
  const [loading, setLoading] = useState(false);
  const [action, setAction] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const revokePreview = useCallback(() => {
    setPreviewUrl((url) => {
      if (url) URL.revokeObjectURL(url);
      return null;
    });
  }, []);

  const loadQueue = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await checksApi.printQueue(payPeriodId);
      setQueue(data);
      setSelected(new Set(data.items.filter((item) => item.eligible && item.status === 'unprinted').map((item) => item.key)));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not load the check queue.');
    } finally {
      setLoading(false);
    }
  }, [payPeriodId]);

  useEffect(() => {
    if (!open) return;
    setRun(null);
    setArtifactVerified(false);
    revokePreview();
    void loadQueue();
  }, [open, loadQueue, revokePreview]);

  useEffect(() => () => revokePreview(), [revokePreview]);

  const visibleItems = useMemo(() => (queue?.items || []).filter((item) => {
    if (sourceFilter !== 'all' && item.kind !== sourceFilter) return false;
    if (statusFilter !== 'all' && item.status !== statusFilter) return false;
    return true;
  }), [queue, sourceFilter, statusFilter]);

  const selectedItems = useMemo(
    () => (queue?.items || []).filter((item) => selected.has(item.key)),
    [queue, selected]
  );
  const selectedTotal = selectedItems.reduce((sum, item) => sum + Number(item.amount), 0);
  const sheetCount = queue?.meta.check_stock_type === 'first_hawaiian_4up'
    ? Math.ceil((Math.max(1, startingSlot) - 1 + selectedItems.length) / 4)
    : selectedItems.length;

  const toggle = (item: CheckPrintQueueItem) => {
    if (!item.eligible || run) return;
    setSelected((current) => {
      const next = new Set(current);
      if (next.has(item.key)) next.delete(item.key); else next.add(item.key);
      return next;
    });
  };

  const selectVisible = () => setSelected((current) => {
    const next = new Set(current);
    visibleItems.filter((item) => item.eligible).forEach((item) => next.add(item.key));
    return next;
  });

  const loadPreview = async (printRun: CheckPrintRun) => {
    setAction('Loading and verifying the generated PDF…');
    setError(null);
    setArtifactVerified(false);
    try {
      const pdf = await checksApi.printRunPdf(printRun.id);
      revokePreview();
      setPreviewUrl(URL.createObjectURL(pdf.blob));
      setArtifactVerified(true);
    } catch (err) {
      setError(err instanceof Error
        ? `The package was generated, but its preview could not be loaded: ${err.message}`
        : 'The package was generated, but its preview could not be loaded. Retry before confirming it as printed.');
    } finally {
      setAction(null);
    }
  };

  const generate = async () => {
    if (selectedItems.length === 0) return;
    setAction('Generating an exact print package…');
    setError(null);
    try {
      const response = await checksApi.createPrintRun(payPeriodId, {
        payrollItemIds: selectedItems.filter((item) => item.source_type === 'payroll_item').map((item) => item.source_id),
        nonEmployeeCheckIds: selectedItems.filter((item) => item.source_type === 'non_employee_check').map((item) => item.source_id),
        startingSlot,
      });
      setRun(response.check_print_run);
      await loadPreview(response.check_print_run);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not generate the print package.');
    } finally {
      setAction(null);
    }
  };

  const download = async () => {
    if (!run) return;
    setAction('Preparing download…');
    setError(null);
    try {
      const result = await checksApi.printRunPdf(run.id, 'attachment');
      const url = URL.createObjectURL(result.blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = result.filename || run.filename;
      link.click();
      setArtifactVerified(true);
      setTimeout(() => URL.revokeObjectURL(url), 100);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not download the check package. Retry before confirming it as printed.');
    } finally {
      setAction(null);
    }
  };

  const print = () => {
    if (!previewUrl) return;
    const frame = document.createElement('iframe');
    frame.style.display = 'none';
    frame.src = previewUrl;
    frame.onload = () => frame.contentWindow?.print();
    document.body.appendChild(frame);
    setTimeout(() => frame.remove(), 60_000);
  };

  const confirm = async () => {
    if (!run || !artifactVerified || !window.confirm(`Confirm that all ${run.selected_count} selected checks printed correctly?`)) return;
    setAction('Recording print confirmation…');
    setError(null);
    try {
      await checksApi.confirmPrintRun(run.id);
      onConfirmed();
      await loadQueue();
      setRun((current) => current ? { ...current, status: 'confirmed', confirmed_at: new Date().toISOString() } : current);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not confirm the print run.');
    } finally {
      setAction(null);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="dialog-wide flex max-h-[92vh] flex-col overflow-hidden p-0">
        <DialogHeader className="border-b border-slate-200 bg-slate-950 px-6 py-5 text-white">
          <div className="flex items-start justify-between gap-4 pr-8">
            <div>
              <DialogTitle className="text-xl text-white">Print checks</DialogTitle>
              <DialogDescription className="mt-1 text-slate-300">
                Build one controlled package in check-number order, then confirm only after the paper is correct.
              </DialogDescription>
            </div>
            {queue && <div className="font-mono text-xs text-slate-300">{queue.meta.check_stock_type.replaceAll('_', ' ').toUpperCase()}</div>}
          </div>
        </DialogHeader>

        <div className="grid min-h-0 flex-1 lg:grid-cols-[minmax(0,1.25fr)_minmax(360px,0.75fr)]">
          <section className="min-h-0 overflow-y-auto border-r border-slate-200 p-5">
            <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
              <div className="flex flex-wrap gap-2">
                {(['all', 'employee', 'non_employee'] as SourceFilter[]).map((value) => (
                  <Button key={value} size="sm" variant={sourceFilter === value ? 'default' : 'outline'} onClick={() => setSourceFilter(value)}>
                    {value === 'all' ? 'All checks' : value === 'employee' ? 'Employees' : 'Non-employees'}
                  </Button>
                ))}
                <select className="rounded-md border border-slate-300 bg-white px-3 text-sm" value={statusFilter} onChange={(e) => setStatusFilter(e.target.value as StatusFilter)}>
                  <option value="unprinted">Unprinted</option><option value="printed">Printed</option><option value="all">All statuses</option>
                </select>
              </div>
              <div className="flex gap-2 text-xs">
                <button className="font-semibold text-blue-700" onClick={selectVisible}>Select visible</button>
                <span className="text-slate-300">/</span>
                <button className="font-semibold text-slate-600" onClick={() => setSelected(new Set())}>Clear</button>
              </div>
            </div>

            {loading ? <div className="py-16 text-center text-sm text-slate-500">Loading check queue…</div> : (
              <div className="overflow-hidden rounded-xl border border-slate-200">
                <table className="w-full text-left text-sm">
                  <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500"><tr><th className="w-10 p-3"/><th className="p-3">Check</th><th className="p-3">Payee</th><th className="p-3">Type</th><th className="p-3">Status</th><th className="p-3 text-right">Amount</th></tr></thead>
                  <tbody className="divide-y divide-slate-100">
                    {visibleItems.map((item) => (
                      <tr key={item.key} className={selected.has(item.key) ? 'bg-blue-50/70' : 'bg-white'}>
                        <td className="p-3"><input type="checkbox" checked={selected.has(item.key)} disabled={!item.eligible || Boolean(run)} onChange={() => toggle(item)} aria-label={`Select check ${item.check_number}`} /></td>
                        <td className="p-3 font-mono font-semibold text-slate-900">#{item.check_number}</td>
                        <td className="p-3"><div className="font-medium text-slate-900">{item.payee}</div>{item.disabled_reason && <div className="text-xs text-red-600">{item.disabled_reason}</div>}</td>
                        <td className="p-3 text-slate-600">{item.kind_label}</td>
                        <td className="p-3">{statusBadge(item)}</td>
                        <td className="p-3 text-right font-mono font-semibold">{formatCurrency(item.amount)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
                {visibleItems.length === 0 && <div className="p-10 text-center text-sm text-slate-500">No checks match these filters.</div>}
              </div>
            )}
          </section>

          <aside className="min-h-0 overflow-y-auto bg-slate-50 p-5">
            <div className="rounded-xl border border-slate-200 bg-white p-4">
              <div className="text-xs font-semibold uppercase tracking-[0.16em] text-slate-500">Package summary</div>
              <div className="mt-4 grid grid-cols-2 gap-3">
                <div><div className="text-xs text-slate-500">Selected</div><div className="text-2xl font-bold">{selectedItems.length}</div></div>
                <div><div className="text-xs text-slate-500">Total value</div><div className="text-xl font-bold">{formatCurrency(selectedTotal)}</div></div>
              </div>
              {queue?.meta.check_stock_type === 'first_hawaiian_4up' && !run && (
                <div className="mt-5 border-t border-slate-100 pt-4">
                  <div className="mb-2 text-sm font-semibold text-slate-800">First sheet starts at slot</div>
                  <div className="grid grid-cols-4 gap-2">{[1, 2, 3, 4].map((slot) => <button key={slot} onClick={() => setStartingSlot(slot)} className={`rounded-lg border py-3 font-mono font-bold ${startingSlot === slot ? 'border-blue-600 bg-blue-600 text-white' : 'border-slate-200 bg-white text-slate-700'}`}>{slot}</button>)}</div>
                  <p className="mt-2 text-xs text-slate-500">Estimated stock: {sheetCount} sheet{sheetCount === 1 ? '' : 's'}.</p>
                </div>
              )}
            </div>

            {run && (
              <div className="mt-4 overflow-hidden rounded-xl border border-slate-200 bg-white">
                <div className="flex items-center justify-between border-b border-slate-100 p-4"><div><div className="font-semibold">Generated package #{run.id}</div><div className="mt-1 font-mono text-xs text-slate-500">SHA-256 {run.sha256.slice(0, 16)}…</div></div><Badge variant={run.status === 'confirmed' ? 'success' : 'warning'}>{run.status === 'confirmed' ? 'Confirmed' : 'Awaiting confirmation'}</Badge></div>
                {previewUrl ? (
                  <iframe title="Check package preview" src={previewUrl} className="h-80 w-full bg-slate-900" />
                ) : (
                  <div className="border-b border-slate-100 px-4 py-8 text-center">
                    <p className="text-sm text-slate-600">Preview unavailable. Reload and verify the exact package before confirming it.</p>
                    <Button className="mt-3" size="sm" variant="outline" onClick={() => void loadPreview(run)} disabled={Boolean(action)}>Retry preview</Button>
                  </div>
                )}
                <div className="grid grid-cols-2 gap-2 p-4"><Button variant="outline" onClick={print} disabled={!previewUrl}>Print</Button><Button variant="outline" onClick={() => void download()}>Download</Button></div>
              </div>
            )}
            {error && <div className="mt-4 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700">{error}</div>}
            {action && <div className="mt-4 text-sm font-medium text-blue-700">{action}</div>}
          </aside>
        </div>

        <DialogFooter className="border-t border-slate-200 bg-white px-6 py-4">
          <Button variant="outline" onClick={() => onOpenChange(false)}>Close</Button>
          {!run && <Button onClick={() => void generate()} disabled={selectedItems.length === 0 || Boolean(action)}>Generate print package</Button>}
          {run && run.status !== 'confirmed' && <Button onClick={() => void confirm()} disabled={Boolean(action) || !artifactVerified} className="bg-emerald-700 hover:bg-emerald-800">Confirm printed correctly</Button>}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
