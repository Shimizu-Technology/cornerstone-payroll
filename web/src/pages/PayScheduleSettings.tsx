import { useCallback, useEffect, useMemo, useState, type ReactElement } from 'react';
import { AlertTriangle, CalendarClock, CheckCircle2, History, Scale } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select } from '@/components/ui/select';
import { Textarea } from '@/components/ui/textarea';
import { payScheduleSettingsApi, type PayScheduleSettingsResponse } from '@/services/api';

const WEEKDAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

type FormState = {
  effective_on: string;
  frequency: 'weekly' | 'biweekly' | 'semimonthly' | 'monthly';
  period_rule: 'manual' | 'weekly' | 'biweekly' | 'semimonthly';
  period_start_weekday: number;
  period_anchor_date: string;
  pay_date_rule: 'manual' | 'days_after_period_end';
  pay_date_offset_days: number;
  workweek_start_weekday: number;
  workweek_start_time: string;
  notes: string;
};

function minutesToTime(minutes: number) {
  return `${String(Math.floor(minutes / 60)).padStart(2, '0')}:${String(minutes % 60).padStart(2, '0')}`;
}

function nextEffectiveDate(current: string) {
  const today = new Date();
  const localToday = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
  if (!current || current < localToday) return localToday;
  const next = new Date(`${current}T12:00:00`);
  next.setDate(next.getDate() + 1);
  return `${next.getFullYear()}-${String(next.getMonth() + 1).padStart(2, '0')}-${String(next.getDate()).padStart(2, '0')}`;
}

function buildForm(data: PayScheduleSettingsResponse): FormState {
  const { pay_schedule: schedule, workweek } = data.pay_schedule_settings;
  return {
    effective_on: nextEffectiveDate([schedule.effective_on, workweek.effective_on].sort().at(-1) || ''),
    frequency: schedule.frequency,
    period_rule: schedule.period_rule,
    period_start_weekday: schedule.period_start_weekday ?? 0,
    period_anchor_date: schedule.period_anchor_date || '',
    pay_date_rule: schedule.pay_date_rule,
    pay_date_offset_days: schedule.pay_date_offset_days ?? 0,
    workweek_start_weekday: workweek.starts_on_weekday,
    workweek_start_time: minutesToTime(workweek.starts_at_minutes),
    notes: schedule.notes || '',
  };
}

interface PayScheduleSettingsProps {
  embedded?: boolean;
}

export function PayScheduleSettings({ embedded = false }: PayScheduleSettingsProps): ReactElement {
  const [response, setResponse] = useState<PayScheduleSettingsResponse | null>(null);
  const [form, setForm] = useState<FormState | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const data = await payScheduleSettingsApi.get();
      setResponse(data);
      setForm(buildForm(data));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load pay schedule settings');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  const current = response?.pay_schedule_settings;
  const needsConfirmation = current?.pay_schedule.confirmation_status !== 'confirmed' || current?.workweek.confirmation_status !== 'confirmed';
  const sourceLabel = useMemo(() => ({
    operator_confirmed: 'Operator confirmed',
    production_inferred: 'Production inferred',
    legacy_system_default: 'Legacy default',
  }[current?.pay_schedule.source || 'legacy_system_default']), [current?.pay_schedule.source]);

  const reset = () => {
    if (response) setForm(buildForm(response));
    setError(null);
    setSuccess(null);
  };

  const save = async () => {
    if (!form) return;
    if (form.notes.trim().length < 5) {
      setError('Add a short confirmation note identifying who confirmed the schedule or what source was used.');
      return;
    }
    if ((form.period_rule === 'weekly' || form.period_rule === 'biweekly') && Number.isNaN(form.period_start_weekday)) {
      setError('Choose the weekday when the payroll period starts.');
      return;
    }
    if (form.period_rule === 'biweekly' && !form.period_anchor_date) {
      setError('Choose the first day of a known biweekly pay period so alternating weeks stay aligned.');
      return;
    }
    if (form.period_rule === 'biweekly' && new Date(`${form.period_anchor_date}T12:00:00`).getDay() !== form.period_start_weekday) {
      setError(`The biweekly anchor must fall on ${WEEKDAYS[form.period_start_weekday]}.`);
      return;
    }
    try {
      setSaving(true);
      setError(null);
      setSuccess(null);
      const data = await payScheduleSettingsApi.update({
        effective_on: form.effective_on,
        pay_schedule: {
          frequency: form.frequency,
          period_rule: form.period_rule,
          period_start_weekday: form.period_rule === 'weekly' || form.period_rule === 'biweekly' ? form.period_start_weekday : null,
          period_anchor_date: form.period_rule === 'biweekly' ? form.period_anchor_date : null,
          pay_date_rule: form.pay_date_rule,
          pay_date_offset_days: form.pay_date_rule === 'days_after_period_end' ? form.pay_date_offset_days : null,
          timezone: 'Pacific/Guam',
          notes: form.notes,
        },
        workweek: {
          starts_on_weekday: form.workweek_start_weekday,
          starts_at_minutes: 0,
          timezone: 'Pacific/Guam',
          notes: form.notes,
        },
      });
      setResponse(data);
      setForm(buildForm(data));
      setSuccess('The new effective-dated schedule and legal workweek are confirmed. Existing payroll runs were not changed.');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save pay schedule settings');
    } finally {
      setSaving(false);
    }
  };

  if (loading || !form || !current) {
    return <div className="p-8 text-center text-neutral-500">Loading pay schedule settings…</div>;
  }

  return (
    <div>
      {!embedded && <Header title="Pay Schedule & Workweek" description="Define payroll cadence separately from the employer’s legal overtime workweek" />}
      <div className={embedded ? 'space-y-6 pb-28 sm:pb-32' : 'space-y-6 p-4 pb-28 sm:p-6 sm:pb-32 lg:p-8'}>
        {error && <div role="alert" className="rounded-xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-800">{error}</div>}
        {success && <div role="status" className="rounded-xl border border-success-200 bg-success-50 px-4 py-3 text-sm text-success-800">{success}</div>}

        <Card className={needsConfirmation ? 'border-warning-300 bg-warning-50/40' : 'border-success-200 bg-success-50/30'}>
          <CardContent className="flex flex-col gap-4 py-5 sm:flex-row sm:items-center sm:justify-between">
            <div className="flex items-start gap-3">
              {needsConfirmation ? <AlertTriangle className="mt-0.5 h-5 w-5 text-warning-700" /> : <CheckCircle2 className="mt-0.5 h-5 w-5 text-success-700" />}
              <div>
                <p className="font-semibold text-neutral-950">{needsConfirmation ? 'Employer confirmation is still needed' : 'Current configuration is confirmed'}</p>
                <p className="mt-1 text-sm leading-6 text-neutral-600">The current source is shown explicitly so an inferred or legacy rule is never mistaken for an employer-confirmed schedule.</p>
              </div>
            </div>
            <div className="flex flex-wrap gap-2">
              <Badge variant={needsConfirmation ? 'warning' : 'success'}>{needsConfirmation ? 'Needs confirmation' : 'Confirmed'}</Badge>
              <Badge variant="default">{sourceLabel}</Badge>
            </div>
          </CardContent>
        </Card>

        <div className="grid gap-6 xl:grid-cols-2">
          <Card>
            <CardHeader>
              <div className="flex items-center gap-3"><CalendarClock className="h-5 w-5 text-primary-700" /><CardTitle>Payroll cadence</CardTitle></div>
              <CardDescription>Controls how ordinary earning periods are organized. Manual dates remain available for exceptions and clients whose timing is not yet confirmed.</CardDescription>
            </CardHeader>
            <CardContent className="grid gap-5 sm:grid-cols-2">
              <div className="space-y-2"><Label htmlFor="effective-on">Effective date</Label><Input id="effective-on" type="date" value={form.effective_on} onChange={(event) => setForm({ ...form, effective_on: event.target.value })} /></div>
              <div className="space-y-2"><Label htmlFor="frequency">Pay frequency</Label><Select id="frequency" value={form.frequency} onChange={(event) => setForm({ ...form, frequency: event.target.value as FormState['frequency'] })}><option value="weekly">Weekly</option><option value="biweekly">Biweekly</option><option value="semimonthly">Semimonthly</option><option value="monthly">Monthly</option></Select></div>
              <div className="space-y-2"><Label htmlFor="period-rule">Period boundary rule</Label><Select id="period-rule" value={form.period_rule} onChange={(event) => setForm({ ...form, period_rule: event.target.value as FormState['period_rule'] })}><option value="manual">Manual dates</option><option value="weekly">Weekly</option><option value="biweekly">Biweekly</option><option value="semimonthly">1st–15th / 16th–month end</option></Select></div>
              {(form.period_rule === 'weekly' || form.period_rule === 'biweekly') && <div className="space-y-2"><Label htmlFor="period-weekday">Period starts on</Label><Select id="period-weekday" value={form.period_start_weekday} onChange={(event) => setForm({ ...form, period_start_weekday: Number(event.target.value) })}>{WEEKDAYS.map((day, index) => <option key={day} value={index}>{day}</option>)}</Select></div>}
              {form.period_rule === 'biweekly' && <div className="space-y-2 sm:col-span-2"><Label htmlFor="period-anchor">Known period start date</Label><Input id="period-anchor" type="date" required value={form.period_anchor_date} onChange={(event) => setForm({ ...form, period_anchor_date: event.target.value })} /><p className="text-xs leading-5 text-neutral-500">Use the first day of any confirmed two-week pay period. This anchors which alternating week begins each cycle.</p></div>}
              <div className="space-y-2"><Label htmlFor="pay-date-rule">Pay-date rule</Label><Select id="pay-date-rule" value={form.pay_date_rule} onChange={(event) => setForm({ ...form, pay_date_rule: event.target.value as FormState['pay_date_rule'] })}><option value="manual">Manual pay date</option><option value="days_after_period_end">Days after period ends</option></Select></div>
              {form.pay_date_rule === 'days_after_period_end' && <div className="space-y-2"><Label htmlFor="pay-date-offset">Days after period end</Label><Input id="pay-date-offset" type="number" min={0} max={31} value={form.pay_date_offset_days} onChange={(event) => setForm({ ...form, pay_date_offset_days: Number(event.target.value) })} /></div>}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <div className="flex items-center gap-3"><Scale className="h-5 w-5 text-primary-700" /><CardTitle>Legal overtime workweek</CardTitle></div>
              <CardDescription>This fixed seven-day window controls overtime analysis. It is independent from weekly, biweekly, or semimonthly payroll dates.</CardDescription>
            </CardHeader>
            <CardContent className="grid gap-5 sm:grid-cols-2">
              <div className="space-y-2"><Label htmlFor="workweek-day">Workweek starts on</Label><Select id="workweek-day" value={form.workweek_start_weekday} onChange={(event) => setForm({ ...form, workweek_start_weekday: Number(event.target.value) })}>{WEEKDAYS.map((day, index) => <option key={day} value={index}>{day}</option>)}</Select></div>
              <div className="space-y-2">
                <Label htmlFor="workweek-time">Start time (Guam)</Label>
                <Input id="workweek-time" type="time" value={form.workweek_start_time} disabled />
                <p className="text-xs leading-5 text-neutral-500">
                  {form.workweek_start_time === '00:00'
                    ? 'Midnight is required while payroll imports contain work dates rather than clock timestamps.'
                    : `This legacy ${form.workweek_start_time} boundary is not supported by date-only records. Saving establishes a midnight boundary.`}
                </p>
              </div>
              <div className="space-y-2 sm:col-span-2"><Label htmlFor="schedule-notes">Confirmation source / notes</Label><Textarea id="schedule-notes" required value={form.notes} onChange={(event) => setForm({ ...form, notes: event.target.value })} placeholder="Who confirmed this schedule, and what source was used?" /></div>
            </CardContent>
          </Card>
        </div>

        <Card className="border-primary-100 bg-primary-50/30">
          <CardContent className="flex items-start gap-3 py-5"><History className="mt-0.5 h-5 w-5 shrink-0 text-primary-700" /><div><p className="font-semibold text-neutral-950">Saving creates a new effective-dated record</p><p className="mt-1 text-sm leading-6 text-neutral-600">Prior settings and completed payroll remain intact. This confirmation does not recalculate payroll, change historical dates, or add employee hours.</p></div></CardContent>
        </Card>
      </div>

      <div className="fixed inset-x-0 bottom-0 z-30 border-t border-neutral-200 bg-white/95 px-4 py-3 shadow-[0_-16px_40px_-28px_rgba(15,23,42,0.6)] backdrop-blur sm:left-[var(--sidebar-width,0px)] sm:px-6">
        <div className="mx-auto flex max-w-7xl items-center justify-between gap-3"><p className="hidden text-sm text-neutral-500 sm:block">Existing payroll runs will not be recalculated.</p><div className="ml-auto flex gap-2"><Button type="button" variant="outline" onClick={reset} disabled={saving}>Cancel</Button><Button type="button" onClick={() => void save()} disabled={saving}>{saving ? 'Saving…' : 'Confirm & save schedule'}</Button></div></div>
      </div>
    </div>
  );
}
