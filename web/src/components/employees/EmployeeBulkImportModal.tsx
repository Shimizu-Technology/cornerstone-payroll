import { useState, useRef, useCallback } from 'react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { employeeBulkImportApi } from '@/services/api';
import type { BulkImportPreviewRow, BulkImportPreviewResult, BulkImportApplyResult } from '@/services/api';
import { Upload, FileSpreadsheet, CheckCircle2, AlertCircle, AlertTriangle, X, Download, Loader2 } from 'lucide-react';

type Step = 'upload' | 'preview' | 'importing' | 'done';

interface Props {
  open: boolean;
  onClose: () => void;
  onComplete: () => void;
}

export function EmployeeBulkImportModal({ open, onClose, onComplete }: Props) {
  const [step, setStep] = useState<Step>('upload');
  const [file, setFile] = useState<File | null>(null);
  const [previewData, setPreviewData] = useState<BulkImportPreviewResult | null>(null);
  const [skippedRows, setSkippedRows] = useState<Set<number>>(new Set());
  const [result, setResult] = useState<BulkImportApplyResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const reset = useCallback(() => {
    setStep('upload');
    setFile(null);
    setPreviewData(null);
    setSkippedRows(new Set());
    setResult(null);
    setError(null);
    setLoading(false);
  }, []);

  const handleClose = () => {
    if (step === 'done') onComplete();
    reset();
    onClose();
  };

  const handleFileSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0];
    if (f) {
      setFile(f);
      setError(null);
    }
  };

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    const f = e.dataTransfer.files?.[0];
    if (f) {
      const ext = f.name.split('.').pop()?.toLowerCase();
      if (['csv', 'xlsx', 'xls'].includes(ext || '')) {
        setFile(f);
        setError(null);
      } else {
        setError('Please upload a CSV or Excel (.xlsx) file');
      }
    }
  };

  const handlePreview = async () => {
    if (!file) return;
    setLoading(true);
    setError(null);
    try {
      const data = await employeeBulkImportApi.preview(file);
      setPreviewData(data);
      const autoSkip = new Set<number>();
      data.rows.forEach(r => {
        if (!r.valid) autoSkip.add(r.row_number);
      });
      setSkippedRows(autoSkip);
      setStep('preview');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to parse file');
    } finally {
      setLoading(false);
    }
  };

  const handleApply = async () => {
    if (!file || !previewData) return;
    setStep('importing');
    setError(null);
    try {
      const res = await employeeBulkImportApi.apply(file, Array.from(skippedRows));
      setResult(res);
      setStep('done');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to import employees');
      setStep('preview');
    }
  };

  const toggleSkipRow = (rowNum: number) => {
    setSkippedRows(prev => {
      const next = new Set(prev);
      if (next.has(rowNum)) next.delete(rowNum);
      else next.add(rowNum);
      return next;
    });
  };

  const importableCount = previewData
    ? previewData.rows.filter(r => r.valid && !skippedRows.has(r.row_number)).length
    : 0;

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="fixed inset-0 bg-black/50" onClick={step !== 'importing' ? handleClose : undefined} />
      <div className="relative z-50 bg-white rounded-xl shadow-2xl w-full max-w-5xl max-h-[90vh] flex flex-col mx-4">
        {/* Header */}
        <div className="flex items-center justify-between border-b px-6 py-4 shrink-0">
          <div>
            <h3 className="text-lg font-semibold text-gray-900">Bulk Import Employees</h3>
            <p className="text-sm text-gray-500 mt-0.5">
              {step === 'upload' && 'Upload a CSV or Excel file with employee data'}
              {step === 'preview' && `Review ${previewData?.summary.total || 0} rows before importing`}
              {step === 'importing' && 'Creating employees...'}
              {step === 'done' && 'Import complete'}
            </p>
          </div>
          {step !== 'importing' && (
            <button onClick={handleClose} className="text-gray-400 hover:text-gray-600 p-1">
              <X className="w-5 h-5" />
            </button>
          )}
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto px-6 py-5">
          {error && (
            <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-lg flex items-start gap-2">
              <AlertCircle className="w-4 h-4 text-red-600 mt-0.5 shrink-0" />
              <p className="text-sm text-red-700">{error}</p>
            </div>
          )}

          {step === 'upload' && (
            <div className="space-y-6">
              {/* Template download */}
              <div className="bg-blue-50 border border-blue-200 rounded-lg p-4 flex items-start gap-3">
                <FileSpreadsheet className="w-5 h-5 text-blue-600 mt-0.5 shrink-0" />
                <div>
                  <p className="text-sm font-medium text-blue-800">Start with the template</p>
                  <p className="text-sm text-blue-700 mt-0.5">
                    Download the CSV template, fill in your employee data, then upload it here.
                  </p>
                  <button
                    onClick={() => employeeBulkImportApi.downloadTemplate()}
                    className="inline-flex items-center gap-1.5 mt-2 text-sm font-medium text-blue-700 hover:text-blue-900"
                  >
                    <Download className="w-3.5 h-3.5" />
                    Download Template (CSV)
                  </button>
                </div>
              </div>

              {/* File upload area */}
              <div
                className={`border-2 border-dashed rounded-xl p-10 text-center transition-colors ${
                  file ? 'border-green-300 bg-green-50' : 'border-gray-300 hover:border-blue-400 hover:bg-blue-50/30'
                }`}
                onDragOver={e => e.preventDefault()}
                onDrop={handleDrop}
              >
                {file ? (
                  <div className="flex flex-col items-center gap-3">
                    <CheckCircle2 className="w-10 h-10 text-green-500" />
                    <div>
                      <p className="font-medium text-gray-900">{file.name}</p>
                      <p className="text-sm text-gray-500">{(file.size / 1024).toFixed(1)} KB</p>
                    </div>
                    <Button variant="outline" size="sm" onClick={() => { setFile(null); if (fileInputRef.current) fileInputRef.current.value = ''; }}>
                      Choose Different File
                    </Button>
                  </div>
                ) : (
                  <div className="flex flex-col items-center gap-3">
                    <Upload className="w-10 h-10 text-gray-400" />
                    <div>
                      <p className="font-medium text-gray-700">Drop your file here, or click to browse</p>
                      <p className="text-sm text-gray-500 mt-1">Supports CSV and Excel (.xlsx) files</p>
                    </div>
                    <Button variant="outline" size="sm" onClick={() => fileInputRef.current?.click()}>
                      Browse Files
                    </Button>
                  </div>
                )}
                <input
                  ref={fileInputRef}
                  type="file"
                  accept=".csv,.xlsx,.xls"
                  onChange={handleFileSelect}
                  className="hidden"
                />
              </div>
            </div>
          )}

          {step === 'preview' && previewData && (
            <div className="space-y-4">
              {/* Summary badges */}
              <div className="flex items-center gap-3 flex-wrap">
                <Badge className="bg-gray-100 text-gray-700 text-xs px-2.5 py-1">
                  {previewData.summary.total} total rows
                </Badge>
                <Badge className="bg-green-100 text-green-700 text-xs px-2.5 py-1">
                  {importableCount} to import
                </Badge>
                {previewData.summary.invalid > 0 && (
                  <Badge className="bg-red-100 text-red-700 text-xs px-2.5 py-1">
                    {previewData.summary.invalid} invalid
                  </Badge>
                )}
                {previewData.summary.duplicates > 0 && (
                  <Badge className="bg-amber-100 text-amber-700 text-xs px-2.5 py-1">
                    {previewData.summary.duplicates} possible duplicates
                  </Badge>
                )}
                {skippedRows.size > 0 && (
                  <Badge className="bg-gray-100 text-gray-500 text-xs px-2.5 py-1">
                    {skippedRows.size} skipped
                  </Badge>
                )}
              </div>

              {/* New departments notice */}
              {previewData.summary.new_departments && previewData.summary.new_departments.length > 0 && (
                <div className="px-3 py-2 bg-blue-50 border border-blue-200 rounded-lg flex items-start gap-2 text-sm">
                  <svg className="w-4 h-4 text-blue-600 mt-0.5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                  <span className="text-blue-800">
                    <strong>New departments will be created:</strong>{' '}
                    {previewData.summary.new_departments.join(', ')}
                  </span>
                </div>
              )}

              {/* Preview table */}
              <div className="border rounded-lg overflow-hidden">
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="bg-gray-50 border-b">
                        <th className="px-3 py-2 text-left font-medium text-gray-600 w-10">
                          <span className="sr-only">Include</span>
                        </th>
                        <th className="px-3 py-2 text-left font-medium text-gray-600">Row</th>
                        <th className="px-3 py-2 text-left font-medium text-gray-600">Name</th>
                        <th className="px-3 py-2 text-left font-medium text-gray-600">Type</th>
                        <th className="px-3 py-2 text-left font-medium text-gray-600">Pay Rate</th>
                        <th className="px-3 py-2 text-left font-medium text-gray-600">Frequency</th>
                        <th className="px-3 py-2 text-left font-medium text-gray-600">Filing</th>
                        <th className="px-3 py-2 text-left font-medium text-gray-600">Dept</th>
                        <th className="px-3 py-2 text-left font-medium text-gray-600">Status</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y">
                      {previewData.rows.map(row => (
                        <PreviewRow
                          key={row.row_number}
                          row={row}
                          skipped={skippedRows.has(row.row_number)}
                          onToggle={() => toggleSkipRow(row.row_number)}
                        />
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          )}

          {step === 'importing' && (
            <div className="flex flex-col items-center justify-center py-16 gap-4">
              <Loader2 className="w-10 h-10 animate-spin text-blue-600" />
              <p className="text-gray-600 font-medium">Creating {importableCount} employees...</p>
              <p className="text-sm text-gray-500">This may take a moment</p>
            </div>
          )}

          {step === 'done' && result && (
            <div className="space-y-6">
              <div className="flex flex-col items-center py-8 gap-3">
                <CheckCircle2 className="w-14 h-14 text-green-500" />
                <h4 className="text-xl font-semibold text-gray-900">Import Complete</h4>
                <p className="text-gray-600">
                  Successfully created <span className="font-semibold text-green-700">{result.created}</span> employee{result.created !== 1 ? 's' : ''}
                  {result.failed > 0 && (
                    <>, <span className="font-semibold text-red-600">{result.failed}</span> failed</>
                  )}
                </p>
              </div>

              {result.errors.length > 0 && (
                <div className="bg-red-50 border border-red-200 rounded-lg p-4">
                  <p className="text-sm font-medium text-red-800 mb-2">Failed rows:</p>
                  <ul className="space-y-1">
                    {result.errors.map((e, idx) => (
                      <li key={idx} className="text-sm text-red-700">
                        Row {e.row}: {e.messages.join(', ')}
                      </li>
                    ))}
                  </ul>
                </div>
              )}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="border-t px-6 py-4 flex items-center justify-between shrink-0 bg-gray-50 rounded-b-xl">
          <div>
            {step === 'preview' && (
              <Button variant="outline" onClick={() => { setStep('upload'); setPreviewData(null); }}>
                Back
              </Button>
            )}
          </div>
          <div className="flex items-center gap-3">
            {step !== 'importing' && (
              <Button variant="outline" onClick={handleClose}>
                {step === 'done' ? 'Close' : 'Cancel'}
              </Button>
            )}
            {step === 'upload' && (
              <Button onClick={handlePreview} disabled={!file || loading}>
                {loading ? (
                  <span className="flex items-center gap-2">
                    <Loader2 className="w-4 h-4 animate-spin" />
                    Parsing...
                  </span>
                ) : (
                  'Upload & Preview'
                )}
              </Button>
            )}
            {step === 'preview' && (
              <Button onClick={handleApply} disabled={importableCount === 0}>
                Import {importableCount} Employee{importableCount !== 1 ? 's' : ''}
              </Button>
            )}
            {step === 'done' && (
              <Button onClick={() => { onComplete(); reset(); onClose(); }}>
                Go to Employees
              </Button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

function PreviewRow({ row, skipped, onToggle }: { row: BulkImportPreviewRow; skipped: boolean; onToggle: () => void }) {
  const isInvalid = !row.valid;
  const rowClass = isInvalid
    ? 'bg-red-50'
    : row.duplicate
    ? 'bg-amber-50'
    : skipped
    ? 'bg-gray-50 opacity-50'
    : 'hover:bg-gray-50';

  return (
    <tr className={rowClass}>
      <td className="px-3 py-2">
        <input
          type="checkbox"
          checked={!skipped && row.valid}
          disabled={isInvalid}
          onChange={onToggle}
          className="rounded border-gray-300"
        />
      </td>
      <td className="px-3 py-2 text-gray-500 text-xs">{row.row_number}</td>
      <td className="px-3 py-2 font-medium text-gray-900">
        {row.data.first_name} {row.data.last_name}
        {row.data.middle_name && <span className="text-gray-400 ml-1">{row.data.middle_name}</span>}
      </td>
      <td className="px-3 py-2">
        <Badge variant="outline" className="text-xs">
          {row.data.employment_type || 'hourly'}
        </Badge>
      </td>
      <td className="px-3 py-2">{row.data.pay_rate ? `$${Number(row.data.pay_rate).toFixed(2)}` : '—'}</td>
      <td className="px-3 py-2 text-xs text-gray-600">{row.data.pay_frequency || '—'}</td>
      <td className="px-3 py-2 text-xs text-gray-600">{row.data.filing_status || '—'}</td>
      <td className="px-3 py-2 text-xs text-gray-600">{row.data.department || '—'}</td>
      <td className="px-3 py-2">
        {isInvalid ? (
          <div className="flex items-start gap-1">
            <AlertCircle className="w-3.5 h-3.5 text-red-500 mt-0.5 shrink-0" />
            <span className="text-xs text-red-600">{row.errors.join('; ')}</span>
          </div>
        ) : row.duplicate ? (
          <div className="flex items-center gap-1">
            <AlertTriangle className="w-3.5 h-3.5 text-amber-500 shrink-0" />
            <span className="text-xs text-amber-600">Possible duplicate</span>
          </div>
        ) : (
          <div className="flex items-center gap-1">
            <CheckCircle2 className="w-3.5 h-3.5 text-green-500 shrink-0" />
            <span className="text-xs text-green-600">Valid</span>
          </div>
        )}
      </td>
    </tr>
  );
}
