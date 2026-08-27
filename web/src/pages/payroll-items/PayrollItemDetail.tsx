import { useCallback, useEffect, useState, type ReactElement } from 'react';
import {
  ArrowLeft,
  ArrowRight,
  Banknote,
  CalendarDays,
  CheckCircle2,
  Clock3,
  FileInput,
  Printer,
  ReceiptText,
  RefreshCw,
  ShieldCheck,
  UserRound,
} from 'lucide-react';
import { Link, useLocation, useParams, useSearchParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { WorkspaceLoader } from '@/components/records/WorkspaceLoader';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { formatCurrency, formatDate, formatDateRange, formatGuamDateTime } from '@/lib/utils';
import {
  currentAppPath,
  employeePath,
  payrollItemPath,
  payRunPath,
  safeInternalReturnPath,
} from '@/lib/routes';
import { employeesApi, payrollItemsApi, payPeriodsApi } from '@/services/api';
import type { Employee, PayPeriod, PayrollItem } from '@/types';

export function PayrollItemDetail(): ReactElement {
  const { companyId: companyIdParam, id: payRunIdParam, payrollItemId: payrollItemIdParam } = useParams<{
    companyId: string;
    id: string;
    payrollItemId: string;
  }>();
  const companyId = Number(companyIdParam);
  const payRunId = Number(payRunIdParam);
  const payrollItemId = Number(payrollItemIdParam);
  const location = useLocation();
  const [searchParams] = useSearchParams();
  const [payRun, setPayRun] = useState<PayPeriod | null>(null);
  const [payrollItem, setPayrollItem] = useState<PayrollItem | null>(null);
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fallback = payRunPath(companyId, payRunId, 'overview');
  const returnTo = safeInternalReturnPath(searchParams.get('return_to'), fallback);
  const currentPath = currentAppPath(location.pathname, location.search);

  const load = useCallback(async () => {
    if (![payRunId, payrollItemId].every((value) => Number.isInteger(value) && value > 0)) {
      setError('This payroll-item link is invalid.');
      setLoading(false);
      return;
    }

    setLoading(true);
    setError(null);
    try {
      const [payRunResponse, payrollItemResponse] = await Promise.all([
        payPeriodsApi.get(payRunId),
        payrollItemsApi.get(payRunId, payrollItemId),
      ]);
      const summaryItem = payRunResponse.pay_period.payroll_items?.find((item) => item.id === payrollItemId);
      const mergedItem: PayrollItem = { ...summaryItem, ...payrollItemResponse.payroll_item };
      if (!Number.isInteger(mergedItem.employee_id) || mergedItem.employee_id < 1) {
        throw new Error('This payroll item is not linked to an employee record.');
      }
      const employeeResponse = await employeesApi.get(mergedItem.employee_id);
      setPayRun(payRunResponse.pay_period);
      setPayrollItem(mergedItem);
      setEmployee(employeeResponse.data);
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : 'Could not load this payroll item.');
    } finally {
      setLoading(false);
    }
  }, [payRunId, payrollItemId]);

  useEffect(() => {
    void load();
  }, [load]);

  if (loading) {
    return <WorkspaceLoader label="Loading payroll item" />;
  }

  if (!payRun || !payrollItem || !employee || error) {
    return (
      <div className="p-4 sm:p-6 lg:p-8">
        <Card className="mx-auto max-w-2xl border-danger-200 bg-danger-50">
          <CardContent className="p-6">
            <p className="text-xs font-bold uppercase tracking-[0.14em] text-danger-700">Payroll item unavailable</p>
            <h1 className="mt-2 font-display text-2xl font-extrabold tracking-tight text-neutral-950">This payroll item could not be opened</h1>
            <p className="mt-2 text-sm leading-6 text-neutral-700">{error || 'The record may no longer exist, or the link may belong to another client or pay run.'}</p>
            <div className="mt-5 flex flex-wrap gap-3"><Button onClick={() => void load()}><RefreshCw className="mr-2 h-4 w-4" />Try again</Button><Link className="inline-flex min-h-11 items-center gap-2 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-700" to={returnTo}><ArrowLeft className="h-4 w-4" />Back</Link></div>
          </CardContent>
        </Card>
      </div>
    );
  }

  const employeeName = `${employee.first_name} ${employee.last_name}`;
  const taxes = Number(payrollItem.withholding_tax || 0) + Number(payrollItem.social_security_tax || 0) + Number(payrollItem.medicare_tax || 0) + Number(payrollItem.additional_medicare_tax || 0);
  const inputSource = payrollItem.import_source || payrollItem.timekeeping_source || 'manual';

  return (
    <div>
      <Header
        title={`${employeeName} · ${formatDate(payRun.pay_date)}`}
        description={`${formatDateRange(payRun.start_date, payRun.end_date)} · Payroll item #${payrollItem.id}`}
        actions={<div className="flex w-full flex-wrap gap-2 sm:w-auto sm:justify-end"><Link className="inline-flex min-h-11 items-center gap-2 rounded-full border border-neutral-300 bg-white px-4 text-sm font-semibold text-neutral-700 transition hover:border-primary-300 hover:text-primary-800" to={returnTo}><ArrowLeft className="h-4 w-4" />Back</Link><Link className="inline-flex min-h-11 items-center gap-2 rounded-full bg-primary-700 px-4 text-sm font-semibold text-white transition hover:bg-primary-800" to={employeePath(companyId, employee.id, 'pay-history', { returnTo: currentPath })}><UserRound className="h-4 w-4" />Employee workspace</Link></div>}
      />

      <section className="border-b border-neutral-200 bg-neutral-50/70 px-4 py-3 sm:px-6 lg:px-8" aria-label="Payroll item identity">
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant={payrollItem.voided ? 'danger' : payRun.status === 'committed' ? 'success' : 'default'}>{payrollItem.voided ? 'Voided' : payRun.status === 'committed' ? 'Finalized' : 'In progress'}</Badge>
          <Badge variant="default">{payrollItem.employment_type}</Badge>
          {payrollItem.check_number && <Badge variant={payrollItem.check_printed_at ? 'success' : 'info'}>Check #{payrollItem.check_number}</Badge>}
        </div>
      </section>

      <main className="space-y-6 p-4 sm:p-6 lg:p-8">
        <nav aria-label="Payroll item relationships" className="grid gap-3 sm:grid-cols-2">
          <RelationshipLink icon={UserRound} eyebrow="Employee" title={employeeName} detail="Open pay setup, history, and activity" href={employeePath(companyId, employee.id, 'overview', { returnTo: currentPath })} />
          <RelationshipLink icon={CalendarDays} eyebrow="Source pay run" title={formatDateRange(payRun.start_date, payRun.end_date)} detail={`Pay date ${formatDate(payRun.pay_date)} · ${payRun.status}`} href={payRunPath(companyId, payRun.id, 'overview', { returnTo: currentPath })} />
        </nav>

        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <Metric icon={Banknote} label="Gross pay" value={formatCurrency(Number(payrollItem.gross_pay || 0))} detail={`${Number(payrollItem.total_hours || 0).toFixed(2)} total hours`} />
          <Metric icon={ShieldCheck} label="Employee taxes" value={formatCurrency(taxes)} detail="FIT, Social Security, and Medicare" />
          <Metric icon={ReceiptText} label="Other deductions" value={formatCurrency(Math.max(0, Number(payrollItem.total_deductions || 0) - taxes))} detail="Retirement, loans, insurance, and fields" />
          <Metric icon={CheckCircle2} label="Net pay" value={formatCurrency(Number(payrollItem.net_pay || 0))} detail={payrollItem.check_number ? `Check #${payrollItem.check_number}` : 'Check not assigned'} />
        </div>

        <div className="grid gap-6 lg:grid-cols-2">
          <Card>
            <CardHeader><CardTitle>Input and calculation context</CardTitle><p className="mt-1 text-sm text-neutral-500">The source signals behind this exact payroll result.</p></CardHeader>
            <CardContent className="grid gap-5 sm:grid-cols-2">
              <ContextRow icon={FileInput} label="Input source" value={inputSource.replaceAll('_', ' ')} />
              <ContextRow icon={Clock3} label="Regular hours" value={Number(payrollItem.hours_worked || 0).toFixed(2)} />
              <ContextRow icon={Clock3} label="Overtime hours" value={Number(payrollItem.overtime_hours || 0).toFixed(2)} />
              <ContextRow icon={Banknote} label="Applied pay rate" value={formatCurrency(Number(payrollItem.pay_rate || 0))} />
              <ContextRow icon={Banknote} label="Bonus" value={formatCurrency(Number(payrollItem.bonus || 0))} />
              <ContextRow icon={ReceiptText} label="Reported tips" value={formatCurrency(Number(payrollItem.reported_tips || 0))} />
            </CardContent>
          </Card>

          <Card>
            <CardHeader><CardTitle>Check context</CardTitle><p className="mt-1 text-sm text-neutral-500">Payment identity and print lifecycle attached to this record.</p></CardHeader>
            <CardContent className="grid gap-5 sm:grid-cols-2">
              <ContextRow icon={Printer} label="Check number" value={payrollItem.check_number || 'Not assigned'} />
              <ContextRow icon={Printer} label="Check status" value={payrollItem.voided ? 'Voided' : payrollItem.check_printed_at ? 'Printed' : payrollItem.check_number ? 'Assigned' : 'Pending'} />
              <ContextRow icon={CalendarDays} label="Check date" value={payrollItem.check_date ? formatDate(payrollItem.check_date) : formatDate(payRun.pay_date)} />
              <ContextRow icon={Printer} label="Print count" value={String(payrollItem.check_print_count || 0)} />
              <ContextRow icon={CalendarDays} label="Printed at" value={payrollItem.check_printed_at ? formatGuamDateTime(payrollItem.check_printed_at) : 'Not printed'} />
              <ContextRow icon={ReceiptText} label="Memo" value={payrollItem.check_memo || 'No memo'} />
            </CardContent>
          </Card>
        </div>

        {(payrollItem.custom_earnings?.length || payrollItem.custom_deductions?.length || payrollItem.payroll_field_entries?.length) ? (
          <Card>
            <CardHeader><CardTitle>Applied payroll components</CardTitle><p className="mt-1 text-sm text-neutral-500">Named additions, deductions, and payroll fields recorded on this result.</p></CardHeader>
            <CardContent className="grid gap-6 lg:grid-cols-3">
              <ComponentList title="Custom earnings" entries={(payrollItem.custom_earnings || []).map((entry) => ({ label: entry.label, amount: entry.amount }))} />
              <ComponentList title="Custom deductions" entries={(payrollItem.custom_deductions || []).map((entry) => ({ label: entry.label, amount: entry.amount }))} />
              <ComponentList title="Payroll fields" entries={(payrollItem.payroll_field_entries || []).filter((entry) => entry.active !== false).map((entry) => ({ label: entry.label, amount: entry.amount }))} />
            </CardContent>
          </Card>
        ) : null}

        <p className="text-xs leading-5 text-neutral-400">Canonical record: {payrollItemPath(companyId, payRun.id, payrollItem.id)}</p>
      </main>
    </div>
  );
}

function RelationshipLink({ icon: Icon, eyebrow, title, detail, href }: { icon: typeof UserRound; eyebrow: string; title: string; detail: string; href: string }): ReactElement {
  return <Link to={href} className="group grid min-h-24 grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-4 rounded-[1.35rem] border border-neutral-200 bg-white p-4 shadow-sm transition hover:-translate-y-0.5 hover:border-primary-300 hover:shadow-md"><span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-primary-50 text-primary-700"><Icon className="h-5 w-5" /></span><span><span className="block text-xs font-bold uppercase tracking-[0.12em] text-neutral-400">{eyebrow}</span><span className="mt-1 block font-display text-lg font-bold text-neutral-950 group-hover:text-primary-800">{title}</span><span className="mt-1 block text-sm text-neutral-500">{detail}</span></span><ArrowRight className="h-5 w-5 text-neutral-300 transition group-hover:translate-x-1 group-hover:text-primary-700" /></Link>;
}

function Metric({ icon: Icon, label, value, detail }: { icon: typeof Banknote; label: string; value: string; detail: string }): ReactElement {
  return <Card><CardContent className="p-5"><span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-primary-50 text-primary-700"><Icon className="h-5 w-5" /></span><p className="mt-4 text-xs font-bold uppercase tracking-[0.12em] text-neutral-400">{label}</p><p className="mt-2 font-display text-2xl font-extrabold tracking-tight text-neutral-950">{value}</p><p className="mt-1 text-sm text-neutral-500">{detail}</p></CardContent></Card>;
}

function ContextRow({ icon: Icon, label, value }: { icon: typeof Banknote; label: string; value: string }): ReactElement {
  return <div className="flex items-start gap-3"><span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-neutral-100 text-neutral-600"><Icon className="h-4 w-4" /></span><div><p className="text-xs font-bold uppercase tracking-[0.1em] text-neutral-400">{label}</p><p className="mt-1 text-sm font-semibold capitalize text-neutral-800">{value}</p></div></div>;
}

function ComponentList({ title, entries }: { title: string; entries: Array<{ label: string; amount: number }> }): ReactElement {
  return <section><h2 className="text-sm font-bold text-neutral-950">{title}</h2>{entries.length ? <div className="mt-3 space-y-2">{entries.map((entry, index) => <div key={`${entry.label}-${index}`} className="flex items-center justify-between gap-3 rounded-xl bg-neutral-50 px-3 py-2 text-sm"><span className="font-medium text-neutral-700">{entry.label}</span><span className="font-semibold tabular-nums text-neutral-950">{formatCurrency(Number(entry.amount || 0))}</span></div>)}</div> : <p className="mt-3 text-sm text-neutral-500">None applied.</p>}</section>;
}
