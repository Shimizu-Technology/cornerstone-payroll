import { ACTION_OVERLAY_LAYERS, useFeedbackState, ActionFeedback, useFeedback } from '@/components/ui/action-feedback';
/**
 * CPR-66: ChecksPanel
 * Shows all checks for a committed pay period with print/void/reissue controls.
 */
import { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import type { ReactElement } from 'react';
import { createPortal } from 'react-dom';
import type { CheckItem, CheckListMeta, EarningsStatementItem, PayPeriod } from '@/types';
import { checksApi, payStubsApi } from '@/services/api';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from '@/components/ui/dialog';
import { MobileCardActions, MobileField, MobileRecordCard } from '@/components/ui/mobile-record';
import { VoidCheckModal } from './VoidCheckModal';
import { ReprintCheckModal } from './ReprintCheckModal';
import { InlineCheckNumberField } from '@/components/checks/InlineCheckNumberField';
import { checkNumberValidationError } from '@/components/checks/checkNumberDrafts';
import { canEditPayrollCheckNumber } from '@/components/checks/checkNumberEditability';
import { RecordCheckDeliveryDialog } from './RecordCheckDeliveryDialog';

interface ChecksPanelProps {
  payPeriod: PayPeriod;
  searchTerm?: string;
  refreshToken?: number;
  onChecksChanged?: () => Promise<void>;
}

type CheckAction = 'preview' | 'stub';

function checkStatusBadge(item: CheckItem): ReactElement {
  if (item.voided) return <Badge variant="danger">Voided</Badge>;
  if (item.check_status === 'delivered') return <Badge variant="success">Issued</Badge>;
  if (item.check_printed_at)
    return (
      <Badge variant="info">
        Printed / ready{item.check_print_count > 1 ? ` (×${item.check_print_count})` : ''}
      </Badge>
    );
  if (item.check_status === 'prepared') return <Badge variant="info">Package prepared</Badge>;
  if (item.check_number) return <Badge variant="warning">Not prepared</Badge>;
  return <Badge variant="default">No Check</Badge>;
}

function formatCurrency(amount: number) {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(amount);
}

function formatEventTime(value?: string | null) {
  if (!value) return null;
  return new Date(value).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  });
}

function eventLabel(eventType: string): string {
  switch (eventType) {
    case 'assigned': return 'Assigned';
    case 'prepared': return 'Package prepared';
    case 'printed': return 'Printed';
    case 'delivered': return 'Issued';
    case 'voided': return 'Voided';
    case 'reprinted': return 'Reissued';
    case 'batch_downloaded': return 'Batch downloaded';
    case 'replaced': return 'Replaced';
    case 'renumbered': return 'Renumbered';
    default: return eventType;
  }
}

export function ChecksPanel({ payPeriod, searchTerm = '', refreshToken = 0, onChecksChanged }: ChecksPanelProps) {
  const { notify } = useFeedback();
  const loadRequest = useRef(0);
  const [checks, setChecks] = useState<CheckItem[]>([]);
  const [statementItems, setStatementItems] = useState<EarningsStatementItem[]>([]);
  const [statementSearch, setStatementSearch] = useState('');
  const [statementPreview, setStatementPreview] = useState<{ item: EarningsStatementItem; url: string } | null>(null);
  const [meta, setMeta] = useState<CheckListMeta | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actionLoading, setActionLoading] = useState<{ id: number; action: CheckAction } | null>(null);
  const [batchLoading, setBatchLoading] = useState(false);
  const [batchAction, setBatchAction] = useState<string | null>(null);
  const [startingSlot, setStartingSlot] = useState(1);
  const [selectedStubIds, setSelectedStubIds] = useState<number[]>([]);
  const [checkNumberDrafts, setCheckNumberDrafts] = useState<Record<number, string>>({});
  const [savingCheckNumbers, setSavingCheckNumbers] = useState(false);
  const [checkNumberSaveError, setCheckNumberSaveError, checkNumberSaveErrorFeedbackAttempt] = useFeedbackState<string | null>(null);

  // Modal state
  const [voidTarget, setVoidTarget] = useState<CheckItem | null>(null);
  const [reprintTarget, setReprintTarget] = useState<CheckItem | null>(null);
  const [deliveryTarget, setDeliveryTarget] = useState<CheckItem | null>(null);
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [previewItem, setPreviewItem] = useState<CheckItem | null>(null);

  const load = useCallback(async () => {
    const request = ++loadRequest.current;
    setStatementPreview(null);
    try {
      setLoading(true);
      setError(null);
      const data = await checksApi.list(payPeriod.id);
      if (request !== loadRequest.current) return;
      setChecks(data.checks);
      const statements = data.earnings_statement_items || [];
      setStatementItems(statements);
      setMeta(data.meta);
      setCheckNumberDrafts(Object.fromEntries(data.checks.map((item) => [item.id, item.check_number || ''])));
      setSelectedStubIds((current) => current.filter((id) => statements.some((item) => item.id === id)));
    } catch (err) {
      if (request === loadRequest.current) setError(err instanceof Error ? err.message : 'Failed to load checks and earnings statements');
    } finally {
      if (request === loadRequest.current) setLoading(false);
    }
  }, [payPeriod.id]);

  const invalidateLoad = useCallback(() => { loadRequest.current++; }, []);

  useEffect(() => {
    void load();
    return invalidateLoad;
  }, [load, refreshToken, invalidateLoad]);

  const isActionLoading = (id: number, action: CheckAction) =>
    actionLoading?.id === id && actionLoading.action === action;

  useEffect(() => {
    const url = statementPreview?.url;
    return () => { if (url) URL.revokeObjectURL(url); };
  }, [statementPreview?.url]);

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
      notify({ tone: 'error', message: err instanceof Error ? err.message : 'Failed to load check PDF' });
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
      notify({ tone: 'error', message: 'Pop-up blocked. Please allow pop-ups for this site to print checks.' });
    }
  };

  const handleDownloadStubForItem = async (item: Pick<CheckItem, 'id' | 'employee_name'>) => {
    setActionLoading({ id: item.id, action: 'stub' });
    try {
      const result = await payStubsApi.batchPdf(payPeriod.id, [item.id]);
      const url = URL.createObjectURL(result.blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = result.filename || `paystub_${item.employee_name.replace(/\s+/g, '_')}_${payPeriod.pay_date ?? 'undated'}.pdf`;
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 100);
    } catch (err) {
      notify({ tone: 'error', message: err instanceof Error ? err.message : 'Failed to download pay stub' });
    } finally {
      setActionLoading(null);
    }
  };

  const handlePrintStubForItem = async (item: Pick<CheckItem, 'id' | 'employee_name'>) => {
    setActionLoading({ id: item.id, action: 'stub' });
    try {
      const result = await payStubsApi.batchPdf(payPeriod.id, [item.id]);
      const url = URL.createObjectURL(result.blob);
      const printWindow = window.open(url);
      if (printWindow) {
        printWindow.addEventListener('load', () => {
          printWindow.print();
          setTimeout(() => URL.revokeObjectURL(url), 60000);
        });
      } else {
        URL.revokeObjectURL(url);
        notify({ tone: 'error', message: 'Pop-up blocked. Please allow pop-ups for this site to print pay stubs.' });
      }
    } catch (err) {
      notify({ tone: 'error', message: err instanceof Error ? err.message : 'Failed to print pay stub' });
    } finally {
      setActionLoading(null);
    }
  };

  const selectedStubIdSet = new Set(selectedStubIds);

  const selectedStubRequestIds = () =>
    selectedStubIds.length > 0 ? selectedStubIds : undefined;

  const notifySkippedPayStubs = (skippedCount?: number) => {
    if (!skippedCount || selectedStubIds.length > 0) return;
    notify({ tone: 'info', message: `${skippedCount} employee${skippedCount === 1 ? '' : 's'} with no pay activity were skipped.` });
  };

  const handleDownloadPayStubs = async () => {
    setBatchLoading(true);
    setBatchAction(selectedStubIds.length > 0 ? 'Generating selected pay stubs...' : 'Generating pay stubs...');
    try {
      const result = await payStubsApi.batchPdf(payPeriod.id, selectedStubRequestIds());
      setBatchAction('Downloading pay stubs...');
      const url = URL.createObjectURL(result.blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = result.filename || `paystubs_${payPeriod.pay_date ?? 'undated'}.pdf`;
      a.click();
      notifySkippedPayStubs(result.skippedCount);
      setTimeout(() => URL.revokeObjectURL(url), 100);
    } catch (err) {
      notify({ tone: 'error', message: err instanceof Error ? err.message : 'Failed to download pay stubs' });
    } finally {
      setBatchLoading(false);
      setBatchAction(null);
    }
  };

  const handlePrintPayStubs = async () => {
    setBatchLoading(true);
    setBatchAction(selectedStubIds.length > 0 ? 'Generating selected pay stubs...' : 'Generating pay stubs...');
    try {
      const result = await payStubsApi.batchPdf(payPeriod.id, selectedStubRequestIds());
      setBatchAction('Opening pay stubs...');
      const url = URL.createObjectURL(result.blob);
      const printWindow = window.open(url);
      if (printWindow) {
        notifySkippedPayStubs(result.skippedCount);
        printWindow.addEventListener('load', () => {
          printWindow.print();
          setTimeout(() => URL.revokeObjectURL(url), 60000);
        });
      } else {
        URL.revokeObjectURL(url);
        notify({ tone: 'error', message: 'Pop-up blocked. Please allow pop-ups for this site to print pay stubs.' });
      }
    } catch (err) {
      notify({ tone: 'error', message: err instanceof Error ? err.message : 'Failed to print pay stubs' });
    } finally {
      setBatchLoading(false);
      setBatchAction(null);
    }
  };

  const handleDirectDepositStubs = async (print: boolean) => {
    setBatchLoading(true);
    setBatchAction(print ? 'Opening direct-deposit stubs...' : 'Downloading direct-deposit stubs...');
    try {
      const result = await payStubsApi.directDepositStubsPdf(payPeriod.id);
      const url = URL.createObjectURL(result.blob);
      if (print) {
        const printWindow = window.open(url);
        if (!printWindow) {
          URL.revokeObjectURL(url);
          notify({ tone: 'error', message: 'Pop-up blocked. Please allow pop-ups to print direct-deposit stubs.' });
          return;
        }
        printWindow.addEventListener('load', () => {
          printWindow.print();
          setTimeout(() => URL.revokeObjectURL(url), 60000);
        });
      } else {
        const link = document.createElement('a');
        link.href = url;
        link.download = result.filename || `direct_deposit_stubs_${payPeriod.pay_date ?? 'undated'}.pdf`;
        link.click();
        setTimeout(() => URL.revokeObjectURL(url), 100);
      }
    } catch (err) {
      notify({ tone: 'error', message: err instanceof Error ? err.message : 'Failed to generate direct-deposit stubs' });
    } finally {
      setBatchLoading(false);
      setBatchAction(null);
    }
  };

  const checkNumberChanges = useMemo(() => checks.filter((item) =>
    !item.voided && (checkNumberDrafts[item.id] ?? item.check_number ?? '').trim() !== (item.check_number || '').trim()
  ), [checkNumberDrafts, checks]);
  const checkNumberErrors = useMemo(() => {
    const errors: Record<number, string> = {};
    const owners = new Map<string, number[]>();
    checks.filter((item) => !item.voided && item.check_number).forEach((item) => {
      const value = (checkNumberDrafts[item.id] ?? item.check_number ?? '').trim();
      const validationError = checkNumberValidationError(value);
      if (validationError) errors[item.id] = validationError;
      if (value) owners.set(value, [...(owners.get(value) || []), item.id]);
    });
    owners.forEach((ids, number) => {
      if (ids.length > 1) ids.forEach((id) => { errors[id] = `Check #${number} is entered more than once.`; });
    });
    return errors;
  }, [checkNumberDrafts, checks]);

  const discardCheckNumberChanges = () => {
    setCheckNumberDrafts(Object.fromEntries(checks.map((item) => [item.id, item.check_number || ''])));
    setCheckNumberSaveError(null);
  };

  const saveCheckNumberChanges = async () => {
    if (checkNumberChanges.length === 0 || Object.keys(checkNumberErrors).length > 0) return;
    setSavingCheckNumbers(true);
    setCheckNumberSaveError(null);
    try {
      await checksApi.updateCheckNumbers(
        payPeriod.id,
        checkNumberChanges.map((item) => ({
          source_type: 'payroll_item',
          source_id: item.id,
          check_number: (checkNumberDrafts[item.id] || '').trim(),
        })),
        'Saved from the pay period Checks worksheet'
      );
      await load();
      await onChecksChanged?.();
    } catch (err) {
      setCheckNumberSaveError(err instanceof Error ? err.message : 'Could not save check numbers. No changes were applied.');
    } finally {
      setSavingCheckNumbers(false);
    }
  };

  // ---- Void complete callback ----
  const handleVoidComplete = async () => {
    setVoidTarget(null);
    await Promise.all([load(), onChecksChanged?.()]);
  };

  // ---- Reprint complete callback ----
  const handleReprintComplete = async () => {
    setReprintTarget(null);
    await Promise.all([load(), onChecksChanged?.()]);
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
        Loading checks and earnings statements…
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

  const isFirstHawaiian4Up = meta?.check_stock_type === 'first_hawaiian_4up';
  const normalizedSearch = searchTerm.trim().toLowerCase();
  const filteredChecks = normalizedSearch
    ? checks.filter((item) => {
        const statusLabel = item.check_status || (item.check_number ? 'unprinted' : 'no check');

        return [
          item.employee_name,
          item.check_number,
          statusLabel,
        ].some((value) => value?.toLowerCase().includes(normalizedSearch));
      })
    : checks;
  const normalizedStatementSearch = (searchTerm || statementSearch).trim().toLowerCase();
  const filteredStatements = statementItems.filter((item) =>
    !normalizedStatementSearch || item.employee_name.toLowerCase().includes(normalizedStatementSearch));
  const stubEligibleIds = filteredStatements.map((item) => item.id);
  const allVisibleStubsSelected = stubEligibleIds.length > 0 && stubEligibleIds.every((id) => selectedStubIdSet.has(id));
  const hasPrintableStub = statementItems.length > 0;
  const hasPhysicalChecks = checks.some((item) => !item.voided && Number(item.net_pay) > 0);
  const directDepositCount = statementItems.filter((item) => !item.statement_only && item.payment_delivery_method === 'direct_deposit').length;
  const statementOnlyCount = statementItems.filter((item) => item.statement_only).length;

  const toggleStubSelection = (item: EarningsStatementItem) => {
    setSelectedStubIds((current) =>
      current.includes(item.id) ? current.filter((id) => id !== item.id) : [...current, item.id]
    );
  };

  const toggleAllVisibleStubs = () => {
    setSelectedStubIds((current) => {
      const currentSet = new Set(current);
      if (allVisibleStubsSelected) {
        stubEligibleIds.forEach((id) => currentSet.delete(id));
      } else {
        stubEligibleIds.forEach((id) => currentSet.add(id));
      }
      return Array.from(currentSet);
    });
  };

  const handleViewStatement = async (item: EarningsStatementItem) => {
    const request = loadRequest.current;
    setActionLoading({ id: item.id, action: 'stub' });
    try {
      const result = await payStubsApi.batchPdf(payPeriod.id, [item.id]);
      if (request === loadRequest.current) setStatementPreview({ item, url: URL.createObjectURL(result.blob) });
    } catch (err) {
      notify({ tone: 'error', message: err instanceof Error ? err.message : 'Failed to open earnings statement' });
    } finally {
      setActionLoading(null);
    }
  };

  return (
    <div className="space-y-4">
      {/* Header + batch actions */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex flex-wrap gap-x-4 gap-y-1 text-sm text-gray-600">
          {meta && (
            <>
              <span><span className="font-medium text-gray-900">{meta.total}</span> paper checks</span>
              {meta.direct_deposit_count > 0 && <span><span className="font-medium text-blue-700">{meta.direct_deposit_count}</span> direct-deposit stubs</span>}
              <span><span className="font-medium text-yellow-700">{meta.unprinted}</span> not prepared</span>
              <span><span className="font-medium text-blue-700">{meta.prepared}</span> prepared</span>
              <span><span className="font-medium text-green-700">{meta.printed}</span> printed</span>
              <span><span className="font-medium text-success-700">{meta.delivered}</span> issued</span>
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

        <div className="grid w-full grid-cols-1 gap-2 sm:flex sm:w-auto sm:flex-wrap sm:items-center sm:justify-end [&>button]:w-full sm:[&>button]:w-auto">
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
        </div>
      </div>

      {isFirstHawaiian4Up && hasPhysicalChecks && (
        <div className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
          First Hawaiian 4-Up checks do not include a pay stub on the check stock. Print matching stubs on plain white paper after printing checks.
        </div>
      )}

      {hasPhysicalChecks && <div className="rounded-lg border border-blue-100 bg-blue-50 px-3 py-2 text-sm text-blue-900">
        Saving a check package prepares the selected checks. Record a check as issued only after it was released to the employee.
        {checks.some((item) => item.aire_linked && !item.voided) && ' Linked AIRE hours are not marked paid until then.'}
      </div>}

      <section aria-label="Earnings statements" className="rounded-2xl border border-neutral-200 bg-white p-4 shadow-sm sm:p-5">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h3 className="font-semibold text-neutral-950">Earnings statements</h3>
            <p className="mt-1 max-w-2xl text-sm text-neutral-600">Includes paper checks, direct deposits, and earned pay reduced to $0 by deductions. Statements print on plain paper and do not issue a payment.</p>
            <p className="mt-2 text-sm text-neutral-600">{statementItems.length} statement{statementItems.length === 1 ? '' : 's'} · {directDepositCount} direct deposit{directDepositCount === 1 ? '' : 's'} · {statementOnlyCount} statement only</p>
          </div>
          <div className="grid grid-cols-1 gap-2 sm:flex sm:flex-wrap sm:justify-end">
            <Button size="sm" onClick={() => void handlePrintPayStubs()} disabled={batchLoading || !hasPrintableStub}>
              {selectedStubIds.length ? `Print ${selectedStubIds.length} selected statement${selectedStubIds.length === 1 ? '' : 's'}` : 'Print all earnings statements'}
            </Button>
            <Button size="sm" variant="outline" onClick={() => void handleDownloadPayStubs()} disabled={batchLoading || !hasPrintableStub}>
              {selectedStubIds.length ? 'Download selected statements' : 'Download all earnings statements'}
            </Button>
          </div>
        </div>
        {directDepositCount > 0 && (
          <div className="mt-3 flex flex-wrap gap-2">
            <Button size="sm" variant="outline" onClick={() => void handleDirectDepositStubs(true)} disabled={batchLoading}>Print direct-deposit statements</Button>
            <Button size="sm" variant="outline" onClick={() => void handleDirectDepositStubs(false)} disabled={batchLoading}>Download direct-deposit statements</Button>
          </div>
        )}
        {statementItems.length > 0 ? (
          <>
            <div className="mt-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <Input aria-label="Search earnings statements" placeholder="Search employees…" value={statementSearch} onChange={(event) => setStatementSearch(event.target.value)} className="sm:max-w-xs" />
              <div className="flex flex-wrap items-center gap-3 text-sm">
                <label className="flex min-h-11 items-center gap-2">
                  <input type="checkbox" className="h-4 w-4" checked={allVisibleStubsSelected} onChange={toggleAllVisibleStubs} disabled={stubEligibleIds.length === 0} aria-label="Select all visible earnings statements" />
                  Select visible
                </label>
                {selectedStubIds.length > 0 && <Button size="sm" variant="outline" onClick={() => setSelectedStubIds([])}>Clear selection ({selectedStubIds.length})</Button>}
              </div>
            </div>
            {filteredStatements.length === 0 && <p className="mt-4 text-sm text-neutral-500">No earnings statements match this search.</p>}
            {[true, false].map((statementOnly) => {
              const groupItems = filteredStatements.filter((item) => item.statement_only === statementOnly);
              if (!groupItems.length) return null;
              return (
                <div key={String(statementOnly)} className="mt-4">
                  <h4 className="text-sm font-semibold text-neutral-800">{statementOnly ? 'Statement only · no payment issued' : 'Paychecks and direct deposits'} ({groupItems.length})</h4>
                  <ul className="mt-2 space-y-2">
                    {groupItems.map((item) => (
                      <li key={item.id} className="rounded-xl border border-neutral-200 p-3 sm:grid sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center sm:gap-4" aria-label={`Earnings statement for ${item.employee_name}`}>
                        <div>
                          <label className="flex min-h-11 items-center gap-3">
                            <input type="checkbox" className="h-4 w-4 shrink-0" checked={selectedStubIdSet.has(item.id)} onChange={() => toggleStubSelection(item)} aria-label={`Select earnings statement for ${item.employee_name}`} />
                            <span className="min-w-0 break-words font-semibold text-neutral-950">{item.employee_name}</span>
                          </label>
                          <p className="ml-7 text-xs text-neutral-600">{item.statement_only ? 'No payment issued' : item.payment_delivery_method === 'direct_deposit' ? 'Direct deposit' : 'Paper check'} · Gross {formatCurrency(item.gross_pay)} · Deductions {formatCurrency(item.total_deductions)} · Net {formatCurrency(item.net_pay)}</p>
                        </div>
                        <div className="mt-3 grid grid-cols-3 gap-2 sm:mt-0 sm:flex sm:flex-wrap sm:justify-end">
                          <Button size="sm" variant="outline" onClick={() => void handleViewStatement(item)} disabled={isActionLoading(item.id, 'stub')}>View</Button>
                          <Button size="sm" variant="outline" onClick={() => void handlePrintStubForItem(item)} disabled={isActionLoading(item.id, 'stub')}>Print</Button>
                          <Button size="sm" variant="outline" onClick={() => void handleDownloadStubForItem(item)} disabled={isActionLoading(item.id, 'stub')}>Download</Button>
                        </div>
                      </li>
                    ))}
                  </ul>
                </div>
              );
            })}
          </>
        ) : <p className="mt-4 text-sm text-neutral-500">No earnings statements are needed for this run. Employees with no payroll activity are omitted.</p>}
      </section>

      {checkNumberChanges.length > 0 && (
        <div className="flex flex-col gap-3 rounded-xl border border-amber-300 bg-amber-50 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <p className="text-sm font-semibold text-amber-950">
              {checkNumberChanges.length} unsaved check-number change{checkNumberChanges.length === 1 ? '' : 's'}
            </p>
            <p className="mt-0.5 text-xs text-amber-800">Review the highlighted fields. Nothing changes until you save.</p>
          </div>
          <div className="flex gap-2">
            <Button size="sm" variant="outline" onClick={discardCheckNumberChanges} disabled={savingCheckNumbers}>Discard</Button>
            <Button size="sm" onClick={() => void saveCheckNumberChanges()} disabled={savingCheckNumbers || Object.keys(checkNumberErrors).length > 0}>
              {savingCheckNumbers ? 'Saving…' : 'Save check numbers'}
            </Button>
          </div>
        </div>
      )}
      {checkNumberSaveError && <ActionFeedback retryKey={checkNumberSaveErrorFeedbackAttempt} tone="error" message={checkNumberSaveError} />}

      {/* Checks table */}
      {filteredChecks.length === 0 ? (
        <div className="py-8 text-center text-gray-500 text-sm">
          {normalizedSearch ? 'No checks match this search.' : 'No paper checks were issued for this pay period.'}
        </div>
      ) : (
        <>
          <div className="space-y-3 sm:hidden">
            {filteredChecks.map((item) => {
              const latestEvent = item.events?.[item.events.length - 1];
              const shouldShowReason = Boolean(
                latestEvent?.reason && ['voided', 'reprinted', 'replaced', 'renumbered'].includes(latestEvent.event_type)
              );

              return (
                <MobileRecordCard key={item.id} tone={item.voided ? 'muted' : 'default'}>
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="truncate font-semibold text-neutral-950">{item.employee_name}</p>
                      {item.department_name && <p className="truncate text-sm text-neutral-500">{item.department_name}</p>}
                    </div>
                    {checkStatusBadge(item)}
                  </div>

                  <div className="mt-4 grid grid-cols-1 gap-3">
                    <MobileField label="Net pay" value={formatCurrency(item.net_pay)} />
                  </div>

                  {item.reprint_of_check_number && (
                    <p className="mt-2 text-xs text-orange-700">Replaces #{item.reprint_of_check_number}</p>
                  )}

                  {latestEvent && (
                    <div className="mt-3 rounded-xl border border-neutral-200 bg-neutral-50 p-3 text-xs text-neutral-600">
                      <p>
                        Last event: {eventLabel(latestEvent.event_type)} #{latestEvent.check_number || '—'}
                        {latestEvent.user_name ? ` by ${latestEvent.user_name}` : ''}
                        {formatEventTime(latestEvent.created_at) ? ` · ${formatEventTime(latestEvent.created_at)}` : ''}
                      </p>
                      {shouldShowReason && <p className="mt-1 text-orange-700">Reason: {latestEvent.reason}</p>}
                    </div>
                  )}

                  {!item.voided && item.check_number && (
                    <div className="mt-4 rounded-xl border border-slate-200 bg-slate-50 p-3">
                      <p className="mb-2 text-xs font-medium text-slate-500">Check number</p>
                      <InlineCheckNumberField
                        value={checkNumberDrafts[item.id] ?? item.check_number ?? ''}
                        ariaLabel={`Check number for ${item.employee_name}`}
                        disabled={savingCheckNumbers || !canEditPayrollCheckNumber(item)}
                        dirty={checkNumberChanges.some((changed) => changed.id === item.id)}
                        error={checkNumberErrors[item.id]}
                        onChange={(value) => setCheckNumberDrafts((current) => ({ ...current, [item.id]: value }))}
                        onReset={() => setCheckNumberDrafts((current) => ({ ...current, [item.id]: item.check_number || '' }))}
                      />
                    </div>
                  )}

                  <MobileCardActions className="grid grid-cols-2">
                    {item.check_number && (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => handlePreviewPdf(item)}
                        disabled={isActionLoading(item.id, 'preview')}
                        className={item.voided ? 'text-gray-500' : ''}
                      >
                        {isActionLoading(item.id, 'preview') ? 'Loading…' : item.voided ? 'Void PDF' : 'Preview'}
                      </Button>
                    )}
                    {!item.voided && (
                      <Button size="sm" variant="outline" onClick={() => void handlePrintStubForItem(item)} disabled={isActionLoading(item.id, 'stub')}>
                        {isActionLoading(item.id, 'stub') ? 'Loading…' : 'Stub'}
                      </Button>
                    )}
                    {!item.voided && (item.check_status === 'prepared' || item.check_status === 'printed') && (
                      <Button size="sm" onClick={() => setDeliveryTarget(item)}>
                        Record Issued
                      </Button>
                    )}
                    {!item.voided && item.check_number && (
                      <Button size="sm" variant="outline" onClick={() => setReprintTarget(item)} disabled={actionLoading?.id === item.id} className="border-orange-300 text-orange-700 hover:bg-orange-50">
                        Reissue
                      </Button>
                    )}
                    {!item.voided && item.check_number && (
                      <Button size="sm" variant="outline" onClick={() => setVoidTarget(item)} disabled={actionLoading?.id === item.id} className="border-red-300 text-red-700 hover:bg-red-50">
                        Void
                      </Button>
                    )}
                    {item.voided && <span className="text-xs italic text-red-600" title={item.void_reason ?? undefined}>Voided</span>}
                  </MobileCardActions>
                </MobileRecordCard>
              );
            })}
          </div>

          <div className="hidden max-w-full overflow-x-auto overscroll-x-contain sm:block">
            <table className="min-w-[760px] w-full border-collapse text-sm">
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
                    <div className="flex items-center gap-2">
                      {item.voided || !item.check_number ? (
                        <span className="font-mono">{item.check_number || '—'}</span>
                      ) : (
                        <InlineCheckNumberField
                          value={checkNumberDrafts[item.id] ?? item.check_number ?? ''}
                          ariaLabel={`Check number for ${item.employee_name}`}
                          disabled={savingCheckNumbers || !canEditPayrollCheckNumber(item)}
                          dirty={checkNumberChanges.some((changed) => changed.id === item.id)}
                          error={checkNumberErrors[item.id]}
                          onChange={(value) => setCheckNumberDrafts((current) => ({ ...current, [item.id]: value }))}
                          onReset={() => setCheckNumberDrafts((current) => ({ ...current, [item.id]: item.check_number || '' }))}
                        />
                      )}
                      {item.reprint_of_check_number && (
                        <span className="text-xs text-orange-700" title={`Reissued replacement for #${item.reprint_of_check_number}`}>
                          replaces #{item.reprint_of_check_number}
                        </span>
                      )}
                    </div>
                  </td>
                  <td className="px-3 py-2 text-gray-900">
                    <div className="space-y-0.5">
                      <div>{item.employee_name}</div>
                      {item.department_name && (
                        <div className="text-xs text-gray-500">{item.department_name}</div>
                      )}
                      {item.events && item.events.length > 0 && (() => {
                        const latest = item.events[item.events.length - 1];
                        const shouldShowReason = Boolean(
                          latest.reason && ['voided', 'reprinted', 'replaced', 'renumbered'].includes(latest.event_type)
                        );
                        return (
                          <div className="space-y-0.5 text-xs text-gray-500">
                            <div>
                              Last event: {eventLabel(latest.event_type)} #{latest.check_number || '—'}
                              {latest.user_name ? ` by ${latest.user_name}` : ''}
                              {formatEventTime(latest.created_at) ? ` · ${formatEventTime(latest.created_at)}` : ''}
                            </div>
                            {shouldShowReason && (
                              <div className="max-w-md text-orange-700">
                                Reason: {latest.reason}
                              </div>
                            )}
                          </div>
                        );
                      })()}
                    </div>
                  </td>
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

                      {!item.voided && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => void handlePrintStubForItem(item)}
                          disabled={isActionLoading(item.id, 'stub')}
                          className="text-xs px-2 py-1"
                        >
                          {isActionLoading(item.id, 'stub') ? '…' : 'Stub'}
                        </Button>
                      )}

                      {!item.voided && (item.check_status === 'prepared' || item.check_status === 'printed') && (
                        <Button
                          size="sm"
                          onClick={() => setDeliveryTarget(item)}
                          className="text-xs px-2 py-2"
                        >
                          Record Issued
                        </Button>
                      )}

                      {/* Reissue physical check */}
                      {!item.voided && item.check_number && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => setReprintTarget(item)}
                          disabled={actionLoading?.id === item.id}
                          className="text-xs px-2 py-1 text-orange-700 border-orange-300 hover:bg-orange-50"
                        >
                          Reissue
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
        </>
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
      {deliveryTarget && (
        <RecordCheckDeliveryDialog
          item={deliveryTarget}
          onClose={() => setDeliveryTarget(null)}
          onComplete={async () => {
            setDeliveryTarget(null);
            await Promise.all([load(), onChecksChanged?.()]);
          }}
        />
      )}

      <Dialog open={statementPreview !== null} onOpenChange={(open) => { if (!open) setStatementPreview(null); }}>
        <DialogContent className="dialog-wide flex h-[90dvh] flex-col">
          <DialogHeader>
            <DialogTitle>Earnings statement — {statementPreview?.item.employee_name}</DialogTitle>
            <DialogDescription>Print on plain paper. This statement does not issue a check or bank transfer.</DialogDescription>
          </DialogHeader>
          {statementPreview && <>
            <div className="flex flex-wrap gap-2">
              <Button size="sm" onClick={() => void handlePrintStubForItem(statementPreview.item)} disabled={isActionLoading(statementPreview.item.id, 'stub')}>Print statement</Button>
              <Button size="sm" variant="outline" onClick={() => void handleDownloadStubForItem(statementPreview.item)} disabled={isActionLoading(statementPreview.item.id, 'stub')}>Download statement</Button>
              <Button size="sm" variant="outline" onClick={() => setStatementPreview(null)}>Close</Button>
            </div>
            <iframe src={statementPreview.url} title={`Earnings statement PDF for ${statementPreview.item.employee_name}`} className="min-h-0 flex-1 rounded-lg border bg-neutral-50" />
          </>}
        </DialogContent>
      </Dialog>

      {/* Large centered PDF Preview — rendered as portal to avoid z-index/overflow issues */}
      {previewUrl && previewItem && createPortal(
        <div className={`fixed inset-0 ${ACTION_OVERLAY_LAYERS.legacyDialog} flex items-center justify-center bg-gray-900/70 p-4`}>
          <div className="flex h-[92vh] w-[95vw] max-w-[1400px] flex-col overflow-hidden rounded-2xl bg-white shadow-2xl">
            <div className="flex items-center justify-between border-b px-6 py-4">
              <div>
                <h2 className="text-lg font-semibold text-gray-900">
                  Check #{previewItem.check_number} — {previewItem.employee_name}
                </h2>
                <p className="mt-1 text-sm text-gray-500">
                  Preview sized for desktop review and printing checks onto stock paper. Generate a saved package to mark this check prepared.
                  {isFirstHawaiian4Up ? ' Print the matching stub separately on plain paper.' : ' A separate plain-paper stub is also available when needed.'}
                </p>
              </div>
              <div className="flex items-center gap-3">
                {!previewItem.voided && (
                  <>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => void handlePrintStubForItem(previewItem)}
                      disabled={isActionLoading(previewItem.id, 'stub')}
                    >
                      Print Stub
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => void handleDownloadStubForItem(previewItem)}
                      disabled={isActionLoading(previewItem.id, 'stub')}
                    >
                      Download Stub
                    </Button>
                  </>
                )}
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
