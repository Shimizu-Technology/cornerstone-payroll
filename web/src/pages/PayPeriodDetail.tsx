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
import type { PayPeriod, PayrollItem, Employee, TaxSyncStatus } from '@/types';

interface HoursEntry {
  regular: number;
  overtime: number;
}

const MAX_HOURS_PER_PERIOD = 200;
const toNumber = (value: unknown): number => {
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};

const taxSyncStatusConfig: Record<TaxSyncStatus, { label: string; variant: 'default' | 'success' | 'warning' | 'danger' | 'info' }> = {
  pending: { label: 'Tax Sync Pending', variant: 'default' },
  syncing: { label: 'Tax Syncing...', variant: 'info' },
  synced: { label: 'Tax Synced', variant: 'success' },
  failed: { label: 'Tax Sync Failed', variant: 'danger' },
};

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
  const [retryingSyncTax, setRetryingSyncTax] = useState(false);

  const loadPayPeriod = useCallback(async (periodId: number) => {
    try {
      setLoading(true);
      setError(null);

      // Load pay period and employees in parallel
      const [ppResponse, empResponse] = await Promise.all([
        payPeriodsApi.get(periodId),
        employeesApi.list({ status: 'active', per_page: 100 }),
      ]);

      setPayPeriod(ppResponse.pay_period);
      setPayrollItems(ppResponse.pay_period.payroll_items || []);
      setEmployees(empResponse.data);

      // Build hours map: use existing payroll items first, then fill defaults for remaining employees
      const hours: Record<string, HoursEntry> = {};
      (ppResponse.pay_period.payroll_items || []).forEach((item: PayrollItem) => {
        const employee = empResponse.data.find((emp: Employee) => emp.id === item.employee_id);
        const isSalary = employee?.employment_type === 'salary';
        hours[String(item.employee_id)] = {
          regular: isSalary ? 0 : (item.hours_worked || 80),
          overtime: isSalary ? 0 : (item.overtime_hours || 0),
        };
      });
      empResponse.data.forEach((emp: Employee) => {
        if (!hours[String(emp.id)]) {
          hours[String(emp.id)] = { regular: emp.employment_type === 'salary' ? 0 : 80, overtime: 0 };
        }
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
    }
  }, [id, loadPayPeriod]);

  const updateHours = (employeeId: number, field: 'regular' | 'overtime', value: number) => {
    const clampedValue = Math.max(0, Math.min(MAX_HOURS_PER_PERIOD, value));
    setHoursMap((prev) => ({
      ...prev,
      [String(employeeId)]: {
        ...prev[String(employeeId)],
        [field]: clampedValue,
      },
    }));
  };

  const handleRunPayroll = async () => {
    if (!payPeriod) return;
    try {
      setProcessing(true);
      setError(null);

      const invalidHours = Object.entries(hoursMap).find(([, entry]) => {
        return (
          entry.regular < 0 ||
          entry.overtime < 0 ||
          entry.regular > MAX_HOURS_PER_PERIOD ||
          entry.overtime > MAX_HOURS_PER_PERIOD
        );
      });
      if (invalidHours) {
        setError(`Hours must be between 0 and ${MAX_HOURS_PER_PERIOD} per period`);
        return;
      }

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

  const handleRetryTaxSync = async () => {
    if (!payPeriod) return;
    try {
      setRetryingSyncTax(true);
      setError(null);
      const response = await payPeriodsApi.retryTaxSync(payPeriod.id);
      setPayPeriod(response.pay_period);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to retry tax sync');
    } finally {
      setRetryingSyncTax(false);
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

  const syncStatus = payPeriod.tax_sync_status as TaxSyncStatus | null | undefined;
  const syncConfig = syncStatus ? taxSyncStatusConfig[syncStatus] : null;
  const canRetrySyncTax = isCommitted && (syncStatus === 'failed' || syncStatus === 'pending');

  // Summaries
  const totalGross = payrollItems.reduce((s, i) => s + toNumber(i.gross_pay), 0);
  const totalWithholding = payrollItems.reduce((s, i) => s + toNumber(i.withholding_tax), 0);
  const totalSS = payrollItems.reduce((s, i) => s + toNumber(i.social_security_tax), 0);
  const totalMedicare = payrollItems.reduce((s, i) => s + toNumber(i.medicare_tax), 0);
  const totalDeductions = payrollItems.reduce((s, i) => s + toNumber(i.total_deductions), 0);
  const totalNet = payrollItems.reduce((s, i) => s + toNumber(i.net_pay), 0);
  const totalEmployerSS = payrollItems.reduce((s, i) => s + toNumber(i.employer_social_security_tax), 0);
  const totalEmployerMedicare = payrollItems.reduce((s, i) => s + toNumber(i.employer_medicare_tax), 0);
  const totalEmployerTaxes = totalEmployerSS + totalEmployerMedicare;
  const totalDRTDeposit = totalWithholding + totalSS + totalMedicare + totalEmployerTaxes;

  return (
    <div>
      <Header
        title={`Pay Period: ${formatDateRange(payPeriod.start_date, payPeriod.end_date)}`}
        description={`Pay Date: ${new Date(payPeriod.pay_date).toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })}`}
        actions={
          <div className="flex w-full flex-wrap gap-2 sm:w-auto sm:justify-end">
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

      <div className="p-4 space-y-6 sm:p-6 lg:p-8">
        {error && (
          <div className="p-4 bg-red-50 border border-red-200 text-red-700 rounded-lg">
            {error}
          </div>
        )}

        {/* Status Bar */}
        <div className="flex flex-wrap items-center gap-3">
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
          {isCommitted && syncConfig && (
            <>
              <Badge variant={syncConfig.variant}>
                {syncConfig.label}
              </Badge>
              {syncStatus === 'synced' && payPeriod.tax_synced_at && (
                <span className="text-sm text-gray-500">
                  Synced {new Date(payPeriod.tax_synced_at).toLocaleString()}
                </span>
              )}
              {syncStatus === 'failed' && payPeriod.tax_sync_last_error && (
                <span className="text-sm text-red-600 max-w-md truncate" title={payPeriod.tax_sync_last_error}>
                  {payPeriod.tax_sync_last_error}
                </span>
              )}
              {canRetrySyncTax && (
                <Button
                  variant="outline"
                  size="sm"
                  onClick={handleRetryTaxSync}
                  disabled={retryingSyncTax}
                >
                  {retryingSyncTax ? 'Retrying...' : 'Retry Tax Sync'}
                </Button>
              )}
              {payPeriod.tax_sync_attempts != null && payPeriod.tax_sync_attempts > 0 && syncStatus !== 'synced' && (
                <span className="text-xs text-gray-400">
                  Attempt {payPeriod.tax_sync_attempts}/{5}
                </span>
              )}
            </>
          )}
        </div>

        {/* Summary Cards */}
        {payrollItems.length > 0 && (
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-5 lg:gap-4">
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-gray-500 uppercase tracking-wider">Employees</p>
                <p className="mt-1 text-2xl font-semibold text-gray-900">{payrollItems.length}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-gray-500 uppercase tracking-wider">Gross Pay</p>
                <p className="mt-1 wrap-break-word text-xl font-semibold text-gray-900 sm:text-2xl">{formatCurrency(totalGross)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-gray-500 uppercase tracking-wider">Total Taxes</p>
                <p className="mt-1 wrap-break-word text-xl font-semibold text-red-600 sm:text-2xl">{formatCurrency(totalDeductions)}</p>
              </CardContent>
            </Card>
            <Card>
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-gray-500 uppercase tracking-wider">Net Pay</p>
                <p className="mt-1 wrap-break-word text-xl font-semibold text-green-600 sm:text-2xl">{formatCurrency(totalNet)}</p>
              </CardContent>
            </Card>
            <Card className="border-amber-200 bg-amber-50">
              <CardContent className="pt-5 pb-4">
                <p className="text-xs font-medium text-amber-700 uppercase tracking-wider">DRT Deposit</p>
                <p className="mt-1 wrap-break-word text-xl font-semibold text-amber-800 sm:text-2xl">{formatCurrency(totalDRTDeposit)}</p>
              </CardContent>
            </Card>
          </div>
        )}

        {/* Hours Input (Draft Mode) */}
        {(isDraft || isCalculated) && (
          <Card>
            <div className="p-4 border-b">
              <h3 className="font-semibold text-gray-900">
                {isCalculated ? 'Adjust Hours' : 'Enter Hours'}
              </h3>
              <p className="text-sm text-gray-500 mt-1">
                {isCalculated
                  ? 'Update hours and click Recalculate to refresh payroll amounts.'
                  : 'Enter hours for each employee for this pay period. Default is 80 hours (biweekly).'}
              </p>
            </div>
            <div className="overflow-x-auto">
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
                    const payRate = toNumber(emp.pay_rate);
                    const estGross = emp.employment_type === 'salary'
                      ? payRate / 26  // Biweekly salary
                      : (hours.regular * payRate) + (hours.overtime * payRate * 1.5);
                    return (
                      <TableRow key={emp.id}>
                        <TableCell>
                          <div>
                            <p className="font-medium text-gray-900">{emp.first_name} {emp.last_name}</p>
                            <p className="text-xs text-gray-500 capitalize">{emp.employment_type}</p>
                          </div>
                        </TableCell>
                        <TableCell className="text-gray-700">
                          {emp.employment_type === 'salary'
                            ? `$${(payRate / 26).toFixed(2)}/period`
                            : `$${payRate.toFixed(2)}/hr`}
                        </TableCell>
                        <TableCell className="text-center">
                          <input
                            type="number"
                            value={hours.regular}
                            onChange={(e) => updateHours(emp.id, 'regular', parseFloat(e.target.value) || 0)}
                            className="w-20 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 disabled:bg-gray-100 disabled:text-gray-400"
                            min={0}
                            step={0.5}
                            disabled={emp.employment_type === 'salary'}
                          />
                        </TableCell>
                        <TableCell className="text-center">
                          <input
                            type="number"
                            value={hours.overtime}
                            onChange={(e) => updateHours(emp.id, 'overtime', parseFloat(e.target.value) || 0)}
                            className="w-20 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 disabled:bg-gray-100 disabled:text-gray-400"
                            min={0}
                            step={0.5}
                            disabled={emp.employment_type === 'salary'}
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
            </div>
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
                        {item.employment_type === 'salary' ? (
                          <span className="text-gray-400">—</span>
                        ) : (
                          <>
                            {item.hours_worked || 0}
                            {(item.overtime_hours || 0) > 0 && (
                              <span className="text-orange-600 ml-1">+{item.overtime_hours} OT</span>
                            )}
                          </>
                        )}
                      </TableCell>
                      <TableCell className="text-right">
                        {(() => {
                          const payRate = toNumber(item.pay_rate);
                          return item.employment_type === 'salary'
                            ? `$${(payRate / 26).toFixed(2)}/period`
                            : `$${payRate.toFixed(2)}/hr`;
                        })()}
                      </TableCell>
                      <TableCell className="text-right font-medium">{formatCurrency(toNumber(item.gross_pay))}</TableCell>
                      <TableCell className="text-right text-red-600">{formatCurrency(toNumber(item.withholding_tax))}</TableCell>
                      <TableCell className="text-right text-red-600">{formatCurrency(toNumber(item.social_security_tax))}</TableCell>
                      <TableCell className="text-right text-red-600">{formatCurrency(toNumber(item.medicare_tax))}</TableCell>
                      <TableCell className="text-right text-red-600 font-medium">{formatCurrency(toNumber(item.total_deductions))}</TableCell>
                      <TableCell className="text-right font-bold text-green-600">{formatCurrency(toNumber(item.net_pay))}</TableCell>
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
              <div className="mt-6 flex flex-col gap-3 border-t-2 border-amber-300 pt-4 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <p className="text-lg font-bold text-amber-900">Total DRT Deposit</p>
                  <p className="text-sm text-amber-700">Employee withholdings + Employer SS & Medicare</p>
                </div>
                <p className="wrap-break-word text-2xl font-bold text-amber-900">{formatCurrency(totalDRTDeposit)}</p>
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
