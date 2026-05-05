import { useEffect, useMemo, useState } from 'react';
import { Button } from '@/components/ui/button';
import { payPeriodsApi, timeTrackingSourcesApi } from '@/services/api';
import type { TimeTrackingImportData, TimeTrackingPreviewRow, TimeTrackingSource } from '@/services/api';
import type { Employee, PayPeriod } from '@/types';

interface Props {
  open: boolean;
  onClose: () => void;
  payPeriod: PayPeriod;
  employees: Employee[];
  onImportComplete: () => void;
}

type Step = 'select' | 'review' | 'done';

export function TimeTrackingImportModal({ open, onClose, payPeriod, employees, onImportComplete }: Props) {
  const [step, setStep] = useState<Step>('select');
  const [sources, setSources] = useState<TimeTrackingSource[]>([]);
  const [sourceId, setSourceId] = useState<number | ''>('');
  const [startDate, setStartDate] = useState(payPeriod.start_date);
  const [endDate, setEndDate] = useState(payPeriod.end_date);
  const [preview, setPreview] = useState<TimeTrackingImportData | null>(null);
  const [mappings, setMappings] = useState<Map<string, number | null>>(new Map());
  const [includedRows, setIncludedRows] = useState<Set<string>>(new Set());
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [appliedCount, setAppliedCount] = useState(0);

  useEffect(() => {
    if (!open) return;

    setStep('select');
    setPreview(null);
    setMappings(new Map());
    setIncludedRows(new Set());
    setError(null);
    setStartDate(payPeriod.start_date);
    setEndDate(payPeriod.end_date);
    setAppliedCount(0);

    timeTrackingSourcesApi.list()
      .then((res) => {
        const active = res.time_tracking_sources.filter((source) => source.active);
        setSources(active);
        setSourceId(active[0]?.id || '');
      })
      .catch((err) => setError(err instanceof Error ? err.message : 'Failed to load time tracking sources'));
  }, [open, payPeriod.start_date, payPeriod.end_date]);

  const rows: TimeTrackingPreviewRow[] = useMemo(() => preview?.processed_payload?.rows || [], [preview]);
  const effectiveWarningsFor = (row: TimeTrackingPreviewRow) => (row.warnings || []).filter((warning) => {
    return !(warning.code === 'unmatched_employee' && mappings.get(row.source_user_id));
  });
  const includedPreviewRows = rows.filter((row) => includedRows.has(row.source_user_id));
  const mappedIncludedRows = includedPreviewRows.filter((row) => mappings.get(row.source_user_id));
  const includedEmployeeIds = mappedIncludedRows.map((row) => mappings.get(row.source_user_id)).filter((id): id is number => Boolean(id));
  const duplicateEmployeeIds = new Set(includedEmployeeIds.filter((id, idx) => includedEmployeeIds.indexOf(id) !== idx));
  const readyRows = mappedIncludedRows.filter((row) => effectiveWarningsFor(row).length === 0 && !duplicateEmployeeIds.has(mappings.get(row.source_user_id) as number)).length;
  const warningCount = mappedIncludedRows.reduce((sum, row) => sum + effectiveWarningsFor(row).length, 0);
  const duplicateMappingCount = mappedIncludedRows.filter((row) => duplicateEmployeeIds.has(mappings.get(row.source_user_id) as number)).length;
  const excludedCount = rows.length - includedPreviewRows.length;
  const mappedIncludedCount = mappedIncludedRows.length;
  const unmappedIncludedCount = includedPreviewRows.length - mappedIncludedCount;
  const canApply = mappedIncludedCount > 0 && warningCount === 0 && duplicateEmployeeIds.size === 0;

  const handlePreview = async () => {
    if (!sourceId) {
      setError('Choose a time tracking source first.');
      return;
    }

    setLoading(true);
    setError(null);
    try {
      const res = await payPeriodsApi.previewTimeTrackingImport(payPeriod.id, {
        source_id: Number(sourceId),
        start_date: startDate,
        end_date: endDate,
      });
      setPreview(res.import);
      const next = new Map<string, number | null>();
      const included = new Set<string>();
      (res.import.processed_payload.rows || []).forEach((row) => {
        next.set(row.source_user_id, row.employee_id);
        included.add(row.source_user_id);
      });
      setMappings(next);
      setIncludedRows(included);
      setStep('review');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to fetch time tracking hours');
    } finally {
      setLoading(false);
    }
  };

  const handleApply = async () => {
    if (!preview) return;
    setLoading(true);
    setError(null);
    try {
      const applyMappings = rows.map((row) => {
        const employeeId = mappings.get(row.source_user_id) || null;

        return {
          source_user_id: row.source_user_id,
          employee_id: employeeId,
          include: includedRows.has(row.source_user_id) && Boolean(employeeId),
        };
      });

      const res = await payPeriodsApi.applyTimeTrackingImport(payPeriod.id, {
        import_id: preview.id,
        mappings: applyMappings,
      });

      if (res.results.errors.length > 0) {
        setError('Some rows could not be imported. Resolve warnings/mappings and try again.');
        return;
      }

      setAppliedCount(res.results.applied.length);
      setStep('done');
      onImportComplete();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to apply time tracking import');
    } finally {
      setLoading(false);
    }
  };

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="fixed inset-0 bg-black/50" onClick={onClose} />
      <div className="relative z-50 flex max-h-[90vh] w-full max-w-5xl flex-col overflow-hidden rounded-lg bg-white shadow-xl mx-4">
        <div className="border-b px-6 py-4 flex items-center justify-between">
          <div>
            <h3 className="text-lg font-semibold text-gray-900">Import Time Tracking</h3>
            <p className="text-sm text-gray-500 mt-0.5">
              Pull approved hours from AIRE, Cornerstone Tax, or another connected source.
            </p>
          </div>
          <button onClick={onClose} className="text-gray-400 hover:text-gray-600 p-1">✕</button>
        </div>

        <div className="flex-1 overflow-y-auto px-6 py-4 space-y-4">
          {error && <div className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700">{error}</div>}

          {step === 'select' && (
            <div className="space-y-4">
              {sources.length === 0 ? (
                <div className="rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">
                  No active time tracking sources are configured for this company yet.
                </div>
              ) : (
                <>
                  <label className="block text-sm font-medium text-gray-700">
                    Time tracking source
                    <select
                      value={sourceId}
                      onChange={(e) => setSourceId(e.target.value ? Number(e.target.value) : '')}
                      className="mt-1 w-full rounded-md border px-3 py-2 text-sm"
                    >
                      {sources.map((source) => (
                        <option key={source.id} value={source.id}>{source.name}</option>
                      ))}
                    </select>
                  </label>
                  <div className="grid gap-4 sm:grid-cols-2">
                    <label className="block text-sm font-medium text-gray-700">
                      Start date
                      <input type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} className="mt-1 w-full rounded-md border px-3 py-2 text-sm" />
                    </label>
                    <label className="block text-sm font-medium text-gray-700">
                      End date
                      <input type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} className="mt-1 w-full rounded-md border px-3 py-2 text-sm" />
                    </label>
                  </div>
                  <div className="rounded-lg border border-blue-200 bg-blue-50 p-4 text-sm text-blue-800">
                    Payroll will fetch the surrounding full work weeks so 40-hour weekly overtime is calculated correctly, then only import hours inside this pay period.
                  </div>
                </>
              )}
            </div>
          )}

          {step === 'review' && preview && (
            <div className="space-y-4">
              <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
                <span className="text-gray-600">
                  {includedPreviewRows.length} included · {excludedCount} excluded · {readyRows} ready · {unmappedIncludedCount} unmapped · {warningCount} warning{warningCount === 1 ? '' : 's'}
                </span>
                <span className="text-xs text-gray-500">
                  OT window: {preview.fetch_start_date} → {preview.fetch_end_date}
                </span>
              </div>

              {warningCount > 0 && (
                <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800">
                  Resolve pending/open time entries or exclude rows that should not be imported. Mapped rows must be warning-free.
                </div>
              )}

              {unmappedIncludedCount > 0 && (
                <div className="rounded-lg border border-blue-200 bg-blue-50 p-3 text-sm text-blue-800">
                  {unmappedIncludedCount} included row{unmappedIncludedCount === 1 ? '' : 's'} have no payroll employee mapping. Map them to import hours, or uncheck Include so the skip is explicit.
                </div>
              )}

              {duplicateMappingCount > 0 && (
                <div className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700">
                  {duplicateMappingCount} included row{duplicateMappingCount === 1 ? '' : 's'} map to a payroll employee that is already selected. Each payroll employee can only be imported once per preview.
                </div>
              )}

              <div className="overflow-hidden rounded-lg border">
                <table className="min-w-full divide-y divide-gray-200 text-sm">
                  <thead className="bg-gray-50">
                    <tr>
                      <th className="px-4 py-2 text-left text-xs font-medium uppercase text-gray-500">Import</th>
                      <th className="px-4 py-2 text-left text-xs font-medium uppercase text-gray-500">Source employee</th>
                      <th className="px-4 py-2 text-left text-xs font-medium uppercase text-gray-500">Payroll employee</th>
                      <th className="px-4 py-2 text-right text-xs font-medium uppercase text-gray-500">Regular</th>
                      <th className="px-4 py-2 text-right text-xs font-medium uppercase text-gray-500">OT</th>
                      <th className="px-4 py-2 text-left text-xs font-medium uppercase text-gray-500">Status</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-200 bg-white">
                    {rows.map((row) => {
                      const included = includedRows.has(row.source_user_id);
                      const mappedEmployeeId = mappings.get(row.source_user_id);
                      const mapped = Boolean(mappedEmployeeId);
                      const duplicateMapping = mappedEmployeeId != null && duplicateEmployeeIds.has(mappedEmployeeId);
                      const effectiveWarnings = effectiveWarningsFor(row);

                      return (
                      <tr key={row.source_user_id} className={!included ? 'bg-gray-50 opacity-70' : (!mapped || effectiveWarnings.length) ? 'bg-amber-50' : ''}>
                        <td className="px-4 py-2 align-top">
                          <label className="inline-flex items-center gap-2 text-xs font-medium text-gray-700">
                            <input
                              type="checkbox"
                              checked={included}
                              onChange={(e) => {
                                setIncludedRows((prev) => {
                                  const next = new Set(prev);
                                  if (e.target.checked) {
                                    next.add(row.source_user_id);
                                  } else {
                                    next.delete(row.source_user_id);
                                  }
                                  return next;
                                });
                              }}
                              className="rounded border-gray-300"
                            />
                            {included ? 'Include' : 'Skip'}
                          </label>
                        </td>
                        <td className="px-4 py-2">
                          <div className="font-medium text-gray-900">{row.source_display_name}</div>
                          {row.source_email && <div className="text-xs text-gray-500">{row.source_email}</div>}
                        </td>
                        <td className="px-4 py-2">
                          <select
                            value={mappings.get(row.source_user_id) ?? ''}
                            onChange={(e) => setMappings((prev) => new Map(prev).set(row.source_user_id, e.target.value ? Number(e.target.value) : null))}
                            disabled={!included}
                            className="w-full rounded border px-2 py-1 text-sm disabled:bg-gray-100 disabled:text-gray-500"
                          >
                            <option value="">-- Map employee --</option>
                            {employees.map((employee) => (
                              <option key={employee.id} value={employee.id}>{[employee.first_name, employee.last_name].filter(Boolean).join(' ')}</option>
                            ))}
                          </select>
                          <div className="mt-1 text-xs text-gray-500">{row.match_method} · {Math.round((row.match_score || 0) * 100)}%</div>
                        </td>
                        <td className="px-4 py-2 text-right font-mono">{Number(row.regular_hours || 0).toFixed(2)}</td>
                        <td className="px-4 py-2 text-right font-mono">{Number(row.overtime_hours || 0).toFixed(2)}</td>
                        <td className="px-4 py-2">
                          {!included ? (
                            <span className="rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-700">Skipped</span>
                          ) : !mapped ? (
                            <span className="rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800">Needs mapping or will be skipped</span>
                          ) : duplicateMapping ? (
                            <span className="rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-700">Duplicate payroll employee</span>
                          ) : effectiveWarnings.length ? (
                            <ul className="list-disc pl-4 text-xs text-amber-800">
                              {effectiveWarnings.map((warning, idx) => <li key={idx}>{warning.message}</li>)}
                            </ul>
                          ) : (
                            <span className="rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-800">Ready</span>
                          )}
                        </td>
                      </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </div>
          )}

          {step === 'done' && (
            <div className="py-8 text-center">
              <div className="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-green-100 text-green-700">✓</div>
              <h4 className="text-lg font-semibold text-gray-900">Time tracking imported</h4>
              <p className="mt-2 text-sm text-gray-600">{appliedCount} employee row{appliedCount === 1 ? '' : 's'} applied. Run payroll to calculate taxes and deductions.</p>
            </div>
          )}
        </div>

        <div className="flex justify-end gap-3 border-t bg-gray-50 px-6 py-4">
          {step === 'select' && (
            <>
              <Button variant="outline" onClick={onClose}>Cancel</Button>
              <Button onClick={handlePreview} disabled={loading || !sourceId || sources.length === 0}>{loading ? 'Fetching...' : 'Fetch Hours'}</Button>
            </>
          )}
          {step === 'review' && (
            <>
              <Button variant="outline" onClick={() => setStep('select')}>Back</Button>
              <Button onClick={handleApply} disabled={loading || !canApply}>{loading ? 'Applying...' : 'Apply Import'}</Button>
            </>
          )}
          {step === 'done' && <Button onClick={onClose}>Close</Button>}
        </div>
      </div>
    </div>
  );
}
