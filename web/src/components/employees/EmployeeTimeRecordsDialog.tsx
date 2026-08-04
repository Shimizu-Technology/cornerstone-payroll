import { useCallback, useEffect, useState } from 'react';
import { CalendarDays, Clock3, PencilLine, Plus } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NumericInput } from '@/components/ui/numeric-input';
import { Textarea } from '@/components/ui/textarea';
import { employeesApi } from '@/services/api';
import type { DailyTimeRecord, DailyTimeRecordInput, Employee } from '@/types';

interface Props {
  employee: Employee;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

function dateRange(): { start: string; end: string } {
  const today = new Date();
  const start = new Date(today.getFullYear(), today.getMonth() - 1, 1);
  const end = new Date(today.getFullYear(), today.getMonth() + 2, 0);
  return { start: start.toLocaleDateString('en-CA'), end: end.toLocaleDateString('en-CA') };
}

const EMPTY: DailyTimeRecordInput = { work_date: '', scheduled_hours: 0, actual_worked_hours: null, pto_hours: 0, holiday_hours: 0, exception_reason: '', override_reason: '' };

export function EmployeeTimeRecordsDialog({ employee, open, onOpenChange }: Props) {
  const initialRange = dateRange();
  const [startDate, setStartDate] = useState(initialRange.start);
  const [endDate, setEndDate] = useState(initialRange.end);
  const [records, setRecords] = useState<DailyTimeRecord[]>([]);
  const [editing, setEditing] = useState<DailyTimeRecord | null>(null);
  const [draft, setDraft] = useState<DailyTimeRecordInput>(EMPTY);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await employeesApi.timeRecords(employee.id, { start_date: startDate, end_date: endDate });
      setRecords(response.data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to load daily time records');
    } finally {
      setLoading(false);
    }
  }, [employee.id, endDate, startDate]);

  useEffect(() => {
    if (open) void load();
  }, [load, open]);

  const beginNew = () => {
    setEditing(null);
    setDraft({ ...EMPTY });
    setError(null);
  };

  const beginEdit = (record: DailyTimeRecord) => {
    setEditing(record);
    setDraft({
      scheduled_hours: Number(record.scheduled_hours),
      actual_worked_hours: record.actual_worked_hours == null ? null : Number(record.actual_worked_hours),
      pto_hours: Number(record.pto_hours),
      holiday_hours: Number(record.holiday_hours),
      exception_reason: record.exception_reason || '',
      override_reason: '',
    });
    setError(null);
  };

  const save = async () => {
    if (!editing && !draft.work_date) return;
    if (editing && (draft.override_reason || '').trim().length < 5) {
      setError('Explain the correction in at least 5 characters so the prior version remains understandable.');
      return;
    }
    setSaving(true);
    setError(null);
    try {
      if (editing) {
        await employeesApi.updateTimeRecord(employee.id, editing.id, draft);
      } else {
        await employeesApi.createTimeRecord(employee.id, draft);
      }
      setEditing(null);
      setDraft(EMPTY);
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to save the daily time record');
    } finally {
      setSaving(false);
    }
  };

  const editorVisible = editing !== null || draft.work_date !== '';

  return (
    <Dialog open={open} onOpenChange={(nextOpen) => !saving && onOpenChange(nextOpen)}>
      <DialogContent className="dialog-wide dialog-top max-h-[calc(100vh-2rem)] max-w-5xl overflow-y-auto rounded-3xl p-0">
        <div className="border-b border-neutral-800 bg-neutral-950 px-6 py-5 text-white sm:rounded-t-3xl">
          <DialogHeader>
            <div className="mb-3 flex h-10 w-10 items-center justify-center rounded-2xl bg-white/10 ring-1 ring-white/15"><CalendarDays className="h-5 w-5" /></div>
            <DialogTitle className="text-xl text-white">Daily salary time records</DialogTitle>
            <DialogDescription className="text-neutral-300">Review the schedule-derived ledger and record actual-time, PTO, or holiday exceptions for {employee.first_name}. Corrections create a new revision instead of rewriting the prior entry.</DialogDescription>
          </DialogHeader>
        </div>

        <div className="space-y-5 px-4 py-5 sm:px-6">
          <div className="flex flex-col gap-3 rounded-2xl border border-neutral-200 bg-neutral-50 p-4 sm:flex-row sm:items-end">
            <div className="flex-1"><label className="mb-1 block text-xs font-semibold uppercase tracking-wide text-neutral-500">From</label><Input type="date" value={startDate} onChange={(event) => setStartDate(event.target.value)} /></div>
            <div className="flex-1"><label className="mb-1 block text-xs font-semibold uppercase tracking-wide text-neutral-500">Through</label><Input type="date" value={endDate} onChange={(event) => setEndDate(event.target.value)} /></div>
            <Button type="button" variant="outline" onClick={() => void load()} disabled={loading}>Refresh</Button>
            <Button type="button" onClick={beginNew}><Plus className="mr-2 h-4 w-4" />Add day</Button>
          </div>

          {error && <div className="rounded-2xl border border-danger-200 bg-danger-50 p-3 text-sm text-danger-800">{error}</div>}

          {editorVisible && (
            <div className="rounded-2xl border border-primary-200 bg-primary-50/40 p-4">
              <div className="mb-4 flex items-center gap-2 text-sm font-semibold text-primary-950"><PencilLine className="h-4 w-4" />{editing ? `Correct ${editing.work_date}` : 'Add a daily record'}</div>
              <div className="grid gap-3 sm:grid-cols-3 lg:grid-cols-5">
                {!editing && <div><label className="mb-1 block text-xs font-medium text-neutral-700">Work date *</label><Input type="date" value={draft.work_date || ''} onChange={(event) => setDraft({ ...draft, work_date: event.target.value })} /></div>}
                <div><label className="mb-1 block text-xs font-medium text-neutral-700">Scheduled</label><NumericInput min={0} max={24} value={draft.scheduled_hours} onValueChange={(value) => setDraft({ ...draft, scheduled_hours: value || 0 })} /></div>
                <div><label className="mb-1 block text-xs font-medium text-neutral-700">Actually worked</label><NumericInput min={0} max={24} value={draft.actual_worked_hours ?? null} onValueChange={(value) => setDraft({ ...draft, actual_worked_hours: value })} placeholder="Use schedule" /></div>
                <div><label className="mb-1 block text-xs font-medium text-neutral-700">PTO</label><NumericInput min={0} max={24} value={draft.pto_hours} onValueChange={(value) => setDraft({ ...draft, pto_hours: value || 0 })} /></div>
                <div><label className="mb-1 block text-xs font-medium text-neutral-700">Holiday</label><NumericInput min={0} max={24} value={draft.holiday_hours} onValueChange={(value) => setDraft({ ...draft, holiday_hours: value || 0 })} /></div>
              </div>
              <div className="mt-3 grid gap-3 sm:grid-cols-2">
                <div><label className="mb-1 block text-xs font-medium text-neutral-700">Exception note</label><Textarea rows={2} value={draft.exception_reason || ''} onChange={(event) => setDraft({ ...draft, exception_reason: event.target.value })} placeholder="PTO, holiday, schedule variance, or imported source context" /></div>
                {editing && <div><label className="mb-1 block text-xs font-medium text-neutral-700">Correction reason *</label><Textarea rows={2} value={draft.override_reason || ''} onChange={(event) => setDraft({ ...draft, override_reason: event.target.value })} placeholder="Why this revision is necessary" /></div>}
              </div>
              <div className="mt-4 flex justify-end gap-2"><Button type="button" variant="outline" onClick={() => { setEditing(null); setDraft(EMPTY); }}>Cancel edit</Button><Button type="button" onClick={save} disabled={saving}>{saving ? 'Saving revision...' : 'Save time record'}</Button></div>
            </div>
          )}

          <div className="overflow-hidden rounded-2xl border border-neutral-200">
            {loading ? <p className="p-6 text-sm text-neutral-500">Loading time records...</p> : records.length === 0 ? (
              <div className="p-6 text-center"><Clock3 className="mx-auto h-6 w-6 text-neutral-400" /><p className="mt-2 text-sm font-medium text-neutral-700">No records in this date range</p><p className="mt-1 text-xs text-neutral-500">Schedule records appear when a regular payroll is prepared; actual-time records can also be entered manually.</p></div>
            ) : (
              <div className="divide-y divide-neutral-200">
                {records.map((record) => (
                  <button type="button" key={record.id} onClick={() => beginEdit(record)} className="grid w-full gap-2 bg-white p-4 text-left hover:bg-primary-50/50 sm:grid-cols-[1.2fr_repeat(4,0.75fr)_1fr] sm:items-center">
                    <div><p className="text-sm font-semibold text-neutral-900">{record.work_date}</p><p className="text-xs text-neutral-500">{record.source.replaceAll('_', ' ')} · revision {record.revision}</p></div>
                    <p className="text-xs text-neutral-600"><span className="font-semibold text-neutral-900">{Number(record.scheduled_hours)}</span> scheduled</p>
                    <p className="text-xs text-neutral-600"><span className="font-semibold text-neutral-900">{record.actual_worked_hours == null ? '—' : Number(record.actual_worked_hours)}</span> actual</p>
                    <p className="text-xs text-neutral-600"><span className="font-semibold text-neutral-900">{Number(record.pto_hours)}</span> PTO</p>
                    <p className="text-xs text-neutral-600"><span className="font-semibold text-neutral-900">{Number(record.holiday_hours)}</span> holiday</p>
                    <p className="truncate text-xs text-neutral-500">{record.exception_reason || 'No exception note'}</p>
                  </button>
                ))}
              </div>
            )}
          </div>
        </div>

        <DialogFooter className="sticky bottom-0 z-10 border-t border-neutral-200 bg-white/95 px-6 py-4 backdrop-blur-md sm:rounded-b-3xl"><Button type="button" variant="outline" onClick={() => onOpenChange(false)}>Close</Button></DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
