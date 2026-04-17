import { useState, useEffect, useCallback, useRef } from 'react';
import { createPortal } from 'react-dom';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { nonEmployeeChecksApi, payPeriodsApi, companiesApi } from '@/services/api';
import type { CompanyDetail } from '@/services/api';
import type { NonEmployeeCheck, NonEmployeeCheckType } from '@/types';
import { DRT } from '@/lib/constants';
import { NonEmployeeCheckEditModal } from './NonEmployeeCheckEditModal';
import { NonEmployeeCheckHistory } from './NonEmployeeCheckHistory';

interface NonEmployeeChecksPanelProps {
  payPeriodId: number;
  companyId: number;
  payPeriodStatus?: string;
  payPeriodEndDate?: string;
  /**
   * Fired whenever the set of checks is (re)loaded or a single check is
   * updated locally. Lets parent pages observe non-employee-check state
   * without owning the fetch — used by the pay period page to detect when
   * the FIT deposit amount has been overridden away from the calculated
   * value derived from PayrollItems.
   */
  onChecksLoaded?: (checks: NonEmployeeCheck[]) => void;
}

function CopyField({ label, value }: { label: string; value: string }) {
  const [copied, setCopied] = useState(false);
  const handleCopy = () => {
    navigator.clipboard.writeText(value).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  };
  return (
    <div className="flex items-center gap-1.5">
      <span className="font-medium">{label}:</span>{' '}
      <span className="font-mono">{value}</span>
      <button
        onClick={handleCopy}
        className="inline-flex items-center text-amber-600 hover:text-amber-800 p-0.5 rounded"
        title={`Copy ${label}`}
      >
        {copied ? (
          <svg className="w-3.5 h-3.5 text-green-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
          </svg>
        ) : (
          <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z" />
          </svg>
        )}
      </button>
    </div>
  );
}

function getTaxQuarter(dateStr?: string): { year: number; quarter: number } | null {
  if (!dateStr) return null;
  const d = new Date(dateStr);
  if (isNaN(d.getTime())) return null;
  const month = d.getMonth();
  return { year: d.getFullYear(), quarter: Math.floor(month / 3) + 1 };
}

const CHECK_TYPE_LABELS: Record<NonEmployeeCheckType, string> = {
  contractor: 'Contractor',
  tax_deposit: 'Tax Deposit',
  child_support: 'Child Support',
  garnishment: 'Garnishment',
  vendor: 'Vendor',
  reimbursement: 'Reimbursement',
  other: 'Other',
};

const STATUS_COLORS: Record<string, string> = {
  pending: 'bg-gray-100 text-gray-700',
  unprinted: 'bg-yellow-100 text-yellow-700',
  printed: 'bg-green-100 text-green-700',
  voided: 'bg-red-100 text-red-700',
};

export function NonEmployeeChecksPanel({ payPeriodId, companyId, payPeriodStatus, payPeriodEndDate, onChecksLoaded }: NonEmployeeChecksPanelProps) {
  const [checks, setChecks] = useState<NonEmployeeCheck[]>([]);
  const [loading, setLoading] = useState(false);
  const [company, setCompany] = useState<CompanyDetail | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [formData, setFormData] = useState({
    payable_to: '',
    amount: '',
    check_type: 'other' as NonEmployeeCheckType,
    memo: '',
    description: '',
    reference_number: '',
    check_number: '',
  });
  const [formError, setFormError] = useState<string | null>(null);
  const [voidingId, setVoidingId] = useState<number | null>(null);
  const [voidReason, setVoidReason] = useState('');
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [previewCheck, setPreviewCheck] = useState<NonEmployeeCheck | null>(null);
  const [pdfLoading, setPdfLoading] = useState<number | null>(null);
  const [creating, setCreating] = useState(false);
  const [deletingId, setDeletingId] = useState<number | null>(null);
  const [voidConfirming, setVoidConfirming] = useState(false);
  const [markingPrintedId, setMarkingPrintedId] = useState<number | null>(null);
  const [generatingFit, setGeneratingFit] = useState(false);
  const [fitError, setFitError] = useState<string | null>(null);
  const [editingCheck, setEditingCheck] = useState<NonEmployeeCheck | null>(null);
  const [expandedHistoryIds, setExpandedHistoryIds] = useState<Set<number>>(new Set());

  const toggleHistory = (id: number) => {
    setExpandedHistoryIds(prev => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };

  const handleSavedCheck = (updated: NonEmployeeCheck) => {
    // Pure state update — the onChecksLoaded notification is fired by the
    // effect below (we used to call it from inside the setter, which is a
    // side-effect-during-render anti-pattern that double-fires under
    // React StrictMode).
    setChecks(prev => prev.map(c => (c.id === updated.id ? updated : c)));
    // If the user has the history open for this check, force a remount so the
    // newly-created edit row appears. We do this by toggling it off+on once.
    if (expandedHistoryIds.has(updated.id)) {
      setExpandedHistoryIds(prev => {
        const next = new Set(prev);
        next.delete(updated.id);
        return next;
      });
      setTimeout(() => {
        setExpandedHistoryIds(prev => new Set(prev).add(updated.id));
      }, 0);
    }
  };

  // Keep the parent's onChecksLoaded callback in a ref so loadChecks doesn't
  // need it in its dependency array. This avoids re-creating loadChecks every
  // time the parent re-renders (which would re-trigger the load effect).
  const onChecksLoadedRef = useRef(onChecksLoaded);
  useEffect(() => {
    onChecksLoadedRef.current = onChecksLoaded;
  }, [onChecksLoaded]);

  const loadChecks = useCallback(async () => {
    setLoading(true);
    try {
      const res = await nonEmployeeChecksApi.list({ pay_period_id: payPeriodId });
      setChecks(res.non_employee_checks);
    } catch {
      // ignore
    } finally {
      setLoading(false);
    }
  }, [payPeriodId]);

  useEffect(() => { loadChecks(); }, [loadChecks]);

  // Notify the parent whenever the local checks array changes (initial load,
  // reloads, or single-check updates). Done in an effect so it stays out of
  // any render-phase setState updater.
  useEffect(() => {
    onChecksLoadedRef.current?.(checks);
  }, [checks]);

  useEffect(() => {
    if (companyId) {
      companiesApi.get(companyId).then(data => setCompany(data.company)).catch(() => {});
    }
  }, [companyId]);

  const handleCreate = async () => {
    setFormError(null);
    if (!formData.payable_to || !formData.amount) {
      setFormError('Payable To and Amount are required');
      return;
    }
    setCreating(true);
    try {
      await nonEmployeeChecksApi.create({
        pay_period_id: payPeriodId,
        payable_to: formData.payable_to,
        amount: parseFloat(formData.amount),
        check_type: formData.check_type,
        memo: formData.memo || undefined,
        description: formData.description || undefined,
        reference_number: formData.reference_number || undefined,
        check_number: formData.check_number || undefined,
      });
      setShowForm(false);
      setFormData({ payable_to: '', amount: '', check_type: 'other', memo: '', description: '', reference_number: '', check_number: '' });
      loadChecks();
    } catch (err) {
      setFormError(err instanceof Error ? err.message : 'Failed to create check');
    } finally {
      setCreating(false);
    }
  };

  const handleVoid = async (id: number) => {
    if (!voidReason) return;
    setVoidConfirming(true);
    try {
      await nonEmployeeChecksApi.voidCheck(id, voidReason);
      setVoidingId(null);
      setVoidReason('');
      loadChecks();
    } catch {
      // ignore
    } finally {
      setVoidConfirming(false);
    }
  };

  const handleMarkPrinted = async (id: number) => {
    setMarkingPrintedId(id);
    try {
      await nonEmployeeChecksApi.markPrinted(id);
      loadChecks();
    } catch {
      // ignore
    } finally {
      setMarkingPrintedId(null);
    }
  };

  const handleDelete = async (id: number) => {
    if (!confirm('Delete this non-employee check?')) return;
    setDeletingId(id);
    try {
      await nonEmployeeChecksApi.delete(id);
      loadChecks();
    } catch {
      // ignore
    } finally {
      setDeletingId(null);
    }
  };

  const handlePreviewPdf = async (check: NonEmployeeCheck) => {
    setPdfLoading(check.id);
    try {
      const blob = await nonEmployeeChecksApi.checkPdf(check.id);
      if (previewUrl) URL.revokeObjectURL(previewUrl);
      const url = URL.createObjectURL(blob);
      setPreviewUrl(url);
      setPreviewCheck(check);
    } catch (err) {
      alert(err instanceof Error ? err.message : 'Failed to load check PDF');
    } finally {
      setPdfLoading(null);
    }
  };

  const handleClosePreview = () => {
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    setPreviewUrl(null);
    setPreviewCheck(null);
  };

  const handleDownloadFromPreview = () => {
    if (!previewUrl || !previewCheck) return;
    const a = document.createElement('a');
    a.href = previewUrl;
    a.download = `ne_check_${previewCheck.check_number || previewCheck.id}.pdf`;
    a.click();
  };

  const handlePrintFromPreview = () => {
    if (!previewUrl) return;
    const printWindow = window.open(previewUrl);
    if (printWindow) {
      printWindow.addEventListener('load', () => { printWindow.print(); });
    } else {
      alert('Pop-up blocked. Please allow pop-ups to print checks.');
    }
  };

  const handlePrintSingle = async (check: NonEmployeeCheck) => {
    setPdfLoading(check.id);
    try {
      const blob = await nonEmployeeChecksApi.checkPdf(check.id);
      const url = URL.createObjectURL(blob);
      const printWindow = window.open(url);
      if (printWindow) {
        printWindow.addEventListener('load', () => {
          printWindow.print();
          setTimeout(() => URL.revokeObjectURL(url), 60000);
        });
      } else {
        URL.revokeObjectURL(url);
        alert('Pop-up blocked. Please allow pop-ups to print checks.');
      }
    } catch (err) {
      alert(err instanceof Error ? err.message : 'Failed to generate PDF');
    } finally {
      setPdfLoading(null);
    }
  };

  // Identify the auto-generated FIT deposit by its stable marker, falling back
  // to the legacy string match for any rows not yet caught by the data backfill.
  const hasFitCheck = checks.some(
    c =>
      !c.voided &&
      (c.auto_generated_type === 'fit_deposit' ||
        (c.check_type === 'tax_deposit' && c.payable_to === 'EFTPS - Federal Income Tax'))
  );
  const showGenerateFit = payPeriodStatus === 'committed' && !hasFitCheck;

  const handleGenerateFitCheck = async () => {
    setGeneratingFit(true);
    setFitError(null);
    try {
      await payPeriodsApi.generateFitCheck(payPeriodId);
      loadChecks();
    } catch (err) {
      setFitError(err instanceof Error ? err.message : 'Failed to generate FIT check');
    } finally {
      setGeneratingFit(false);
    }
  };

  const fmt = (v: number | string) => `$${Number(v).toFixed(2)}`;

  return (
    <Card>
      <div className="p-4 border-b bg-blue-50">
        <div className="flex items-center justify-between">
          <div>
            <h3 className="font-semibold text-blue-900">Non-Employee Checks</h3>
            <p className="text-sm text-blue-700 mt-1">
              Tax deposits, garnishments, vendor payments, etc.
            </p>
          </div>
          <div className="flex gap-2">
            {showGenerateFit && (
              <Button
                size="sm"
                variant="outline"
                onClick={handleGenerateFitCheck}
                disabled={generatingFit}
                className="border-amber-300 text-amber-700 hover:bg-amber-50"
              >
                {generatingFit ? 'Generating...' : 'Generate FIT Check'}
              </Button>
            )}
            <Button size="sm" onClick={() => setShowForm(!showForm)}>
              {showForm ? 'Cancel' : '+ Add Check'}
            </Button>
          </div>
        </div>
      </div>

      {showForm && (
        <div className="p-4 border-b bg-blue-50/30">
          {formError && <p className="text-sm text-red-600 mb-2">{formError}</p>}
          <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
            <input className="border rounded px-3 py-2 text-sm" placeholder="Payable To *" value={formData.payable_to} onChange={e => setFormData(p => ({ ...p, payable_to: e.target.value }))} />
            <input className="border rounded px-3 py-2 text-sm" placeholder="Amount *" type="number" step="0.01" value={formData.amount} onChange={e => setFormData(p => ({ ...p, amount: e.target.value }))} />
            <select className="border rounded px-3 py-2 text-sm" value={formData.check_type} onChange={e => setFormData(p => ({ ...p, check_type: e.target.value as NonEmployeeCheckType }))}>
              {Object.entries(CHECK_TYPE_LABELS).map(([val, label]) => (
                <option key={val} value={val}>{label}</option>
              ))}
            </select>
            <input className="border rounded px-3 py-2 text-sm" placeholder="Check #" value={formData.check_number} onChange={e => setFormData(p => ({ ...p, check_number: e.target.value }))} />
            <input className="border rounded px-3 py-2 text-sm" placeholder="Memo" value={formData.memo} onChange={e => setFormData(p => ({ ...p, memo: e.target.value }))} />
            <input className="border rounded px-3 py-2 text-sm" placeholder="Reference #" value={formData.reference_number} onChange={e => setFormData(p => ({ ...p, reference_number: e.target.value }))} />
          </div>
          <textarea className="mt-2 w-full border rounded px-3 py-2 text-sm" placeholder="Description" rows={2} value={formData.description} onChange={e => setFormData(p => ({ ...p, description: e.target.value }))} />
          <div className="mt-3 flex gap-2">
            <Button size="sm" onClick={handleCreate} disabled={creating}>
              {creating ? 'Creating...' : 'Create Check'}
            </Button>
            <Button size="sm" variant="outline" onClick={() => setShowForm(false)} disabled={creating}>Cancel</Button>
          </div>
        </div>
      )}

      {fitError && (
        <div className="mx-4 mt-4 p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-700">
          {fitError}
        </div>
      )}

      {/* Form 500 callout when tax deposit checks exist */}
      {!loading && checks.some(c => c.check_type === 'tax_deposit' && !c.voided) && (
        <div className="mx-4 mt-4 p-3 bg-amber-50 border border-amber-200 rounded-lg flex items-start gap-3">
          <svg className="w-5 h-5 text-amber-600 mt-0.5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
          </svg>
          <div className="text-sm flex-1">
            <p className="font-medium text-amber-800">DRT Form 500 Required</p>
            <p className="text-amber-700 mt-0.5">
              Tax deposit checks require a Guam DRT Form 500 (Depository Receipt for Income Tax Withheld).{' '}
              <a href={DRT.FORM_500_PDF} target="_blank" rel="noopener noreferrer" className="text-blue-600 hover:text-blue-800 underline font-medium">
                Open Form 500
              </a>
              {' · '}
              <a href={DRT.FORMS_PAGE} target="_blank" rel="noopener noreferrer" className="text-blue-600 hover:text-blue-800 underline">
                All DRT Forms
              </a>
            </p>
            {(() => {
              const taxDeposit = checks.find(c => c.check_type === 'tax_deposit' && !c.voided);
              const taxQ = getTaxQuarter(payPeriodEndDate);
              const fullAddress = company?.address_line1
                ? [
                    company.address_line1,
                    company.address_line2,
                    [company.city, company.state, company.zip].filter(Boolean).join(', ')
                  ].filter(Boolean).join(', ')
                : null;

              return (company || taxDeposit || taxQ) ? (
                <div className="mt-2 pt-2 border-t border-amber-200 text-amber-800">
                  <p className="text-xs font-medium text-amber-600 uppercase tracking-wide mb-1.5">Form 500 Quick-Fill</p>
                  <div className="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-1.5">
                    {taxDeposit && (
                      <CopyField label="Total Taxes" value={`$${Number(taxDeposit.amount).toFixed(2)}`} />
                    )}
                    {company?.ein && (
                      <CopyField label="EIN" value={company.ein} />
                    )}
                    {taxQ && (
                      <CopyField label="Tax Year" value={String(taxQ.year)} />
                    )}
                    {taxQ && (
                      <div className="flex items-center gap-1.5">
                        <span className="font-medium">Quarter:</span>{' '}
                        <span>Q{taxQ.quarter} ({['Jan–Mar', 'Apr–Jun', 'Jul–Sep', 'Oct–Dec'][taxQ.quarter - 1]})</span>
                      </div>
                    )}
                    {company?.name && (
                      <CopyField label="Company" value={company.name} />
                    )}
                    {fullAddress && (
                      <div className="sm:col-span-2">
                        <CopyField label="Address" value={fullAddress} />
                      </div>
                    )}
                  </div>
                </div>
              ) : null;
            })()}
          </div>
        </div>
      )}

      <div className="p-4">
        {loading ? (
          <p className="text-sm text-gray-500">Loading...</p>
        ) : checks.length === 0 ? (
          <p className="text-sm text-gray-500 italic">No non-employee checks for this pay period.</p>
        ) : (
          <div className="space-y-3">
            {checks.map(check => {
              const historyOpen = expandedHistoryIds.has(check.id);
              const editCount = check.edit_count ?? 0;
              return (
                <div
                  key={check.id}
                  className={`border rounded-lg overflow-hidden ${check.voided ? 'bg-red-50 border-red-200' : 'hover:bg-gray-50'}`}
                >
                  <div className="flex items-center justify-between p-3">
                    <div className="flex-1">
                      <div className="flex items-center gap-2 flex-wrap">
                        <span className="font-medium text-sm">{check.payable_to}</span>
                        <Badge className={STATUS_COLORS[check.check_status] || 'bg-gray-100 text-gray-700'}>
                          {check.check_status}
                        </Badge>
                        <Badge variant="outline">{CHECK_TYPE_LABELS[check.check_type as NonEmployeeCheckType] || check.check_type}</Badge>
                        {check.auto_generated_type === 'fit_deposit' && (
                          <Badge className="bg-amber-100 text-amber-800">Auto FIT</Badge>
                        )}
                        {editCount > 0 && (
                          <button
                            onClick={() => toggleHistory(check.id)}
                            className="inline-flex items-center gap-1 rounded-full bg-blue-50 px-2 py-0.5 text-xs font-medium text-blue-700 hover:bg-blue-100"
                            title={historyOpen ? 'Hide edit history' : 'Show edit history'}
                          >
                            <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                              <path strokeLinecap="round" strokeLinejoin="round" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
                            </svg>
                            {editCount} edit{editCount === 1 ? '' : 's'}
                          </button>
                        )}
                      </div>
                      <div className="flex items-center gap-4 text-xs text-gray-500 mt-1 flex-wrap">
                        <span className="font-semibold text-gray-900">{fmt(check.amount)}</span>
                        {check.check_number && <span>Check #{check.check_number}</span>}
                        {check.memo && <span>{check.memo}</span>}
                        {check.reference_number && <span>Ref: {check.reference_number}</span>}
                        {check.check_type === 'tax_deposit' && (
                          <a
                            href={DRT.FORM_500_PDF}
                            target="_blank"
                            rel="noopener noreferrer"
                            className="inline-flex items-center gap-1 text-blue-600 hover:text-blue-800 font-medium"
                          >
                            <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                              <path strokeLinecap="round" strokeLinejoin="round" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14" />
                            </svg>
                            Form 500
                          </a>
                        )}
                      </div>
                    </div>
                    <div className="flex gap-1 shrink-0">
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => handlePreviewPdf(check)}
                        disabled={pdfLoading === check.id}
                        className="text-xs px-2 py-1"
                      >
                        {pdfLoading === check.id ? '...' : 'Preview'}
                      </Button>
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => handlePrintSingle(check)}
                        disabled={pdfLoading === check.id}
                        className="text-xs px-2 py-1"
                      >
                        Print
                      </Button>
                      {!check.voided && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => setEditingCheck(check)}
                          className="text-xs px-2 py-1"
                        >
                          Edit
                        </Button>
                      )}
                      {!check.voided && !check.printed_at && (
                        <Button size="sm" variant="outline" onClick={() => handleMarkPrinted(check.id)} disabled={markingPrintedId === check.id}>
                          {markingPrintedId === check.id ? 'Marking...' : 'Mark Printed'}
                        </Button>
                      )}
                      {!check.voided && voidingId !== check.id && (
                        <Button size="sm" variant="outline" className="text-red-600 border-red-300" onClick={() => setVoidingId(check.id)}>
                          Void
                        </Button>
                      )}
                      {voidingId === check.id && (
                        <div className="flex gap-1">
                          <input className="border rounded px-2 py-1 text-xs w-32" placeholder="Reason..." value={voidReason} onChange={e => setVoidReason(e.target.value)} />
                          <Button size="sm" variant="destructive" onClick={() => handleVoid(check.id)} disabled={voidConfirming}>
                            {voidConfirming ? 'Voiding...' : 'Confirm'}
                          </Button>
                          <Button size="sm" variant="outline" onClick={() => { setVoidingId(null); setVoidReason(''); }} disabled={voidConfirming}>Cancel</Button>
                        </div>
                      )}
                      {!check.printed_at && !check.voided && (
                        <Button size="sm" variant="ghost" className="text-red-400" onClick={() => handleDelete(check.id)} disabled={deletingId === check.id}>
                          {deletingId === check.id ? 'Deleting...' : 'Delete'}
                        </Button>
                      )}
                    </div>
                  </div>
                  {historyOpen && (
                    <div className="border-t bg-gray-50">
                      <div className="px-3 py-1.5 text-xs font-medium text-gray-600 uppercase tracking-wide">
                        Edit History
                      </div>
                      <NonEmployeeCheckHistory checkId={check.id} />
                    </div>
                  )}
                </div>
              );
            })}

            <div className="pt-2 border-t flex justify-between text-sm font-semibold">
              <span>Total ({checks.filter(c => !c.voided).length} checks)</span>
              <span>{fmt(checks.filter(c => !c.voided).reduce((sum, c) => sum + Number(c.amount), 0))}</span>
            </div>
          </div>
        )}
      </div>

      <NonEmployeeCheckEditModal
        check={editingCheck}
        onClose={() => setEditingCheck(null)}
        onSaved={handleSavedCheck}
      />

      {/* Full-page PDF Preview modal — rendered as portal for proper z-index */}
      {previewUrl && previewCheck && createPortal(
        <div className="fixed inset-0 z-[9999] flex items-center justify-center bg-gray-900/70 p-4">
          <div className="flex h-[92vh] w-[95vw] max-w-[1400px] flex-col overflow-hidden rounded-2xl bg-white shadow-2xl">
            <div className="flex items-center justify-between border-b px-6 py-4">
              <div>
                <h2 className="text-lg font-semibold text-gray-900">
                  {previewCheck.payable_to}
                  {previewCheck.check_number && ` — Check #${previewCheck.check_number}`}
                </h2>
                <p className="mt-1 text-sm text-gray-500">
                  {CHECK_TYPE_LABELS[previewCheck.check_type as NonEmployeeCheckType] || previewCheck.check_type} &middot; {fmt(previewCheck.amount)}
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
    </Card>
  );
}
