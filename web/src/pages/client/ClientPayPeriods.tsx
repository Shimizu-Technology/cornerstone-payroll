import { useCallback, useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router';
import { Search } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { clientPayPeriodsApi } from '@/services/api';
import { formatCurrency, formatDateRange, payPeriodStatusConfig } from '@/lib/utils';
import type { PayPeriod } from '@/types';

export function ClientPayPeriods() {
  const navigate = useNavigate();
  const [payPeriods, setPayPeriods] = useState<PayPeriod[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState('');

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const response = await clientPayPeriodsApi.list();
      setPayPeriods(response.pay_periods);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load pay periods');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const visiblePayPeriods = useMemo(() => {
    const query = search.trim().toLowerCase();
    if (!query) return payPeriods;
    return payPeriods.filter((period) =>
      [
        formatDateRange(period.start_date, period.end_date),
        new Date(period.pay_date).toLocaleDateString(),
        period.status,
        period.period_description,
      ]
        .filter(Boolean)
        .join(' ')
        .toLowerCase()
        .includes(query)
    );
  }, [payPeriods, search]);

  return (
    <div>
      <Header title="Pay Periods" description="Review payroll runs and employee pay information." />

      <div className="p-6 lg:p-8 space-y-6">
        {error && <div className="rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">{error}</div>}
        <div className="rounded-xl border border-primary-200 bg-primary-50/70 px-4 py-3 text-sm text-primary-800">
          Clients only see committed payrolls here so the portal stays read-only and reflects finalized payroll history.
        </div>

        <div className="flex flex-col gap-4 md:flex-row">
          <div className="relative max-w-md flex-1">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-400" />
            <Input className="pl-10" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search pay periods..." />
          </div>
        </div>

        <Card>
          {loading ? (
            <div className="py-12 text-center text-sm text-gray-500">Loading pay periods...</div>
          ) : visiblePayPeriods.length === 0 ? (
            <div className="py-12 text-center text-sm text-gray-500">No pay periods found.</div>
          ) : (
            <Table stickyHeader>
              <TableHeader>
                <TableRow>
                  <TableHead>Pay Period</TableHead>
                  <TableHead>Pay Date</TableHead>
                  <TableHead>Employees</TableHead>
                  <TableHead>Gross Pay</TableHead>
                  <TableHead>Net Pay</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody striped>
                {visiblePayPeriods.map((period) => (
                  <TableRow key={period.id}>
                    <TableCell className="font-medium text-gray-900">{formatDateRange(period.start_date, period.end_date)}</TableCell>
                    <TableCell>{new Date(period.pay_date).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' })}</TableCell>
                    <TableCell>{period.employee_count ?? period.payroll_items_count ?? 0}</TableCell>
                    <TableCell>{formatCurrency(period.total_gross ?? 0)}</TableCell>
                    <TableCell>{formatCurrency(period.total_net ?? 0)}</TableCell>
                    <TableCell>
                      <Badge variant={period.status === 'committed' ? 'success' : period.status === 'approved' ? 'info' : period.status === 'calculated' ? 'warning' : 'default'}>
                        {payPeriodStatusConfig[period.status]?.label || period.status}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-right">
                      <Button variant="ghost" size="sm" onClick={() => navigate(`/pay-periods/${period.id}`)}>
                        View
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </Card>
      </div>
    </div>
  );
}
