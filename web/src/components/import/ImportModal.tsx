import { useEffect, useState, useRef } from 'react';
import { CheckCircle2, Download, RefreshCw } from 'lucide-react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { formatCurrency } from '@/lib/utils';
import { payrollIntakeImportsApi, payPeriodsApi } from '@/services/api';
import type { ImportPreviewResponse, MosaSourceRow, PayrollIntakeImportData } from '@/services/api';
import type { PayPeriod, PayrollItem } from '@/types';

interface ImportModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  payPeriodId: number;
  onSourcePreviewed?: () => void;
  onImportComplete: (payPeriod: PayPeriod & { payroll_items?: PayrollItem[] }) => void;
}

type Step = 'upload' | 'preview' | 'applying' | 'done';
type EditableSourceRow = MosaSourceRow;

export function ImportModal({ open, onOpenChange, payPeriodId, onSourcePreviewed, onImportComplete }: ImportModalProps) {
  const [step, setStep] = useState<Step>('upload');
  const [pdfFile, setPdfFile] = useState<File | null>(null);
  const [excelFile, setExcelFile] = useState<File | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [previewData, setPreviewData] = useState<ImportPreviewResponse | null>(null);
  const [sourceRows, setSourceRows] = useState<EditableSourceRow[]>([]);
  const [tipsPaidOutFromTips, setTipsPaidOutFromTips] = useState(false);
  const [reviewedSuggestedMatches, setReviewedSuggestedMatches] = useState(false);
  const [reviewedOverwrite, setReviewedOverwrite] = useState(false);
  const [results, setResults] = useState<{ success: number; errors: string[] } | null>(null);
  const [templateDownloading, setTemplateDownloading] = useState(false);
  const [currentPackage, setCurrentPackage] = useState<PayrollIntakeImportData | null>(null);
  const [replacementConfirmed, setReplacementConfirmed] = useState(false);
  const [replacementReason, setReplacementReason] = useState('');
  const pdfInputRef = useRef<HTMLInputElement>(null);
  const excelInputRef = useRef<HTMLInputElement>(null);

  const reset = () => {
    setStep('upload');
    setPdfFile(null);
    setExcelFile(null);
    setLoading(false);
    setError(null);
    setPreviewData(null);
    setSourceRows([]);
    setTipsPaidOutFromTips(false);
    setReviewedSuggestedMatches(false);
    setReviewedOverwrite(false);
    setResults(null);
    setTemplateDownloading(false);
    setCurrentPackage(null);
    setReplacementConfirmed(false);
    setReplacementReason('');
  };

  useEffect(() => {
    if (!open) return;

    let active = true;
    payrollIntakeImportsApi.list(payPeriodId).then((response) => {
      if (!active) return;
      setCurrentPackage(response.imports.find((entry) => entry.source_type === 'mosa_revel' && entry.current) || null);
    }).catch((err) => {
      if (active) setError(err instanceof Error ? err.message : 'Could not load retained source history');
    });
    return () => { active = false; };
  }, [open, payPeriodId]);

  const handleDownloadTemplate = async () => {
    try {
      setTemplateDownloading(true);
      setError(null);
      const blob = await payPeriodsApi.downloadSupplementalTemplate(payPeriodId);
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = 'Cornerstone-payroll-changes.xlsx';
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      URL.revokeObjectURL(url);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to download the change workbook');
    } finally {
      setTemplateDownloading(false);
    }
  };

  const openPreview = (data: ImportPreviewResponse) => {
    setPreviewData(data);
    setSourceRows(data.preview.source_rows.map((row) => ({
      ...row,
      disposition: row.row_kind === 'matched' && row.errors.length === 0 ? 'included' : 'pending',
    })));
    setTipsPaidOutFromTips(data.preview.tips_paid_out_from_tips);
    setReviewedSuggestedMatches(false);
    setReviewedOverwrite(false);
    setStep('preview');
  };

  const handleResumeCurrent = async () => {
    try {
      setLoading(true);
      setError(null);
      openPreview(await payPeriodsApi.currentImport(payPeriodId));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not reopen the current MoSa import');
    } finally {
      setLoading(false);
    }
  };

  const handleClose = () => {
    if (loading || step === 'applying') return;
    reset();
    onOpenChange(false);
  };

  const handlePreview = async () => {
    if (!pdfFile) return;
    try {
      setLoading(true);
      setError(null);
      setReviewedSuggestedMatches(false);
      setReviewedOverwrite(false);
      const data = await payPeriodsApi.previewImport(
        payPeriodId,
        pdfFile,
        excelFile || undefined,
        tipsPaidOutFromTips,
        currentPackage && replacementConfirmed
          ? { supersedesPackageId: currentPackage.package_id, reason: replacementReason.trim() }
          : undefined,
      );
      openPreview(data);
      onSourcePreviewed?.();
      void payrollIntakeImportsApi.list(payPeriodId).then((history) => {
        setCurrentPackage(history.imports.find((entry) => entry.source_type === 'mosa_revel' && entry.current) || null);
      }).catch(() => undefined);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to parse files');
    } finally {
      setLoading(false);
    }
  };

  const handleApply = async () => {
    if (!previewData) return;
    try {
      setStep('applying');
      setError(null);
      const response = await payPeriodsApi.applyImport(payPeriodId, {
        import_id: previewData.import_id,
        rows: sourceRows.map((row) => ({
          id: row.id,
          disposition: row.disposition,
          disposition_reason: row.disposition_reason,
          target_pay_period_id: row.target_pay_period_id,
        })),
        acknowledge_low_confidence_matches: reviewedSuggestedMatches,
        force_overwrite: reviewedOverwrite,
      });
      setResults({
        success: response.results.success.length,
        errors: response.results.errors.map((e) => `${e.name}: ${e.error}`),
      });
      setStep('done');
      onImportComplete(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to apply import');
      setStep('preview');
    }
  };

  const updateSourceRow = (rowId: number, patch: Partial<EditableSourceRow>) => {
    setReviewedOverwrite(false);
    setSourceRows((current) => current.map((row) => row.id === rowId ? { ...row, ...patch } : row));
  };

  const matched = previewData?.preview.matched || [];
  const includedSourceRows = sourceRows.filter((row) => row.disposition === 'included');
  const includedSourceRowIds = new Set(includedSourceRows.map((row) => row.id));
  const included = matched.filter((row) => includedSourceRowIds.has(row.source_row_id));
  const missingPeriodPay = included.filter((row) => row.period_pay_missing);
  const overwriteRows = included.filter((row) => row.overwrite_required);
  const incompleteSourceRows = sourceRows.filter((row) => (
    row.disposition === 'pending'
      || (['excluded', 'deferred', 'informational'].includes(row.disposition) && !row.disposition_reason?.trim())
      || (row.disposition === 'deferred' && !row.target_pay_period_id)
  ));
  const duplicateIncludedEmployeeIds = new Set(includedSourceRows.map((row) => row.employee_id).filter(Boolean).filter((id, index, ids) => ids.indexOf(id) !== index));
  const includedBlockingRows = includedSourceRows.filter((row) => row.errors.some((entry) => entry.code !== 'duplicate_employee' || duplicateIncludedEmployeeIds.has(row.employee_id)));
  const unresolvedCount = incompleteSourceRows.length + includedBlockingRows.length;
  const suggestedMatchCount = previewData?.preview.low_confidence_matches.filter((match) => includedSourceRows.some((row) => row.employee_id === match.employee_id)).length || 0;
  const suggestedMatches = previewData?.preview.low_confidence_matches.filter((match) => includedSourceRows.some((row) => row.employee_id === match.employee_id)) || [];
  const nonMatchedSourceRows = sourceRows.filter((row) => row.row_kind !== 'matched');
  const canApply = Boolean(
    previewData
      && sourceRows.length > 0
      && incompleteSourceRows.length === 0
      && includedBlockingRows.length === 0
      && duplicateIncludedEmployeeIds.size === 0
      && missingPeriodPay.length === 0
      && (overwriteRows.length === 0 || reviewedOverwrite)
      && (suggestedMatchCount === 0 || reviewedSuggestedMatches),
  );
  const replacementReady = !replacementConfirmed || replacementReason.trim().length > 0;

  const dispositionControls = (row: EditableSourceRow) => (
    <div className="space-y-2">
      <Select
        aria-label={`Outcome for ${row.source_employee_name}`}
        value={row.disposition}
        onChange={(event) => {
          const disposition = event.target.value as EditableSourceRow['disposition'];
          updateSourceRow(row.id, {
            disposition,
            disposition_reason: disposition === 'included' ? null : row.disposition_reason,
            target_pay_period_id: disposition === 'deferred' ? row.target_pay_period_id : null,
          });
        }}
      >
        <option value="pending">Choose outcome</option>
        {row.row_kind === 'matched' && <option value="included">Include in this payroll</option>}
        <option value="excluded">Exclude from payroll</option>
        <option value="deferred">Move to a future payroll</option>
        <option value="informational">Informational only</option>
      </Select>
      {['excluded', 'deferred', 'informational'].includes(row.disposition) && (
        <>
          <Input
            aria-label={`Reason for ${row.source_employee_name}`}
            value={row.disposition_reason || ''}
            onChange={(event) => updateSourceRow(row.id, { disposition_reason: event.target.value })}
            placeholder="Required reason"
          />
          {row.disposition === 'deferred' && (
            <Select
              aria-label={`Future payroll for ${row.source_employee_name}`}
              value={row.target_pay_period_id ? String(row.target_pay_period_id) : ''}
              onChange={(event) => updateSourceRow(row.id, { target_pay_period_id: event.target.value ? Number(event.target.value) : null })}
            >
              <option value="">Choose future payroll</option>
              {previewData?.source_package.disposition_targets.map((target) => <option key={target.id} value={target.id}>{target.label}</option>)}
            </Select>
          )}
        </>
      )}
    </div>
  );

  return (
    <Dialog open={open} onOpenChange={handleClose} dismissOnEscape={!loading && step !== 'applying'}>
      <DialogContent className="dialog-top dialog-wide max-w-6xl max-h-[calc(100vh-8rem)] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Import Payroll Data</DialogTitle>
          <DialogDescription>
            {step === 'upload' && 'Upload the Revel hours PDF and, when needed, one payroll change workbook.'}
            {step === 'preview' && (unresolvedCount > 0
              ? `${unresolvedCount} source row${unresolvedCount === 1 ? '' : 's'} need attention before this import can be applied.`
              : missingPeriodPay.length > 0
                ? 'Enter the missing period pay before applying this import.'
                : `${included.length} employees are ready. Review the source matches and apply.`)}
            {step === 'applying' && 'Applying import...'}
            {step === 'done' && 'Import complete.'}
          </DialogDescription>
        </DialogHeader>

        {error && (
          <div className="p-3 bg-red-50 border border-red-200 text-red-700 rounded-lg text-sm">
            {error}
          </div>
        )}

        {/* Upload Step */}
        {step === 'upload' && (
          <div className="space-y-4 py-2">
            {currentPackage && (
              <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-amber-950">
                <div className="flex items-start gap-3">
                  <RefreshCw className="mt-0.5 h-5 w-5 shrink-0" aria-hidden="true" />
                  <div className="flex-1">
                    <p className="font-semibold">Revision {currentPackage.package_revision} is the current retained source</p>
                    <p className="mt-1 text-sm text-amber-800">
                      {['previewed', 'reviewed'].includes(currentPackage.status)
                        ? 'Continue the saved review, or upload corrected files and document what changed.'
                        : 'This source was already applied. Upload again only when MoSa sent a correction.'}
                    </p>
                    {['previewed', 'reviewed'].includes(currentPackage.status) && (
                      <Button type="button" variant="outline" size="sm" className="mt-3 border-amber-300 bg-white" onClick={() => void handleResumeCurrent()} disabled={loading}>
                        Continue revision {currentPackage.package_revision}
                      </Button>
                    )}
                    <label className="mt-3 flex items-start gap-2 text-sm font-medium">
                      <input type="checkbox" checked={replacementConfirmed} onChange={(event) => setReplacementConfirmed(event.target.checked)} className="mt-0.5 rounded border-amber-300" />
                      <span>This corrected Revel package replaces revision {currentPackage.package_revision}.</span>
                    </label>
                    {replacementConfirmed && (
                      <Input
                        label="What changed?"
                        value={replacementReason}
                        onChange={(event) => setReplacementReason(event.target.value)}
                        placeholder="Example: MoSa corrected Mo’s regular hours."
                        className="mt-3 bg-white"
                      />
                    )}
                  </div>
                </div>
              </div>
            )}
            <div className="rounded-2xl border border-primary-200 bg-primary-50/60 p-4">
              <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <p className="font-semibold text-primary-950">Start with this payroll's change-only workbook</p>
                  <p className="mt-1 text-sm text-primary-800">It is prefilled with Cornerstone employee IDs and the exact payroll dates. MoSa enters Mo and Sara’s pay separately, plus tips and approved period-only items. Recurring loans and 401(k) setup stay in Cornerstone.</p>
                </div>
                <Button type="button" variant="outline" onClick={handleDownloadTemplate} disabled={templateDownloading} className="shrink-0">
                  <Download className="mr-2 h-4 w-4" aria-hidden="true" />
                  {templateDownloading ? 'Preparing...' : 'Download workbook'}
                </Button>
              </div>
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Revel POS Payroll PDF <span className="text-red-500">*</span>
              </label>
              <input
                ref={pdfInputRef}
                type="file"
                accept=".pdf"
                onChange={(e) => setPdfFile(e.target.files?.[0] || null)}
                className="block w-full text-sm text-gray-500 file:mr-4 file:py-2 file:px-4 file:rounded-md file:border-0 file:text-sm file:font-medium file:bg-blue-50 file:text-blue-700 hover:file:bg-blue-100"
              />
              {pdfFile && <p className="text-xs text-gray-500 mt-1">{pdfFile.name}</p>}
              <p className="mt-2 text-xs text-gray-500">
                Keep using the original Revel report. Its regular and overtime hours are imported; Revel pay rates and pay amounts are ignored. The dates in the report must match this payroll.
              </p>
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Cornerstone payroll changes workbook (optional)
              </label>
              <input
                ref={excelInputRef}
                type="file"
                accept=".xlsx,.xls"
                onChange={(e) => {
                  setExcelFile(e.target.files?.[0] || null);
                  setTipsPaidOutFromTips(false);
                }}
                className="block w-full text-sm text-gray-500 file:mr-4 file:py-2 file:px-4 file:rounded-md file:border-0 file:text-sm file:font-medium file:bg-blue-50 file:text-blue-700 hover:file:bg-blue-100"
              />
              {excelFile && <p className="text-xs text-gray-500 mt-1">{excelFile.name}</p>}
            </div>

            <label className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
              <input
                type="checkbox"
                checked={tipsPaidOutFromTips}
                onChange={(event) => setTipsPaidOutFromTips(event.target.checked)}
                className="mt-0.5 rounded border-amber-300"
                disabled={!excelFile}
              />
              <span>
                <span className="font-medium">Legacy workbook fallback: all tips in this workbook were already paid out daily.</span>{' '}
                The generated workbook records this per employee, so this switch is only needed for an older MoSa workbook.
              </span>
            </label>
          </div>
        )}

        {/* Preview Step */}
        {step === 'upload' && (
          <p className="text-sm text-gray-500">Older workbook only: an optional BONUSES sheet uses row 4 headers, column C last name, D first name, and F bonus amount. The current workbook uses dedicated OWNER PERIOD PAY and ONE-TIME COMPONENTS sheets.</p>
        )}

        {step === 'preview' && previewData && (
          <div className="space-y-3">
            <div className="flex flex-wrap items-center gap-x-4 gap-y-2 rounded-2xl border border-green-200 bg-green-50 px-4 py-3 text-sm text-green-900">
              <span className="inline-flex items-center gap-2 font-semibold">
                <CheckCircle2 className="h-4 w-4" aria-hidden="true" />
                {previewData.source_package.verified_source_count} source{previewData.source_package.source_count === 1 ? '' : 's'} retained and verified
              </span>
              <span>Package revision {previewData.source_package.package_revision} · {previewData.source_package.package_id.slice(0, 8)}</span>
            </div>
            {(previewData.preview.source_warnings || []).map((warning) => (
              <div key={warning.code} className="rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
                {warning.message}
              </div>
            ))}
            {missingPeriodPay.length > 0 && (
              <div role="alert" className="rounded-lg border border-warning-200 bg-warning-50 p-4 text-sm text-warning-900">
                <p className="font-medium">Period pay is required for {missingPeriodPay.map((row) => row.employee_name).join(', ')}.</p>
                <p className="mt-2">Enter a separate amount for each person on the workbook’s OWNER PERIOD PAY sheet, or in the payroll worksheet, then preview again. Combined owner amounts are not accepted. If an employee should not be paid in this run, choose a different outcome and record why.</p>
                <Button variant="outline" className="mt-4" onClick={handleClose}>Return to payroll worksheet</Button>
              </div>
            )}
            {overwriteRows.length > 0 && (
              <label className="flex items-start gap-2 rounded-lg border border-warning-200 bg-warning-50 p-4 text-sm text-warning-900">
                <input type="checkbox" checked={reviewedOverwrite} onChange={(event) => setReviewedOverwrite(event.target.checked)} className="shrink-0 self-start" />
                <span>Replace existing hours, tips and direct loan deductions with the reviewed source values for {overwriteRows.map((row) => row.employee_name).join(', ')}. Saved period pay and manually entered bonuses are retained.</span>
              </label>
            )}
            {unresolvedCount > 0 && (
              <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-900">
                <p className="font-medium">Choose a documented outcome for every source row.</p>
                <p className="mt-1 text-red-800">Included rows must be valid and unique. Anything not paid now needs a reason and, when deferred, a named future payroll.</p>
              </div>
            )}

            {nonMatchedSourceRows.length > 0 && (
              <div className="space-y-3 rounded-2xl border border-neutral-200 bg-neutral-50 p-4">
                <div>
                  <p className="font-semibold text-neutral-950">Source rows not matched for payment</p>
                  <p className="mt-1 text-sm text-neutral-600">Correct the source and upload a replacement, or record why each row is excluded, deferred, or informational.</p>
                </div>
                {nonMatchedSourceRows.map((row) => (
                  <div key={row.id} className="grid gap-3 rounded-2xl border border-neutral-200 bg-white p-4 md:grid-cols-[minmax(0,1fr)_300px]">
                    <div>
                      <p className="font-medium text-neutral-950">{row.source_employee_name}</p>
                      <p className="mt-1 text-xs uppercase tracking-wide text-neutral-500">{row.row_kind === 'unmatched_revel' ? 'Revel hours' : 'Change workbook'}</p>
                      {row.errors.map((entry) => <p key={entry.code} className="mt-2 text-sm text-danger-700">{entry.message}</p>)}
                    </div>
                    {dispositionControls(row)}
                  </div>
                ))}
              </div>
            )}

            {suggestedMatchCount > 0 && (
              <div className="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">
                <p className="font-medium">Review {suggestedMatchCount} suggested name match{suggestedMatchCount === 1 ? '' : 'es'}</p>
                <ul className="mt-2 space-y-1">
                  {suggestedMatches.map((match, index) => (
                    <li key={`${match.source}-${match.source_name}-${match.employee_id}-${index}`}>
                      {match.source}: “{match.source_name}” → {match.employee_name} ({Math.round(match.confidence * 100)}%)
                    </li>
                  ))}
                </ul>
                <label className="mt-3 flex items-start gap-2 font-medium">
                  <input
                    type="checkbox"
                    checked={reviewedSuggestedMatches}
                    onChange={(event) => setReviewedSuggestedMatches(event.target.checked)}
                    className="mt-0.5 rounded border-amber-300"
                  />
                  <span>I reviewed these suggestions and they point to the correct employees.</span>
                </label>
              </div>
            )}

            <div className="overflow-x-auto">
              <Table className="min-w-[1240px]">
                <TableHeader>
                  <TableRow>
                    <TableHead className="min-w-[180px]">Outcome</TableHead>
                    <TableHead>Employee</TableHead>
                    <TableHead className="text-right">Hours</TableHead>
                    <TableHead className="text-right">Payroll rate</TableHead>
                    <TableHead className="text-right">Tips</TableHead>
                    <TableHead className="text-right">Loan Ded.</TableHead>
                    <TableHead className="min-w-[190px]">One-time items</TableHead>
                    <TableHead className="text-center">Match</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {matched.map((row) => {
                    const sourceRow = sourceRows.find((candidate) => candidate.id === row.source_row_id);
                    if (!sourceRow) return null;
                    const excluded = sourceRow.disposition !== 'included';
                    const classifiedLoanAmount = (row.one_payroll_deduction || 0) + (row.recurring_loan_deduction || 0) + (row.installment_payment || 0);
                    const sourceLoanAmount = Math.max(row.loan_deduction || 0, classifiedLoanAmount);
                    return (
                      <TableRow key={row.source_row_id} className={excluded ? 'bg-neutral-50/70' : ''}>
                        <TableCell>
                          {dispositionControls(sourceRow)}
                        </TableCell>
                        <TableCell>
                          <div>
                            <p className="font-medium text-gray-900">{row.employee_name}</p>
                            {row.pdf_employee_name && row.pdf_employee_name !== row.employee_name && (
                              <p className="text-xs text-gray-500">PDF: {row.pdf_employee_name}</p>
                            )}
                          </div>
                        </TableCell>
                        <TableCell className="text-right">
                          {row.regular_hours}
                          {row.overtime_hours > 0 && (
                            <span className="text-orange-600 ml-1">+{row.overtime_hours} OT</span>
                          )}
                        </TableCell>
                        <TableCell className="text-right">
                          <p>{row.period_pay_required ? (row.period_pay_missing || row.current_period_pay == null ? 'Missing period pay' : formatCurrency(row.current_period_pay)) : formatCurrency(row.pay_rate)}</p>
                          <p className="text-[11px] text-gray-500">
                            {row.period_pay_required
                              ? (row.period_pay_source === 'change_workbook' ? 'Pay this person · change workbook' : 'Pay this person · payroll worksheet')
                              : 'from employee profile'}
                          </p>
                        </TableCell>
                        <TableCell className="text-right">
                          {row.total_tips > 0 ? (
                            <span>
                              {formatCurrency(row.total_tips)}
                              {row.tip_pool && (
                                <Badge variant="default" className="ml-1 text-xs">
                                  {row.tip_pool.toUpperCase()}
                                </Badge>
                              )}
                            </span>
                          ) : (
                            <span className="text-gray-400">—</span>
                          )}
                        </TableCell>
                        <TableCell className="text-right">
                          {sourceLoanAmount > 0 ? (
                            <div>
                              <p>{formatCurrency(sourceLoanAmount)}</p>
                              {((row.recurring_loan_deduction || 0) > 0 || (row.installment_payment || 0) > 0) && (
                                <p className="mt-0.5 text-[11px] text-gray-500">
                                  {(row.recurring_loan_deduction || 0) > 0 && `This payroll ${formatCurrency(row.recurring_loan_deduction || 0)}`}
                                  {(row.recurring_loan_deduction || 0) > 0 && (row.installment_payment || 0) > 0 && ' · '}
                                  {(row.installment_payment || 0) > 0 && `Installment ${formatCurrency(row.installment_payment || 0)}`}
                                </p>
                              )}
                              {(row.loan_reconciliation_matches || []).length > 0 && (
                                <p className="mt-0.5 text-[11px] font-medium text-green-700">
                                  Matched to {(row.loan_reconciliation_matches || []).map((match) => match.name).join(', ')}
                                </p>
                              )}
                            </div>
                          ) : (
                            <span className="text-gray-400">—</span>
                          )}
                        </TableCell>
                        <TableCell>
                          {(row.payroll_components || []).length > 0 || (row.effective_bonus || 0) > 0 ? (
                            <div className="space-y-1.5">
                              {(row.payroll_components || []).map((component, index) => (
                                <div key={`${row.source_row_id}-${component.label}-${index}`} className="rounded-lg border border-slate-200 bg-slate-50 px-2 py-1.5 text-xs">
                                  <div className="flex items-center justify-between gap-3">
                                    <span className="font-medium text-slate-900">{component.label}</span>
                                    <span className={component.kind === 'deduction' ? 'font-semibold text-rose-700' : 'font-semibold text-emerald-700'}>
                                      {formatCurrency(component.amount)}
                                    </span>
                                  </div>
                                  <p className="mt-0.5 text-[11px] text-slate-500">{component.tax_treatment.replaceAll('_', ' ')} · {component.category.replaceAll('_', ' ')}</p>
                                </div>
                              ))}
                              {(row.effective_bonus || 0) > 0 && (
                                <div className="text-xs text-slate-700">
                                  Legacy bonus {formatCurrency(row.effective_bonus || 0)}{row.bonus_keeps_manual ? ' · retained manual value' : ''}
                                </div>
                              )}
                            </div>
                          ) : (
                            <span className="text-gray-400">—</span>
                          )}
                        </TableCell>
                        <TableCell className="text-center">
                          <Badge variant={row.confidence >= 1.0 ? 'default' : row.confidence >= 0.8 ? 'warning' : 'danger'}>
                            {Math.round(row.confidence * 100)}%
                          </Badge>
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </div>

            <div className="space-y-3 text-sm text-gray-500">
              <div className="rounded-lg border border-gray-200 bg-gray-50 p-3 text-gray-700">
                <span className="font-medium">Tip treatment reviewed with these files:</span>{' '}
                {previewData.preview.tips_paid_out_from_tips
                  ? 'Tips were already paid daily and will offset employee checks.'
                  : 'Tips were not already paid daily and will remain in employee checks.'}
              </div>
              <p>
                {previewData.preview.pdf_count} PDF records, {previewData.preview.excel_count} Excel records, {included.length} to import
              </p>
              <p>
                Gross pay and taxes will be calculated from employee profiles, imported hours, separate per-person period pay, tips, and typed one-time components. A manually entered legacy bonus is retained during reimport.
              </p>
              <p>
                Named recurring deductions and installment payments must match a configured ledger before import. The ledger records them only when payroll is committed. A separately labeled one-payroll deduction applies only to this run.
              </p>
            </div>
          </div>
        )}

        {/* Done Step */}
        {step === 'done' && results && (
          <div className="space-y-3 py-2">
            <div className="p-3 bg-green-50 border border-green-200 text-green-800 rounded-lg text-sm">
              Successfully imported {results.success} employee{results.success !== 1 ? 's' : ''}.
            </div>
            {results.errors.length > 0 && (
              <div className="p-3 bg-red-50 border border-red-200 text-red-700 rounded-lg text-sm">
                <p className="font-medium">Errors:</p>
                <ul className="mt-1 list-disc list-inside">
                  {results.errors.map((err, i) => (
                    <li key={i}>{err}</li>
                  ))}
                </ul>
              </div>
            )}
          </div>
        )}

        {/* Applying Step */}
        {step === 'applying' && (
          <div className="py-8 text-center text-gray-500">
            Importing payroll data and calculating taxes...
          </div>
        )}

        <DialogFooter>
          {step === 'upload' && (
            <>
              <Button variant="outline" onClick={handleClose} disabled={loading}>Cancel</Button>
              <Button onClick={handlePreview} disabled={!pdfFile || loading || !replacementReady}>
                {loading ? 'Parsing...' : 'Preview Import'}
              </Button>
            </>
          )}
          {step === 'preview' && (
            <>
              <Button variant="outline" onClick={() => {
                setStep('upload');
                setPreviewData(null);
                setSourceRows([]);
                setReviewedSuggestedMatches(false);
                setReviewedOverwrite(false);
              }}>
                Back
              </Button>
              <Button onClick={handleApply} disabled={!canApply}>
                Apply Import ({included.length} employees)
              </Button>
            </>
          )}
          {step === 'done' && (
            <Button onClick={handleClose}>Close</Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
