// My job (read only): the employee's employer, job title, department, pay
// and pay setup as of today, from GET /employee/job. Rows with nothing set
// are left out, and a former job shows nothing. Pay follows the Show
// amounts setting like every other amount.
import type { ReactElement, ReactNode } from 'react';
import { Link } from 'react-router';
import type { EmployeeJob, JobPay, PayFrequency } from './contracts';
import { useBrand, useReadySession } from './contexts';
import { focusHeadingOnNextScreen } from './focus';
import { formatMoney, longDate, weekdayDate } from './format';
import { Amount, HideAmountsToggle } from './HideAmounts';
import { Card, LoadProblem, SkeletonRows } from './ui';
import { useEmployeeData, type DataState } from './useEmployeeData';

const FREQUENCIES: Record<PayFrequency, string> = {
  weekly: 'Every week',
  biweekly: 'Every two weeks',
  semimonthly: 'Twice a month',
  monthly: 'Once a month',
};

/** The open link's job, shared by Home and My info. Never loaded for a former job. */
function useJob(): { state: DataState<EmployeeJob | null>; reload: () => void } {
  const { isFormer } = useReadySession();
  return useEmployeeData<EmployeeJob | null>(isFormer ? null : 'job', (api, linkId, signal) => api.job(linkId, signal));
}

function Money({ value }: { value: string }): ReactElement {
  return <Amount>{formatMoney(value)}</Amount>;
}

function hasAmounts(pay: JobPay | null): boolean {
  if (!pay) return false;
  return pay.type === 'hourly' || pay.perPeriod !== null;
}

function PayValue({ pay }: { pay: JobPay }): ReactElement {
  if (pay.type === 'hourly') {
    if (pay.rates.length === 1) return <><Money value={pay.rates[0].rate} /> an hour</>;
    return (
      <ul className="emp-job-rates">
        {pay.rates.map((rate, index) => (
          <li key={`${index}-${rate.label ?? ''}`}>
            <span className="min-w-0 break-words font-normal">{rate.label ?? 'Hourly'}</span>
            <span className="shrink-0"><Money value={rate.rate} /> an hour</span>
          </li>
        ))}
      </ul>
    );
  }
  if (pay.perPeriod === null) return <>Set each pay period</>;
  if (pay.type === 'flat_fee') return <><Money value={pay.perPeriod} /> each payday</>;
  return (
    <span className="flex flex-col">
      <span><Money value={pay.perPeriod} /> each payday</span>
      {pay.annual && <span className="font-normal text-neutral-700"><Money value={pay.annual} /> a year</span>}
    </span>
  );
}

function Row({ label, children }: { label: string; children: ReactNode }): ReactElement {
  return (
    <div>
      <dt className="emp-label-quiet">{label}</dt>
      <dd className="emp-detail-value">{children}</dd>
    </div>
  );
}

function JobDetails({ job }: { job: EmployeeJob }): ReactElement {
  const brand = useBrand();
  const { state } = useReadySession();
  const employer = job.employerName ?? (brand.isFallback ? null : brand.name);
  const nextPayday = state.info.nextPayday;
  const pay = job.pay;
  return (
    <Card title="My job" action={hasAmounts(pay) ? <HideAmountsToggle /> : undefined}>
      <dl className="emp-job">
        {employer && <Row label="Employer">{employer}</Row>}
        {job.role && <Row label="Job title">{job.role}</Row>}
        {job.department && <Row label="Department">{job.department}</Row>}
        {pay && <Row label={pay.type === 'hourly' && pay.rates.length > 1 ? 'Pay rates' : 'Pay'}><PayValue pay={pay} /></Row>}
        {job.payFrequency && <Row label="Paid">{FREQUENCIES[job.payFrequency]}</Row>}
        {nextPayday && <Row label="Next payday">{weekdayDate(nextPayday)}</Row>}
        {job.paymentMethod && <Row label="How you're paid">{job.paymentMethod === 'direct_deposit' ? 'Direct deposit' : 'Paper check'}</Row>}
        <Row label="Employment type">{job.workerType === '1099' ? 'Contractor (1099)' : 'Employee (W-2)'}</Row>
        {job.startDate && <Row label="Start date">{longDate(job.startDate)}</Row>}
        {job.employeeId && <Row label="Employee ID">{job.employeeId}</Row>}
      </dl>
      <p className="emp-hint mt-4">
        Something wrong?{' '}
        <Link to="/help" className="emp-link-inline" onClick={focusHeadingOnNextScreen}>
          Contact {job.contactName ?? employer ?? 'your employer'}
        </Link>
      </p>
    </Card>
  );
}

/** The first card on My info. Nothing for a former job. */
export function MyJobCard(): ReactElement | null {
  const { isFormer } = useReadySession();
  const { state, reload } = useJob();
  if (isFormer) return null;
  if (state.status === 'loading') return <Card title="My job"><SkeletonRows rows={4} label="Loading your job" /></Card>;
  if (state.status === 'error') return <Card title="My job"><LoadProblem kind={state.kind} onRetry={reload} what="your job" /></Card>;
  return state.data ? <JobDetails job={state.data} /> : null;
}

/** "Server · Front of House" under the Home greeting, once it's loaded. Nothing when neither is set. */
export function JobLine(): ReactElement | null {
  const { state } = useJob();
  if (state.status !== 'ready' || !state.data) return null;
  const parts = [state.data.role, state.data.department].filter(Boolean);
  if (parts.length === 0) return null;
  return <p className="emp-job-line">{parts.join(' · ')}</p>;
}
