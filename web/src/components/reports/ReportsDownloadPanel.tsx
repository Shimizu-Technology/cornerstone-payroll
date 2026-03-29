import { useState, useCallback, useEffect } from 'react';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { reportsApi } from '@/services/api';
import type { BlobDownload } from '@/services/api';

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

async function fetchReport(reportKey: ReportKey, payPeriodId: number): Promise<BlobDownload> {
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
      return reportsApi.transmittalLogPdf(payPeriodId);
    case 'installmentLoans':
      return reportsApi.installmentLoansPdf();
    case 'fullPrintPackage':
      return reportsApi.fullPrintPackagePdf(payPeriodId);
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

  const isReady = payPeriodStatus !== 'draft';

  const cleanupPreview = useCallback(() => {
    if (previewState.pdfUrl) {
      URL.revokeObjectURL(previewState.pdfUrl);
    }
    setPreviewState({ open: false, key: null, label: '', pdfUrl: null, blobData: null });
  }, [previewState.pdfUrl]);

  const handlePreview = async (reportKey: ReportKey, label: string) => {
    setLoading(prev => ({ ...prev, [reportKey]: true }));
    setError(null);
    setPreviewState({ open: true, key: reportKey, label, pdfUrl: null, blobData: null });

    try {
      const blobData = await fetchReport(reportKey, payPeriodId);
      const url = URL.createObjectURL(blobData.blob);
      setPreviewState(prev => ({ ...prev, pdfUrl: url, blobData }));
    } catch (err) {
      setPreviewState(prev => ({ ...prev, open: false }));
      setError(err instanceof Error ? err.message : 'Failed to generate report');
    } finally {
      setLoading(prev => ({ ...prev, [reportKey]: false }));
    }
  };

  const handleDownload = async (reportKey: ReportKey) => {
    setLoading(prev => ({ ...prev, [reportKey]: true }));
    setError(null);

    try {
      const blobData = await fetchReport(reportKey, payPeriodId);
      downloadBlob(blobData, `${reportKey}.pdf`);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to download report');
    } finally {
      setLoading(prev => ({ ...prev, [reportKey]: false }));
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
    </>
  );
}
