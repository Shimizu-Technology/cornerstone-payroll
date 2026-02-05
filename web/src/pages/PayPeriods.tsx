import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card } from '@/components/ui/card';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { formatCurrency, formatDateRange, payPeriodStatusConfig } from '@/lib/utils';
import type { PayPeriod } from '@/types';

// Placeholder data - will be replaced with API calls
const payPeriods: PayPeriod[] = [
  {
    id: 3,
    company_id: 1,
    start_date: '2026-01-20',
    end_date: '2026-02-02',
    pay_date: '2026-02-06',
    status: 'draft',
    created_at: '2026-01-20T00:00:00Z',
    updated_at: '2026-01-20T00:00:00Z',
    payroll_items_count: 4,
    total_gross: 0,
    total_net: 0,
  },
  {
    id: 2,
    company_id: 1,
    start_date: '2026-01-06',
    end_date: '2026-01-19',
    pay_date: '2026-01-23',
    status: 'committed',
    created_at: '2026-01-06T00:00:00Z',
    updated_at: '2026-01-23T00:00:00Z',
    committed_at: '2026-01-23T00:00:00Z',
    payroll_items_count: 4,
    total_gross: 12450.00,
    total_net: 9876.50,
  },
  {
    id: 1,
    company_id: 1,
    start_date: '2025-12-23',
    end_date: '2026-01-05',
    pay_date: '2026-01-09',
    status: 'committed',
    created_at: '2025-12-23T00:00:00Z',
    updated_at: '2026-01-09T00:00:00Z',
    committed_at: '2026-01-09T00:00:00Z',
    payroll_items_count: 4,
    total_gross: 12450.00,
    total_net: 9876.50,
  },
];

export function PayPeriods() {
  return (
    <div>
      <Header
        title="Pay Periods"
        description="Manage payroll periods and processing"
        actions={<Button>New Pay Period</Button>}
      />

      <div className="p-8">
        {/* Pay Period Table */}
        <Card>
          <Table>
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
            <TableBody>
              {payPeriods.map((period) => {
                const statusConfig = payPeriodStatusConfig[period.status];
                return (
                  <TableRow key={period.id}>
                    <TableCell>
                      <span className="font-medium text-gray-900">
                        {formatDateRange(period.start_date, period.end_date)}
                      </span>
                    </TableCell>
                    <TableCell>
                      <span className="text-sm text-gray-700">
                        {new Date(period.pay_date).toLocaleDateString('en-US', {
                          weekday: 'short',
                          month: 'short',
                          day: 'numeric',
                        })}
                      </span>
                    </TableCell>
                    <TableCell>
                      <span className="text-sm text-gray-700">
                        {period.payroll_items_count}
                      </span>
                    </TableCell>
                    <TableCell>
                      <span className="font-medium text-gray-900">
                        {period.total_gross ? formatCurrency(period.total_gross) : '—'}
                      </span>
                    </TableCell>
                    <TableCell>
                      <span className="font-medium text-gray-900">
                        {period.total_net ? formatCurrency(period.total_net) : '—'}
                      </span>
                    </TableCell>
                    <TableCell>
                      <Badge
                        variant={
                          period.status === 'committed' ? 'success' :
                          period.status === 'approved' ? 'info' :
                          period.status === 'calculated' ? 'warning' :
                          'default'
                        }
                      >
                        {statusConfig.label}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex items-center justify-end gap-2">
                        <Button variant="ghost" size="sm">
                          View
                        </Button>
                        {period.status === 'draft' && (
                          <Button size="sm">
                            Calculate
                          </Button>
                        )}
                        {period.status === 'calculated' && (
                          <Button size="sm">
                            Approve
                          </Button>
                        )}
                        {period.status === 'approved' && (
                          <Button size="sm">
                            Commit
                          </Button>
                        )}
                      </div>
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </Card>

        {/* Workflow explanation */}
        <Card className="mt-8">
          <div className="p-6">
            <h3 className="text-lg font-medium text-gray-900 mb-4">Payroll Workflow</h3>
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-gray-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-gray-600">1</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Draft</p>
                  <p className="text-sm text-gray-500">Create pay period</p>
                </div>
              </div>
              <div className="flex-1 h-px bg-gray-300 mx-4" />
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-yellow-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-yellow-600">2</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Calculated</p>
                  <p className="text-sm text-gray-500">Review totals</p>
                </div>
              </div>
              <div className="flex-1 h-px bg-gray-300 mx-4" />
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-blue-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-blue-600">3</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Approved</p>
                  <p className="text-sm text-gray-500">Ready to commit</p>
                </div>
              </div>
              <div className="flex-1 h-px bg-gray-300 mx-4" />
              <div className="flex items-center gap-2">
                <div className="w-8 h-8 bg-green-100 rounded-full flex items-center justify-center">
                  <span className="text-sm font-medium text-green-600">4</span>
                </div>
                <div>
                  <p className="font-medium text-gray-900">Committed</p>
                  <p className="text-sm text-gray-500">Locked & finalized</p>
                </div>
              </div>
            </div>
          </div>
        </Card>
      </div>
    </div>
  );
}
