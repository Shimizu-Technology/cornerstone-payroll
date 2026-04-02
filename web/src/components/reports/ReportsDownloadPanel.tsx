import { useState, useCallback, useEffect } from 'react';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { reportsApi, transmittalApi } from '@/services/api';
import type { BlobDownload, TransmittalOptions, TransmittalPreview } from '@/services/api';
import { Loader2 } from 'lucide-react';

interface ReportsDownloadPanelProps {
  payPeriodId: number;
  payPeriodStatus: string;
}

type ReportKey =
  | 'payrollRegister'
  | 'payrollSummaryByEmployee'
  | 'deductionsContributions'
  | 'paycheckHistory'
  | 'retirementPlans'
  | 'transmittalLog'
  | 'installmentLoans'
  | 'fullPrintPackage';

const REPORTS: { key: ReportKey; label: string; description: string }[] = [
  { key: 'payrollRegister', label: 'Payroll Register', description: 'Full payroll register with all employee details' },
  { key: 'payrollSummaryByEmployee', label: 'Payroll Summary by Employee', description: 'Detailed breakdown of earnings, deductions, and taxes per employee' },
  { key: 'deductionsContributions', label: 'Deductions & Contributions', description: 'All employee deductions and employer contributions' },
  { key: 'paycheckHistory', label: 'Paycheck History', description: 'Check numbers, amounts, and status for all paychecks' },
  { key: 'retirementPlans', label: 'Retirement Plans Report', description: '401(k) and retirement contributions summary' },
  { key: 'transmittalLog', label: 'Transmittal Log', description: 'Cover document listing all items delivered to client' },
  { key: 'installmentLoans', label: 'Employee Installment Loans', description: 'Loan balances and transaction history' },
  { key: 'fullPrintPackage', label: 'Full Print Package', description: 'All reports combined into a single PDF' },
];

const DEFAULT_REPORT_LIST = [
  'Payroll Summary by Employee',
  'Deductions and Contributions Report',
  'Paycheck History',
  'Retirement Plans Report',
  'Employee Installment Loan Report',
];

const DEFAULT_NOTES = [
  'EFTPS payment to be done by client',
  '401K upload to be submitted by client',
];

function fmt(val: number) {
  return `$${val.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',')}`;
}

function TransmittalEditorModal({
  open,
  onClose,
  onGenerate,
  targetLabel,
  payPeriodId,
}: {
  open: boolean;
  onClose: () => void;
  onGenerate: (options: TransmittalOptions) => void;
  targetLabel: string;
  payPeriodId: number;
}) {
  const [preparerName, setPreparerName] = useState('Cornerstone Tax Services');
  const [notes, setNotes] = useState<string[]>([]);
  const [reportList, setReportList] = useState<string[]>(DEFAULT_REPORT_LIST);
  const [newNote, setNewNote] = useState('');
  const [newReport, setNewReport] = useState('');
  const [preview, setPreview] = useState<TransmittalPreview | null>(null);
  const [loadingPreview, setLoadingPreview] = useState(false);
  const [initialized, setInitialized] = useState(false);
  const [checkFirst, setCheckFirst] = useState('');
  const [checkLast, setCheckLast] = useState('');
  const [neCheckNumbers, setNeCheckNumbers] = useState<Record<number, string>>({});

  useEffect(() => {
    if (!open) {
      setInitialized(false);
      return;
    }
    const handleEsc = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handleEsc);
    return () => document.removeEventListener('keydown', handleEsc);
  }, [open, onClose]);

  useEffect(() => {
    if (!open || initialized) return;
    setLoadingPreview(true);
    setPreparerName('Cornerstone Tax Services');
    setReportList([...DEFAULT_REPORT_LIST]);
    setNewNote('');
    setNewReport('');
    transmittalApi.preview(payPeriodId).then((data) => {
      setPreview(data);
      setCheckFirst(data.payroll_checks.first || '');
      setCheckLast(data.payroll_checks.last || '');
      const neNums: Record<number, string> = {};
      data.non_employee_checks.forEach(c => { neNums[c.id] = c.check_number || ''; });
      setNeCheckNumbers(neNums);
      const autoNotes: string[] = [];
      if (data.tax_totals.total_fica > 0) {
        autoNotes.push(`EFTPS Payment (Social Security & Medicare): ${fmt(data.tax_totals.total_fica)} — to be deducted from bank account`);
      }
      if (data.tax_totals.fit > 0) {
        autoNotes.push(`FIT Deposit Total: ${fmt(data.tax_totals.fit)} — check to Treasurer of Guam for DRT`);
      }
      autoNotes.push(...DEFAULT_NOTES);
      setNotes(autoNotes);
      setInitialized(true);
    }).catch(() => {
      setNotes([...DEFAULT_NOTES]);
      setInitialized(true);
    }).finally(() => setLoadingPreview(false));
  }, [open, payPeriodId, initialized]);

  if (!open) return null;

  const handleAddNote = () => {
    const trimmed = newNote.trim();
    if (trimmed) {
      setNotes(prev => [...prev, trimmed]);
      setNewNote('');
    }
  };

  const handleRemoveNote = (idx: number) => {
    setNotes(prev => prev.filter((_, i) => i !== idx));
  };

  const handleAddReport = () => {
    const trimmed = newReport.trim();
    if (trimmed) {
      setReportList(prev => [...prev, trimmed]);
      setNewReport('');
    }
  };

  const handleRemoveReport = (idx: number) => {
    setReportList(prev => prev.filter((_, i) => i !== idx));
  };

  const handleGenerate = () => {
    const hasNeOverrides = Object.values(neCheckNumbers).some(v => v.trim());
    onGenerate({
      preparerName: preparerName.trim() || undefined,
      notes: notes.length > 0 ? notes : undefined,
      reportList: reportList.length > 0 ? reportList : undefined,
      checkNumberFirst: checkFirst.trim() || undefined,
      checkNumberLast: checkLast.trim() || undefined,
      nonEmployeeCheckNumbers: hasNeOverrides ? neCheckNumbers : undefined,
    });
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="fixed inset-0 bg-black/50" onClick={onClose} />
      <div className="relative z-50 bg-white rounded-lg shadow-xl w-full max-w-3xl max-h-[90vh] overflow-y-auto mx-4">
        <div className="sticky top-0 bg-white border-b px-6 py-4 flex items-center justify-between rounded-t-lg z-10">
          <h3 className="text-lg font-semibold text-gray-900">Edit {targetLabel}</h3>
          <button onClick={onClose} className="text-gray-400 hover:text-gray-600 p-1">
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {loadingPreview ? (
          <div className="flex items-center justify-center py-12">
            <Loader2 className="w-6 h-6 animate-spin text-blue-600" />
            <span className="ml-2 text-sm text-gray-500">Loading transmittal data...</span>
          </div>
        ) : (
          <div className="px-6 py-4 space-y-6">
            {/* Preparer Name */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Preparer Name</label>
              <input
                type="text"
                value={preparerName}
                onChange={(e) => setPreparerName(e.target.value)}
                placeholder="e.g. Cornerstone Tax Services"
                className="w-full border rounded-md px-3 py-2 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
              />
            </div>

            {/* Documents Provided Preview */}
            {preview && (
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">Documents Provided to Client</label>
                <div className="bg-gray-50 border rounded-lg p-4 space-y-4 text-sm">
                  {/* Payroll Checks */}
                  {preview.payroll_checks.count > 0 && (
                    <div>
                      <p className="font-medium text-gray-900">1) Payroll Checks</p>
                      <div className="ml-6 text-gray-600 space-y-1.5 mt-1">
                        <p>Number of Checks: <span className="font-medium text-gray-900">{preview.payroll_checks.count}</span></p>
                        <div className="flex items-center gap-2">
                          <span>Checks #</span>
                          <input
                            type="text"
                            value={checkFirst}
                            onChange={(e) => setCheckFirst(e.target.value)}
                            className="w-20 border rounded px-2 py-0.5 text-sm font-medium text-gray-900 text-center"
                            placeholder="First"
                          />
                          <span>through</span>
                          <input
                            type="text"
                            value={checkLast}
                            onChange={(e) => setCheckLast(e.target.value)}
                            className="w-20 border rounded px-2 py-0.5 text-sm font-medium text-gray-900 text-center"
                            placeholder="Last"
                          />
                        </div>
                      </div>
                    </div>
                  )}

                  {/* Non-Employee Checks */}
                  {preview.non_employee_checks.map((check, idx) => (
                    <div key={check.id}>
                      <p className="font-medium text-gray-900">
                        {(preview.payroll_checks.count > 0 ? 2 : 1) + idx}) {check.payable_to} — {check.check_type}
                      </p>
                      <div className="ml-6 text-gray-600 space-y-1 mt-1">
                        <div className="flex items-center gap-2">
                          <span>Check #:</span>
                          <input
                            type="text"
                            value={neCheckNumbers[check.id] || ''}
                            onChange={(e) => setNeCheckNumbers(prev => ({ ...prev, [check.id]: e.target.value }))}
                            className="w-24 border rounded px-2 py-0.5 text-sm font-medium text-gray-900 text-center"
                            placeholder="____"
                          />
                        </div>
                        <p>Amount: <span className="font-medium text-gray-900">{fmt(check.amount)}</span></p>
                        <p>Payable to: <span className="font-medium text-gray-900">{check.payable_to}</span></p>
                        {check.memo && <p>For: {check.check_type} — {check.memo}</p>}
                        {check.description && <p>Description/Memo: {check.description}</p>}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {/* Employer Tax Obligations */}
            {preview && preview.tax_totals.total_drt_deposit > 0 && (
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">Employer Tax Obligations</label>
                <div className="bg-amber-50 border border-amber-200 rounded-lg p-4 text-sm">
                  <div className="grid grid-cols-2 gap-x-8 gap-y-1">
                    <div>
                      <p className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-1">Federal / Guam Income Tax</p>
                      <div className="flex justify-between">
                        <span className="text-gray-600">Employee FIT Withheld</span>
                        <span className="font-medium">{fmt(preview.tax_totals.fit)}</span>
                      </div>
                      <div className="flex justify-between border-t mt-1 pt-1 font-semibold">
                        <span>FIT Subtotal</span>
                        <span>{fmt(preview.tax_totals.fit)}</span>
                      </div>
                    </div>
                    <div>
                      <p className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-1">Social Security & Medicare (FICA)</p>
                      <div className="flex justify-between">
                        <span className="text-gray-600">Employee SS (6.2%)</span>
                        <span>{fmt(preview.tax_totals.employee_ss)}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-gray-600">Employer SS (6.2%)</span>
                        <span>{fmt(preview.tax_totals.employer_ss)}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-gray-600">Employee Medicare (1.45%)</span>
                        <span>{fmt(preview.tax_totals.employee_medicare)}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-gray-600">Employer Medicare (1.45%)</span>
                        <span>{fmt(preview.tax_totals.employer_medicare)}</span>
                      </div>
                      <div className="flex justify-between border-t mt-1 pt-1 font-semibold">
                        <span>FICA Subtotal</span>
                        <span>{fmt(preview.tax_totals.total_fica)}</span>
                      </div>
                    </div>
                  </div>
                  <div className="mt-3 pt-3 border-t border-amber-300 flex justify-between text-base font-bold text-amber-800">
                    <span>Total DRT Deposit (FIT + FICA)</span>
                    <span>{fmt(preview.tax_totals.total_drt_deposit)}</span>
                  </div>
                </div>
              </div>
            )}

            {/* Notes */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Notes</label>
              <p className="text-xs text-gray-500 mb-2">Instructions or reminders for the client — auto-populated with tax totals</p>
              <div className="space-y-2">
                {notes.map((note, idx) => (
                  <div key={idx} className="flex items-center gap-2 group">
                    <input
                      type="text"
                      value={note}
                      onChange={(e) => {
                        const updated = [...notes];
                        updated[idx] = e.target.value;
                        setNotes(updated);
                      }}
                      className="flex-1 border rounded-md px-3 py-1.5 text-sm"
                    />
                    <button
                      onClick={() => handleRemoveNote(idx)}
                      className="text-red-400 hover:text-red-600 opacity-0 group-hover:opacity-100 transition-opacity p-1"
                      title="Remove"
                    >
                      <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                      </svg>
                    </button>
                  </div>
                ))}
                <div className="flex items-center gap-2">
                  <input
                    type="text"
                    value={newNote}
                    onChange={(e) => setNewNote(e.target.value)}
                    onKeyDown={(e) => { if (e.key === 'Enter') handleAddNote(); }}
                    placeholder="Add a note..."
                    className="flex-1 border border-dashed rounded-md px-3 py-1.5 text-sm text-gray-500"
                  />
                  <button
                    onClick={handleAddNote}
                    disabled={!newNote.trim()}
                    className="text-blue-600 hover:text-blue-800 disabled:text-gray-300 text-sm font-medium px-2"
                  >
                    + Add
                  </button>
                </div>
              </div>
            </div>

            {/* Report List */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Reports Included</label>
              <p className="text-xs text-gray-500 mb-2">Listed on the transmittal as documents provided to client</p>
              <div className="space-y-2">
                {reportList.map((report, idx) => (
                  <div key={idx} className="flex items-center gap-2 group">
                    <span className="text-sm text-gray-500 w-6 text-right">{idx + 1}.</span>
                    <input
                      type="text"
                      value={report}
                      onChange={(e) => {
                        const updated = [...reportList];
                        updated[idx] = e.target.value;
                        setReportList(updated);
                      }}
                      className="flex-1 border rounded-md px-3 py-1.5 text-sm"
                    />
                    <button
                      onClick={() => handleRemoveReport(idx)}
                      className="text-red-400 hover:text-red-600 opacity-0 group-hover:opacity-100 transition-opacity p-1"
                      title="Remove"
                    >
                      <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                      </svg>
                    </button>
                  </div>
                ))}
                <div className="flex items-center gap-2">
                  <span className="text-sm text-gray-400 w-6 text-right">{reportList.length + 1}.</span>
                  <input
                    type="text"
                    value={newReport}
                    onChange={(e) => setNewReport(e.target.value)}
                    onKeyDown={(e) => { if (e.key === 'Enter') handleAddReport(); }}
                    placeholder="Add a report..."
                    className="flex-1 border border-dashed rounded-md px-3 py-1.5 text-sm text-gray-500"
                  />
                  <button
                    onClick={handleAddReport}
                    disabled={!newReport.trim()}
                    className="text-blue-600 hover:text-blue-800 disabled:text-gray-300 text-sm font-medium px-2"
                  >
                    + Add
                  </button>
                </div>
              </div>
            </div>
          </div>
        )}

        <div className="sticky bottom-0 bg-gray-50 border-t px-6 py-4 flex justify-end gap-3 rounded-b-lg">
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button onClick={handleGenerate} disabled={loadingPreview}>Generate {targetLabel}</Button>
        </div>
      </div>
    </div>
  );
}

function downloadBlob(blobData: BlobDownload, fallbackName: string) {
  const url = URL.createObjectURL(blobData.blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = blobData.filename || fallbackName;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

async function fetchReport(
  reportKey: ReportKey,
  payPeriodId: number,
  transmittalOptions?: TransmittalOptions
): Promise<BlobDownload> {
  switch (reportKey) {
    case 'payrollRegister':
      return reportsApi.payrollRegisterPdf(payPeriodId);
    case 'payrollSummaryByEmployee':
      return reportsApi.payrollSummaryByEmployeePdf(payPeriodId);
    case 'deductionsContributions':
      return reportsApi.deductionsContributionsPdf(payPeriodId);
    case 'paycheckHistory':
      return reportsApi.paycheckHistoryPdf(payPeriodId);
    case 'retirementPlans':
      return reportsApi.retirementPlansPdf(payPeriodId);
    case 'transmittalLog':
      return reportsApi.transmittalLogPdf(payPeriodId, transmittalOptions);
    case 'installmentLoans':
      return reportsApi.installmentLoansPdf();
    case 'fullPrintPackage':
      return reportsApi.fullPrintPackagePdf(payPeriodId, transmittalOptions);
  }
}

function PdfPreviewModal({
  open,
  onClose,
  pdfUrl,
  title,
  onDownload,
  onPrint,
}: {
  open: boolean;
  onClose: () => void;
  pdfUrl: string | null;
  title: string;
  onDownload: () => void;
  onPrint: () => void;
}) {
  useEffect(() => {
    if (!open) return;
    const handleEsc = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handleEsc);
    return () => document.removeEventListener('keydown', handleEsc);
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex flex-col">
      <div className="fixed inset-0 bg-black/60" onClick={onClose} />

      <div className="relative z-50 flex flex-col h-full m-3 sm:m-6">
        {/* Header */}
        <div className="flex items-center justify-between bg-gray-900 text-white px-4 py-3 rounded-t-lg shrink-0">
          <h3 className="font-semibold text-sm sm:text-base truncate mr-4">{title}</h3>
          <div className="flex items-center gap-2 shrink-0">
            <button
              onClick={onPrint}
              className="flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium bg-white/10 hover:bg-white/20 rounded transition-colors"
              title="Print"
            >
              <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M17 17h2a2 2 0 002-2v-4a2 2 0 00-2-2H5a2 2 0 00-2 2v4a2 2 0 002 2h2m2 4h6a2 2 0 002-2v-4a2 2 0 00-2-2H9a2 2 0 00-2 2v4a2 2 0 002 2zm8-12V5a2 2 0 00-2-2H9a2 2 0 00-2 2v4h10z" />
              </svg>
              Print
            </button>
            <button
              onClick={onDownload}
              className="flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium bg-white/10 hover:bg-white/20 rounded transition-colors"
              title="Download"
            >
              <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
              </svg>
              Download
            </button>
            <button
              onClick={onClose}
              className="ml-2 p-1.5 hover:bg-white/20 rounded transition-colors"
              title="Close (Esc)"
            >
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
        </div>

        {/* PDF Content */}
        <div className="flex-1 bg-gray-200 rounded-b-lg overflow-hidden min-h-0">
          {pdfUrl ? (
            <iframe
              src={pdfUrl}
              className="w-full h-full border-0"
              title={title}
            />
          ) : (
            <div className="flex items-center justify-center h-full">
              <div className="flex flex-col items-center gap-3 text-gray-500">
                <svg className="animate-spin h-8 w-8" viewBox="0 0 24 24">
                  <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none" />
                  <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                </svg>
                <p className="text-sm font-medium">Generating report...</p>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

export function ReportsDownloadPanel({ payPeriodId, payPeriodStatus }: ReportsDownloadPanelProps) {
  const [loading, setLoading] = useState<Record<string, boolean>>({});
  const [error, setError] = useState<string | null>(null);
  const [previewState, setPreviewState] = useState<{
    open: boolean;
    key: ReportKey | null;
    label: string;
    pdfUrl: string | null;
    blobData: BlobDownload | null;
  }>({ open: false, key: null, label: '', pdfUrl: null, blobData: null });
  const [transmittalEditor, setTransmittalEditor] = useState<{
    open: boolean;
    key: ReportKey | null;
    label: string;
    mode: 'preview' | 'download';
  }>({ open: false, key: null, label: '', mode: 'preview' });

  const isReady = payPeriodStatus !== 'draft';

  const needsTransmittalEditor = (key: ReportKey) => key === 'transmittalLog' || key === 'fullPrintPackage';

  const cleanupPreview = useCallback(() => {
    if (previewState.pdfUrl) {
      URL.revokeObjectURL(previewState.pdfUrl);
    }
    setPreviewState({ open: false, key: null, label: '', pdfUrl: null, blobData: null });
  }, [previewState.pdfUrl]);

  const handlePreview = async (reportKey: ReportKey, label: string, transmittalOpts?: TransmittalOptions) => {
    if (needsTransmittalEditor(reportKey) && !transmittalOpts) {
      setTransmittalEditor({ open: true, key: reportKey, label, mode: 'preview' });
      return;
    }

    setLoading(prev => ({ ...prev, [reportKey]: true }));
    setError(null);
    setPreviewState({ open: true, key: reportKey, label, pdfUrl: null, blobData: null });

    try {
      const blobData = await fetchReport(reportKey, payPeriodId, transmittalOpts);
      const url = URL.createObjectURL(blobData.blob);
      setPreviewState(prev => ({ ...prev, pdfUrl: url, blobData }));
    } catch (err) {
      setPreviewState(prev => ({ ...prev, open: false }));
      setError(err instanceof Error ? err.message : 'Failed to generate report');
    } finally {
      setLoading(prev => ({ ...prev, [reportKey]: false }));
    }
  };

  const handleDownload = async (reportKey: ReportKey, transmittalOpts?: TransmittalOptions) => {
    if (needsTransmittalEditor(reportKey) && !transmittalOpts) {
      setTransmittalEditor({ open: true, key: reportKey, label: REPORTS.find(r => r.key === reportKey)?.label || '', mode: 'download' });
      return;
    }

    setLoading(prev => ({ ...prev, [reportKey]: true }));
    setError(null);

    try {
      const blobData = await fetchReport(reportKey, payPeriodId, transmittalOpts);
      downloadBlob(blobData, `${reportKey}.pdf`);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to download report');
    } finally {
      setLoading(prev => ({ ...prev, [reportKey]: false }));
    }
  };

  const handleTransmittalGenerate = (options: TransmittalOptions) => {
    const { key, mode } = transmittalEditor;
    setTransmittalEditor({ open: false, key: null, label: '', mode: 'preview' });
    if (!key) return;

    if (mode === 'preview') {
      handlePreview(key, REPORTS.find(r => r.key === key)?.label || '', options);
    } else {
      handleDownload(key, options);
    }
  };

  const handlePreviewDownload = () => {
    if (previewState.blobData) {
      downloadBlob(previewState.blobData, `${previewState.key || 'report'}.pdf`);
    }
  };

  const handlePreviewPrint = () => {
    if (previewState.pdfUrl) {
      const printWindow = window.open(previewState.pdfUrl, '_blank');
      if (printWindow) {
        printWindow.addEventListener('load', () => {
          printWindow.print();
        });
      }
    }
  };

  if (!isReady) return null;

  return (
    <>
      <Card>
        <div className="p-4 border-b bg-gray-50">
          <h3 className="font-semibold text-gray-900">Reports & Documents</h3>
          <p className="text-sm text-gray-500 mt-1">
            View, download, or print reports for this pay period
          </p>
        </div>
        <div className="p-4">
          {error && (
            <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded text-sm text-red-700">
              {error}
            </div>
          )}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
            {REPORTS.map(report => (
              <div key={report.key} className="flex items-center justify-between p-3 border rounded-lg hover:bg-gray-50 transition-colors">
                <div className="mr-3 min-w-0">
                  <p className="font-medium text-sm text-gray-900">{report.label}</p>
                  <p className="text-xs text-gray-500 truncate">{report.description}</p>
                </div>
                <div className="flex items-center gap-1.5 shrink-0">
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => handlePreview(report.key, report.label)}
                    disabled={loading[report.key]}
                    className="text-xs"
                  >
                    {loading[report.key] ? (
                      <span className="flex items-center gap-1">
                        <svg className="animate-spin h-3 w-3" viewBox="0 0 24 24">
                          <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none" />
                          <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                        </svg>
                        Loading...
                      </span>
                    ) : (
                      <>
                        <svg className="w-3.5 h-3.5 mr-1" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                          <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
                          <path strokeLinecap="round" strokeLinejoin="round" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z" />
                        </svg>
                        View
                      </>
                    )}
                  </Button>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => handleDownload(report.key)}
                    disabled={loading[report.key]}
                    className="text-xs"
                    title="Download PDF"
                  >
                    <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
                    </svg>
                  </Button>
                </div>
              </div>
            ))}
          </div>
        </div>
      </Card>

      <PdfPreviewModal
        open={previewState.open}
        onClose={cleanupPreview}
        pdfUrl={previewState.pdfUrl}
        title={previewState.label}
        onDownload={handlePreviewDownload}
        onPrint={handlePreviewPrint}
      />

      <TransmittalEditorModal
        open={transmittalEditor.open}
        onClose={() => setTransmittalEditor({ open: false, key: null, label: '', mode: 'preview' })}
        onGenerate={handleTransmittalGenerate}
        targetLabel={transmittalEditor.label}
        payPeriodId={payPeriodId}
      />
    </>
  );
}
