import { useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { clientPayPeriodsApi } from '@/services/api';
import { formatCurrency, formatDateRange } from '@/lib/utils';
import type { PayrollItem } from '@/types';
import { payRunsPath } from '@/lib/routes';

export function ClientPayPeriodDetail() {
  const navigate = useNavigate();
  const { companyId: companyIdParam, id } = useParams<{ companyId: string; id: string }>();
  const companyId = Number(companyIdParam);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [payPeriod, setPayPeriod] = useState<Awaited<ReturnType<typeof clientPayPeriodsApi.get>>['pay_period'] | null>(null);
  const [search, setSearch] = useState('');
  const [employmentType, setEmploymentType] = useState('');

  const load = useCallback(async () => {
    if (!id) return;
    try {
      setLoading(true);
      setError(null);
      const response = await clientPayPeriodsApi.get(Number(id));
      setPayPeriod(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load pay period');
    } finally {
      setLoading(false);
    }
  }, [id]);

  useEffect(() => {
    void load();
  }, [load]);

  const visibleItems = useMemo(() => {
    const items = payPeriod?.payroll_items || [];
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
  }, [employmentType, payPeriod?.payroll_items, search]);

  return (
    <div>
      <Header
        title={payPeriod ? `Pay Period: ${formatDateRange(payPeriod.start_date, payPeriod.end_date)}` : 'Pay Period'}
        description={payPeriod ? `Pay Date: ${new Date(payPeriod.pay_date).toLocaleDateString()}` : 'Review employee payroll for this period.'}
        actions={<Button variant="outline" onClick={() => navigate(payRunsPath(companyId))}>Back to List</Button>}
      />

      <div className="p-6 lg:p-8 space-y-6">
        {error && <div className="rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">{error}</div>}

        {loading ? (
          <div className="py-12 text-center text-sm text-gray-500">Loading pay period...</div>
        ) : payPeriod ? (
          <>
            <div className="grid gap-6 md:grid-cols-2 xl:grid-cols-4">
              <SummaryCard label="Employees" value={String(payPeriod.employee_count ?? payPeriod.payroll_items?.length ?? 0)} />
              <SummaryCard label="Gross Pay" value={formatCurrency(payPeriod.total_gross ?? 0)} />
              <SummaryCard label="Net Pay" value={formatCurrency(payPeriod.total_net ?? 0)} />
              <SummaryCard label="Status" value={payPeriod.status.charAt(0).toUpperCase() + payPeriod.status.slice(1)} />
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

function SummaryCard({ label, value }: { label: string; value: string }) {
  return (
    <Card>
      <CardContent className="pt-6">
        <p className="text-sm font-medium text-neutral-500">{label}</p>
        <p className="mt-3 text-3xl font-semibold tracking-tight text-neutral-900">{value}</p>
      </CardContent>
    </Card>
  );
}

function PayrollItemRow({ item }: { item: PayrollItem }) {
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
