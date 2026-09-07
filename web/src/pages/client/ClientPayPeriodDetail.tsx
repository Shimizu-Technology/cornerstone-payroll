import { useCallback, useEffect, useMemo, useRef, useState, type ReactElement } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { clientPayPeriodsApi } from '@/services/api';
import { formatCurrency, formatDate, formatDateRange } from '@/lib/utils';
import type { PayrollItem } from '@/types';
import { payRunsPath, safeInternalReturnPath } from '@/lib/routes';

export function ClientPayPeriodDetail(): ReactElement {
  const navigate = useNavigate();
  const { companyId: companyIdParam, id } = useParams<{ companyId: string; id: string }>();
  const [searchParams] = useSearchParams();
  const companyId = Number(companyIdParam);
  const payPeriodId = Number(id);
  const routeKey = `${companyId}:${payPeriodId}`;
  const returnTo = safeInternalReturnPath(searchParams.get('return_to'), payRunsPath(companyId));
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [payPeriod, setPayPeriod] = useState<Awaited<ReturnType<typeof clientPayPeriodsApi.get>>['pay_period'] | null>(null);
  const [search, setSearch] = useState('');
  const [employmentType, setEmploymentType] = useState('');
  const [resolvedRouteKey, setResolvedRouteKey] = useState<string | null>(null);
  const loadRequestIdRef = useRef(0);
  const resolvedPayPeriod = resolvedRouteKey === routeKey ? payPeriod : null;
  const resolvedError = resolvedRouteKey === routeKey ? error : null;

  const load = useCallback(async (): Promise<void> => {
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

    setLoading(true);
    setResolvedRouteKey(null);
    setError(null);
    setPayPeriod(null);
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
        actions={<Button variant="outline" onClick={() => navigate(returnTo)}>Back to List</Button>}
      />

      <div className="p-6 lg:p-8 space-y-6">
        {resolvedError && <div className="rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">{resolvedError}</div>}

        {loading || resolvedRouteKey !== routeKey ? (
          <div className="py-12 text-center text-sm text-gray-500">Loading pay period...</div>
        ) : resolvedPayPeriod ? (
          <>
            <div className="grid gap-6 md:grid-cols-2 xl:grid-cols-4">
              <SummaryCard label="Employees" value={String(resolvedPayPeriod.employee_count ?? resolvedPayPeriod.payroll_items?.length ?? 0)} />
              <SummaryCard label="Gross Pay" value={formatCurrency(resolvedPayPeriod.total_gross ?? 0)} />
              <SummaryCard label="Net Pay" value={formatCurrency(resolvedPayPeriod.total_net ?? 0)} />
              <SummaryCard label="Status" value={resolvedPayPeriod.status.charAt(0).toUpperCase() + resolvedPayPeriod.status.slice(1)} />
            </div>

            <Card>
              <CardHeader>
                <div className="flex flex-col gap-4 xl:flex-row xl:items-center xl:justify-between">
                  <div>
                    <CardTitle>Employee Payroll</CardTitle>
                    <p className="mt-1 text-sm text-gray-500">Read-only payroll detail for this pay period.</p>
                  </div>
                  <div className="flex flex-col gap-3 md:flex-row">
                    <Select value={employmentType} onChange={(e) => setEmploymentType(e.target.value)} className="w-44">
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
                <Table stickyHeader containerClassName="max-h-[34rem]">
                  <TableHeader>
                    <TableRow>
                      <TableHead stickyLeft>Employee</TableHead>
                      <TableHead>Hours</TableHead>
                      <TableHead>Rate</TableHead>
                      <TableHead>Gross</TableHead>
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
              </CardContent>
            </Card>
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

function PayrollItemRow({ item }: PayrollItemRowProps): ReactElement {
  return (
    <TableRow>
      <TableCell stickyLeft className="bg-inherit">
        <div>
          <p className="font-medium text-gray-900">{item.employee_name}</p>
          <p className="text-xs uppercase tracking-wide text-gray-500">{item.employment_type}</p>
        </div>
      </TableCell>
      <TableCell>{item.total_hours ?? item.hours_worked ?? '—'}</TableCell>
      <TableCell>{formatCurrency(item.pay_rate)}{item.employment_type === 'hourly' ? '/hr' : ''}</TableCell>
      <TableCell>{formatCurrency(item.gross_pay ?? 0)}</TableCell>
      <TableCell>{formatCurrency(item.total_deductions ?? 0)}</TableCell>
      <TableCell>{formatCurrency(item.net_pay ?? 0)}</TableCell>
    </TableRow>
  );
}
