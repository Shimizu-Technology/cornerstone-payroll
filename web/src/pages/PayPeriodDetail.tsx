import { useEffect, useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
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
import { payPeriodsApi } from '@/services/api';
import type { PayPeriod, PayrollItem } from '@/types';

export function PayPeriodDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [payPeriod, setPayPeriod] = useState<PayPeriod | null>(null);
  const [payrollItems, setPayrollItems] = useState<PayrollItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [processing, setProcessing] = useState(false);

  useEffect(() => {
    if (id) {
      loadPayPeriod(parseInt(id));
    }
  }, [id]);

  const loadPayPeriod = async (periodId: number) => {
    try {
      setLoading(true);
      setError(null);
      const response = await payPeriodsApi.get(periodId);
      setPayPeriod(response.pay_period);
      setPayrollItems(response.pay_period.payroll_items || []);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load pay period');
    } finally {
      setLoading(false);
    }
  };

  const handleRunPayroll = async () => {
    if (!payPeriod) return;
    try {
      setProcessing(true);
      setError(null);
      const response = await payPeriodsApi.runPayroll(payPeriod.id);
      setPayPeriod(response.pay_period);
      setPayrollItems(response.pay_period.payroll_items || []);
      
      // Show results
      if (response.results.errors.length > 0) {
        setError(`Calculated ${response.results.success.length} employees. ${response.results.errors.length} errors: ${response.results.errors.map(e => e.error).join(', ')}`);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to run payroll');
    } finally {
      setProcessing(false);
    }
  };

  const handleApprove = async () => {
    if (!payPeriod) return;
    try {
      setProcessing(true);
      setError(null);
      const response = await payPeriodsApi.approve(payPeriod.id);
      setPayPeriod(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to approve pay period');
    } finally {
      setProcessing(false);
    }
  };

  const handleCommit = async () => {
    if (!payPeriod) return;
    if (!confirm('Are you sure you want to commit this pay period? This action cannot be undone and will update YTD totals.')) {
      return;
    }
    try {
      setProcessing(true);
      setError(null);
      const response = await payPeriodsApi.commit(payPeriod.id);
      setPayPeriod(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to commit pay period');
    } finally {
      setProcessing(false);
    }
  };

  if (loading) {
    return (
      <div className="p-8 text-center text-gray-500">Loading...</div>
    );
  }

  if (!payPeriod) {
    return (
      <div className="p-8 text-center text-gray-500">Pay period not found</div>
    );
  }

  const statusConfig = payPeriodStatusConfig[payPeriod.status];

  // Calculate summary
  const summary = {
    totalGross: payrollItems.reduce((sum, item) => sum + (item.gross_pay || 0), 0),
    totalWithholding: payrollItems.reduce((sum, item) => sum + (item.withholding_tax || 0), 0),
    totalSS: payrollItems.reduce((sum, item) => sum + (item.social_security_tax || 0), 0),
    totalMedicare: payrollItems.reduce((sum, item) => sum + (item.medicare_tax || 0), 0),
    totalDeductions: payrollItems.reduce((sum, item) => sum + (item.total_deductions || 0), 0),
    totalNet: payrollItems.reduce((sum, item) => sum + (item.net_pay || 0), 0),
  };

  return (
    <div>
      <Header
        title={`Pay Period: ${formatDateRange(payPeriod.start_date, payPeriod.end_date)}`}
        description={`Pay Date: ${new Date(payPeriod.pay_date).toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })}`}
        actions={
          <div className="flex gap-2">
            <Button variant="outline" onClick={() => navigate('/pay-periods')}>
              Back to List
            </Button>
            {payPeriod.status === 'draft' && (
              <Button onClick={handleRunPayroll} disabled={processing}>
                {processing ? 'Processing...' : 'Calculate Payroll'}
              </Button>
            )}
            {payPeriod.status === 'calculated' && (
              <>
                <Button variant="outline" onClick={handleRunPayroll} disabled={processing}>
                  Recalculate
                </Button>
                <Button onClick={handleApprove} disabled={processing}>
                  {processing ? 'Processing...' : 'Approve'}
                </Button>
              </>
            )}
            {payPeriod.status === 'approved' && (
              <Button onClick={handleCommit} disabled={processing}>
                {processing ? 'Processing...' : 'Commit & Finalize'}
              </Button>
            )}
          </div>
        }
      />

      <div className="p-8">
        {/* Error display */}
        {error && (
          <div className="mb-4 p-4 bg-red-50 border border-red-200 text-red-700 rounded-lg">
            {error}
          </div>
        )}

        {/* Summary Cards */}
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
          <Card className="p-4">
            <div className="text-sm text-gray-500">Status</div>
            <Badge
              variant={
                payPeriod.status === 'committed' ? 'success' :
                payPeriod.status === 'approved' ? 'info' :
                payPeriod.status === 'calculated' ? 'warning' :
                'default'
              }
              className="mt-1"
            >
              {statusConfig?.label || payPeriod.status}
            </Badge>
          </Card>
          <Card className="p-4">
            <div className="text-sm text-gray-500">Employees</div>
            <div className="text-2xl font-bold text-gray-900">{payrollItems.length}</div>
          </Card>
          <Card className="p-4">
            <div className="text-sm text-gray-500">Total Gross</div>
            <div className="text-2xl font-bold text-gray-900">{formatCurrency(summary.totalGross)}</div>
          </Card>
          <Card className="p-4">
            <div className="text-sm text-gray-500">Total Net</div>
            <div className="text-2xl font-bold text-green-600">{formatCurrency(summary.totalNet)}</div>
          </Card>
        </div>

        {/* Tax Summary */}
        <Card className="mb-8">
          <div className="p-4 border-b">
            <h3 className="font-medium text-gray-900">Tax Summary</h3>
          </div>
          <div className="p-4 grid grid-cols-2 md:grid-cols-4 gap-4">
            <div>
              <div className="text-sm text-gray-500">Federal/Guam Withholding</div>
              <div className="text-lg font-medium text-gray-900">{formatCurrency(summary.totalWithholding)}</div>
            </div>
            <div>
              <div className="text-sm text-gray-500">Social Security (6.2%)</div>
              <div className="text-lg font-medium text-gray-900">{formatCurrency(summary.totalSS)}</div>
            </div>
            <div>
              <div className="text-sm text-gray-500">Medicare (1.45%)</div>
              <div className="text-lg font-medium text-gray-900">{formatCurrency(summary.totalMedicare)}</div>
            </div>
            <div>
              <div className="text-sm text-gray-500">Total Deductions</div>
              <div className="text-lg font-medium text-red-600">{formatCurrency(summary.totalDeductions)}</div>
            </div>
          </div>
        </Card>

        {/* Payroll Items Table */}
        <Card>
          <div className="p-4 border-b">
            <h3 className="font-medium text-gray-900">Employee Payroll</h3>
          </div>
          {payrollItems.length === 0 ? (
            <div className="p-8 text-center text-gray-500">
              No payroll items yet. Click "Calculate Payroll" to process all active employees.
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Employee</TableHead>
                  <TableHead>Type</TableHead>
                  <TableHead className="text-right">Hours</TableHead>
                  <TableHead className="text-right">Rate</TableHead>
                  <TableHead className="text-right">Gross</TableHead>
                  <TableHead className="text-right">Withholding</TableHead>
                  <TableHead className="text-right">SS</TableHead>
                  <TableHead className="text-right">Medicare</TableHead>
                  <TableHead className="text-right">Deductions</TableHead>
                  <TableHead className="text-right">Net Pay</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {payrollItems.map((item) => (
                  <TableRow key={item.id}>
                    <TableCell>
                      <span className="font-medium text-gray-900">{item.employee_name}</span>
                    </TableCell>
                    <TableCell>
                      <Badge variant={item.employment_type === 'salary' ? 'info' : 'default'}>
                        {item.employment_type}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-right">
                      {item.employment_type === 'hourly' ? (
                        <span>
                          {item.hours_worked || 0}
                          {(item.overtime_hours || 0) > 0 && (
                            <span className="text-orange-600 ml-1">+{item.overtime_hours} OT</span>
                          )}
                        </span>
                      ) : (
                        <span className="text-gray-400">—</span>
                      )}
                    </TableCell>
                    <TableCell className="text-right">
                      {item.employment_type === 'hourly'
                        ? `$${item.pay_rate?.toFixed(2)}/hr`
                        : `$${item.pay_rate?.toLocaleString()}/yr`
                      }
                    </TableCell>
                    <TableCell className="text-right font-medium">
                      {formatCurrency(item.gross_pay || 0)}
                    </TableCell>
                    <TableCell className="text-right text-red-600">
                      {formatCurrency(item.withholding_tax || 0)}
                    </TableCell>
                    <TableCell className="text-right text-red-600">
                      {formatCurrency(item.social_security_tax || 0)}
                    </TableCell>
                    <TableCell className="text-right text-red-600">
                      {formatCurrency(item.medicare_tax || 0)}
                    </TableCell>
                    <TableCell className="text-right text-red-600">
                      {formatCurrency(item.total_deductions || 0)}
                    </TableCell>
                    <TableCell className="text-right font-bold text-green-600">
                      {formatCurrency(item.net_pay || 0)}
                    </TableCell>
                  </TableRow>
                ))}
                {/* Totals row */}
                <TableRow className="bg-gray-50 font-bold">
                  <TableCell colSpan={4}>Totals</TableCell>
                  <TableCell className="text-right">{formatCurrency(summary.totalGross)}</TableCell>
                  <TableCell className="text-right text-red-600">{formatCurrency(summary.totalWithholding)}</TableCell>
                  <TableCell className="text-right text-red-600">{formatCurrency(summary.totalSS)}</TableCell>
                  <TableCell className="text-right text-red-600">{formatCurrency(summary.totalMedicare)}</TableCell>
                  <TableCell className="text-right text-red-600">{formatCurrency(summary.totalDeductions)}</TableCell>
                  <TableCell className="text-right text-green-600">{formatCurrency(summary.totalNet)}</TableCell>
                </TableRow>
              </TableBody>
            </Table>
          )}
        </Card>

        {/* Notes */}
        {payPeriod.notes && (
          <Card className="mt-8">
            <div className="p-4 border-b">
              <h3 className="font-medium text-gray-900">Notes</h3>
            </div>
            <div className="p-4 text-gray-600">
              {payPeriod.notes}
            </div>
          </Card>
        )}

        {/* Committed timestamp */}
        {payPeriod.committed_at && (
          <div className="mt-4 text-sm text-gray-500 text-center">
            Committed on {new Date(payPeriod.committed_at).toLocaleString()}
          </div>
        )}
      </div>
    </div>
  );
}
