import { useEffect, useState, useCallback, Fragment } from 'react';
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
import { ImportModal } from '@/components/import/ImportModal';
import { ChecksPanel } from '@/components/payroll/ChecksPanel';
import { CorrectionPanel } from '@/components/payroll/CorrectionPanel';
import { PayrollItemEditModal } from '@/components/payroll/PayrollItemEditModal';
import { ReportsDownloadPanel } from '@/components/reports/ReportsDownloadPanel';
import { NonEmployeeChecksPanel } from '@/components/checks/NonEmployeeChecksPanel';
import type { PayPeriod, PayrollItem, Employee, PayrollItemWageRateHours, TaxSyncStatus } from '@/types';

interface HoursEntry {
  regular: number;
  overtime: number;
  wage_rates?: PayrollItemWageRateHours[];
}

const MAX_HOURS_PER_PERIOD = 200;
const toNumber = (value: unknown): number => {
  const parsed = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};

function templateWageRates(employee: Employee, payrollItem?: PayrollItem): PayrollItemWageRateHours[] {
  const existing = payrollItem?.wage_rate_hours;
  if (existing && existing.length > 0) {
    return existing.map((entry) => ({
      employee_wage_rate_id: entry.employee_wage_rate_id,
      label: entry.label,
      rate: toNumber(entry.rate),
      regular_hours: toNumber(entry.regular_hours),
      overtime_hours: toNumber(entry.overtime_hours),
      holiday_hours: toNumber(entry.holiday_hours),
      pto_hours: toNumber(entry.pto_hours),
      is_primary: entry.is_primary ?? false,
      active: entry.active ?? true,
    }));
  }

  const configuredRates = employee.wage_rates || [];
  const defaultPrimaryHours = configuredRates.length > 1 ? 0 : toNumber(payrollItem?.hours_worked ?? 80);

  return configuredRates.map((rate) => ({
    employee_wage_rate_id: rate.id,
    label: rate.label,
    rate: toNumber(rate.rate),
    regular_hours: rate.is_primary ? defaultPrimaryHours : 0,
    overtime_hours: rate.is_primary ? toNumber(payrollItem?.overtime_hours ?? 0) : 0,
    holiday_hours: rate.is_primary ? toNumber(payrollItem?.holiday_hours ?? 0) : 0,
    pto_hours: rate.is_primary ? toNumber(payrollItem?.pto_hours ?? 0) : 0,
    is_primary: rate.is_primary,
    active: rate.active,
  }));
}

function buildHoursMap(payrollItems: PayrollItem[], employees: Employee[]): Record<string, HoursEntry> {
  const hours: Record<string, HoursEntry> = {};
  const employeeMap = new Map(employees.map((emp) => [emp.id, emp]));

  payrollItems.forEach((item) => {
    const employee = employeeMap.get(item.employee_id);
    const noHours = employee?.employment_type === 'salary' || (employee?.employment_type === 'contractor' && employee?.contractor_pay_type !== 'hourly');
    const wageRates = employee && (employee.employment_type === 'hourly' || (employee.employment_type === 'contractor' && employee.contractor_pay_type === 'hourly'))
      ? templateWageRates(employee, item)
      : [];
    hours[String(item.employee_id)] = {
      regular: noHours ? 0 : (item.hours_worked || 80),
      overtime: noHours ? 0 : (item.overtime_hours || 0),
      wage_rates: wageRates.length > 0 ? wageRates : undefined,
    };
  });

  employees.forEach((emp) => {
    if (!hours[String(emp.id)]) {
      const noHours = emp.employment_type === 'salary' || (emp.employment_type === 'contractor' && emp.contractor_pay_type !== 'hourly');
      const wageRates = emp.employment_type === 'hourly' || (emp.employment_type === 'contractor' && emp.contractor_pay_type === 'hourly')
        ? templateWageRates(emp)
        : [];
      const regularDefault = wageRates.length > 1
        ? wageRates.reduce((sum, rate) => sum + toNumber(rate.regular_hours), 0)
        : (noHours ? 0 : 80);
      hours[String(emp.id)] = {
        regular: regularDefault,
        overtime: 0,
        wage_rates: wageRates.length > 0 ? wageRates : undefined,
      };
    }
  });

  return hours;
}

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
  const [importModalOpen, setImportModalOpen] = useState(false);
  const [editingItem, setEditingItem] = useState<PayrollItem | null>(null);

  const loadAllActiveEmployees = useCallback(async () => {
    const allEmployees: Employee[] = [];
    let page = 1;
    let totalPages = 1;

    try {
      do {
        const response = await employeesApi.list({ status: 'active', per_page: 100, page });
        allEmployees.push(...response.data);
        totalPages = response.meta.total_pages;
        page += 1;
      } while (page <= totalPages);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Unknown error';
      throw new Error(`Failed to load active employees page ${page}: ${message}`);
    }

    return allEmployees;
  }, []);

  const loadPayPeriod = useCallback(async (periodId: number) => {
    try {
      setLoading(true);
      setError(null);

      // Load pay period and employees in parallel
      const [ppResponse, empResponse] = await Promise.all([
        payPeriodsApi.get(periodId),
        loadAllActiveEmployees(),
      ]);

      setPayPeriod(ppResponse.pay_period);
      setPayrollItems(ppResponse.pay_period.payroll_items || []);
      setEmployees(empResponse);
      setHoursMap(buildHoursMap(ppResponse.pay_period.payroll_items || [], empResponse));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load pay period');
    } finally {
      setLoading(false);
    }
  }, [loadAllActiveEmployees]);

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

  const updateWageRateHours = (
    employeeId: number,
    index: number,
    field: 'regular_hours' | 'overtime_hours',
    value: number
  ) => {
    const clampedValue = Math.max(0, Math.min(MAX_HOURS_PER_PERIOD, value));
    setHoursMap((prev) => {
      const current = prev[String(employeeId)];
      const wageRates = [...(current?.wage_rates || [])];
      if (!wageRates[index]) return prev;

      wageRates[index] = {
        ...wageRates[index],
        [field]: clampedValue,
      };

      return {
        ...prev,
        [String(employeeId)]: {
          regular: wageRates.reduce((sum, entry) => sum + toNumber(entry.regular_hours), 0),
          overtime: wageRates.reduce((sum, entry) => sum + toNumber(entry.overtime_hours), 0),
          wage_rates: wageRates,
        },
      };
    });
  };

  const handleRunPayroll = async () => {
    if (!payPeriod) return;
    try {
      setProcessing(true);
      setError(null);

      const invalidHours = Object.entries(hoursMap).find(([, entry]) => {
        const rateEntryInvalid = (entry.wage_rates || []).some((rate) => (
          toNumber(rate.regular_hours) < 0 ||
          toNumber(rate.overtime_hours) < 0 ||
          toNumber(rate.regular_hours) > MAX_HOURS_PER_PERIOD ||
          toNumber(rate.overtime_hours) > MAX_HOURS_PER_PERIOD
        ));

        return (
          entry.regular < 0 ||
          entry.overtime < 0 ||
          entry.regular > MAX_HOURS_PER_PERIOD ||
          entry.overtime > MAX_HOURS_PER_PERIOD ||
          rateEntryInvalid
        );
      });
      if (invalidHours) {
        setError(`Hours must be between 0 and ${MAX_HOURS_PER_PERIOD} per period`);
        return;
      }

      // Build hours payload
      const hours: Record<string, { regular?: number; overtime?: number; wage_rates?: PayrollItemWageRateHours[] }> = {};
      Object.entries(hoursMap).forEach(([empId, entry]) => {
        hours[empId] = entry.wage_rates && entry.wage_rates.length > 1
          ? {
              regular: entry.regular,
              overtime: entry.overtime,
              wage_rates: entry.wage_rates,
            }
          : { regular: entry.regular, overtime: entry.overtime };
      });

      const response = await payPeriodsApi.runPayroll(payPeriod.id, {
        hours,
      });
      setPayPeriod(response.pay_period);
      setPayrollItems(response.pay_period.payroll_items || []);
      setHoursMap(buildHoursMap(response.pay_period.payroll_items || [], employees));

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

  const handleImportComplete = (updatedPayPeriod: PayPeriod & { payroll_items?: PayrollItem[] }) => {
    setPayPeriod(updatedPayPeriod);
    setPayrollItems(updatedPayPeriod.payroll_items || []);
    setHoursMap(buildHoursMap(updatedPayPeriod.payroll_items || [], employees));
  };

  const handlePayrollItemSaved = (updated: PayrollItem) => {
    setPayrollItems((prev) =>
      prev.map((item) => (item.id === updated.id ? updated : item))
    );
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
  const isVoided = payPeriod.correction_status === 'voided';
  const isCorrection = payPeriod.correction_status === 'correction';
  const statusConfig = payPeriodStatusConfig[payPeriod.status];

  const syncStatus = payPeriod.tax_sync_status as TaxSyncStatus | null | undefined;
  const syncConfig = syncStatus ? taxSyncStatusConfig[syncStatus] : null;
  const MAX_SYNC_ATTEMPTS = 5;
  const canRetrySyncTax = isCommitted && (syncStatus === 'failed' || syncStatus === 'pending');
  const canImportMosa = isDraft;

  // Summaries
  const w2Items = payrollItems.filter(i => i.employment_type !== 'contractor');
  const contractorItems = payrollItems.filter(i => i.employment_type === 'contractor');
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
  const totalContractorPay = contractorItems.reduce((s, i) => s + toNumber(i.gross_pay), 0);

  const employeeLookup = new Map(employees.map((emp) => [emp.id, emp]));
  const typeOrder: Record<string, number> = { salary: 0, hourly: 1, contractor: 2 };
  const sortedPayrollItems = [...payrollItems].sort((a, b) => {
    const orderA = typeOrder[a.employment_type] ?? 1;
    const orderB = typeOrder[b.employment_type] ?? 1;
    if (orderA !== orderB) return orderA - orderB;
    return (a.employee_name || '').localeCompare(b.employee_name || '');
  });

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
              <>
                {canImportMosa && (
                  <Button variant="outline" onClick={() => setImportModalOpen(true)}>
                    Import (MoSa)
                  </Button>
                )}
                <Button onClick={handleRunPayroll} disabled={processing}>
                  {processing ? 'Calculating...' : 'Calculate Payroll'}
                </Button>
              </>
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
              isVoided ? 'danger' :
              isCommitted ? 'success' : isApproved ? 'info' : isCalculated ? 'warning' : 'default'
            }
          >
            {isVoided ? 'Voided' : statusConfig?.label || payPeriod.status}
          </Badge>
          {isCorrection && (
            <Badge variant="warning">Correction Run</Badge>
          )}
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
                  Attempt {payPeriod.tax_sync_attempts}/{MAX_SYNC_ATTEMPTS}
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
            {contractorItems.length > 0 && (
              <Card className="border-emerald-200 bg-emerald-50">
                <CardContent className="pt-5 pb-4">
                  <p className="text-xs font-medium text-emerald-700 uppercase tracking-wider">1099 Contractors ({contractorItems.length})</p>
                  <p className="mt-1 wrap-break-word text-xl font-semibold text-emerald-800 sm:text-2xl">{formatCurrency(totalContractorPay)}</p>
                </CardContent>
              </Card>
            )}
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
                  : 'Enter hours for each employee for this pay period. Single-rate hourly employees default to 80 hours; multi-rate rows start at 0.'}
              </p>
            </div>
            <div className="overflow-x-auto">
              <Table className="min-w-[1380px]">
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-[220px]">Employee</TableHead>
                    <TableHead className="w-[300px]">Rate</TableHead>
                    <TableHead className="w-[300px] text-center">Regular Hours</TableHead>
                    <TableHead className="w-[300px] text-center">Overtime Hours</TableHead>
                    <TableHead className="w-[160px] text-right">Est. Gross</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {(() => {
                    const payrollEmployeeIds = new Set(payrollItems.map((pi) => pi.employee_id));
                    const displayEmployees = isCalculated
                      ? employees.filter((emp) => payrollEmployeeIds.has(emp.id))
                      : employees;
                    return displayEmployees.map((emp) => {
                    const hours = hoursMap[String(emp.id)] || { regular: 80, overtime: 0 };
                    const payRate = toNumber(emp.pay_rate);
                    const isContractorHourly = emp.employment_type === 'contractor' && emp.contractor_pay_type === 'hourly';
                    const isContractorFlat = emp.employment_type === 'contractor' && emp.contractor_pay_type !== 'hourly';
                    const activeWageRates = (hours.wage_rates || []).filter((rate) => rate.active !== false);
                    const hasMultiRate = (emp.employment_type === 'hourly' || isContractorHourly) && activeWageRates.length > 1;
                    const noHoursType = emp.employment_type === 'salary' || isContractorFlat;
                    const estGross = emp.employment_type === 'salary'
                      ? payRate / 26
                      : isContractorFlat
                      ? payRate
                      : hasMultiRate
                      ? activeWageRates.reduce(
                          (sum, rate) => sum + (toNumber(rate.regular_hours) * toNumber(rate.rate)) + (toNumber(rate.overtime_hours) * toNumber(rate.rate) * 1.5),
                          0
                        )
                      : (hours.regular * payRate) + (hours.overtime * payRate * 1.5);
                    return (
                      <TableRow key={emp.id} className={emp.employment_type === 'contractor' ? 'bg-emerald-50/30' : undefined}>
                        <TableCell>
                          <div>
                            <p className="font-medium text-gray-900">{emp.first_name} {emp.last_name}</p>
                            <p className="text-xs text-gray-500 capitalize">
                              {isContractorHourly ? '1099 (Hourly)' : isContractorFlat ? '1099 (Flat Fee)' : emp.employment_type}
                            </p>
                          </div>
                        </TableCell>
                        <TableCell className="text-gray-700">
                          {emp.employment_type === 'salary' ? (
                            `$${(payRate / 26).toFixed(2)}/period`
                          ) : isContractorFlat ? (
                            `$${payRate.toFixed(2)}/period`
                          ) : hasMultiRate ? (
                            <div className="space-y-1 text-left">
                              {activeWageRates.map((rate) => (
                                <div key={`${emp.id}-${rate.label}`} className="text-xs">
                                  <span className="font-medium text-gray-900">{rate.label}</span>{' '}
                                  <span className="text-gray-500">${toNumber(rate.rate).toFixed(2)}/hr</span>
                                </div>
                              ))}
                            </div>
                          ) : (
                            `$${payRate.toFixed(2)}/hr`
                          )}
                        </TableCell>
                        <TableCell className="text-center align-top">
                          {hasMultiRate ? (
                            <div className="space-y-2">
                              {activeWageRates.map((rate, index) => (
                                <div key={`${emp.id}-${rate.label}-regular`} className="grid grid-cols-[12rem_5rem] items-center gap-3">
                                  <span
                                    className="text-left text-xs leading-tight text-gray-500 whitespace-nowrap"
                                    title={rate.label}
                                  >
                                    {rate.label}
                                  </span>
                                  <input
                                    type="number"
                                    value={toNumber(rate.regular_hours)}
                                    onChange={(e) => updateWageRateHours(emp.id, index, 'regular_hours', parseFloat(e.target.value) || 0)}
                                    className="w-20 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                                    min={0}
                                    step={0.5}
                                  />
                                </div>
                              ))}
                            </div>
                          ) : (
                            <input
                              type="number"
                              value={hours.regular}
                              onChange={(e) => updateHours(emp.id, 'regular', parseFloat(e.target.value) || 0)}
                              className="w-20 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 disabled:bg-gray-100 disabled:text-gray-400"
                              min={0}
                              step={0.5}
                              disabled={noHoursType}
                            />
                          )}
                        </TableCell>
                        <TableCell className="text-center align-top">
                          {hasMultiRate ? (
                            <div className="space-y-2">
                              {activeWageRates.map((rate, index) => (
                                <div key={`${emp.id}-${rate.label}-overtime`} className="grid grid-cols-[12rem_5rem] items-center gap-3">
                                  <span
                                    className="text-left text-xs leading-tight text-gray-500 whitespace-nowrap"
                                    title={rate.label}
                                  >
                                    {rate.label}
                                  </span>
                                  <input
                                    type="number"
                                    value={toNumber(rate.overtime_hours)}
                                    onChange={(e) => updateWageRateHours(emp.id, index, 'overtime_hours', parseFloat(e.target.value) || 0)}
                                    className="w-20 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                                    min={0}
                                    step={0.5}
                                  />
                                </div>
                              ))}
                            </div>
                          ) : (
                            <input
                              type="number"
                              value={hours.overtime}
                              onChange={(e) => updateHours(emp.id, 'overtime', parseFloat(e.target.value) || 0)}
                              className="w-20 text-center border border-gray-300 rounded-md px-2 py-1.5 text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 disabled:bg-gray-100 disabled:text-gray-400"
                              min={0}
                              step={0.5}
                              disabled={noHoursType}
                            />
                          )}
                        </TableCell>
                        <TableCell className="text-right font-medium text-gray-700">
                          {formatCurrency(estGross)}
                        </TableCell>
                      </TableRow>
                    );
                    });
                  })()}
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
              <p className="text-sm text-gray-500 mt-1">
                Salary employees listed first, then hourly alphabetically.
              </p>
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
                    {(isCalculated) && <TableHead className="text-center w-16"></TableHead>}
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {sortedPayrollItems.map((item, idx) => {
                    const isManual = !item.import_source;
                    const isSalary = item.employment_type === 'salary';
                    const isContractor = item.employment_type === 'contractor';
                    const empRecord = employeeLookup.get(item.employee_id);
                    const isContractorHourly = isContractor && empRecord?.contractor_pay_type === 'hourly';
                    const isContractorFlat = isContractor && empRecord?.contractor_pay_type !== 'hourly';
                    const itemWageRates = (item.wage_rate_hours || []).filter((rate) => rate.active !== false);
                    const hasMultiRateResults = (item.employment_type === 'hourly' || isContractorHourly) && itemWageRates.length > 1;
                    const prevType = idx > 0 ? sortedPayrollItems[idx - 1]?.employment_type : null;
                    const showSalaryDivider = isSalary && idx === 0;
                    const showHourlyDivider = item.employment_type === 'hourly' && prevType !== 'hourly';
                    const showContractorDivider = isContractor && prevType !== 'contractor';

                    return (
                      <Fragment key={item.id}>
                        {showSalaryDivider && (
                          <TableRow className="bg-indigo-50">
                            <TableCell colSpan={isCalculated ? 10 : 9} className="py-1.5 text-xs font-semibold text-indigo-700 uppercase tracking-wider">
                              Salary Employees
                            </TableCell>
                          </TableRow>
                        )}
                        {showHourlyDivider && (
                          <TableRow className="bg-gray-100">
                            <TableCell colSpan={isCalculated ? 10 : 9} className="py-1.5 text-xs font-semibold text-gray-600 uppercase tracking-wider">
                              Hourly Employees
                            </TableCell>
                          </TableRow>
                        )}
                        {showContractorDivider && (
                          <TableRow className="bg-emerald-50">
                            <TableCell colSpan={isCalculated ? 10 : 9} className="py-1.5 text-xs font-semibold text-emerald-700 uppercase tracking-wider">
                              1099 Contractors
                            </TableCell>
                          </TableRow>
                        )}
                        <TableRow key={item.id} className={isContractor ? 'bg-emerald-50/30' : (isManual || (isSalary && item.salary_override)) ? 'bg-amber-50/50' : undefined}>
                          <TableCell>
                            <div className="flex items-center gap-2">
                              <div>
                                <p className="font-medium text-gray-900">{item.employee_name}</p>
                                <div className="flex items-center gap-1.5 mt-0.5">
                                  {isSalary && (
                                    <span className="inline-flex items-center rounded-full bg-indigo-100 px-1.5 py-0.5 text-[10px] font-medium text-indigo-700">
                                      Salary
                                    </span>
                                  )}
                                  {isContractor && (
                                    <span className="inline-flex items-center rounded-full bg-emerald-100 px-1.5 py-0.5 text-[10px] font-medium text-emerald-700">
                                      1099
                                    </span>
                                  )}
                                  {hasMultiRateResults && (
                                    <span className="inline-flex items-center rounded-full bg-blue-100 px-1.5 py-0.5 text-[10px] font-medium text-blue-700">
                                      Multi-rate
                                    </span>
                                  )}
                                  {(isManual || (isSalary && item.salary_override)) && !isContractor && (
                                    <span className="inline-flex items-center rounded-full bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-700">
                                      Manual
                                    </span>
                                  )}
                                </div>
                              </div>
                            </div>
                          </TableCell>
                          <TableCell className="text-right">
                            {isSalary || isContractorFlat ? (
                              <span className="text-gray-400">—</span>
                            ) : hasMultiRateResults ? (
                              <div className="space-y-1 text-left inline-block">
                                {itemWageRates.map((rate) => {
                                  const totalHours = toNumber(rate.regular_hours) + toNumber(rate.overtime_hours);
                                  return (
                                    <div key={`${item.id}-${rate.label}-hours`} className="text-xs">
                                      <span className="font-medium text-gray-900">{rate.label}</span>{' '}
                                      <span className="text-gray-600">{totalHours}</span>
                                      {toNumber(rate.overtime_hours) > 0 && (
                                        <span className="text-orange-600 ml-1">({toNumber(rate.overtime_hours)} OT)</span>
                                      )}
                                    </div>
                                  );
                                })}
                              </div>
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
                              if (isSalary) {
                                const override = item.salary_override ? toNumber(item.salary_override) : 0;
                                if (override > 0) return <span className="text-indigo-600" title="Salary Override">{formatCurrency(override)}/period</span>;
                                const payRate = toNumber(item.pay_rate);
                                return `${formatCurrency(payRate / 26)}/period`;
                              }
                              if (isContractorFlat) {
                                const override = item.salary_override ? toNumber(item.salary_override) : 0;
                                if (override > 0) return <span className="text-emerald-600" title="Flat Fee Override">{formatCurrency(override)}/period</span>;
                                return <span className="text-emerald-600">{formatCurrency(toNumber(item.pay_rate))}/period</span>;
                              }
                              if (hasMultiRateResults) {
                                return (
                                  <div className="space-y-1 text-left inline-block">
                                    {itemWageRates.map((rate) => (
                                      <div key={`${item.id}-${rate.label}-rate`} className="text-xs">
                                        <span className="font-medium text-gray-900">{rate.label}</span>{' '}
                                        <span className="text-gray-500">${toNumber(rate.rate).toFixed(2)}/hr</span>
                                      </div>
                                    ))}
                                  </div>
                                );
                              }
                              if (isContractorHourly) {
                                return `$${toNumber(item.pay_rate).toFixed(2)}/hr`;
                              }
                              return `$${toNumber(item.pay_rate).toFixed(2)}/hr`;
                            })()}
                          </TableCell>
                          <TableCell className="text-right font-medium">{formatCurrency(toNumber(item.gross_pay))}</TableCell>
                          <TableCell className="text-right text-red-600">{formatCurrency(toNumber(item.withholding_tax))}</TableCell>
                          <TableCell className="text-right text-red-600">{formatCurrency(toNumber(item.social_security_tax))}</TableCell>
                          <TableCell className="text-right text-red-600">{formatCurrency(toNumber(item.medicare_tax))}</TableCell>
                          <TableCell className="text-right text-red-600 font-medium">{formatCurrency(toNumber(item.total_deductions))}</TableCell>
                          <TableCell className="text-right font-bold text-green-600">{formatCurrency(toNumber(item.net_pay))}</TableCell>
                          {(isCalculated) && (
                            <TableCell className="text-center">
                              <button
                                onClick={() => setEditingItem(item)}
                                className="text-xs text-blue-600 hover:text-blue-800 hover:underline font-medium"
                              >
                                Edit
                              </button>
                            </TableCell>
                          )}
                        </TableRow>
                      </Fragment>
                    );
                  })}
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
                Amounts Cornerstone must deposit with Guam DRT
              </p>
            </div>
            <div className="p-4">
              <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                {/* FIT Column */}
                <div>
                  <h4 className="text-sm font-semibold text-gray-500 uppercase tracking-wider mb-3">Federal / Guam Income Tax</h4>
                  <div className="space-y-2">
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employee FIT Withheld</span>
                      <span className="font-medium">{formatCurrency(totalWithholding)}</span>
                    </div>
                    <div className="flex justify-between pt-2 border-t font-semibold">
                      <span>FIT Subtotal</span>
                      <span>{formatCurrency(totalWithholding)}</span>
                    </div>
                  </div>
                </div>
                {/* SS + Medicare Column */}
                <div>
                  <h4 className="text-sm font-semibold text-gray-500 uppercase tracking-wider mb-3">Social Security & Medicare (FICA)</h4>
                  <div className="space-y-2">
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employee Social Security (6.2%)</span>
                      <span className="font-medium">{formatCurrency(totalSS)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employer Social Security (6.2%)</span>
                      <span className="font-medium">{formatCurrency(totalEmployerSS)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employee Medicare (1.45%)</span>
                      <span className="font-medium">{formatCurrency(totalMedicare)}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-gray-600">Employer Medicare (1.45%)</span>
                      <span className="font-medium">{formatCurrency(totalEmployerMedicare)}</span>
                    </div>
                    <div className="flex justify-between pt-2 border-t font-semibold">
                      <span>FICA Subtotal</span>
                      <span>{formatCurrency(totalSS + totalEmployerSS + totalMedicare + totalEmployerMedicare)}</span>
                    </div>
                  </div>
                </div>
              </div>
              {/* Grand total */}
              <div className="mt-6 flex flex-col gap-3 border-t-2 border-amber-300 pt-4 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <p className="text-lg font-bold text-amber-900">Total DRT Deposit</p>
                  <p className="text-sm text-amber-700">FIT + Employee & Employer SS & Medicare</p>
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

        {/* CPR-66: Checks Panel — only for committed pay periods */}
        {isCommitted && (
          <Card>
            <div className="p-4 border-b flex items-center justify-between">
              <h3 className="font-semibold text-gray-900">Checks</h3>
              <a
                href={`/settings/checks`}
                className="text-xs text-blue-600 hover:underline"
              >
                Check Settings ›
              </a>
            </div>
            <div className="p-4">
              <ChecksPanel payPeriod={payPeriod} />
            </div>
          </Card>
        )}

        {/* Non-Employee Checks — for committed pay periods */}
        {isCommitted && payPeriod.company_id && (
          <NonEmployeeChecksPanel
            payPeriodId={payPeriod.id}
            companyId={payPeriod.company_id}
          />
        )}

        {/* Reports Download Panel — for calculated/approved/committed */}
        {!isDraft && payrollItems.length > 0 && (
          <ReportsDownloadPanel
            payPeriodId={payPeriod.id}
            payPeriodStatus={payPeriod.status}
          />
        )}

        {/* CPR-71: Correction Panel — committed and voided periods */}
        {(isCommitted || isVoided || isCorrection) && (
          <Card>
            <div className="p-4 border-b">
              <h3 className="font-semibold text-gray-900">Payroll Corrections</h3>
              <p className="text-sm text-gray-500 mt-0.5">
                Void this period, create a correction re-run, or review correction history.
              </p>
            </div>
            <div className="p-4">
              <CorrectionPanel
                payPeriod={payPeriod}
                onPayPeriodChange={(updated) => {
                  setPayPeriod(updated);
                  if (updated.payroll_items) {
                    setPayrollItems(updated.payroll_items);
                  }
                }}
              />
            </div>
          </Card>
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

      {/* Import Modal */}
      <ImportModal
        open={importModalOpen}
        onOpenChange={setImportModalOpen}
        payPeriodId={payPeriod.id}
        onImportComplete={handleImportComplete}
      />

      {/* Payroll Item Edit Modal */}
      <PayrollItemEditModal
        open={editingItem !== null}
        onOpenChange={(isOpen) => { if (!isOpen) setEditingItem(null); }}
        payPeriodId={payPeriod.id}
        item={editingItem}
        onSaved={handlePayrollItemSaved}
        contractorPayType={editingItem ? employeeLookup.get(editingItem.employee_id)?.contractor_pay_type as 'hourly' | 'flat_fee' | undefined : undefined}
        wageRates={editingItem ? (employeeLookup.get(editingItem.employee_id)?.wage_rates || []) : []}
      />
    </div>
  );
}
