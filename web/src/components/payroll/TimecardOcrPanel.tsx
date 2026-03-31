import { useState, useCallback, useEffect, useRef } from 'react';
import { timecardsApi, punchEntriesApi, employeesApi } from '@/services/api';
import type { TimecardData, PunchEntryData } from '@/services/api';
import type { Employee } from '@/types';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';

// ──── Time format helpers ──────────────────────────────
function to12h(time24: string | null): string {
  if (!time24) return '';
  const [hStr, mStr] = time24.split(':');
  let h = parseInt(hStr, 10);
  const m = mStr || '00';
  if (isNaN(h)) return time24;
  const ampm = h >= 12 ? 'PM' : 'AM';
  if (h === 0) h = 12;
  else if (h > 12) h -= 12;
  return `${h}:${m} ${ampm}`;
}

function to24h(time12: string): string | null {
  const raw = time12.trim();
  if (!raw) return null;

  // Already 24h format (e.g. "13:05")
  if (/^\d{1,2}:\d{2}$/.test(raw) && !raw.match(/[APap]/)) return raw;

  const match = raw.match(/^(\d{1,2}):?(\d{2})?\s*([APap][Mm]?)$/);
  if (!match) return raw;

  let h = parseInt(match[1], 10);
  const m = match[2] || '00';
  const period = match[3].toUpperCase();

  if (period.startsWith('P') && h < 12) h += 12;
  if (period.startsWith('A') && h === 12) h = 0;

  return `${h.toString().padStart(2, '0')}:${m}`;
}

function confidenceColor(c: number | null): string {
  if (c === null) return 'bg-gray-100 text-gray-600';
  if (c >= 0.9) return 'bg-green-100 text-green-800';
  if (c >= 0.7) return 'bg-yellow-100 text-yellow-800';
  return 'bg-red-100 text-red-800';
}

function statusBadge(status: string) {
  const colors: Record<string, string> = {
    pending: 'bg-gray-200 text-gray-700',
    processing: 'bg-blue-100 text-blue-700',
    complete: 'bg-yellow-100 text-yellow-800',
    failed: 'bg-red-100 text-red-800',
    reviewed: 'bg-green-100 text-green-800',
  };
  return <Badge className={colors[status] || 'bg-gray-100'}>{status}</Badge>;
}

// ──── Spinner ──────────────────────────────────────────
function Spinner({ size = 'md' }: { size?: 'sm' | 'md' | 'lg' }) {
  const px = size === 'sm' ? 'w-4 h-4' : size === 'lg' ? 'w-8 h-8' : 'w-6 h-6';
  return (
    <svg className={`${px} animate-spin text-indigo-600`} viewBox="0 0 24 24" fill="none">
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
      <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
    </svg>
  );
}

// ──── Upload Section ──────────────────────────────────
function UploadSection({ payPeriodId, onUploaded }: { payPeriodId?: number; onUploaded: () => void }) {
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState('');
  const [dragOver, setDragOver] = useState(false);

  const handleFiles = async (files: FileList | null) => {
    if (!files?.length) return;
    setUploading(true);
    setError('');

    try {
      for (const file of Array.from(files)) {
        await timecardsApi.upload(file, payPeriodId);
      }
      onUploaded();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Upload failed');
    } finally {
      setUploading(false);
    }
  };

  return (
    <div
      className={`border-2 border-dashed rounded-lg p-6 text-center transition-colors ${
        dragOver ? 'border-indigo-400 bg-indigo-50' : 'border-gray-300 hover:border-gray-400'
      }`}
      onDragOver={(e) => { e.preventDefault(); setDragOver(true); }}
      onDragLeave={() => setDragOver(false)}
      onDrop={(e) => { e.preventDefault(); setDragOver(false); handleFiles(e.dataTransfer.files); }}
    >
      {uploading ? (
        <div className="flex flex-col items-center gap-3 py-4">
          <Spinner size="lg" />
          <p className="font-medium text-indigo-900">Uploading &amp; segmenting...</p>
          <p className="text-xs text-gray-500">This should only take a few seconds.</p>
        </div>
      ) : (
        <>
          <p className="text-sm text-gray-600 mb-3">
            Drag & drop timecard images or PDFs here, or click to browse
          </p>
          <input
            type="file"
            accept="image/*,.pdf"
            multiple
            className="hidden"
            id="timecard-upload"
            onChange={(e) => handleFiles(e.target.files)}
          />
          <Button variant="outline" onClick={() => document.getElementById('timecard-upload')?.click()}>
            Select Files
          </Button>
        </>
      )}
      {error && <p className="text-sm text-red-600 mt-2">{error}</p>}
    </div>
  );
}

// ──── Timecard List Item ────────────────────────────────
function TimecardListItem({ tc, onSelect, onReprocess, onDelete }: {
  tc: TimecardData;
  onSelect: () => void;
  onReprocess: () => void;
  onDelete: () => void;
}) {
  const isProcessing = tc.ocr_status === 'pending' || tc.ocr_status === 'processing';

  return (
    <div
      className={`flex items-center justify-between p-3 border rounded-lg cursor-pointer transition-colors ${
        isProcessing ? 'bg-indigo-50/50 border-indigo-200' : 'hover:bg-gray-50'
      }`}
      onClick={isProcessing ? undefined : onSelect}
    >
      <div className="flex items-center gap-3 flex-1">
        {isProcessing ? (
          <div className="w-12 h-16 flex items-center justify-center rounded border border-indigo-200 bg-indigo-50">
            <Spinner size="sm" />
          </div>
        ) : tc.image_url ? (
          <img src={tc.image_url} alt="Timecard" className="w-12 h-16 object-cover rounded border" />
        ) : null}
        <div>
          <div className="flex items-center gap-2">
            <span className="font-medium text-sm">
              {isProcessing ? 'Processing with GPT...' : (tc.employee_name || 'Unknown Employee')}
            </span>
            {statusBadge(tc.ocr_status)}
            {!isProcessing && tc.overall_confidence !== null && (
              <Badge className={confidenceColor(tc.overall_confidence)}>
                {(tc.overall_confidence * 100).toFixed(0)}%
              </Badge>
            )}
          </div>
          <p className="text-xs text-gray-500 mt-0.5">
            {isProcessing ? (
              'OCR is running in the background. This takes 60-90 seconds per card.'
            ) : tc.period_start && tc.period_end ? (
              <>
                {tc.period_start} – {tc.period_end}
                {tc.review_summary.attention_count > 0 && (
                  <span className="text-orange-600 ml-2">
                    {tc.review_summary.attention_count} items need attention
                  </span>
                )}
              </>
            ) : 'Period not detected'}
          </p>
        </div>
      </div>
      <div className="flex gap-1" onClick={(e) => e.stopPropagation()}>
        {tc.ocr_status === 'failed' && (
          <Button size="sm" variant="outline" onClick={onReprocess}>Retry OCR</Button>
        )}
        {!isProcessing && (
          <Button size="sm" variant="outline" className="text-red-600" onClick={onDelete}>Delete</Button>
        )}
      </div>
    </div>
  );
}

// ──── Inline-editable time input ───────────────────────
function TimeInput({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <input
      className="w-[5.5rem] text-xs border border-gray-200 rounded px-1.5 py-1 font-mono focus:border-indigo-400 focus:ring-1 focus:ring-indigo-200 outline-none"
      value={value}
      onChange={(e) => onChange(e.target.value)}
      placeholder="—"
    />
  );
}

// ──── Timecard Detail / Review Screen ──────────────────
type EditableEntry = {
  id: number;
  card_day: number | null;
  date: string;
  clock_in: string;
  lunch_out: string;
  lunch_in: string;
  clock_out: string;
  in3: string;
  out3: string;
};

function buildEditable(entries: PunchEntryData[]): EditableEntry[] {
  return entries.map((pe) => ({
    id: pe.id,
    card_day: pe.card_day,
    date: pe.date || '',
    clock_in: to12h(pe.clock_in),
    lunch_out: to12h(pe.lunch_out),
    lunch_in: to12h(pe.lunch_in),
    clock_out: to12h(pe.clock_out),
    in3: to12h(pe.in3),
    out3: to12h(pe.out3),
  }));
}

function TimecardDetail({ timecard: initialTc, onBack, payPeriodId, employees, onApplied }: {
  timecard: TimecardData;
  onBack: () => void;
  payPeriodId?: number;
  employees: Employee[];
  onApplied?: () => void;
}) {
  const [tc, setTc] = useState(initialTc);
  const [editable, setEditable] = useState<EditableEntry[]>(() => buildEditable(initialTc.punch_entries));
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [reprocessing, setReprocessing] = useState(false);
  const [reviewing, setReviewing] = useState(false);
  const [applying, setApplying] = useState(false);
  const [editingName, setEditingName] = useState(false);
  const [nameValue, setNameValue] = useState(tc.employee_name || '');
  const [selectedEmployeeId, setSelectedEmployeeId] = useState<number | ''>('');
  const [error, setError] = useState('');

  const reload = useCallback(async () => {
    const fresh = await timecardsApi.show(tc.id);
    setTc(fresh);
    setEditable(buildEditable(fresh.punch_entries));
    setDirty(false);
  }, [tc.id]);

  const sortedEntries = [...tc.punch_entries].sort((a, b) => (a.card_day ?? 99) - (b.card_day ?? 99));
  const sortedEditable = [...editable].sort((a, b) => (a.card_day ?? 99) - (b.card_day ?? 99));
  const punchesWithData = sortedEntries.filter((pe) => !pe.blank_day);

  const updateField = (id: number, field: keyof EditableEntry, value: string) => {
    setEditable((prev) => prev.map((e) => (e.id === id ? { ...e, [field]: value } : e)));
    setDirty(true);
  };

  const handleSaveAll = async () => {
    setSaving(true);
    setError('');
    try {
      for (const entry of editable) {
        const original = tc.punch_entries.find((pe) => pe.id === entry.id);
        if (!original) continue;

        const changes: Record<string, string | null> = {};
        const fieldsToCheck = ['clock_in', 'lunch_out', 'lunch_in', 'clock_out', 'in3', 'out3'] as const;

        for (const f of fieldsToCheck) {
          const converted = to24h(entry[f]);
          if (converted !== original[f]) {
            changes[f] = converted;
          }
        }
        if (entry.date !== (original.date || '')) {
          changes['date'] = entry.date || null;
        }

        if (Object.keys(changes).length > 0) {
          await punchEntriesApi.update(entry.id, changes as Partial<PunchEntryData>);
        }
      }
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Save failed');
    } finally {
      setSaving(false);
    }
  };

  const handleApproveAll = async () => {
    setSaving(true);
    try {
      const needsApproval = tc.punch_entries.filter(
        (pe) => pe.needs_attention && pe.review_state === 'unresolved'
      );
      for (const pe of needsApproval) {
        await punchEntriesApi.update(pe.id, { review_state: 'approved', reviewed_by_name: 'Admin' });
      }
      await reload();
    } finally {
      setSaving(false);
    }
  };

  const handleReprocess = async () => {
    setReprocessing(true);
    setError('');
    try {
      const updated = await timecardsApi.reprocess(tc.id);
      setTc(updated);
      setEditable(buildEditable(updated.punch_entries));
      setDirty(false);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Reprocess failed');
    } finally {
      setReprocessing(false);
    }
  };

  const handleReview = async () => {
    setReviewing(true);
    setError('');
    try {
      const updated = await timecardsApi.review(tc.id, 'Admin');
      setTc(updated);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Review failed');
    } finally {
      setReviewing(false);
    }
  };

  const handleApplyToPayroll = async () => {
    if (!payPeriodId || !onApplied) return;
    setApplying(true);
    setError('');
    try {
      const empId = selectedEmployeeId || undefined;
      await timecardsApi.applyToPayroll(tc.id, payPeriodId, empId ? Number(empId) : undefined);
      onApplied();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to apply to payroll');
    } finally {
      setApplying(false);
    }
  };

  const handleSaveName = async () => {
    try {
      const updated = await timecardsApi.update(tc.id, { employee_name: nameValue });
      setTc(updated);
      setEditingName(false);
    } catch { /* ignore */ }
  };

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex items-center gap-3">
        <Button variant="outline" size="sm" onClick={onBack}>Back</Button>
        <h3 className="font-semibold text-lg flex-1">
          {editingName ? (
            <span className="flex items-center gap-2">
              <input className="border rounded px-2 py-1 text-sm" value={nameValue} onChange={(e) => setNameValue(e.target.value)} />
              <Button size="sm" onClick={handleSaveName}>Save</Button>
              <Button size="sm" variant="outline" onClick={() => setEditingName(false)}>Cancel</Button>
            </span>
          ) : (
            <span className="cursor-pointer hover:underline" onClick={() => setEditingName(true)}>
              {tc.employee_name || 'Unknown Employee'} ✏️
            </span>
          )}
        </h3>
        {statusBadge(tc.ocr_status)}
        {tc.overall_confidence !== null && (
          <Badge className={confidenceColor(tc.overall_confidence)}>
            {(tc.overall_confidence * 100).toFixed(0)}% confidence
          </Badge>
        )}
      </div>

      {error && <div className="bg-red-50 text-red-700 px-3 py-2 rounded text-sm">{error}</div>}

      <div className="flex gap-4">
        {/* Image preview */}
        <div className="w-72 shrink-0">
          {tc.preprocessed_image_url ? (
            <img src={tc.preprocessed_image_url} alt="Processed timecard" className="w-full rounded border" />
          ) : tc.image_url ? (
            <img src={tc.image_url} alt="Original timecard" className="w-full rounded border" />
          ) : (
            <div className="bg-gray-100 rounded border h-96 flex items-center justify-center text-gray-400">No image</div>
          )}
          <p className="text-xs text-gray-500 mt-1">Period: {tc.period_start || '?'} – {tc.period_end || '?'}</p>
        </div>

        {/* Punch table — always editable */}
        <div className="flex-1 overflow-x-auto">
          <table className="w-full text-left">
            <thead>
              <tr className="text-xs text-gray-500 border-b">
                <th className="px-1 py-1 w-8">Day</th>
                <th className="px-1 py-1 w-24">Date</th>
                <th className="px-1 py-1 w-8">DOW</th>
                <th className="px-1 py-1">In</th>
                <th className="px-1 py-1">Out</th>
                <th className="px-1 py-1">In</th>
                <th className="px-1 py-1">Out</th>
                <th className="px-1 py-1">In3</th>
                <th className="px-1 py-1">Out3</th>
                <th className="px-1 py-1 text-right w-14">Hours</th>
                <th className="px-1 py-1 w-12">Conf</th>
                <th className="px-1 py-1">Notes</th>
              </tr>
            </thead>
            <tbody>
              {sortedEditable.map((entry) => {
                const original = sortedEntries.find((pe) => pe.id === entry.id);
                if (!original || original.blank_day) return null;
                const hasData = original.clock_in || original.lunch_out || original.lunch_in || original.clock_out || original.in3 || original.out3;
                if (!hasData) return null;

                const rowBg = original.needs_attention
                  ? original.review_state === 'approved' ? 'bg-blue-50' : 'bg-orange-50'
                  : '';

                return (
                  <tr key={entry.id} className={`text-sm ${rowBg}`}>
                    <td className="px-1 py-1 font-mono text-xs text-gray-500">{entry.card_day}</td>
                    <td className="px-1 py-1">
                      <input
                        type="date"
                        className="text-xs border border-gray-200 rounded px-1 py-0.5 w-[7rem] focus:border-indigo-400 outline-none"
                        value={entry.date}
                        onChange={(e) => updateField(entry.id, 'date', e.target.value)}
                      />
                    </td>
                    <td className="px-1 py-1 text-xs text-gray-500">{original.day_of_week || ''}</td>
                    <td className="px-1 py-1"><TimeInput value={entry.clock_in} onChange={(v) => updateField(entry.id, 'clock_in', v)} /></td>
                    <td className="px-1 py-1"><TimeInput value={entry.lunch_out} onChange={(v) => updateField(entry.id, 'lunch_out', v)} /></td>
                    <td className="px-1 py-1"><TimeInput value={entry.lunch_in} onChange={(v) => updateField(entry.id, 'lunch_in', v)} /></td>
                    <td className="px-1 py-1"><TimeInput value={entry.clock_out} onChange={(v) => updateField(entry.id, 'clock_out', v)} /></td>
                    <td className="px-1 py-1"><TimeInput value={entry.in3} onChange={(v) => updateField(entry.id, 'in3', v)} /></td>
                    <td className="px-1 py-1"><TimeInput value={entry.out3} onChange={(v) => updateField(entry.id, 'out3', v)} /></td>
                    <td className="px-1 py-1 text-xs text-right font-mono">{original.hours_worked?.toFixed(2) ?? '-'}</td>
                    <td className="px-1 py-1">
                      <Badge className={`text-[10px] ${confidenceColor(original.confidence)}`}>
                        {original.confidence !== null ? `${(original.confidence * 100).toFixed(0)}%` : '-'}
                      </Badge>
                    </td>
                    <td className="px-1 py-1 text-[10px] text-gray-500 max-w-28 truncate" title={original.notes || ''}>
                      {original.needs_attention && original.review_state === 'unresolved' && (
                        <span className="text-orange-600 font-medium">⚠ </span>
                      )}
                      {original.notes || ''}
                    </td>
                  </tr>
                );
              })}
            </tbody>
            <tfoot>
              <tr className="border-t font-semibold text-sm">
                <td colSpan={9} className="px-1 py-2 text-right">Total:</td>
                <td className="px-1 py-2 text-right font-mono">
                  {punchesWithData.reduce((sum, pe) => sum + (pe.hours_worked || 0), 0).toFixed(2)}
                </td>
                <td colSpan={2} />
              </tr>
            </tfoot>
          </table>

          {/* Save bar */}
          {dirty && (
            <div className="flex items-center gap-2 mt-3 p-2 bg-yellow-50 border border-yellow-200 rounded">
              <span className="text-sm text-yellow-800 flex-1">You have unsaved changes</span>
              <Button size="sm" onClick={handleSaveAll} disabled={saving}>
                {saving ? <><Spinner size="sm" /> Saving...</> : 'Save All Changes'}
              </Button>
            </div>
          )}
        </div>
      </div>

      {/* Action bar */}
      <div className="flex flex-wrap items-center gap-2 border-t pt-3">
        {(tc.ocr_status === 'complete' || tc.ocr_status === 'failed') && (
          <Button variant="outline" onClick={handleReprocess} disabled={reprocessing}>
            {reprocessing ? <><Spinner size="sm" /> Re-running OCR...</> : 'Re-run OCR'}
          </Button>
        )}

        {tc.ocr_status === 'complete' && tc.review_summary.attention_count > 0 && (
          <>
            <p className="text-sm text-orange-600">
              {tc.review_summary.attention_count} punch entries need attention
            </p>
            <Button size="sm" variant="outline" onClick={handleApproveAll} disabled={saving}>
              Approve All Flagged
            </Button>
          </>
        )}

        {tc.ocr_status === 'complete' && tc.review_summary.attention_count === 0 && (
          <Button onClick={handleReview} disabled={reviewing}>
            {reviewing ? <><Spinner size="sm" /> Marking...</> : 'Mark Reviewed'}
          </Button>
        )}

        {tc.ocr_status === 'reviewed' && payPeriodId && (
          <div className="flex items-center gap-2 w-full border-t pt-3 mt-1">
            <span className="text-sm font-medium text-gray-700 whitespace-nowrap">Assign to employee:</span>
            <select
              className="border rounded px-2 py-1.5 text-sm flex-1 max-w-xs"
              value={selectedEmployeeId}
              onChange={(e) => setSelectedEmployeeId(e.target.value ? Number(e.target.value) : '')}
            >
              <option value="">Auto-match by name</option>
              {employees.map((emp) => (
                <option key={emp.id} value={emp.id}>
                  {emp.first_name} {emp.last_name}
                </option>
              ))}
            </select>
            <Button className="bg-green-600 hover:bg-green-700" onClick={handleApplyToPayroll} disabled={applying}>
              {applying ? <><Spinner size="sm" /> Applying...</> : 'Apply Hours to Payroll'}
            </Button>
          </div>
        )}
        {tc.ocr_status === 'reviewed' && !payPeriodId && (
          <div className="flex items-center gap-2 w-full border-t pt-3 mt-1">
            <Badge className="bg-green-100 text-green-800">Reviewed</Badge>
            <span className="text-sm text-gray-600">
              Total hours: <strong className="font-mono">{punchesWithData.reduce((sum, pe) => sum + (pe.hours_worked || 0), 0).toFixed(2)}</strong>
              — Open this timecard from a pay period to apply hours to payroll.
            </span>
          </div>
        )}
      </div>
    </div>
  );
}

// ──── Pagination Controls ──────────────────────────────
function Pagination({ page, totalPages, totalCount, onPageChange }: {
  page: number; totalPages: number; totalCount: number; onPageChange: (p: number) => void;
}) {
  if (totalPages <= 1) return null;
  return (
    <div className="flex items-center justify-between pt-3 border-t">
      <span className="text-xs text-gray-500">{totalCount} total timecard{totalCount !== 1 ? 's' : ''}</span>
      <div className="flex items-center gap-1">
        <Button size="sm" variant="outline" disabled={page <= 1} onClick={() => onPageChange(page - 1)}>Previous</Button>
        <span className="text-xs text-gray-600 px-2">Page {page} of {totalPages}</span>
        <Button size="sm" variant="outline" disabled={page >= totalPages} onClick={() => onPageChange(page + 1)}>Next</Button>
      </div>
    </div>
  );
}

// ──── Main Panel ───────────────────────────────────────
export function TimecardOcrPanel({ payPeriodId, onPayrollUpdated }: {
  payPeriodId?: number;
  onPayrollUpdated?: () => void;
}) {
  const isStandalone = !payPeriodId;
  const [timecards, setTimecards] = useState<TimecardData[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedId, setSelectedId] = useState<number | null>(null);

  // Standalone pagination state
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalCount, setTotalCount] = useState(0);
  const [searchQuery, setSearchQuery] = useState('');
  const [activeSearch, setActiveSearch] = useState('');
  const [statusFilter, setStatusFilter] = useState('');
  const perPage = 12;

  const loadTimecards = useCallback(async () => {
    setLoading(true);
    try {
      if (isStandalone) {
        const resp = await timecardsApi.listPaginated({
          page, perPage, search: activeSearch || undefined, status: statusFilter || undefined,
        });
        setTimecards(resp.timecards);
        setTotalPages(resp.meta.total_pages);
        setTotalCount(resp.meta.total_count);
      } else {
        const data = await timecardsApi.list(payPeriodId);
        setTimecards(data);
      }
    } catch { /* ignore */ }
    finally { setLoading(false); }
  }, [isStandalone, payPeriodId, page, perPage, activeSearch, statusFilter]);

  const loadEmployees = useCallback(async () => {
    try {
      const resp = await employeesApi.list({ status: 'active', per_page: 500 });
      setEmployees(resp.data || []);
    } catch { /* ignore */ }
  }, []);

  useEffect(() => { loadTimecards(); loadEmployees(); }, [loadTimecards, loadEmployees]);

  // Track processing IDs independently from filtered view so polling doesn't
  // stop when a status filter hides pending/processing cards.
  const [processingIds, setProcessingIds] = useState<Set<number>>(new Set());
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // When timecards load, update the set of known processing IDs
  useEffect(() => {
    const activeIds = timecards
      .filter(tc => tc.ocr_status === 'pending' || tc.ocr_status === 'processing')
      .map(tc => tc.id);
    if (activeIds.length > 0) {
      setProcessingIds(prev => {
        const next = new Set(prev);
        activeIds.forEach(id => next.add(id));
        return next;
      });
    }
  }, [timecards]);

  const hasProcessing = processingIds.size > 0;

  useEffect(() => {
    if (!hasProcessing) return;

    pollRef.current = setInterval(async () => {
      try {
        if (isStandalone) {
          const resp = await timecardsApi.listPaginated({
            page, perPage, search: activeSearch || undefined, status: statusFilter || undefined,
          });
          setTimecards(resp.timecards);
          setTotalPages(resp.meta.total_pages);
          setTotalCount(resp.meta.total_count);

          // Clear IDs that are no longer processing (check unfiltered)
          const stillProcessing = resp.timecards
            .filter(tc => tc.ocr_status === 'pending' || tc.ocr_status === 'processing')
            .map(tc => tc.id);
          // If we have a filter active, also check the known IDs individually
          if (statusFilter && processingIds.size > 0) {
            const checkResp = await timecardsApi.listPaginated({ page: 1, perPage: 100, status: 'processing' });
            const pendingResp = await timecardsApi.listPaginated({ page: 1, perPage: 100, status: 'pending' });
            const allActive = new Set([
              ...checkResp.timecards.map(tc => tc.id),
              ...pendingResp.timecards.map(tc => tc.id),
            ]);
            setProcessingIds(allActive);
          } else {
            setProcessingIds(new Set(stillProcessing));
          }
        } else {
          const data = await timecardsApi.list(payPeriodId);
          setTimecards(data);
          const stillProcessing = data
            .filter(tc => tc.ocr_status === 'pending' || tc.ocr_status === 'processing')
            .map(tc => tc.id);
          setProcessingIds(new Set(stillProcessing));
        }
      } catch { /* ignore */ }
    }, 5000);

    return () => { if (pollRef.current) clearInterval(pollRef.current); };
  }, [hasProcessing, isStandalone, payPeriodId, page, perPage, activeSearch, statusFilter]);

  const handleSearch = () => {
    setPage(1);
    setActiveSearch(searchQuery);
  };

  const handleDelete = async (id: number) => {
    if (!window.confirm('Delete this timecard?')) return;
    try {
      await timecardsApi.delete(id);
      setTimecards((prev) => prev.filter((tc) => tc.id !== id));
      if (selectedId === id) setSelectedId(null);
      if (isStandalone) setTotalCount((c) => c - 1);
    } catch { /* ignore */ }
  };

  const handleReprocess = async (id: number) => {
    try {
      const updated = await timecardsApi.reprocess(id);
      setTimecards((prev) => prev.map((tc) => (tc.id === id ? updated : tc)));
    } catch { /* ignore */ }
  };

  const selectedTc = timecards.find((tc) => tc.id === selectedId);

  if (selectedTc) {
    return (
      <Card className="p-4">
        <TimecardDetail
          timecard={selectedTc}
          onBack={() => { setSelectedId(null); loadTimecards(); }}
          payPeriodId={payPeriodId}
          employees={employees}
          onApplied={() => { setSelectedId(null); loadTimecards(); onPayrollUpdated?.(); }}
        />
      </Card>
    );
  }

  return (
    <Card>
      <div className="p-4 border-b bg-indigo-50">
        <h3 className="font-semibold text-indigo-900">Timecard OCR</h3>
        <p className="text-sm text-indigo-700 mt-1">
          Upload timecard images or PDFs. GPT will extract punch times for review.
        </p>
      </div>

      <div className="p-4 space-y-4">
        <UploadSection payPeriodId={payPeriodId} onUploaded={() => { if (isStandalone) setPage(1); loadTimecards(); }} />

        {/* Search & filter — standalone mode only */}
        {isStandalone && (
          <div className="flex flex-wrap items-center gap-2">
            <input
              className="border rounded px-3 py-1.5 text-sm flex-1 min-w-[200px] max-w-sm focus:border-indigo-400 focus:ring-1 focus:ring-indigo-200 outline-none"
              placeholder="Search by employee name..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && handleSearch()}
            />
            <Button size="sm" variant="outline" onClick={handleSearch}>Search</Button>
            <select
              className="border rounded px-2 py-1.5 text-sm"
              value={statusFilter}
              onChange={(e) => { setStatusFilter(e.target.value); setPage(1); }}
            >
              <option value="">All statuses</option>
              <option value="pending">Pending</option>
              <option value="processing">Processing</option>
              <option value="complete">Complete</option>
              <option value="reviewed">Reviewed</option>
              <option value="failed">Failed</option>
            </select>
            {(activeSearch || statusFilter) && (
              <Button size="sm" variant="outline" className="text-gray-500" onClick={() => { setSearchQuery(''); setActiveSearch(''); setStatusFilter(''); setPage(1); }}>
                Clear filters
              </Button>
            )}
          </div>
        )}

        {hasProcessing && (
          <div className="flex items-center gap-3 p-3 rounded-lg bg-indigo-50 border border-indigo-200">
            <Spinner size="sm" />
            <div>
              <p className="text-sm font-medium text-indigo-900">
                OCR processing {processingIds.size} timecard(s) in the background...
              </p>
              <p className="text-xs text-indigo-600 mt-0.5">
                You can continue using the app. Cards will appear when ready (60-90s each).
              </p>
            </div>
          </div>
        )}

        {loading ? (
          <div className="flex items-center gap-2 text-sm text-gray-500">
            <Spinner size="sm" /> Loading timecards...
          </div>
        ) : timecards.length === 0 ? (
          <p className="text-sm text-gray-400 italic">
            {isStandalone && (activeSearch || statusFilter)
              ? 'No timecards match your filters.'
              : 'No timecards uploaded yet.'}
          </p>
        ) : (
          <div className="space-y-2">
            <h4 className="text-sm font-medium text-gray-700">
              {isStandalone ? `${totalCount} Timecard${totalCount !== 1 ? 's' : ''}` : `${timecards.length} Timecard${timecards.length !== 1 ? 's' : ''}`}
            </h4>
            {timecards.map((tc) => (
              <TimecardListItem
                key={tc.id}
                tc={tc}
                onSelect={() => setSelectedId(tc.id)}
                onReprocess={() => handleReprocess(tc.id)}
                onDelete={() => handleDelete(tc.id)}
              />
            ))}
            {isStandalone && (
              <Pagination page={page} totalPages={totalPages} totalCount={totalCount} onPageChange={setPage} />
            )}
          </div>
        )}
      </div>
    </Card>
  );
}
