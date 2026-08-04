import { useEffect, useMemo, useState } from 'react';
import { AlertTriangle, CalendarRange, CheckCircle2, Clock3, History, Scale, Settings2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NumericInput } from '@/components/ui/numeric-input';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { employeesApi } from '@/services/api';
import type { Employee, EmployeeOvertimeStatus, EmployeeTimekeepingMode, EmployeeWorkProfile, EmployeeWorkProfileInput } from '@/types';
import { EmployeeTimeRecordsDialog } from '@/components/employees/EmployeeTimeRecordsDialog';

const WEEKDAYS = [
  ['sunday', 'Sun'], ['monday', 'Mon'], ['tuesday', 'Tue'], ['wednesday', 'Wed'],
  ['thursday', 'Thu'], ['friday', 'Fri'], ['saturday', 'Sat'],
] as const;

const STANDARD_SCHEDULE: Record<string, number> = {
  sunday: 0, monday: 8, tuesday: 8, wednesday: 8, thursday: 8, friday: 8, saturday: 0,
};

function todayIsoDate(): string {
  return new Date().toLocaleDateString('en-CA');
}

function nextDate(date: string): string {
  const parsed = new Date(`${date}T00:00:00`);
  parsed.setDate(parsed.getDate() + 1);
  return parsed.toLocaleDateString('en-CA');
}

function initialInput(employee: Employee): EmployeeWorkProfileInput {
  const current = employee.current_work_profile;
  const earliest = current ? nextDate(current.effective_on) : employee.hire_date;
  return {
    effective_on: earliest > todayIsoDate() ? earliest : todayIsoDate(),
    pay_basis: employee.employment_type,
    overtime_status: current?.overtime_status || 'needs_review',
    exemption_category: current?.exemption_category || '',
    exemption_reason: current?.exemption_reason || '',
    standard_weekly_hours: Number(current?.standard_weekly_hours || 40),
    daily_schedule: current?.daily_schedule || STANDARD_SCHEDULE,
    timekeeping_mode: current?.timekeeping_mode || 'schedule_with_exceptions',
    source: 'operator_confirmed',
    notes: '',
  };
}

function statusLabel(profile: EmployeeWorkProfile): string {
  if (profile.overtime_status === 'needs_review') return 'Overtime status needs review';
  return profile.overtime_status === 'exempt' ? 'Salary · overtime exempt' : 'Salary · overtime eligible';
}

interface Props {
  employee: Employee;
  canManage: boolean;
  onUpdated: (profile: EmployeeWorkProfile) => void;
}

export function EmployeeWorkProfilePanel({ employee, canManage, onUpdated }: Props) {
  const [open, setOpen] = useState(false);
  const [timeRecordsOpen, setTimeRecordsOpen] = useState(false);
  const [form, setForm] = useState<EmployeeWorkProfileInput>(() => initialInput(employee));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const current = employee.current_work_profile;

  useEffect(() => {
    if (!open) return;
    setForm(initialInput(employee));
    setError(null);
  }, [employee, open]);

  const scheduledTotal = useMemo(
    () => Object.values(form.daily_schedule).reduce((sum, hours) => sum + Number(hours || 0), 0),
    [form.daily_schedule],
  );
  const scheduleMatches = Math.abs(scheduledTotal - Number(form.standard_weekly_hours || 0)) < 0.001;
  const exemptComplete = form.overtime_status !== 'exempt'
    || (Boolean(form.exemption_category) && (form.exemption_reason || '').trim().length >= 10);
  const canSubmit = Boolean(form.effective_on)
    && form.overtime_status !== 'needs_review'
    && Number(form.standard_weekly_hours) > 0
    && (form.timekeeping_mode !== 'schedule_with_exceptions' || scheduleMatches)
    && exemptComplete
    && !saving;

  const submit = async () => {
    if (!canSubmit) return;
    setSaving(true);
    setError(null);
    try {
      const response = await employeesApi.createWorkProfile(employee.id, form);
      onUpdated(response.data);
      setOpen(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to save the new work profile');
    } finally {
      setSaving(false);
    }
  };

  return (
    <>
      <Card className="mb-6 border-primary-100 bg-primary-50/30">
        <CardHeader>
          <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
            <div className="flex gap-3">
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-primary-100 text-primary-800">
                <Clock3 className="h-5 w-5" />
              </div>
              <div>
                <CardTitle>Salary timekeeping & overtime profile</CardTitle>
                <CardDescription>Controls informational salary hours, legal workweek allocation, and overtime treatment without changing prior payroll.</CardDescription>
              </div>
            </div>
            <div className="flex flex-col gap-2 sm:flex-row">
              <Button type="button" variant="outline" onClick={() => setTimeRecordsOpen(true)}><CalendarRange className="mr-2 h-4 w-4" />Review daily time</Button>
              {canManage && <Button type="button" variant="outline" onClick={() => setOpen(true)}><Settings2 className="mr-2 h-4 w-4" />{current ? 'Change profile' : 'Set up profile'}</Button>}
            </div>
          </div>
        </CardHeader>
        <CardContent>
          {current ? (
            <div className="grid gap-3 sm:grid-cols-3">
              <div className="rounded-2xl border border-neutral-200 bg-white p-4">
                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Classification</p>
                <p className="mt-2 text-sm font-semibold text-neutral-900">{statusLabel(current)}</p>
                <p className="mt-1 text-xs text-neutral-600">Effective {current.effective_on}</p>
              </div>
              <div className="rounded-2xl border border-neutral-200 bg-white p-4">
                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Standard time</p>
                <p className="mt-2 text-sm font-semibold text-neutral-900">{Number(current.standard_weekly_hours || 0)} hours / week</p>
                <p className="mt-1 text-xs text-neutral-600">{current.timekeeping_mode.replaceAll('_', ' ')}</p>
              </div>
              <div className="rounded-2xl border border-neutral-200 bg-white p-4">
                <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Confirmation</p>
                <p className="mt-2 flex items-center gap-1.5 text-sm font-semibold text-emerald-800"><CheckCircle2 className="h-4 w-4" />Confirmed</p>
                <p className="mt-1 text-xs text-neutral-600">New changes create a dated record; this one is never overwritten.</p>
              </div>
            </div>
          ) : (
            <div className="flex items-start gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-amber-950">
              <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-amber-700" />
              <div><p className="text-sm font-semibold">Salary work rules are not confirmed</p><p className="mt-1 text-sm leading-6">Payroll dollars keep their existing behavior, but the app will not invent 40 hours or an overtime exemption. A manager must confirm the actual schedule and classification.</p></div>
            </div>
          )}
        </CardContent>
      </Card>

      <Dialog open={open} onOpenChange={(nextOpen) => !saving && setOpen(nextOpen)}>
        <DialogContent className="dialog-top max-h-[calc(100vh-2rem)] max-w-2xl overflow-y-auto rounded-3xl p-0">
          <div className="border-b border-primary-800 bg-primary-950 px-6 py-5 text-white sm:rounded-t-3xl">
            <DialogHeader>
              <div className="mb-3 flex h-10 w-10 items-center justify-center rounded-2xl bg-white/10 ring-1 ring-white/15"><Scale className="h-5 w-5" /></div>
              <DialogTitle className="text-xl text-white">Confirm a new salary work profile</DialogTitle>
              <DialogDescription className="text-neutral-300">The current profile closes the day before this one begins. Existing payroll items, daily records, and reports are not rewritten.</DialogDescription>
            </DialogHeader>
          </div>

          <div className="space-y-5 px-6 py-6">
            {error && <div className="rounded-2xl border border-danger-200 bg-danger-50 p-3 text-sm text-danger-800">{error}</div>}
            <div className="grid gap-4 sm:grid-cols-2">
              <div>
                <label className="mb-1 block text-sm font-medium text-neutral-800">Effective date <span className="text-danger-600">*</span></label>
                <Input type="date" min={current ? nextDate(current.effective_on) : employee.hire_date} value={form.effective_on} onChange={(event) => setForm({ ...form, effective_on: event.target.value })} />
              </div>
              <div>
                <label className="mb-1 block text-sm font-medium text-neutral-800">Overtime status <span className="text-danger-600">*</span></label>
                <Select value={form.overtime_status} onChange={(event) => setForm({ ...form, overtime_status: event.target.value as EmployeeOvertimeStatus })}>
                  <option value="needs_review">Needs legal review</option>
                  <option value="exempt">Exempt from overtime</option>
                  <option value="nonexempt">Eligible for overtime</option>
                </Select>
                {form.overtime_status === 'needs_review' && <p className="mt-1 text-xs text-amber-700">Choose a confirmed status before saving. Salary alone does not establish an overtime exemption.</p>}
              </div>
            </div>

            {form.overtime_status === 'exempt' && (
              <div className="grid gap-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 sm:grid-cols-2">
                <div>
                  <label className="mb-1 block text-sm font-medium text-amber-950">Exemption category <span className="text-danger-600">*</span></label>
                  <Select value={form.exemption_category || ''} onChange={(event) => setForm({ ...form, exemption_category: event.target.value })}>
                    <option value="">Select the confirmed duties test</option>
                    <option value="executive">Executive</option><option value="administrative">Administrative</option><option value="professional">Professional</option>
                    <option value="computer">Computer employee</option><option value="outside_sales">Outside sales</option><option value="highly_compensated">Highly compensated</option><option value="other">Other / reviewed separately</option>
                  </Select>
                </div>
                <div>
                  <label className="mb-1 block text-sm font-medium text-amber-950">Basis for exemption <span className="text-danger-600">*</span></label>
                  <Textarea rows={2} value={form.exemption_reason || ''} onChange={(event) => setForm({ ...form, exemption_reason: event.target.value })} placeholder="Record who confirmed the duties test and the supporting basis." />
                </div>
              </div>
            )}

            <div className="grid gap-4 sm:grid-cols-2">
              <div>
                <label className="mb-1 block text-sm font-medium text-neutral-800">Timekeeping method <span className="text-danger-600">*</span></label>
                <Select value={form.timekeeping_mode} onChange={(event) => setForm({ ...form, timekeeping_mode: event.target.value as EmployeeTimekeepingMode })}>
                  <option value="schedule_with_exceptions">Standard schedule with exceptions</option>
                  <option value="imported">Imported actual time</option>
                  <option value="manual">Manual actual time</option>
                </Select>
              </div>
              <div>
                <label className="mb-1 block text-sm font-medium text-neutral-800">Standard weekly hours <span className="text-danger-600">*</span></label>
                <NumericInput value={Number(form.standard_weekly_hours || 0)} min={0.01} max={168} onValueChange={(value) => setForm({ ...form, standard_weekly_hours: value || 0 })} />
              </div>
            </div>

            {form.timekeeping_mode === 'schedule_with_exceptions' && (
              <div>
                <div className="mb-2 flex items-center justify-between gap-3"><label className="text-sm font-medium text-neutral-800">Normal daily schedule <span className="text-danger-600">*</span></label><span className={`text-xs font-semibold ${scheduleMatches ? 'text-emerald-700' : 'text-danger-700'}`}>{scheduledTotal} / {Number(form.standard_weekly_hours || 0)} hours</span></div>
                <div className="grid grid-cols-4 gap-2 sm:grid-cols-7">
                  {WEEKDAYS.map(([key, label]) => <div key={key}><label className="mb-1 block text-center text-xs font-medium text-neutral-600">{label}</label><NumericInput value={Number(form.daily_schedule[key] || 0)} min={0} max={24} onValueChange={(value) => setForm({ ...form, daily_schedule: { ...form.daily_schedule, [key]: value || 0 } })} className="text-center" /></div>)}
                </div>
                {!scheduleMatches && <p className="mt-2 text-xs text-danger-700">Daily schedule must total the standard weekly hours.</p>}
              </div>
            )}

            <div>
              <label className="mb-1 block text-sm font-medium text-neutral-800">Internal setup note <span className="text-xs font-normal text-neutral-500">(optional)</span></label>
              <Textarea rows={2} value={form.notes || ''} onChange={(event) => setForm({ ...form, notes: event.target.value })} placeholder="Record the employer confirmation source or policy reference." />
            </div>

            <div className="flex items-start gap-3 rounded-2xl border border-neutral-200 bg-neutral-50 p-4 text-sm leading-6 text-neutral-700"><History className="mt-0.5 h-5 w-5 shrink-0" /><p>Hours are allocated by actual pay-period dates and the company’s confirmed legal workweek. Semi-monthly periods can split a workweek without double-counting time.</p></div>
          </div>

          <DialogFooter className="sticky bottom-0 z-10 border-t border-neutral-200 bg-white/95 px-6 py-4 backdrop-blur-md sm:rounded-b-3xl">
            <Button type="button" variant="outline" onClick={() => setOpen(false)} disabled={saving}>Cancel</Button>
            <Button type="button" onClick={submit} disabled={!canSubmit}>{saving ? 'Saving profile...' : 'Confirm new profile'}<CalendarRange className="ml-2 h-4 w-4" /></Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <EmployeeTimeRecordsDialog employee={employee} open={timeRecordsOpen} onOpenChange={setTimeRecordsOpen} />
    </>
  );
}
