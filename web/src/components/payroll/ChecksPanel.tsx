/**
 * CPR-66: ChecksPanel
 * Shows all checks for a committed pay period with print/void/reprint controls.
 */
import { useState, useEffect, useCallback } from 'react';
import { createPortal } from 'react-dom';
import type { CheckItem, CheckListMeta, PayPeriod } from '@/types';
import { checksApi } from '@/services/api';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { VoidCheckModal } from './VoidCheckModal';
import { ReprintCheckModal } from './ReprintCheckModal';

interface ChecksPanelProps {
  payPeriod: PayPeriod;
  searchTerm?: string;
}

type CheckAction = 'preview' | 'saveCheckNumber' | 'markPrinted';

function checkStatusBadge(item: CheckItem) {
  if (item.voided) return <Badge variant="danger">Voided</Badge>;
  if (item.check_printed_at)
    return (
      <Badge variant="success">
        Printed{item.check_print_count > 1 ? ` (×${item.check_print_count})` : ''}
      </Badge>
    );
  if (item.check_number) return <Badge variant="warning">Unprinted</Badge>;
  return <Badge variant="default">No Check</Badge>;
}

function formatCurrency(amount: number) {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(amount);
}

export function ChecksPanel({ payPeriod, searchTerm = '' }: ChecksPanelProps) {
  const [checks, setChecks] = useState<CheckItem[]>([]);
  const [meta, setMeta] = useState<CheckListMeta | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actionLoading, setActionLoading] = useState<{ id: number; action: CheckAction } | null>(null);
  const [batchLoading, setBatchLoading] = useState(false);
  const [batchAction, setBatchAction] = useState<string | null>(null);
  const [startingSlot, setStartingSlot] = useState(1);
  const [editingCheckId, setEditingCheckId] = useState<number | null>(null);
  const [draftCheckNumber, setDraftCheckNumber] = useState('');
  const [checkNumberError, setCheckNumberError] = useState<string | null>(null);

  // Modal state
  const [voidTarget, setVoidTarget] = useState<CheckItem | null>(null);
  const [reprintTarget, setReprintTarget] = useState<CheckItem | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [previewItem, setPreviewItem] = useState<CheckItem | null>(null);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const data = await checksApi.list(payPeriod.id);
      setChecks(data.checks);
      setMeta(data.meta);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load checks');
    } finally {
      setLoading(false);
    }
  }, [payPeriod.id]);

  useEffect(() => { load(); }, [load]);

  const isActionLoading = (id: number, action: CheckAction) =>
    actionLoading?.id === id && actionLoading.action === action;

  // ---- Batch PDF download ----
  const handleBatchDownload = async () => {
    setBatchLoading(true);
    setBatchAction('Generating PDF...');
    try {
      const result = await checksApi.batchPdf(payPeriod.id, isFirstHawaiian4Up ? { startingSlot } : undefined);
      setBatchAction('Downloading...');
      const url = URL.createObjectURL(result.blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = result.filename || `checks_${payPeriod.pay_date ?? 'undated'}_batch.pdf`;
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 100);
    } catch (err) {
      alert(err instanceof Error ? err.message : 'Failed to download PDF');
    } finally {
      setBatchLoading(false);
      setBatchAction(null);
    }
  };

  // ---- Mark all printed ----
  const handleMarkAllPrinted = async () => {
    if (!window.confirm('Mark all unprinted checks as printed?')) return;
    setBatchLoading(true);
    setBatchAction('Marking as printed...');
    try {
      const result = await checksApi.markAllPrinted(payPeriod.id);
      await load();
      if (result.marked_printed > 0) {
        alert(`${result.marked_printed} check(s) marked as printed.`);
      }
    } catch (err) {
      alert(err instanceof Error ? err.message : 'Failed to mark checks as printed');
    } finally {
      setBatchLoading(false);
      setBatchAction(null);
    }
  };

  // ---- Preview single check PDF ----
  const handlePreviewPdf = async (item: CheckItem) => {
    setActionLoading({ id: item.id, action: 'preview' });
    try {
      const blob = await checksApi.checkPdf(item.id, isFirstHawaiian4Up ? { startingSlot } : undefined);
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      const url = URL.createObjectURL(blob);
      setPreviewUrl(url);
      setPreviewItem(item);
    } catch (err) {
      alert(err instanceof Error ? err.message : 'Failed to load check PDF');
    } finally {
      setActionLoading(null);
    }
  };

  const handleClosePreview = () => {
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    setPreviewUrl(null);
    setPreviewItem(null);
  };

  const handleDownloadFromPreview = () => {
    if (!previewUrl || !previewItem) return;
    const a = document.createElement('a');
    a.href = previewUrl;
    a.download = `check_${previewItem.check_number || previewItem.id}.pdf`;
    a.click();
  };

  const handlePrintFromPreview = () => {
    if (!previewUrl) return;
    const printWindow = window.open(previewUrl);
    if (printWindow) {
      printWindow.addEventListener('load', () => {
        printWindow.print();
      });
    } else {
      alert('Pop-up blocked. Please allow pop-ups for this site to print checks.');
    }
  };

  const handlePrintAll = async () => {
    setBatchLoading(true);
    setBatchAction('Generating checks for printing...');
    try {
      const result = await checksApi.batchPdf(payPeriod.id, isFirstHawaiian4Up ? { startingSlot } : undefined);
      setBatchAction('Opening print dialog...');
      const url = URL.createObjectURL(result.blob);
      const printWindow = window.open(url);
      if (printWindow) {
        printWindow.addEventListener('load', () => {
          printWindow.print();
          setTimeout(() => URL.revokeObjectURL(url), 60000);
        });
      } else {
        URL.revokeObjectURL(url);
        alert('Pop-up blocked. Please allow pop-ups for this site to print checks.');
      }
    } catch (err) {
      alert(err instanceof Error ? err.message : 'Failed to generate PDF for printing');
    } finally {
      setBatchLoading(false);
      setBatchAction(null);
    }
  };

  const startCheckNumberEdit = (item: CheckItem) => {
    setEditingCheckId(item.id);
    setDraftCheckNumber(item.check_number || '');
    setCheckNumberError(null);
  };

  const cancelCheckNumberEdit = () => {
    setEditingCheckId(null);
    setDraftCheckNumber('');
    setCheckNumberError(null);
  };

  const handleSaveCheckNumber = async (item: CheckItem) => {
    const nextNumber = draftCheckNumber.trim();
    if (!nextNumber) {
      setCheckNumberError('Enter a check number.');
      return;
    }
    if (!/^\d+$/.test(nextNumber)) {
      setCheckNumberError('Check number must be numeric.');
      return;
    }
    if (nextNumber === item.check_number) {
      cancelCheckNumberEdit();
      return;
    }

    setActionLoading({ id: item.id, action: 'saveCheckNumber' });
    setCheckNumberError(null);
    try {
      const result = await checksApi.updateCheckNumber(
        item.id,
        nextNumber,
        'Corrected from the pay period Checks section'
      );
      setChecks((current) =>
        current.map((check) => (check.id === item.id ? result.payroll_item : check))
      );
      setPreviewItem((current) =>
        current?.id === item.id ? result.payroll_item : current
      );
      cancelCheckNumberEdit();
    } catch (err) {
      setCheckNumberError(err instanceof Error ? err.message : 'Failed to update check number');
    } finally {
      setActionLoading(null);
    }
  };

  // ---- Mark single printed ----
  const handleMarkPrinted = async (item: CheckItem) => {
    setActionLoading({ id: item.id, action: 'markPrinted' });
    try {
      const result = await checksApi.markPrinted(item.id);
      if (result.already_printed) {
        alert('This check was already marked as printed. Print count incremented.');
      }
      await load();
    } catch (err) {
      alert(err instanceof Error ? err.message : 'Failed to mark check as printed');
    } finally {
      setActionLoading(null);
    }
  };

  // ---- Void complete callback ----
  const handleVoidComplete = async () => {
    setVoidTarget(null);
    await load();
  };

  // ---- Reprint complete callback ----
  const handleReprintComplete = async () => {
    setReprintTarget(null);
    await load();
  };

  if (payPeriod.status !== 'committed') {
    return (
      <div className="p-4 bg-yellow-50 border border-yellow-200 rounded-lg text-sm text-yellow-800">
        Check printing is only available for committed pay periods.
      </div>
    );
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center py-8 text-gray-500 text-sm">
        Loading checks…
      </div>
    );
  }

  if (error) {
    return (
      <div className="p-4 bg-red-50 border border-red-200 rounded-lg text-sm text-red-800">
        {error}
        <button className="ml-2 underline" onClick={load}>Retry</button>
      </div>
    );
  }

  const unprintedCount = meta?.unprinted ?? 0;
  const isFirstHawaiian4Up = meta?.check_stock_type === 'first_hawaiian_4up';
  const normalizedSearch = searchTerm.trim().toLowerCase();
  const filteredChecks = normalizedSearch
    ? checks.filter((item) => {
        const statusLabel = item.voided
          ? 'voided'
          : item.check_printed_at
          ? 'printed'
          : item.check_number
          ? 'unprinted'
          : 'no check';

        return [
          item.employee_name,
          item.check_number,
          statusLabel,
        ].some((value) => value?.toLowerCase().includes(normalizedSearch));
      })
    : checks;

  return (
    <div className="space-y-4">
      {/* Header + batch actions */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex gap-4 text-sm text-gray-600">
          {meta && (
            <>
              <span><span className="font-medium text-gray-900">{meta.total}</span> total</span>
              <span><span className="font-medium text-yellow-700">{meta.unprinted}</span> unprinted</span>
              <span><span className="font-medium text-green-700">{meta.printed}</span> printed</span>
              {meta.voided > 0 && (
                <span><span className="font-medium text-red-700">{meta.voided}</span> voided</span>
              )}
            </>
          )}
          {normalizedSearch && (
            <span>
              Showing <span className="font-medium text-gray-900">{filteredChecks.length}</span> of{' '}
              <span className="font-medium text-gray-900">{checks.length}</span>
            </span>
          )}
        </div>

        <div className="flex gap-2 items-center">
          {isFirstHawaiian4Up && (
            <label className="flex items-center gap-2 text-sm text-gray-600">
              Start slot
              <select
                className="rounded border border-gray-300 bg-white px-2 py-1 text-sm"
                value={startingSlot}
                onChange={(e) => setStartingSlot(Number(e.target.value))}
                disabled={batchLoading}
              >
                <option value={1}>1</option>
                <option value={2}>2</option>
                <option value={3}>3</option>
                <option value={4}>4</option>
              </select>
            </label>
          )}
          {batchAction && (
            <span className="text-sm text-blue-600 animate-pulse mr-2">{batchAction}</span>
          )}
          {unprintedCount > 0 && (
            <Button
              size="sm"
              variant="outline"
              onClick={handleMarkAllPrinted}
              disabled={batchLoading}
            >
              ✓ Mark All Printed
            </Button>
          )}
          <Button
            size="sm"
            variant="outline"
            onClick={handlePrintAll}
            disabled={batchLoading || checks.length === 0}
          >
            Print All Checks
          </Button>
          <Button
            size="sm"
            onClick={handleBatchDownload}
            disabled={batchLoading || checks.length === 0}
          >
            Download All Checks PDF
          </Button>
        </div>
      </div>

      {isFirstHawaiian4Up && (
        <div className="rounded-lg border border-blue-200 bg-blue-50 px-3 py-2 text-sm text-blue-900">
          First Hawaiian 4-Up mode prints four checks per sheet and keeps payroll stubs separate. Use the start slot when loading a partially used sheet.
        </div>
      )}

      {/* Checks table */}
      {filteredChecks.length === 0 ? (
        <div className="py-8 text-center text-gray-500 text-sm">
          {normalizedSearch ? 'No checks match this search.' : 'No checks found for this pay period.'}
        </div>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm border-collapse">
            <thead>
              <tr className="border-b border-gray-200 bg-gray-50">
                <th className="px-3 py-2 text-left font-medium text-gray-600">Check #</th>
                <th className="px-3 py-2 text-left font-medium text-gray-600">Employee</th>
                <th className="px-3 py-2 text-right font-medium text-gray-600">Net Pay</th>
                <th className="px-3 py-2 text-center font-medium text-gray-600">Status</th>
                <th className="px-3 py-2 text-right font-medium text-gray-600">Actions</th>
              </tr>
            </thead>
            <tbody>
              {filteredChecks.map((item) => (
                <tr
                  key={item.id}
                  className={`border-b border-gray-100 hover:bg-gray-50 ${item.voided ? 'opacity-60' : ''}`}
                >
                  <td className="px-3 py-2 text-gray-800">
                    {editingCheckId === item.id ? (
                      <div className="space-y-1">
                        <div className="flex items-center gap-1">
                          <input
                            type="text"
                            inputMode="numeric"
                            value={draftCheckNumber}
                            onChange={(e) => setDraftCheckNumber(e.target.value)}
                            onKeyDown={(e) => {
                              if (e.key === 'Enter') handleSaveCheckNumber(item);
                              if (e.key === 'Escape') cancelCheckNumberEdit();
                            }}
                            className="h-8 w-24 rounded border border-blue-300 px-2 font-mono text-sm text-gray-900 focus:border-blue-500 focus:ring-2 focus:ring-blue-100"
                            autoFocus
                          />
                          <Button
                            size="sm"
                            onClick={() => handleSaveCheckNumber(item)}
                            disabled={isActionLoading(item.id, 'saveCheckNumber')}
                            className="h-8 px-2 text-xs"
                          >
                            Save
                          </Button>
                          <Button
                            size="sm"
                            variant="outline"
                            onClick={cancelCheckNumberEdit}
                            disabled={isActionLoading(item.id, 'saveCheckNumber')}
                            className="h-8 px-2 text-xs"
                          >
                            Cancel
                          </Button>
                        </div>
                        {checkNumberError && (
                          <p className="max-w-xs text-xs font-normal text-red-600">{checkNumberError}</p>
                        )}
                      </div>
                    ) : (
                      <div className="flex items-center gap-2">
                        <span className="font-mono">{item.check_number || '—'}</span>
                        {item.reprint_of_check_number && (
                          <span className="text-xs text-orange-600" title={`Reprint of #${item.reprint_of_check_number}`}>
                            (reprint)
                          </span>
                        )}
                        {!item.voided && item.check_number && (
                          <button
                            type="button"
                            onClick={() => startCheckNumberEdit(item)}
                            className="text-xs font-medium text-blue-600 hover:text-blue-800"
                          >
                            Edit
                          </button>
                        )}
                      </div>
                    )}
                  </td>
                  <td className="px-3 py-2 text-gray-900">{item.employee_name}</td>
                  <td className="px-3 py-2 text-right font-medium text-gray-900">
                    {formatCurrency(item.net_pay)}
                  </td>
                  <td className="px-3 py-2 text-center">
                    {checkStatusBadge(item)}
                  </td>
                  <td className="px-3 py-2">
                    <div className="flex justify-end gap-1">
                      {/* Preview check PDF */}
                      {item.check_number && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => handlePreviewPdf(item)}
                          disabled={isActionLoading(item.id, 'preview')}
                          className={`text-xs px-2 py-1 ${item.voided ? 'text-gray-500' : ''}`}
                        >
                          {isActionLoading(item.id, 'preview') ? '…' : item.voided ? 'VOID PDF' : 'Preview'}
                        </Button>
                      )}

                      {/* Mark printed */}
                      {!item.voided && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => handleMarkPrinted(item)}
                          disabled={isActionLoading(item.id, 'markPrinted')}
                          className="text-xs px-2 py-1"
                        >
                          {isActionLoading(item.id, 'markPrinted') ? '…' : item.check_printed_at ? '+ Print' : 'Mark Printed'}
                        </Button>
                      )}

                      {/* Reprint */}
                      {!item.voided && item.check_number && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => setReprintTarget(item)}
                          disabled={actionLoading?.id === item.id}
                          className="text-xs px-2 py-1 text-orange-700 border-orange-300 hover:bg-orange-50"
                        >
                          Reprint
                        </Button>
                      )}

                      {/* Void */}
                      {!item.voided && item.check_number && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => setVoidTarget(item)}
                          disabled={actionLoading?.id === item.id}
                          className="text-xs px-2 py-1 text-red-700 border-red-300 hover:bg-red-50"
                        >
                          Void
                        </Button>
                      )}

                      {/* Void history indicator */}
                      {item.voided && (
                        <span className="text-xs text-red-600 italic" title={item.void_reason ?? undefined}>
                          Voided
                        </span>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* Modals */}
      {voidTarget && (
        <VoidCheckModal
          item={voidTarget}
          onClose={() => setVoidTarget(null)}
          onComplete={handleVoidComplete}
        />
      )}
      {reprintTarget && (
        <ReprintCheckModal
          item={reprintTarget}
          onClose={() => setReprintTarget(null)}
          onComplete={handleReprintComplete}
        />
      )}

      {/* Large centered PDF Preview — rendered as portal to avoid z-index/overflow issues */}
      {previewUrl && previewItem && createPortal(
        <div className="fixed inset-0 z-[9999] flex items-center justify-center bg-gray-900/70 p-4">
          <div className="flex h-[92vh] w-[95vw] max-w-[1400px] flex-col overflow-hidden rounded-2xl bg-white shadow-2xl">
            <div className="flex items-center justify-between border-b px-6 py-4">
              <div>
                <h2 className="text-lg font-semibold text-gray-900">
                  Check #{previewItem.check_number} — {previewItem.employee_name}
                </h2>
                <p className="mt-1 text-sm text-gray-500">
                  Preview sized for desktop review and printing checks onto stock paper.
                </p>
              </div>
              <div className="flex items-center gap-3">
                <Button variant="outline" size="sm" onClick={handlePrintFromPreview}>
                  Print
                </Button>
                <Button variant="outline" size="sm" onClick={handleDownloadFromPreview}>
                  Download PDF
                </Button>
                <Button size="sm" onClick={handleClosePreview}>
                  Close
                </Button>
              </div>
            </div>
            <div className="flex-1 bg-gray-100 p-5">
              <iframe
                src={`${previewUrl}#toolbar=0&navpanes=0&scrollbar=1&view=Fit`}
                className="h-full w-full rounded-xl border bg-white shadow-lg"
                title="Check Preview"
              />
            </div>
          </div>
        </div>,
        document.body
      )}
    </div>
  );
}
