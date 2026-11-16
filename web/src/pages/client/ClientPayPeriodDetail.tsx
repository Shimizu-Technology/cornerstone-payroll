import { ActionFeedback } from '@/components/ui/action-feedback';
import { useCallback, useEffect, useMemo, useRef, useState, type ReactElement } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { MobileField, MobileRecordCard } from '@/components/ui/mobile-record';
import { clientPayrollSubmissionsApi } from '@/services/payrollSubmissions';
import { clientPayPeriodsApi } from '@/services/api';
import { formatCurrency, formatDate, formatDateRange } from '@/lib/utils';
import { ClientPayrollReview } from '@/components/client-portal/ClientPayrollReview';
import { ClientPayStubButton } from '@/components/client-portal/ClientPayStubButton';
import type { PayrollItem } from '@/types';
import { payRunsPath, safeInternalReturnPath } from '@/lib/routes';
import { parsePositiveRouteId } from '@/lib/route-params';

export function ClientPeriodFilesLink({ startDate, endDate }: { startDate: string; endDate: string }) {
  const [filesRef, setFilesRef] = useState<string | null>(null);
  useEffect(() => {
    let active = true;
    setFilesRef(null);
    void clientPayrollSubmissionsApi.get(`${startDate}_${endDate}`).then(result => {
      if (active) setFilesRef(result.data.ref);
    }).catch(() => {});
    return () => { active = false; };
  }, [startDate, endDate]);
  return filesRef ? <Link className="inline-flex min-h-11 items-center px-4 text-primary-800 underline" to={`/payroll-files/${filesRef}`}>Pay Period Files</Link> : null;
}

export function ClientPayPeriodDetail(): ReactElement {
  const navigate = useNavigate();
  const { companyId: companyIdParam, id } = useParams<{ companyId: string; id: string }>();
  const [searchParams] = useSearchParams();
  const companyId = parsePositiveRouteId(companyIdParam) ?? 0;
  const payPeriodId = parsePositiveRouteId(id) ?? 0;
  const routeKey = `${companyId}:${payPeriodId}`;
  const listFallback = companyId > 0 ? payRunsPath(companyId) : '/pay-periods';
  const returnTo = safeInternalReturnPath(searchParams.get('return_to'), listFallback);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [payPeriod, setPayPeriod] = useState<Awaited<ReturnType<typeof clientPayPeriodsApi.get>>['pay_period'] | null>(null);
  const [search, setSearch] = useState('');
  const [employmentType, setEmploymentType] = useState('');
  const [resolvedRouteKey, setResolvedRouteKey] = useState<string | null>(null);
  const loadRequestIdRef = useRef(0);
  const resolvedPayPeriod = resolvedRouteKey === routeKey ? payPeriod : null;
  const resolvedError = resolvedRouteKey === routeKey ? error : null;

  const load = useCallback(async (retainCurrent = false): Promise<void> => {
    const requestId = ++loadRequestIdRef.current;
    const isCurrentRequest = (): boolean => loadRequestIdRef.current === requestId;

    if (![companyId, payPeriodId].every((value) => Number.isInteger(value) && value > 0)) {
      if (isCurrentRequest()) {
        setPayPeriod(null);
        setError('This pay-period link is invalid.');
        setResolvedRouteKey(routeKey);
        setLoading(false);
      }
      return;
    }

    if (!retainCurrent) {
      setLoading(true);
      setResolvedRouteKey(null);
      setPayPeriod(null);
    }
    setError(null);
    try {
      const response = await clientPayPeriodsApi.get(payPeriodId, companyId);
      if (!isCurrentRequest()) return;
      setPayPeriod(response.pay_period);
      setResolvedRouteKey(routeKey);
    } catch (err) {
      if (isCurrentRequest()) {
        setError(err instanceof Error ? err.message : 'Failed to load pay period');
        setResolvedRouteKey(routeKey);
      }
    } finally {
      if (isCurrentRequest()) setLoading(false);
    }
  }, [companyId, payPeriodId, routeKey]);

  useEffect(() => {
    void load();
    return (): void => {
      loadRequestIdRef.current += 1;
    };
  }, [load]);

  const visibleItems = useMemo(() => {
    const items = resolvedPayPeriod?.payroll_items || [];
    return items.filter((item) => {
      const matchesType = !employmentType || item.employment_type === employmentType;
      const haystack = [
        item.employee_name,
        item.employment_type,
      ]
        .filter(Boolean)
        .join(' ')
        .toLowerCase();
      const matchesSearch = !search.trim() || haystack.includes(search.toLowerCase());
      return matchesType && matchesSearch;
    });
  }, [employmentType, resolvedPayPeriod?.payroll_items, search]);

  return (
    <div>
      <Header
        title={resolvedPayPeriod ? `Pay Period: ${formatDateRange(resolvedPayPeriod.start_date, resolvedPayPeriod.end_date)}` : 'Pay Period'}
        description={resolvedPayPeriod ? `Pay Date: ${formatDate(resolvedPayPeriod.pay_date)}` : 'Review employee payroll for this period.'}
        actions={<>{resolvedPayPeriod && <ClientPeriodFilesLink key={routeKey} startDate={resolvedPayPeriod.start_date} endDate={resolvedPayPeriod.end_date} />}<Button variant="outline" onClick={() => navigate(returnTo)}>Back to List</Button></>}
      />

      <div className="space-y-6 p-4 sm:p-6 lg:p-8">
        {resolvedError && <ActionFeedback tone="error" message={resolvedError} />}

        {loading || resolvedRouteKey !== routeKey ? (
          <div className="py-12 text-center text-sm text-gray-500">Loading pay period...</div>
        ) : resolvedPayPeriod ? (
          <>
            <div className="grid gap-6 md:grid-cols-2 xl:grid-cols-4">
              <SummaryCard label="Employees" value={String(resolvedPayPeriod.employee_count ?? resolvedPayPeriod.payroll_items?.length ?? 0)} />
              <SummaryCard label="Gross Pay" value={formatCurrency(resolvedPayPeriod.total_gross ?? 0)} />
              <SummaryCard label="Net Pay" value={formatCurrency(resolvedPayPeriod.total_net ?? 0)} />
              <SummaryCard label="Status" value={resolvedPayPeriod.test_workspace_role === 'baseline' ? 'Paid (copied history)' : resolvedPayPeriod.status === 'approved' ? (resolvedPayPeriod.payroll_review?.status === 'approved' ? 'Client approved' : resolvedPayPeriod.payroll_review?.status === 'changes_requested' ? 'Changes requested' : 'Ready for your review') : resolvedPayPeriod.status.charAt(0).toUpperCase() + resolvedPayPeriod.status.slice(1)} />
            </div>


            <Card>
              <CardHeader>
                <div className="flex flex-col gap-4 xl:flex-row xl:items-center xl:justify-between">
                  <div>
                    <CardTitle>Employee Payroll</CardTitle>
                    <p className="mt-1 text-sm text-gray-500">Hours, earnings, taxes, deductions, and net pay for this exact payroll revision.</p>
                  </div>
                  <div className="flex flex-col gap-3 md:flex-row">
                    <Select value={employmentType} onChange={(e) => setEmploymentType(e.target.value)} className="w-full md:w-44">
                      <option value="">All Types</option>
                      <option value="salary">Salary</option>
                      <option value="hourly">Hourly</option>
                      <option value="contractor">Contractor</option>
                    </Select>
                    <Input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search employees..." className="w-full md:w-72" />
                  </div>
                </div>
              </CardHeader>
              <CardContent className="p-0">
                <div className="space-y-3 p-3 lg:hidden" aria-label="Employee payroll details">
                  {visibleItems.map((item) => (
                    <PayrollItemMobileCard key={item.id} item={item} />
                  ))}
                  {visibleItems.length === 0 && <p className="py-8 text-center text-sm text-neutral-500">No employees match these filters.</p>}
                </div>
                <div className="hidden lg:block">
                <Table stickyHeader containerClassName="max-h-[34rem]">
                  <TableHeader>
                    <TableRow>
                      <TableHead stickyLeft>Employee</TableHead>
                      <TableHead>Hours</TableHead>
                      <TableHead>Rate</TableHead>
                      <TableHead>Gross</TableHead>
                      <TableHead>Taxes</TableHead>
                      <TableHead>Retirement</TableHead>
                      <TableHead>Loans</TableHead>
                      <TableHead>Insurance</TableHead>
                      <TableHead>Total Ded.</TableHead>
                      <TableHead>Net Pay</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody striped>
                    {visibleItems.map((item) => (
                      <PayrollItemRow key={item.id} item={item} />
                    ))}
                  </TableBody>
                </Table>
                </div>
              </CardContent>
            </Card>

            <ClientPayrollReview key={routeKey} payPeriod={resolvedPayPeriod} companyId={companyId} onDone={() => load(true)} />
          </>
        ) : null}
      </div>
    </div>
  );
}

interface SummaryCardProps {
  label: string;
  value: string;
}

function SummaryCard({ label, value }: SummaryCardProps): ReactElement {
  return (
    <Card>
      <CardContent className="pt-6">
        <p className="text-sm font-medium text-neutral-500">{label}</p>
        <p className="mt-3 text-3xl font-semibold tracking-tight text-neutral-900">{value}</p>
      </CardContent>
    </Card>
  );
}

interface PayrollItemRowProps {
  item: PayrollItem;
}

function numericAmount(value: number | string | null | undefined): number {
  const parsed = Number(value);
  return value == null || !Number.isFinite(parsed) ? 0 : parsed;
}

function itemTaxes(item: PayrollItem): number {
  return numericAmount(item.withholding_tax) + numericAmount(item.social_security_tax)
    + numericAmount(item.medicare_tax) + numericAmount(item.additional_medicare_tax)
    + numericAmount(item.state_withheld);
}

function PayrollItemMobileCard({ item }: PayrollItemRowProps): ReactElement {
  const hours = item.total_hours ?? item.hours_worked;
  return (
    <MobileRecordCard>
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="font-semibold text-neutral-950">{item.employee_name}</p>
          {item.pay_stub_available && <ClientPayStubButton itemId={item.id} />}
          <p className="mt-1 text-xs uppercase tracking-wide text-neutral-500">{item.employment_type}</p>
        </div>
        <div className="text-left sm:text-right">
          <p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Net pay</p>
          <p className="font-semibold tabular-nums text-neutral-950">{formatCurrency(numericAmount(item.net_pay))}</p>
        </div>
      </div>
      <div className="mt-4 grid grid-cols-2 gap-3">
        <MobileField label="Hours" value={hours ?? '—'} />
        <MobileField label="Rate" value={item.pay_rate == null ? '—' : `${formatCurrency(numericAmount(item.pay_rate))}${item.employment_type === 'hourly' ? '/hr' : ''}`} />
        <MobileField label="Gross" value={formatCurrency(numericAmount(item.gross_pay))} />
        <MobileField label="Taxes" value={formatCurrency(itemTaxes(item))} />
        <MobileField label="Retirement" value={formatCurrency(numericAmount(item.retirement_payment) + numericAmount(item.roth_retirement_payment))} />
        <MobileField label="Loans" value={formatCurrency(numericAmount(item.loan_payment) || numericAmount(item.loan_deduction))} />
        <MobileField label="Insurance" value={formatCurrency(numericAmount(item.insurance_payment))} />
        <MobileField label="Total deductions" value={formatCurrency(numericAmount(item.total_deductions))} />
      </div>
    </MobileRecordCard>
  );
}

function PayrollItemRow({ item }: PayrollItemRowProps): ReactElement {
  return (
    <TableRow>
      <TableCell stickyLeft className="bg-inherit">
        <div>
          <p className="font-medium text-gray-900">{item.employee_name}</p>
          {item.pay_stub_available && <ClientPayStubButton itemId={item.id} />}
          <p className="text-xs uppercase tracking-wide text-gray-500">{item.employment_type}</p>
        </div>
      </TableCell>
      <TableCell>{item.total_hours ?? item.hours_worked ?? '—'}</TableCell>
      <TableCell>{formatCurrency(item.pay_rate)}{item.employment_type === 'hourly' ? '/hr' : ''}</TableCell>
      <TableCell>{formatCurrency(item.gross_pay ?? 0)}</TableCell>
      <TableCell>{formatCurrency(itemTaxes(item))}</TableCell>
      <TableCell>{formatCurrency((Number(item.retirement_payment) || 0) + (Number(item.roth_retirement_payment) || 0))}</TableCell>
      <TableCell>{formatCurrency(Number(item.loan_payment) || Number(item.loan_deduction) || 0)}</TableCell>
      <TableCell>{formatCurrency(item.insurance_payment ?? 0)}</TableCell>
      <TableCell>{formatCurrency(item.total_deductions ?? 0)}</TableCell>
      <TableCell>{formatCurrency(item.net_pay ?? 0)}</TableCell>
    </TableRow>
  );
}
