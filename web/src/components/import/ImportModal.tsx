import { useState, useRef } from 'react';
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
import { formatCurrency } from '@/lib/utils';
import { payPeriodsApi } from '@/services/api';
import type { ImportPreviewResponse } from '@/services/api';
import type { PayPeriod, PayrollItem } from '@/types';

interface ImportModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  payPeriodId: number;
  onImportComplete: (payPeriod: PayPeriod & { payroll_items?: PayrollItem[] }) => void;
}

type Step = 'upload' | 'preview' | 'applying' | 'done';

export function ImportModal({ open, onOpenChange, payPeriodId, onImportComplete }: ImportModalProps) {
  const [step, setStep] = useState<Step>('upload');
  const [pdfFile, setPdfFile] = useState<File | null>(null);
  const [excelFile, setExcelFile] = useState<File | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [previewData, setPreviewData] = useState<ImportPreviewResponse | null>(null);
  const [excludedIds, setExcludedIds] = useState<Set<number>>(new Set());
  const [tipsPaidOutFromTips, setTipsPaidOutFromTips] = useState(false);
  const [reviewedSuggestedMatches, setReviewedSuggestedMatches] = useState(false);
  const [results, setResults] = useState<{ success: number; errors: string[] } | null>(null);
  const pdfInputRef = useRef<HTMLInputElement>(null);
  const excelInputRef = useRef<HTMLInputElement>(null);

  const reset = () => {
    setStep('upload');
    setPdfFile(null);
    setExcelFile(null);
    setLoading(false);
    setError(null);
    setPreviewData(null);
    setExcludedIds(new Set());
    setTipsPaidOutFromTips(false);
    setReviewedSuggestedMatches(false);
    setResults(null);
  };

  const handleClose = () => {
    reset();
    onOpenChange(false);
  };

  const handlePreview = async () => {
    if (!pdfFile) return;
    try {
      setLoading(true);
      setError(null);
      setReviewedSuggestedMatches(false);
      setExcludedIds(new Set());
      const data = await payPeriodsApi.previewImport(
        payPeriodId,
        pdfFile,
        excelFile || undefined,
        tipsPaidOutFromTips,
      );
      setPreviewData(data);
      setStep('preview');
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
        excluded_employee_ids: Array.from(excludedIds),
        acknowledge_low_confidence_matches: reviewedSuggestedMatches,
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

  const toggleExclude = (employeeId: number) => {
    setExcludedIds((prev) => {
      const next = new Set(prev);
      if (next.has(employeeId)) {
        next.delete(employeeId);
      } else {
        next.add(employeeId);
      }
      return next;
    });
  };

  const matched = previewData?.preview.matched || [];
  const included = matched.filter((r) => !excludedIds.has(r.employee_id));
  const unresolvedCount = previewData
    ? previewData.preview.unmatched_pdf_names.length
      + previewData.preview.unmatched_excel_names.length
      + previewData.preview.duplicate_employee_matches.length
    : 0;
  const suggestedMatchCount = previewData?.preview.low_confidence_matches.length || 0;
  const canApply = Boolean(
    previewData?.preview.can_apply
      && included.length > 0
      && (suggestedMatchCount === 0 || reviewedSuggestedMatches),
  );

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="dialog-top dialog-wide max-w-6xl max-h-[calc(100vh-8rem)] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Import Payroll Data</DialogTitle>
          <DialogDescription>
            {step === 'upload' && 'Upload Revel hours and the optional per-payroll tips and deductions workbook.'}
            {step === 'preview' && (unresolvedCount > 0
              ? `${unresolvedCount} source row${unresolvedCount === 1 ? '' : 's'} need attention before this import can be applied.`
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
                Only regular and overtime hours are imported from Revel. Revel pay rates and pay amounts are ignored.
              </p>
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Tips &amp; payroll deductions workbook (optional)
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
                <span className="font-medium">Tips in this workbook were already paid out daily.</span>{' '}
                Report them as taxable tips and offset them from employee checks.
              </span>
            </label>
          </div>
        )}

        {/* Preview Step */}
        {step === 'preview' && previewData && (
          <div className="space-y-3">
            {unresolvedCount > 0 && (
              <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-900">
                <p className="font-medium">Nothing has been imported. Resolve these source rows first.</p>
                <p className="mt-1 text-red-800">
                  Correct the employee name in Cornerstone or the source file, then go back and preview again.
                </p>
                {previewData.preview.unmatched_pdf_names.length > 0 && (
                  <div className="mt-3">
                    <p className="font-medium">Unmatched Revel hours</p>
                    <ul className="mt-1 list-disc pl-5">
                      {previewData.preview.unmatched_pdf_names.map((name) => <li key={`pdf-${name}`}>{name}</li>)}
                    </ul>
                  </div>
                )}
                {previewData.preview.unmatched_excel_names.length > 0 && (
                  <div className="mt-3">
                    <p className="font-medium">Unmatched tips or deductions</p>
                    <ul className="mt-1 list-disc pl-5">
                      {previewData.preview.unmatched_excel_names.map((name) => <li key={`excel-${name}`}>{name}</li>)}
                    </ul>
                  </div>
                )}
                {previewData.preview.duplicate_employee_matches.length > 0 && (
                  <div className="mt-3">
                    <p className="font-medium">Duplicate Revel employee matches</p>
                    <ul className="mt-1 list-disc pl-5">
                      {previewData.preview.duplicate_employee_matches.map((match) => (
                        <li key={match.employee_id}>{match.employee_name}: {match.source_names.join(', ')}</li>
                      ))}
                    </ul>
                  </div>
                )}
              </div>
            )}

            {suggestedMatchCount > 0 && (
              <div className="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">
                <p className="font-medium">Review {suggestedMatchCount} suggested name match{suggestedMatchCount === 1 ? '' : 'es'}</p>
                <ul className="mt-2 space-y-1">
                  {previewData.preview.low_confidence_matches.map((match, index) => (
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
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-8">
                      <span className="sr-only">Include</span>
                    </TableHead>
                    <TableHead>Employee</TableHead>
                    <TableHead className="text-right">Hours</TableHead>
                    <TableHead className="text-right">Payroll rate</TableHead>
                    <TableHead className="text-right">Tips</TableHead>
                    <TableHead className="text-right">Loan Ded.</TableHead>
                    <TableHead className="text-center">Match</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {matched.map((row) => {
                    const excluded = excludedIds.has(row.employee_id);
                    return (
                      <TableRow key={row.employee_id} className={excluded ? 'opacity-40' : ''}>
                        <TableCell>
                          <input
                            type="checkbox"
                            checked={!excluded}
                            onChange={() => toggleExclude(row.employee_id)}
                            className="rounded border-gray-300"
                          />
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
                          <p>{formatCurrency(row.pay_rate)}</p>
                          <p className="text-[11px] text-gray-500">from employee profile</p>
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
                          {row.loan_deduction > 0 ? (
                            <div>
                              <p>{formatCurrency(row.loan_deduction)}</p>
                              {((row.recurring_loan_deduction || 0) > 0 || (row.installment_payment || 0) > 0) && (
                                <p className="mt-0.5 text-[11px] text-gray-500">
                                  {(row.recurring_loan_deduction || 0) > 0 && `This payroll ${formatCurrency(row.recurring_loan_deduction || 0)}`}
                                  {(row.recurring_loan_deduction || 0) > 0 && (row.installment_payment || 0) > 0 && ' · '}
                                  {(row.installment_payment || 0) > 0 && `Installment ${formatCurrency(row.installment_payment || 0)}`}
                                </p>
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
                Gross pay and taxes will be calculated from Cornerstone employee profiles, imported hours, and this period’s tips and deductions.
              </p>
              <p>
                Excel loan deductions are applied to this payroll run only. They do not create or update Employee Loans balances yet.
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
              <Button variant="outline" onClick={handleClose}>Cancel</Button>
              <Button onClick={handlePreview} disabled={!pdfFile || loading}>
                {loading ? 'Parsing...' : 'Preview Import'}
              </Button>
            </>
          )}
          {step === 'preview' && (
            <>
              <Button variant="outline" onClick={() => {
                setStep('upload');
                setPreviewData(null);
                setReviewedSuggestedMatches(false);
                setExcludedIds(new Set());
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
