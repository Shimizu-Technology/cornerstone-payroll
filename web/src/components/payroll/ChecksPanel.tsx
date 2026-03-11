/**
 * CPR-66: ChecksPanel
 * Shows all checks for a committed pay period with print/void/reprint controls.
 */
import { useState, useEffect, useCallback } from 'react';
import type { CheckItem, CheckListMeta, PayPeriod } from '@/types';
import { checksApi } from '@/services/api';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { VoidCheckModal } from './VoidCheckModal';
import { ReprintCheckModal } from './ReprintCheckModal';

interface ChecksPanelProps {
  payPeriod: PayPeriod;
}

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

export function ChecksPanel({ payPeriod }: ChecksPanelProps) {
  const [checks, setChecks] = useState<CheckItem[]>([]);
  const [meta, setMeta] = useState<CheckListMeta | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actionLoading, setActionLoading] = useState<number | null>(null);
  const [batchLoading, setBatchLoading] = useState(false);

  // Modal state
  const [voidTarget, setVoidTarget] = useState<CheckItem | null>(null);
  const [reprintTarget, setReprintTarget] = useState<CheckItem | null>(null);

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

  // ---- Batch PDF download ----
  const handleBatchDownload = async () => {
    setBatchLoading(true);
    try {
      const blob = await checksApi.batchPdf(payPeriod.id);
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `checks_${payPeriod.pay_date ?? 'undated'}_batch.pdf`;
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 100);
    } catch (err) {
      alert(err instanceof Error ? err.message : 'Failed to download PDF');
    } finally {
      setBatchLoading(false);
    }
  };

  // ---- Mark all printed ----
  const handleMarkAllPrinted = async () => {
    if (!window.confirm('Mark all unprinted checks as printed?')) return;
    setBatchLoading(true);
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
    }
  };

  // ---- Download single check PDF (authenticated) ----
  const handleDownloadPdf = async (item: CheckItem) => {
    setActionLoading(item.id);
    try {
      const blob = await checksApi.checkPdf(item.id);
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `check_${item.check_number || item.id}.pdf`;
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 100);
    } catch (err) {
      alert(err instanceof Error ? err.message : 'Failed to download check PDF');
    } finally {
      setActionLoading(null);
    }
  };

  // ---- Mark single printed ----
  const handleMarkPrinted = async (item: CheckItem) => {
    setActionLoading(item.id);
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
        </div>

        <div className="flex gap-2">
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
            onClick={handleBatchDownload}
            disabled={batchLoading || checks.length === 0}
          >
            {batchLoading ? 'Generating…' : '⬇ Download All Checks PDF'}
          </Button>
        </div>
      </div>

      {/* Checks table */}
      {checks.length === 0 ? (
        <div className="py-8 text-center text-gray-500 text-sm">
          No checks found for this pay period.
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
              {checks.map((item) => (
                <tr
                  key={item.id}
                  className={`border-b border-gray-100 hover:bg-gray-50 ${item.voided ? 'opacity-60' : ''}`}
                >
                  <td className="px-3 py-2 font-mono text-gray-800">
                    {item.check_number || '—'}
                    {item.reprint_of_check_number && (
                      <span className="ml-1 text-xs text-orange-600" title={`Reprint of #${item.reprint_of_check_number}`}>
                        (reprint)
                      </span>
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
                      {/* Download single check PDF (including voided for audit/archival) */}
                      {item.check_number && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => handleDownloadPdf(item)}
                          disabled={actionLoading === item.id}
                          className={`text-xs px-2 py-1 ${item.voided ? 'text-gray-500' : ''}`}
                        >
                          {actionLoading === item.id ? '…' : item.voided ? 'VOID PDF' : 'PDF'}
                        </Button>
                      )}

                      {/* Mark printed */}
                      {!item.voided && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => handleMarkPrinted(item)}
                          disabled={actionLoading === item.id}
                          className="text-xs px-2 py-1"
                        >
                          {actionLoading === item.id ? '…' : item.check_printed_at ? '+ Print' : 'Mark Printed'}
                        </Button>
                      )}

                      {/* Reprint */}
                      {!item.voided && item.check_number && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => setReprintTarget(item)}
                          disabled={actionLoading === item.id}
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
                          disabled={actionLoading === item.id}
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
    </div>
  );
}
