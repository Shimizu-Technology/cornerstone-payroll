import { useEffect, useState, useCallback } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { Header } from '@/components/layout/Header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent } from '@/components/ui/card';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { formatCurrency, formatDateRange, payPeriodStatusConfig } from '@/lib/utils';
import { payPeriodsApi, employeesApi } from '@/services/api';
import type { PayPeriod, PayrollItem, Employee } from '@/types';

interface HoursEntry {
  regular: number;
  overtime: number;
}

export function PayPeriodDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const [payPeriod, setPayPeriod] = useState<PayPeriod | null>(null);
  const [payrollItems, setPayrollItems] = useState<PayrollItem[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [hoursMap, setHoursMap] = useState<Record<string, HoursEntry>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [processing, setProcessing] = useState(false);

  const loadPayPeriod = useCallback(async (periodId: number) => {
    try {
      setLoading(true);
      setError(null);
      const response = await payPeriodsApi.get(periodId);
      setPayPeriod(response.pay_period);
      setPayrollItems(response.pay_period.payroll_items || []);

      // Initialize hours from existing payroll items
      const hours: Record<string, HoursEntry> = {};
      (response.pay_period.payroll_items || []).forEach((item: PayrollItem) => {
        hours[String(item.employee_id)] = {
          regular: item.hours_worked || 80,
          overtime: item.overtime_hours || 0,
        };
      });
      setHoursMap(hours);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load pay period');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (id) {
      loadPayPeriod(parseInt(id));
      // Load active employees for hours input
      employeesApi.list({ status: 'active', per_page: 100 }).then((res) => {
        setEmployees(res.data);
        // Set default hours for employees not yet in hoursMap
        setHoursMap((prev) => {
          const updated = { ...prev };
          res.data.forEach((emp: Employee) => {
            if (!updated[String(emp.id)]) {
              updated[String(emp.id)] = { regular: 80, overtime: 0 };
            }
          });
          return updated;
        });
      });
    }
  }, [id, loadPayPeriod]);

  const updateHours = (employeeId: number, field: 'regular' | 'overtime', value: number) => {
    setHoursMap((prev) => ({
      ...prev,
      [String(employeeId)]: {
        ...prev[String(employeeId)],
        [field]: value,
      },
    }));
  };

  const handleRunPayroll = async () => {
    if (!payPeriod) return;
    try {
      setProcessing(true);
      setError(null);

      // Build hours payload
      const hours: Record<string, { regular?: number; overtime?: number }> = {};
      Object.entries(hoursMap).forEach(([empId, entry]) => {
        hours[empId] = { regular: entry.regular, overtime: entry.overtime };
      });

      const response = await payPeriodsApi.runPayroll(payPeriod.id, { hours });
      setPayPeriod(response.pay_period);
      setPayrollItems(response.pay_period.payroll_items || []);

      if (response.results.errors.length > 0) {
        setError(
          `Calculated ${response.results.success.length} employees. ${response.results.errors.length} errors: ${response.results.errors.map((e) => e.error).join(', ')}`
        );
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
      setError(err instanceof Error ? err.message : 'Failed to approve');
    } finally {
      setProcessing(false);
    }
  };

  const handleCommit = async () => {
    if (!payPeriod) return;
    if (!confirm('Commit this payroll? This will update YTD totals and cannot be undone.')) return;
    try {
      setProcessing(true);
      setError(null);
      const response = await payPeriodsApi.commit(payPeriod.id);
      setPayPeriod(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to commit');
    } finally {
      setProcessing(false);
    }
  };

  if (loading) {
    return <div className="p-8 text-center text-gray-500">Loading...</div>;
  }

  if (!payPeriod) {
    return <div className="p-8 text-center text-gray-500">Pay period not found</div>;
  }

  const isDraft = payPeriod.status === 'draft';
  const isCalculated = payPeriod.status === 'calculated';
  const isApproved = payPeriod.status === 'approved';
  const isCommitted = payPeriod.status === 'committed';
  const statusConfig = payPeriodStatusConfig[payPeriod.status];

  // Summaries
  const totalGross = payrollItems.reduce((s, i) => s + (i.gross_pay || 0), 0);
  const totalWithholding = payrollItems.reduce((s, i) => s + (i.withholding_tax || 0), 0);
  const totalSS = payrollItems.reduce((s, i) => s + (i.social_security_tax || 0), 0);
  const totalMedicare = payrollItems.reduce((s, i) => s + (i.medicare_tax || 0), 0);
  const totalDeductions = payrollItems.reduce((s, i) => s + (i.total_deductions || 0), 0);
  const totalNet = payrollItems.reduce((s, i) => s + (i.net_pay || 0), 0);
  const totalEmployerSS = payrollItems.reduce((s, i) => s + (i.employer_social_security_tax || 0), 0);
  const totalEmployerMedicare = payrollItems.reduce((s, i) => s + (i.employer_medicare_tax || 0), 0);
  const totalEmployerTaxes = totalEmployerSS + totalEmployerMedicare;
  const totalDRTDeposit = totalSS + totalMedicare + totalEmployerTaxes;

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
            {isDraft && (
              <Button onClick={handleRunPayroll} disabled={processing}>
                {processing ? 'Calculating...' : 'Calculate Payroll'}
              </Button>
            )}
            {isCalculated && (
              <>
                <Button variant="outline" onClick={handleRunPayroll} disabled={processing}>
                  Recalculate
                </Button>
                <Button onClick={handleApprove} disabled={processing}>
                  Approve
                </Button>
              </>
            )}
            {isApproved && (
              <Button onClick={handleCommit} disabled={processing}>
                {processing ? 'Committing...' : 'Commit & Finalize'}
              </Button>
            )}
          </div>
        }
      />

      <div className="p-8 space-y-6">
        {error && (
          <div className="p-4 bg-red-50 border border-red-200 text-red-700 rounded-lg">
            {error}
          </div>
        )}

        {/* Status Bar */}
        <div className="flex items-center gap-3">
          <Badge
            variant={
              isCommitted ? 'success' : isApproved ? 'info' : isCalculated ? 'warning' : 'default'
            }
          >
            {statusConfig?.label || payPeriod.status}
          </Badge>
          {isCommitted && payPeriod.committed_at && (
            <span className="text-sm text-gray-500">
              Committed {new Date(payPeriod.committed_at).toLocaleString()}
            </span>
          )}
        </div>

        {/* Summary Cards */}
        {payrollItems.length > 0 && (
          <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-gray-500 uppercase tracking-wider">Employees</p>
                <p className="mt-1 text-2xl font-semibold text-gray-900">{payrollItems.length}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-gray-500 uppercase tracking-wider">Gross Pay</p>
                <p className="mt-1 text-2xl font-semibold text-gray-900">{formatCurrency(totalGross)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-gray-500 uppercase tracking-wider">Total Taxes</p>
                <p className="mt-1 text-2xl font-semibold text-red-600">{formatCurrency(totalDeductions)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-gray-500 uppercase tracking-wider">Net Pay</p>
                <p className="mt-1 text-2xl font-semibold text-green-600">{formatCurrency(totalNet)}</p>
              </CardContent>
            </Card>
            <Card className="border-amber-200 bg-amber-50">
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-amber-700 uppercase tracking-wider">DRT Deposit</p>
                <p className="mt-1 text-2xl font-semibold text-amber-800">{formatCurrency(totalDRTDeposit)}</p>
              </CardContent>
            </Card>
          </div>
        )}

        {/* Hours Input (Draft Mode) */}
        {isDraft && (
          <Card>
            <div className="p-4 border-b">
              <h3 className="font-semibold text-gray-900">Enter Hours</h3>
              <p className="text-sm text-gray-500 mt-1">
                Enter hours for each employee for this pay period. Default is 80 hours (biweekly).
              </p>
            </div>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Employee</TableHead>
                  <TableHead>Rate</TableHead>
                  <TableHead className="text-center">Regular Hours</TableHead>
                  <TableHead className="text-center">Overtime Hours</TableHead>
                  <TableHead className="text-right">Est. Gross</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {employees.map((emp) => {
                  const hours = hoursMap[String(emp.id)] || { regular: 80, overtime: 0 };
                  const estGross = (hours.regular * (emp.pay_rate || 0)) + (hours.overtime * (emp.pay_rate || 0) * 1.5);
                  return (
                    <TableRow key={emp.id}>
                      <TableCell>
                        <div>
                          <p className="font-medium text-gray-900">{emp.first_name} {emp.last_name}</p>
                          <p className="text-xs text-gray-500 capitalize">{emp.employment_type}</p>
                        </div>
                      </TableCell>
                      <TableCell className="text-gray-700">${emp.pay_rate?.toFixed(2)}/hr</TableCell>
                      <TableCell className="text-center">
                        <input
                          type="number"
                          value={hours.regular}
                          onChange={(e) => updateHours(emp.id, 'regular', parseFloat(e.target.value) || 0)}
                          className="w-20 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                          min={0}
                          step={0.5}
                        />
                      </TableCell>
                      <TableCell className="text-center">
                        <input
                          type="number"
                          value={hours.overtime}
                          onChange={(e) => updateHours(emp.id, 'overtime', parseFloat(e.target.value) || 0)}
                          className="w-20 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                          min={0}
                          step={0.5}
                        />
                      </TableCell>
                      <TableCell className="text-right font-medium text-gray-700">
                        {formatCurrency(estGross)}
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </Card>
        )}

        {/* Payroll Results Table (Calculated/Approved/Committed) */}
        {!isDraft && payrollItems.length > 0 && (
          <Card>
            <div className="p-4 border-b">
              <h3 className="font-semibold text-gray-900">Employee Payroll</h3>
            </div>
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Employee</TableHead>
                    <TableHead className="text-right">Hours</TableHead>
                    <TableHead className="text-right">Rate</TableHead>
                    <TableHead className="text-right">Gross</TableHead>
                    <TableHead className="text-right">FIT</TableHead>
                    <TableHead className="text-right">SS (6.2%)</TableHead>
                    <TableHead className="text-right">Medicare</TableHead>
                    <TableHead className="text-right">Total Ded.</TableHead>
                    <TableHead className="text-right">Net Pay</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {payrollItems.map((item) => (
                    <TableRow key={item.id}>
                      <TableCell>
                        <p className="font-medium text-gray-900">{item.employee_name}</p>
                      </TableCell>
                      <TableCell className="text-right">
                        {item.hours_worked || 0}
                        {(item.overtime_hours || 0) > 0 && (
                          <span className="text-orange-600 ml-1">+{item.overtime_hours} OT</span>
                        )}
                      </TableCell>
                      <TableCell className="text-right">${item.pay_rate?.toFixed(2)}/hr</TableCell>
                      <TableCell className="text-right font-medium">{formatCurrency(item.gross_pay || 0)}</TableCell>
                      <TableCell className="text-right text-red-600">{formatCurrency(item.withholding_tax || 0)}</TableCell>
                      <TableCell className="text-right text-red-600">{formatCurrency(item.social_security_tax || 0)}</TableCell>
                      <TableCell className="text-right text-red-600">{formatCurrency(item.medicare_tax || 0)}</TableCell>
                      <TableCell className="text-right text-red-600 font-medium">{formatCurrency(item.total_deductions || 0)}</TableCell>
                      <TableCell className="text-right font-bold text-green-600">{formatCurrency(item.net_pay || 0)}</TableCell>
                    </TableRow>
                  ))}
                  {/* Totals */}
                  <TableRow className="bg-gray-50 font-bold border-t-2">
                    <TableCell colSpan={3}>Totals ({payrollItems.length} employees)</TableCell>
                    <TableCell className="text-right">{formatCurrency(totalGross)}</TableCell>
                    <TableCell className="text-right text-red-600">{formatCurrency(totalWithholding)}</TableCell>
                    <TableCell className="text-right text-red-600">{formatCurrency(totalSS)}</TableCell>
                    <TableCell className="text-right text-red-600">{formatCurrency(totalMedicare)}</TableCell>
                    <TableCell className="text-right text-red-600">{formatCurrency(totalDeductions)}</TableCell>
                    <TableCell className="text-right text-green-600">{formatCurrency(totalNet)}</TableCell>
                  </TableRow>
                </TableBody>
              </Table>
            </div>
          </Card>
        )}

        {/* Employer Tax Obligations (Calculated/Approved/Committed) */}
        {!isDraft && payrollItems.length > 0 && (
          <Card className="border-amber-200">
            <div className="p-4 border-b border-amber-200 bg-amber-50">
              <h3 className="font-semibold text-amber-900">Employer Tax Obligations</h3>
              <p className="text-sm text-amber-700 mt-1">
                Amounts Cornerstone must deposit with Guam DRT in addition to employee withholdings
              </p>
            </div>
            <div className="p-4">
              <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                {/* Employee-side taxes */}
                <div>
                  <h4 className="text-sm font-semibold text-gray-500 uppercase tracking-wider mb-3">Employee Withholdings</h4>
                  <div className="space-y-2">
                    <div className="flex justify-between">
                      <span className="text-gray-600">Federal/Guam Income Tax</span>
                      <span className="font-medium">{formatCurrency(totalWithholding)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Social Security (6.2%)</span>
                      <span className="font-medium">{formatCurrency(totalSS)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Medicare (1.45%)</span>
                      <span className="font-medium">{formatCurrency(totalMedicare)}</span>
                    </div>
                    <div className="flex justify-between pt-2 border-t font-semibold">
                      <span>Subtotal (Employee)</span>
                      <span>{formatCurrency(totalWithholding + totalSS + totalMedicare)}</span>
                    </div>
                  </div>
                </div>
                {/* Employer-side taxes */}
                <div>
                  <h4 className="text-sm font-semibold text-gray-500 uppercase tracking-wider mb-3">Employer Match</h4>
                  <div className="space-y-2">
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employer Social Security (6.2%)</span>
                      <span className="font-medium">{formatCurrency(totalEmployerSS)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employer Medicare (1.45%)</span>
                      <span className="font-medium">{formatCurrency(totalEmployerMedicare)}</span>
                    </div>
                    <div className="flex justify-between pt-2 border-t font-semibold">
                      <span>Subtotal (Employer)</span>
                      <span>{formatCurrency(totalEmployerTaxes)}</span>
                    </div>
                  </div>
                </div>
              </div>
              {/* Grand total */}
              <div className="mt-6 pt-4 border-t-2 border-amber-300 flex justify-between items-center">
                <div>
                  <p className="text-lg font-bold text-amber-900">Total DRT Deposit</p>
                  <p className="text-sm text-amber-700">Employee withholdings + Employer SS & Medicare</p>
                </div>
                <p className="text-2xl font-bold text-amber-900">{formatCurrency(totalDRTDeposit)}</p>
              </div>
            </div>
          </Card>
        )}

        {/* Empty state for draft */}
        {isDraft && payrollItems.length === 0 && employees.length === 0 && (
          <div className="p-12 text-center text-gray-500">
            No active employees found. Add employees first before running payroll.
          </div>
        )}

        {payPeriod.notes && (
          <Card>
            <div className="p-4 border-b">
              <h3 className="font-semibold text-gray-900">Notes</h3>
            </div>
            <div className="p-4 text-gray-600">{payPeriod.notes}</div>
          </Card>
        )}
      </div>
    </div>
  );
}
