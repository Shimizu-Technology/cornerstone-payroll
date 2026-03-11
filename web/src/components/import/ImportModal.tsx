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
      const data = await payPeriodsApi.previewImport(payPeriodId, pdfFile, excelFile || undefined);
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
      const matched = previewData.preview.matched.filter((r) => !excludedIds.has(r.employee_id));
      const response = await payPeriodsApi.applyImport(payPeriodId, {
        import_id: previewData.import_id,
        matched,
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

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="max-w-4xl max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Import Payroll Data</DialogTitle>
          <DialogDescription>
            {step === 'upload' && 'Upload the Revel POS PDF and optional Excel file with tips/loans.'}
            {step === 'preview' && `${included.length} employees matched. Review and apply.`}
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
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Tips &amp; Loans Excel (optional)
              </label>
              <input
                ref={excelInputRef}
                type="file"
                accept=".xlsx,.xls"
                onChange={(e) => setExcelFile(e.target.files?.[0] || null)}
                className="block w-full text-sm text-gray-500 file:mr-4 file:py-2 file:px-4 file:rounded-md file:border-0 file:text-sm file:font-medium file:bg-blue-50 file:text-blue-700 hover:file:bg-blue-100"
              />
              {excelFile && <p className="text-xs text-gray-500 mt-1">{excelFile.name}</p>}
            </div>
          </div>
        )}

        {/* Preview Step */}
        {step === 'preview' && previewData && (
          <div className="space-y-3">
            {/* Unmatched names warning */}
            {previewData.preview.unmatched_pdf_names.length > 0 && (
              <div className="p-3 bg-amber-50 border border-amber-200 text-amber-800 rounded-lg text-sm">
                <p className="font-medium">Unmatched names from PDF:</p>
                <ul className="mt-1 list-disc list-inside">
                  {previewData.preview.unmatched_pdf_names.map((name) => (
                    <li key={name}>{name}</li>
                  ))}
                </ul>
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
                    <TableHead className="text-right">Gross (PDF)</TableHead>
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
                        <TableCell className="text-right">{formatCurrency(row.total_pay)}</TableCell>
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
                            formatCurrency(row.loan_deduction)
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

            <div className="text-sm text-gray-500">
              {previewData.preview.pdf_count} PDF records, {previewData.preview.excel_count} Excel records, {included.length} to import
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
              <Button variant="outline" onClick={() => { setStep('upload'); setPreviewData(null); }}>
                Back
              </Button>
              <Button onClick={handleApply} disabled={included.length === 0}>
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
