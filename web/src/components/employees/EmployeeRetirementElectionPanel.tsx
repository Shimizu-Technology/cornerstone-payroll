import { useFeedbackState, ActionFeedback, useFeedback } from '@/components/ui/action-feedback';
import { useEffect, useState, type ReactElement } from 'react';
import { CheckCircle2, Landmark, Pencil, ShieldCheck, X } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { NumericInput } from '@/components/ui/numeric-input';
import { Select } from '@/components/ui/select';
import { employeesApi } from '@/services/api';
import { formatCurrency, formatDate, formatGuamDateTime } from '@/lib/utils';
import { retirementErrorMessage } from '@/lib/retirement-error';
import { useAuth } from '@/contexts/AuthContext';
import type { Employee, EmployeeRetirementElection, EmployeeRetirementElectionInput } from '@/types';

interface Props {
  employee: Employee;
  onSaved: () => Promise<void>;
}

const percent = (value: number | null | undefined): number => Number(value || 0) * 100;
const rate = (value: number | null): number => Number(value || 0) / 100;

function combinedContribution(election: Pick<EmployeeRetirementElectionInput, 'participating' | 'eligible' | 'traditional_contribution_type' | 'traditional_amount' | 'traditional_rate' | 'roth_contribution_type' | 'roth_amount' | 'roth_rate'>): string {
  if (!election.eligible || !election.participating) return '$0.00';
  const fixed = (election.traditional_contribution_type === 'fixed' ? Number(election.traditional_amount || 0) : 0) +
    (election.roth_contribution_type === 'fixed' ? Number(election.roth_amount || 0) : 0);
  const percentage = (election.traditional_contribution_type === 'percentage' ? percent(election.traditional_rate) : 0) +
    (election.roth_contribution_type === 'percentage' ? percent(election.roth_rate) : 0);
  return percentage > 0 ? `${fixed > 0 ? `${formatCurrency(fixed)} + ` : ''}${percentage.toFixed(2)}% of eligible pay` : `${formatCurrency(fixed)} each payroll`;
}

function initialDraft(employee: Employee): EmployeeRetirementElectionInput {
  const current = employee.current_retirement_election || employee.upcoming_retirement_election;
  const traditionalMatch = Number(employee.employer_retirement_match_rate || 0);
  const rothMatch = Number(employee.employer_roth_match_rate || 0);
  return {
    effective_on: '',
    plan_name: current?.plan_name || '401(k)',
    plan_type: current?.plan_type || 'standard_401k',
    limitation_year_type: current?.limitation_year_type || 'calendar',
    roth_available: current?.roth_available ?? false,
    employer_roth_available: current?.employer_roth_available ?? false,
    plan_source_reference: current?.plan_source_reference || '',
    regular_plan_deferral_limit: current?.regular_plan_deferral_limit ?? null,
    related_plan_review_required: current?.related_plan_review_required ?? false,
    eligible: current?.eligible ?? true,
    participating: current?.participating ?? (Number(employee.retirement_rate || 0) + Number(employee.roth_retirement_rate || 0) > 0),
    traditional_contribution_type: current?.traditional_contribution_type || 'percentage',
    traditional_rate: Number(current?.traditional_rate ?? employee.retirement_rate ?? 0),
    traditional_amount: Number(current?.traditional_amount || 0),
    roth_contribution_type: current?.roth_contribution_type || 'percentage',
    roth_rate: Number(current?.roth_rate ?? employee.roth_retirement_rate ?? 0),
    roth_amount: Number(current?.roth_amount || 0),
    eligible_compensation: current?.eligible_compensation || 'gross_wages',
    catch_up_enabled: current?.catch_up_enabled ?? false,
    limit_priority: current?.limit_priority || 'proportional',
    plan_annual_employee_limit: current?.plan_annual_employee_limit ?? null,
    employer_match_mode: current?.employer_match_mode || (
      Number(employee.employer_retirement_match_rate || 0) + Number(employee.employer_roth_match_rate || 0) > 0
        ? 'compensation_percentage'
        : 'none'
    ),
    employer_match_rate: Number(current?.employer_match_rate ?? (traditionalMatch > 0 ? traditionalMatch : rothMatch)),
    employer_match_deferral_cap_rate: current?.employer_match_deferral_cap_rate ?? null,
    employer_match_period_cap: current?.employer_match_period_cap ?? null,
    employer_match_annual_cap: current?.employer_match_annual_cap ?? null,
    employer_match_ytd_before_system: Number(current?.employer_match_ytd_before_system || 0),
    employer_match_destination: current?.employer_match_destination || (traditionalMatch > 0 ? 'traditional' : rothMatch > 0 ? 'roth' : 'traditional'),
    true_up_policy: current?.true_up_policy || 'none',
    reason: '',
  };
}

export function EmployeeRetirementElectionPanel({ employee, onSaved }: Props): ReactElement {
  const { hasCapability } = useAuth();
  const { notify } = useFeedback();
  const canManage = hasCapability('manage_client_configuration');
  const hasDatedElection = Boolean(employee.current_retirement_election || employee.upcoming_retirement_election || employee.retirement_elections?.length);
  const legacySplitMatch = !employee.current_retirement_election && !employee.upcoming_retirement_election && Number(employee.employer_retirement_match_rate || 0) > 0 && Number(employee.employer_roth_match_rate || 0) > 0;
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState<EmployeeRetirementElectionInput>(() => initialDraft(employee));
  const [saving, setSaving] = useState(false);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const current = employee.current_retirement_election;
  const upcoming = employee.upcoming_retirement_election;

  useEffect(() => {
    if (!editing) setDraft(initialDraft(employee));
  }, [editing, employee]);

  const set = <K extends keyof EmployeeRetirementElectionInput>(key: K, value: EmployeeRetirementElectionInput[K]): void => {
    setDraft((existing) => ({ ...existing, [key]: value }));
  };

  const save = async (): Promise<void> => {
    if (legacySplitMatch) {
      setError('This legacy setup has both Traditional and Roth employer match. Have the plan administrator resolve the split before saving a single-destination election.');
      return;
    }
    if (!draft.effective_on) {
      setError('Choose the first pay date that should use this election.');
      return;
    }
    if (hasDatedElection && !draft.reason.trim()) {
      setError('Add a short reason so the change is clear in payroll history.');
      return;
    }
    if (draft.catch_up_enabled && !employee.date_of_birth) {
      setError('Verify the employee’s date of birth in employee details before enabling catch-up.');
      return;
    }
    const rothConfigured = Number(draft.roth_rate) > 0 || Number(draft.roth_amount) > 0;
    if (draft.participating && (draft.catch_up_enabled || rothConfigured || draft.employer_match_destination === 'roth') && !draft.plan_source_reference?.trim()) {
      setError('Add the verified plan document or administrator reference for catch-up and Roth features.');
      return;
    }
    try {
      setSaving(true);
      setError(null);
      setNotice(null);
      await employeesApi.createRetirementElection(employee.id, draft);
      setEditing(false);
      setNotice('Contribution change saved. Payroll uses it from the selected pay date. Recalculate affected draft payroll.');
      notify({ tone: 'success', message: 'Contribution change saved. Payroll uses it from the selected pay date. Recalculate affected draft payroll.' });
      try {
        await onSaved();
      } catch {
        setNotice('Contribution change saved. The employee record could not refresh. Reload to see the saved change before recording another.');
      }
    } catch (caught) {
      setError(retirementErrorMessage(caught, 'Could not save the retirement election.'));
    } finally {
      setSaving(false);
    }
  };

  return <Card id="retirement-plan" tabIndex={-1} className="scroll-mt-24 overflow-hidden">
    <CardHeader className="flex-col items-start justify-between gap-4 border-b border-neutral-100 bg-neutral-50/70 sm:flex-row">
      <div>
        <CardTitle className="flex items-center gap-2"><Landmark className="h-5 w-5 text-primary-700" />1 · Retirement contributions</CardTitle>
        <p className="mt-2 text-sm leading-6 text-neutral-600">Set what the employee contributes each payroll, then complete the yearly checks below. Each paycheck keeps the contribution settings and limits it used.</p>
      </div>
      {!editing && canManage && <Button variant="outline" onClick={() => { setEditing(true); setNotice(null); }}><Pencil className="mr-2 h-4 w-4" />{hasDatedElection ? 'Record contribution change' : 'Set up retirement'}</Button>}
    </CardHeader>
    <CardContent className="space-y-5 p-5 sm:p-6">
      {notice && <ActionFeedback tone={notice.includes("could not refresh") ? "warning" : "success"} message={notice} />}
      {error && <ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error} />}
      {legacySplitMatch && <p role="alert" className="rounded-xl border border-warning-200 bg-warning-50 px-4 py-3 text-sm leading-6 text-warning-900">Both Traditional and Roth employer match are configured in the legacy setup. Administrator review is required: this election supports one employer contribution destination and cannot preserve the split. Saving is blocked until the legacy setup is resolved.</p>}
      {upcoming && <p className="rounded-xl border border-warning-200 bg-warning-50 px-4 py-3 text-sm text-warning-900"><strong>Scheduled:</strong> {upcoming.plan_name} becomes effective {formatDate(upcoming.effective_on)}.</p>}

      {!editing ? <ElectionSummary election={current} upcoming={upcoming} employee={employee} /> : <fieldset disabled={saving} className="space-y-6">
        <section>
          <p className="text-xs font-bold uppercase tracking-[0.14em] text-primary-700">Participation and start date</p>
          <div className="mt-4 grid gap-4 sm:grid-cols-2">
            <Field label="Plan name"><Input value={draft.plan_name} onChange={(event) => set('plan_name', event.target.value)} placeholder="401(k)" /></Field>
            <Field label="First pay date using this election"><Input type="date" value={draft.effective_on} onChange={(event) => set('effective_on', event.target.value)} /></Field>
          </div>
          <div className="mt-4 grid gap-3 sm:grid-cols-2">
            <Toggle checked={draft.eligible} onChange={(checked) => { set('eligible', checked); if (!checked) set('participating', false); }} title="Eligible for the plan" helper="Turn off when the employee has not met the plan's eligibility rules." />
            <Toggle checked={draft.participating} disabled={!draft.eligible} onChange={(checked) => set('participating', checked)} title="Employee is participating" helper="When off, retirement deductions and employer match are $0." />
          </div>
          <details className="mt-4 rounded-xl border border-neutral-200 p-4" open={draft.catch_up_enabled || Number(draft.roth_rate) > 0 || Number(draft.roth_amount) > 0}>
            <summary className="cursor-pointer text-sm font-semibold text-neutral-800">Plan permissions and administrator review</summary>
            <p className="mt-3 text-sm leading-6 text-neutral-600">Automatic calculations support a standard 401(k) with a calendar limitation year. Other plan types, short years, related-employer plans, and administrator-directed ADP corrections need a separate review.</p>
            <div className="mt-4 grid gap-4 sm:grid-cols-2">
              <Field label="Plan document or administrator reference"><Input value={draft.plan_source_reference || ''} onChange={(event) => set('plan_source_reference', event.target.value)} placeholder="Verified plan document reference" /></Field>
              <Field label="Year used for annual plan limits"><Select value={draft.limitation_year_type || 'calendar'} onChange={(event) => set('limitation_year_type', event.target.value as EmployeeRetirementElectionInput['limitation_year_type'])}><option value="calendar">Calendar year (January–December)</option><option value="non_calendar">Non-calendar year — administrator review</option><option value="short">Short year — administrator review</option></Select></Field>
              <Toggle checked={draft.roth_available ?? false} onChange={(checked) => set('roth_available', checked)} title="Plan permits employee Roth deferrals" helper="Verify designated Roth availability with the plan administrator." />
              <Toggle checked={draft.related_plan_review_required ?? false} onChange={(checked) => set('related_plan_review_required', checked)} title="Related-employer or special plan review needed" helper="Payroll blocks automatic retirement calculations until this is resolved." />
            </div>
          </details>
        </section>

        <section className="border-t border-neutral-200 pt-6">
          <p className="text-xs font-bold uppercase tracking-[0.14em] text-primary-700">Employee contributions</p>
          <p className="mt-3 text-sm leading-6 text-neutral-600">Traditional contributions reduce wages used for income-tax withholding. Roth contributions do not. Both remain subject to Social Security and Medicare.</p>
          <div className="mt-4 grid gap-4 lg:grid-cols-2">
            <ContributionField label="Traditional 401(k)" type={draft.traditional_contribution_type} value={draft.traditional_contribution_type === 'fixed' ? draft.traditional_amount : percent(draft.traditional_rate)} onType={(value) => set('traditional_contribution_type', value)} onValue={(value) => draft.traditional_contribution_type === 'fixed' ? set('traditional_amount', value || 0) : set('traditional_rate', rate(value))} />
            <ContributionField label="Roth 401(k)" type={draft.roth_contribution_type} value={draft.roth_contribution_type === 'fixed' ? draft.roth_amount : percent(draft.roth_rate)} onType={(value) => set('roth_contribution_type', value)} onValue={(value) => draft.roth_contribution_type === 'fixed' ? set('roth_amount', value || 0) : set('roth_rate', rate(value))} />
          </div>
          <div className="mt-4 grid gap-4 sm:grid-cols-2">
            <Field label="Pay included in contribution calculations"><Select value={draft.eligible_compensation} onChange={(event) => {
              const value = event.target.value as EmployeeRetirementElectionInput['eligible_compensation'];
              set('eligible_compensation', value);
              if (value !== 'gross_wages') set('true_up_policy', 'none');
            }}><option value="gross_wages">All gross wages</option><option value="gross_excluding_tips">Gross wages, excluding tips</option><option value="base_pay">Base pay only</option></Select></Field>
            <Field label="How to divide the remaining annual allowance"><Select value={draft.limit_priority} onChange={(event) => set('limit_priority', event.target.value as EmployeeRetirementElectionInput['limit_priority'])}><option value="proportional">Reduce Traditional and Roth proportionally</option><option value="traditional_first">Fund Traditional first</option><option value="roth_first">Fund Roth first</option></Select></Field>
          </div>
          <div className="mt-4">
            <Toggle checked={draft.catch_up_enabled} onChange={(checked) => set('catch_up_enabled', checked)} title="Plan permits age-based catch-up" helper={employee.date_of_birth ? 'Available from age 50, based on age reached by December 31. Verify prior-year employer wages in the yearly checks below.' : 'Verify date of birth in employee details before saving catch-up.'} />
          </div>
          <div className="mt-4 rounded-xl bg-neutral-50 p-4 text-sm leading-6 text-neutral-700"><p><strong>Planned employee contribution: {combinedContribution(draft)}</strong></p><p>Annual limits and available pay may reduce this amount. Catch-up raises the annual limit; it does not add another deduction to the amounts entered above.</p><a className="font-semibold text-primary-700 underline underline-offset-2" href="#retirement-year-evidence">Review yearly retirement checks</a></div>
          <details className="mt-4 rounded-xl border border-neutral-200 p-4"><summary className="cursor-pointer text-sm font-semibold text-neutral-800">Additional plan limits</summary><div className="mt-4 grid gap-4 sm:grid-cols-2"><Field label="Plan's total annual employee limit (optional)" helper="Includes catch-up. Leave blank to use the IRS ceiling; zero permits no employee contributions."><NumericInput value={draft.plan_annual_employee_limit ?? null} onValueChange={(value) => set('plan_annual_employee_limit', value)} min={0} emptyValue={null} fixedDecimalsOnBlur={2} /></Field><Field label="Regular plan deferral limit before catch-up (optional)" helper="Use only a verified annual dollar limit. A percentage limit or ADP correction requires administrator review."><NumericInput value={draft.regular_plan_deferral_limit ?? null} onValueChange={(value) => set('regular_plan_deferral_limit', value)} min={0} emptyValue={null} fixedDecimalsOnBlur={2} /></Field></div></details>
        </section>

        <section className="border-t border-neutral-200 pt-6">
          <p className="text-xs font-bold uppercase tracking-[0.14em] text-primary-700">Employer contribution</p>
          <div className="mt-4 grid gap-4 sm:grid-cols-2">
            <Field label="Match formula"><Select value={draft.employer_match_mode} onChange={(event) => {
              const value = event.target.value as EmployeeRetirementElectionInput['employer_match_mode'];
              set('employer_match_mode', value);
              if (draft.eligible_compensation !== 'gross_wages') set('true_up_policy', 'none');
            }}><option value="none">No employer match</option><option value="employee_deferral_percentage">Percent of employee contribution</option><option value="compensation_percentage">Percent of eligible pay</option></Select></Field>
            {draft.employer_match_mode !== 'none' && <Field label="Employer match percentage"><NumericInput value={percent(draft.employer_match_rate)} onValueChange={(value) => set('employer_match_rate', rate(value))} min={0} max={100} fixedDecimalsOnBlur={2} /></Field>}
            {draft.employer_match_mode === 'employee_deferral_percentage' && <Field label="Match employee contributions up to (% of pay)" helper="Example: 4% means only the first 4% of eligible pay is matchable. Blank means no extra cap; zero permits no match."><NumericInput value={draft.employer_match_deferral_cap_rate == null ? null : percent(draft.employer_match_deferral_cap_rate)} onValueChange={(value) => set('employer_match_deferral_cap_rate', value == null ? null : rate(value))} min={0} max={100} emptyValue={null} fixedDecimalsOnBlur={2} /></Field>}
            {draft.employer_match_mode !== 'none' && <Field label="Employer contribution destination"><Select value={draft.employer_match_destination} onChange={(event) => set('employer_match_destination', event.target.value as EmployeeRetirementElectionInput['employer_match_destination'])}><option value="traditional">Traditional</option><option value="roth">Roth</option></Select></Field>}
          </div>
          {draft.employer_match_mode !== 'none' && draft.employer_match_destination === 'roth' && <div className="mt-4"><Toggle checked={draft.employer_roth_available ?? false} onChange={(checked) => set('employer_roth_available', checked)} title="Administrator confirmed employer Roth support" helper="Requires the plan’s vested-contribution rules and a provider handoff for allocation dates and Form 1099-R reporting." /></div>}
          {draft.employer_match_mode !== 'none' && <details className="mt-4 rounded-2xl border border-neutral-200 bg-neutral-50 p-4">
            <summary className="cursor-pointer text-sm font-semibold text-neutral-800">Employer caps and prior payroll balances</summary>
            <div className="mt-4 grid gap-4 sm:grid-cols-2">
              <Field label="Per-payroll match cap" helper="Blank means no extra cap; zero permits no match."><NumericInput value={draft.employer_match_period_cap ?? null} onValueChange={(value) => set('employer_match_period_cap', value)} min={0} emptyValue={null} fixedDecimalsOnBlur={2} /></Field>
              <Field label="Annual employer match cap" helper="Blank means no extra cap; zero permits no match."><NumericInput value={draft.employer_match_annual_cap ?? null} onValueChange={(value) => set('employer_match_annual_cap', value)} min={0} emptyValue={null} fixedDecimalsOnBlur={2} /></Field>
              <Field label="Employer match already paid before cutover" helper="Enter once when QuickBooks already paid employer match this year."><NumericInput value={draft.employer_match_ytd_before_system} onValueChange={(value) => set('employer_match_ytd_before_system', value || 0)} min={0} fixedDecimalsOnBlur={2} /></Field>
              <Field label="Reconcile employer match year to date" helper={draft.eligible_compensation !== 'gross_wages' ? 'YTD true-up requires all gross wages to be eligible; restricted compensation needs administrator reconciliation.' : undefined}><Select value={draft.true_up_policy} onChange={(event) => set('true_up_policy', event.target.value as EmployeeRetirementElectionInput['true_up_policy'])}><option value="none">No true-up</option><option value="year_to_date" disabled={draft.eligible_compensation !== 'gross_wages'}>Reconcile year to date each payroll</option></Select></Field>
            </div>
          </details>}
        </section>

        <section className="border-t border-neutral-200 pt-6">
          <Field label={hasDatedElection ? 'Reason for this change' : 'Setup note'} helper="Saved permanently with this election."><Input value={draft.reason} onChange={(event) => set('reason', event.target.value)} placeholder={hasDatedElection ? 'Example: New signed election received' : 'Example: Verified against signed plan election'} /></Field>
          <div className="mt-5 flex flex-wrap justify-end gap-3">
            <Button variant="outline" onClick={() => { setEditing(false); setError(null); }}><X className="mr-2 h-4 w-4" />Cancel</Button>
            <Button disabled={saving || legacySplitMatch} onClick={() => void save()}>{saving ? 'Saving…' : 'Save contribution change'}</Button>
          </div>
        </section>
      </fieldset>}

      {(employee.retirement_elections || []).length > 0 && !editing && <details className="border-t border-neutral-200 pt-5">
        <summary className="cursor-pointer text-sm font-semibold text-neutral-800">Election history ({employee.retirement_elections?.length})</summary>
        <div className="mt-4 space-y-3">{employee.retirement_elections?.map((election) => <HistoryRow key={election.id} election={election} currentId={current?.id} upcomingId={upcoming?.id} />)}</div>
      </details>}
    </CardContent>
  </Card>;
}

function ElectionSummary({ election, upcoming, employee }: { election?: EmployeeRetirementElection | null; upcoming?: EmployeeRetirementElection | null; employee: Employee }): ReactElement {
  if (!election && upcoming) return <div className="rounded-2xl border border-primary-100 bg-primary-50/60 p-4 text-sm leading-6 text-neutral-700">Until {formatDate(upcoming.effective_on)}, payroll keeps the legacy setup ({percent(employee.retirement_rate).toFixed(2)}% Traditional and {percent(employee.roth_retirement_rate).toFixed(2)}% Roth). The scheduled <strong>{upcoming.plan_name}</strong> election takes over automatically on that pay date.</div>;
  if (!election) return Number(employee.retirement_rate || 0) + Number(employee.roth_retirement_rate || 0) > 0
    ? <div className="rounded-2xl border border-warning-200 bg-warning-50 p-4 text-sm leading-6 text-warning-900">This employee still uses the basic legacy percentages ({percent(employee.retirement_rate).toFixed(2)}% Traditional and {percent(employee.roth_retirement_rate).toFixed(2)}% Roth). Record a dated election before the next payroll so limits and plan rules are explicit.</div>
    : <p className="text-sm leading-6 text-neutral-600">No employee retirement contributions are configured. Set up an election when the employee joins the plan.</p>;
  const contribution = (type: EmployeeRetirementElection['traditional_contribution_type'], amount: number, electionRate: number): string => type === 'fixed' ? `${formatCurrency(Number(amount))} each payroll` : `${percent(electionRate).toFixed(2)}% of eligible pay`;
  return <div className="grid gap-4 lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]">
    <div className="rounded-2xl border border-primary-100 bg-primary-50/60 p-5">
      <div className="flex flex-wrap items-center gap-2"><Badge variant={election.participating ? 'success' : 'default'}>{election.participating ? 'Participating' : 'Not participating'}</Badge>{election.catch_up_enabled && <Badge variant="default">Plan allows catch-up</Badge>}</div>
      <p className="mt-3 font-display text-xl font-extrabold text-neutral-950">{election.plan_name}</p>
      <p className="mt-2 text-sm text-neutral-600">Effective {formatDate(election.effective_on)} · {election.eligible_compensation.replaceAll('_', ' ')}</p>
      <p className="mt-4 flex items-start gap-2 text-sm leading-6 text-neutral-700"><ShieldCheck className="mt-0.5 h-4 w-4 shrink-0 text-success-700" />Payroll checks annual IRS and plan limits against recorded year-to-date contributions. Required yearly checks must be complete before those contributions can be calculated.</p>
    </div>
    <dl className="grid gap-3 sm:grid-cols-2">
      <SummaryItem label="Planned employee contribution" value={combinedContribution(election)} />
      <SummaryItem label="Traditional" value={contribution(election.traditional_contribution_type, election.traditional_amount, election.traditional_rate)} />
      <SummaryItem label="Roth" value={contribution(election.roth_contribution_type, election.roth_amount, election.roth_rate)} />
      <SummaryItem label="Employer match" value={election.employer_match_mode === 'none' ? 'None' : election.employer_match_mode === 'employee_deferral_percentage' ? `${percent(election.employer_match_rate).toFixed(2)}% of employee contribution` : `${percent(election.employer_match_rate).toFixed(2)}% of eligible pay`} />
      <SummaryItem label="Remaining allowance priority" value={election.limit_priority.replaceAll('_', ' ')} />
    </dl>
  </div>;
}

function ContributionField({ label, type, value, onType, onValue }: { label: string; type: 'percentage' | 'fixed'; value: number; onType: (value: 'percentage' | 'fixed') => void; onValue: (value: number | null) => void }): ReactElement {
  return <div className="rounded-2xl border border-neutral-200 p-4"><p className="text-sm font-semibold text-neutral-900">{label}</p><div className="mt-3 grid grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)] gap-3"><Select aria-label={`${label} type`} value={type} onChange={(event) => onType(event.target.value as 'percentage' | 'fixed')}><option value="percentage">Percent</option><option value="fixed">Fixed amount</option></Select><NumericInput aria-label={`${label} value`} value={value} onValueChange={onValue} min={0} max={type === 'percentage' ? 100 : undefined} fixedDecimalsOnBlur={2} /></div><p className="mt-2 text-xs text-neutral-500">{type === 'percentage' ? 'Percentage of eligible pay' : 'Amount deducted each payroll'}</p></div>;
}

function Toggle({ checked, disabled, onChange, title, helper }: { checked: boolean; disabled?: boolean; onChange: (value: boolean) => void; title: string; helper: string }): ReactElement {
  return <label className={`flex min-h-24 gap-3 rounded-2xl border p-4 ${checked ? 'border-primary-200 bg-primary-50/50' : 'border-neutral-200 bg-white'} ${disabled ? 'opacity-50' : 'cursor-pointer'}`}><input className="mt-1 h-4 w-4 accent-primary-700" type="checkbox" checked={checked} disabled={disabled} onChange={(event) => onChange(event.target.checked)} /><span><span className="block text-sm font-semibold text-neutral-900">{title}</span><span className="mt-1 block text-xs leading-5 text-neutral-500">{helper}</span></span></label>;
}

function Field({ label, helper, children }: { label: string; helper?: string; children: ReactElement }): ReactElement {
  return <label className="block"><span className="block text-sm font-medium text-neutral-700">{label}</span>{helper && <span className="mt-1 block text-xs leading-5 text-neutral-500">{helper}</span>}<span className="mt-2 block">{children}</span></label>;
}

function SummaryItem({ label, value }: { label: string; value: string }): ReactElement {
  return <div className="rounded-xl border border-neutral-200 px-4 py-3"><dt className="text-xs font-bold uppercase tracking-[0.12em] text-neutral-400">{label}</dt><dd className="mt-2 text-sm font-semibold capitalize text-neutral-800">{value}</dd></div>;
}

function HistoryRow({ election, currentId, upcomingId }: { election: EmployeeRetirementElection; currentId?: number; upcomingId?: number }): ReactElement {
  const status = election.id === currentId
    ? <Badge variant="success"><CheckCircle2 className="mr-1 h-3 w-3" />Current</Badge>
    : election.id === upcomingId ? <Badge variant="default">Scheduled</Badge> : <Badge variant="default">History</Badge>;
  return <div className="flex flex-wrap items-start justify-between gap-3 rounded-xl border border-neutral-200 px-4 py-3"><div><p className="text-sm font-semibold text-neutral-900">{election.plan_name} · effective {formatDate(election.effective_on)}</p><p className="mt-1 text-sm text-neutral-600">{election.reason}</p><p className="mt-1 text-xs text-neutral-500">Recorded {formatGuamDateTime(election.created_at)}{election.created_by_name ? ` by ${election.created_by_name}` : ''}</p></div>{status}</div>;
}
