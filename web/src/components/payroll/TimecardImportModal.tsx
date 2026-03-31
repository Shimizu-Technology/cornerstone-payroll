import { useState, useRef, useCallback } from 'react';
import { Button } from '@/components/ui/button';
import { payPeriodsApi } from '@/services/api';
import type { TimecardImportPreviewRow, TimecardImportMapping } from '@/services/api';

interface TimecardImportModalProps {
  open: boolean;
  onClose: () => void;
  payPeriodId: number;
  onImportComplete: () => void;
}

type Step = 'upload' | 'review' | 'done';

export function TimecardImportModal({ open, onClose, payPeriodId, onImportComplete }: TimecardImportModalProps) {
  const [step, setStep] = useState<Step>('upload');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [preview, setPreview] = useState<TimecardImportPreviewRow[]>([]);
  const [allEmployees, setAllEmployees] = useState<{ id: number; name: string }[]>([]);
  const [mappings, setMappings] = useState<Map<number, number | null>>(new Map());
  const [result, setResult] = useState<{ applied: number; errors: number } | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  const reset = useCallback(() => {
    setStep('upload');
    setLoading(false);
    setError(null);
    setPreview([]);
    setAllEmployees([]);
    setMappings(new Map());
    setResult(null);
    if (fileRef.current) fileRef.current.value = '';
  }, []);

  const handleClose = () => {
    reset();
    onClose();
  };

  const handleFileUpload = async (file: File) => {
    setLoading(true);
    setError(null);
    try {
      const res = await payPeriodsApi.previewTimecardImport(payPeriodId, file);
      setPreview(res.preview);
      setAllEmployees(res.all_employees || []);

      const initialMappings = new Map<number, number | null>();
      res.preview.forEach((row, idx) => {
        initialMappings.set(idx, row.employee_id);
      });
      setMappings(initialMappings);
      setStep('review');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to parse CSV');
    } finally {
      setLoading(false);
    }
  };

  const handleApply = async () => {
    setLoading(true);
    setError(null);
    try {
      const importMappings: TimecardImportMapping[] = [];
      preview.forEach((row, idx) => {
        const eid = mappings.get(idx);
        if (eid) {
          importMappings.push({
            employee_id: eid,
            regular_hours: parseFloat(row.regular_hours) || 0,
            overtime_hours: parseFloat(row.overtime_hours) || 0,
          });
        }
      });

      if (importMappings.length === 0) {
        setError('No employees mapped. Please map at least one row.');
        setLoading(false);
        return;
      }

      const res = await payPeriodsApi.applyTimecardImport(payPeriodId, importMappings);
      setResult({ applied: res.applied.length, errors: res.errors.length });
      setStep('done');
      onImportComplete();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to apply import');
    } finally {
      setLoading(false);
    }
  };

  const handleEmployeeChange = (rowIdx: number, employeeId: number | null) => {
    setMappings(prev => {
      const next = new Map(prev);
      next.set(rowIdx, employeeId);
      return next;
    });
  };

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="fixed inset-0 bg-black/50" onClick={handleClose} />
      <div className="relative z-50 bg-white rounded-lg shadow-xl w-full max-w-4xl max-h-[90vh] overflow-hidden mx-4 flex flex-col">
        {/* Header */}
        <div className="border-b px-6 py-4 flex items-center justify-between shrink-0">
          <div>
            <h3 className="text-lg font-semibold text-gray-900">Import from Timecard OCR</h3>
            <p className="text-sm text-gray-500 mt-0.5">
              {step === 'upload' && 'Upload the CSV export from your Timecard OCR system'}
              {step === 'review' && 'Review and confirm employee mappings'}
              {step === 'done' && 'Import complete'}
            </p>
          </div>
          <button onClick={handleClose} className="text-gray-400 hover:text-gray-600 p-1">
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto px-6 py-4">
          {error && (
            <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-700">{error}</div>
          )}

          {step === 'upload' && (
            <div className="space-y-4">
              <div className="border-2 border-dashed border-gray-300 rounded-lg p-8 text-center">
                <svg className="mx-auto h-12 w-12 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5m-13.5-9L12 3m0 0l4.5 4.5M12 3v13.5" />
                </svg>
                <p className="mt-3 text-sm text-gray-600">
                  Upload a CSV file exported from the Timecard OCR system
                </p>
                <p className="text-xs text-gray-400 mt-1">
                  Expected columns: Employee Name, Regular Hours, OT Hours, Total Hours
                </p>
                <input
                  ref={fileRef}
                  type="file"
                  accept=".csv"
                  className="hidden"
                  onChange={(e) => {
                    const file = e.target.files?.[0];
                    if (file) handleFileUpload(file);
                  }}
                />
                <Button
                  className="mt-4"
                  onClick={() => fileRef.current?.click()}
                  disabled={loading}
                >
                  {loading ? 'Parsing...' : 'Select CSV File'}
                </Button>
              </div>

              <div className="bg-blue-50 border border-blue-200 rounded-lg p-4 text-sm text-blue-800">
                <p className="font-medium">How to export from Timecard OCR:</p>
                <ol className="mt-2 list-decimal list-inside space-y-1 text-xs">
                  <li>Open the Timecard OCR app and go to the Payroll Runs section</li>
                  <li>Create or select the payroll run for the relevant period</li>
                  <li>Click &quot;Export CSV&quot; to download the file</li>
                  <li>Upload that CSV here</li>
                </ol>
              </div>
            </div>
          )}

          {step === 'review' && (
            <div className="space-y-4">
              <div className="flex items-center justify-between text-sm">
                <span className="text-gray-600">
                  {preview.length} rows found &middot;{' '}
                  <span className="text-green-600 font-medium">
                    {Array.from(mappings.values()).filter(v => v !== null).length} mapped
                  </span>{' '}
                  &middot;{' '}
                  <span className="text-amber-600 font-medium">
                    {Array.from(mappings.values()).filter(v => v === null).length} unmapped
                  </span>
                </span>
              </div>

              <div className="border rounded-lg overflow-hidden">
                <table className="min-w-full divide-y divide-gray-200 text-sm">
                  <thead className="bg-gray-50">
                    <tr>
                      <th className="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">CSV Name</th>
                      <th className="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Map To Employee</th>
                      <th className="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">Reg Hrs</th>
                      <th className="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">OT Hrs</th>
                      <th className="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">Total</th>
                      <th className="px-4 py-2 text-center text-xs font-medium text-gray-500 uppercase">Match</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-200 bg-white">
                    {preview.map((row, idx) => {
                      const selectedId = mappings.get(idx);
                      return (
                        <tr key={idx} className={selectedId ? '' : 'bg-amber-50'}>
                          <td className="px-4 py-2 text-gray-900 font-medium">{row.csv_name}</td>
                          <td className="px-4 py-2">
                            <select
                              value={selectedId ?? ''}
                              onChange={(e) => {
                                const val = e.target.value;
                                handleEmployeeChange(idx, val ? parseInt(val) : null);
                              }}
                              className="w-full border rounded px-2 py-1 text-sm"
                            >
                              <option value="">-- Skip --</option>
                              {allEmployees.map(emp => (
                                <option key={emp.id} value={emp.id}>{emp.name}</option>
                              ))}
                            </select>
                          </td>
                          <td className="px-4 py-2 text-right font-mono">{row.regular_hours}</td>
                          <td className="px-4 py-2 text-right font-mono">{row.overtime_hours}</td>
                          <td className="px-4 py-2 text-right font-mono">{row.total_hours}</td>
                          <td className="px-4 py-2 text-center">
                            {row.match_score >= 0.8 ? (
                              <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800">
                                {Math.round(row.match_score * 100)}%
                              </span>
                            ) : row.match_score >= 0.6 ? (
                              <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800">
                                {Math.round(row.match_score * 100)}%
                              </span>
                            ) : (
                              <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800">
                                {Math.round(row.match_score * 100)}%
                              </span>
                            )}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>

              {preview.some(r => r.flags) && (
                <div className="bg-amber-50 border border-amber-200 rounded-lg p-3 text-sm text-amber-800">
                  <p className="font-medium">Flags from Timecard OCR:</p>
                  <ul className="mt-1 text-xs space-y-1">
                    {preview.filter(r => r.flags).map((r, i) => (
                      <li key={i}><span className="font-medium">{r.csv_name}:</span> {r.flags}</li>
                    ))}
                  </ul>
                </div>
              )}
            </div>
          )}

          {step === 'done' && result && (
            <div className="text-center py-8">
              <div className="mx-auto w-12 h-12 rounded-full bg-green-100 flex items-center justify-center mb-4">
                <svg className="w-6 h-6 text-green-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
                </svg>
              </div>
              <h4 className="text-lg font-semibold text-gray-900">Import Complete</h4>
              <p className="text-sm text-gray-600 mt-2">
                {result.applied} employee hours imported successfully.
                {result.errors > 0 && ` ${result.errors} errors occurred.`}
              </p>
              <p className="text-xs text-gray-400 mt-1">
                Remember to run payroll to calculate taxes and deductions for the imported hours.
              </p>
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="border-t px-6 py-4 flex justify-end gap-3 shrink-0 bg-gray-50">
          {step === 'review' && (
            <>
              <Button variant="outline" onClick={reset}>Back</Button>
              <Button onClick={handleApply} disabled={loading}>
                {loading ? 'Applying...' : `Apply Import (${Array.from(mappings.values()).filter(v => v !== null).length} employees)`}
              </Button>
            </>
          )}
          {step === 'done' && (
            <Button onClick={handleClose}>Close</Button>
          )}
          {step === 'upload' && (
            <Button variant="outline" onClick={handleClose}>Cancel</Button>
          )}
        </div>
      </div>
    </div>
  );
}
