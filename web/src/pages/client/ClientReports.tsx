import { useCallback, useEffect, useMemo, useState } from 'react';
import { Eye } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Select } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { clientPayPeriodsApi, clientReportsApi } from '@/services/api';
import { comparePayPeriodsByPeriod, formatCurrency } from '@/lib/utils';
import type { PayPeriod } from '@/types';

export function ClientReports() {
  const currentYear = new Date().getFullYear();
  const [payPeriods, setPayPeriods] = useState<PayPeriod[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selectedPayPeriodId, setSelectedPayPeriodId] = useState<string>('');
  const [payrollRegister, setPayrollRegister] = useState<Awaited<ReturnType<typeof clientReportsApi.payrollRegister>>['report'] | null>(null);
  const [ytdSummary, setYtdSummary] = useState<Awaited<ReturnType<typeof clientReportsApi.ytdSummary>>['report'] | null>(null);
  const [startDate, setStartDate] = useState(`${currentYear}-01-01`);
  const [endDate, setEndDate] = useState(new Date().toISOString().slice(0, 10));

  const payPeriodOptions = useMemo(
    () => payPeriods.map((payPeriod) => ({ value: String(payPeriod.id), label: payPeriod.period_description || `${payPeriod.start_date} - ${payPeriod.end_date}` })),
    [payPeriods]
  );

  const loadBaseData = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const response = await clientPayPeriodsApi.list();
      const sorted = [...response.pay_periods].sort((a, b) => comparePayPeriodsByPeriod(a, b, 'desc'));
      setPayPeriods(sorted);
      if (sorted[0]) {
        setSelectedPayPeriodId(String(sorted[0].id));
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load reports');
    } finally {
      setLoading(false);
    }
  }, []);

  const loadPayrollRegister = useCallback(async () => {
    try {
      const response = await clientReportsApi.payrollRegister(Number(selectedPayPeriodId));
      setPayrollRegister(response.report);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load payroll register');
    }
  }, [selectedPayPeriodId]);

  const loadYtdSummary = useCallback(async () => {
    try {
      const response = await clientReportsApi.ytdSummary({ start_date: startDate, end_date: endDate });
      setYtdSummary(response.report);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load report data');
    }
  }, [startDate, endDate]);

  useEffect(() => {
    void loadBaseData();
  }, [loadBaseData]);

  useEffect(() => {
    if (!selectedPayPeriodId) return;
    void loadPayrollRegister();
  }, [loadPayrollRegister, selectedPayPeriodId]);

  useEffect(() => {
    void loadYtdSummary();
  }, [loadYtdSummary]);

  const previewBlob = (blob: Blob) => {
    const url = URL.createObjectURL(blob);
    window.open(url, '_blank', 'noopener,noreferrer');
    window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
  };

  return (
    <div>
      <Header title="Reports" description="Read-only payroll reports for finalized payroll periods." />

      <div className="p-6 lg:p-8 space-y-8">
        {error && <div className="rounded-lg border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-700">{error}</div>}

        {loading ? (
          <div className="py-12 text-center text-sm text-gray-500">Loading reports...</div>
        ) : (
          <>
            <Card>
            <CardHeader>
              <CardTitle>Payroll Register</CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              <Select value={selectedPayPeriodId} onChange={(e) => setSelectedPayPeriodId(e.target.value)}>
                <option value="">Select a pay period</option>
                {payPeriodOptions.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </Select>
              <div className="flex flex-wrap gap-3">
                <Button variant="outline" disabled={!selectedPayPeriodId} onClick={() => void loadPayrollRegister()}>
                  <Eye className="mr-2 h-4 w-4" />
                  Refresh
                </Button>
                <Button
                  disabled={!selectedPayPeriodId}
                  onClick={async () => {
                    const file = await clientReportsApi.payrollRegisterPdf(Number(selectedPayPeriodId));
                    previewBlob(file.blob);
                  }}
                >
                  <Eye className="mr-2 h-4 w-4" />
                  Preview PDF
                </Button>
              </div>
              {payrollRegister && (
                <div className="grid gap-4 md:grid-cols-2">
                  <Metric label="Employees" value={String(payrollRegister.summary.employee_count)} />
                  <Metric label="Net Pay" value={formatCurrency(payrollRegister.summary.total_net)} />
                  <Metric label="Gross Pay" value={formatCurrency(payrollRegister.summary.total_gross)} />
                  <Metric label="Other Earnings" value={formatCurrency(payrollRegister.summary.total_custom_earnings ?? 0)} />
                  <Metric label="Payroll Field Additions" value={formatCurrency((payrollRegister.summary.total_payroll_field_taxable_additions ?? 0) + (payrollRegister.summary.total_payroll_field_non_taxable_additions ?? 0))} />
                  <Metric label="Other Deductions" value={formatCurrency(payrollRegister.summary.total_custom_deductions ?? 0)} />
                  <Metric label="Payroll Field Deductions" value={formatCurrency((payrollRegister.summary.total_payroll_field_pre_tax_deductions ?? 0) + (payrollRegister.summary.total_payroll_field_post_tax_deductions ?? 0))} />
                  <Metric label="Employer Contributions" value={formatCurrency(payrollRegister.summary.total_payroll_field_employer_contributions ?? 0)} />
                  <Metric label="Total Deductions" value={formatCurrency(payrollRegister.summary.total_deductions)} />
                </div>
              )}
            </CardContent>
            </Card>

            <Card>
            <CardHeader>
              <CardTitle>Employee Payroll Summary by Period</CardTitle>
            </CardHeader>
            <CardContent className="space-y-4 p-4">
              <div className="flex flex-wrap items-center gap-2">
                <span className="text-sm font-medium text-gray-700">Pay dates</span>
                <input aria-label="Client report start date" type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} className="h-9 rounded-md border border-gray-300 px-3 text-sm" />
                <span className="text-sm text-gray-500">to</span>
                <input aria-label="Client report end date" type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} className="h-9 rounded-md border border-gray-300 px-3 text-sm" />
                <Button variant="outline" onClick={() => void loadYtdSummary()}>Refresh</Button>
              </div>
              <Table stickyHeader containerClassName="max-h-[26rem]">
                <TableHeader>
                  <TableRow>
                    <TableHead>Employee</TableHead>
                    <TableHead>Gross Pay</TableHead>
                    <TableHead>Other Earn.</TableHead>
                    <TableHead>Field Add.</TableHead>
                    <TableHead>Other Ded.</TableHead>
                    <TableHead>Field Ded.</TableHead>
                    <TableHead>Employer Contrib.</TableHead>
                    <TableHead>Total Ded.</TableHead>
                    <TableHead>FIT</TableHead>
                    <TableHead>Net Pay</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody striped>
                  {(ytdSummary?.employees || []).map((employee) => (
                    <TableRow key={employee.employee_id}>
                      <TableCell className="font-medium text-gray-900">{employee.name}</TableCell>
                      <TableCell>{formatCurrency(employee.gross_pay)}</TableCell>
                      <TableCell>{formatCurrency(employee.custom_earnings_total ?? 0)}</TableCell>
                      <TableCell>{formatCurrency((employee.payroll_field_taxable_additions_total ?? 0) + (employee.payroll_field_non_taxable_additions_total ?? 0))}</TableCell>
                      <TableCell>{formatCurrency(employee.custom_deductions_total ?? 0)}</TableCell>
                      <TableCell>{formatCurrency((employee.payroll_field_pre_tax_deductions_total ?? 0) + (employee.payroll_field_post_tax_deductions_total ?? 0))}</TableCell>
                      <TableCell>{formatCurrency(employee.payroll_field_employer_contributions_total ?? 0)}</TableCell>
                      <TableCell>{formatCurrency(employee.total_deductions ?? 0)}</TableCell>
                      <TableCell>{formatCurrency(employee.withholding_tax)}</TableCell>
                      <TableCell>{formatCurrency(employee.net_pay)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
              {(ytdSummary?.payroll_fields?.totals.length ?? 0) > 0 && (
                <div className="space-y-4 rounded-xl border border-gray-200 p-4">
                  <div>
                    <p className="font-semibold text-gray-900">Payroll field reconciliation</p>
                    <p className="text-sm text-gray-500">Historical field values for payrolls paid in this period, shown from each finalized payroll snapshot.</p>
                  </div>
                  <div className="overflow-hidden rounded-lg border border-gray-200">
                    <div className="divide-y">{ytdSummary!.payroll_fields.totals.map((field, index) => <div key={`${field.label}-${index}`} className="flex items-center justify-between gap-4 px-4 py-3 text-sm"><span><span className="font-medium text-gray-900">{field.label}</span><span className="ml-2 text-gray-500">{field.tax_treatment.replaceAll('_', ' ')} · {field.employer_paid ? 'employer' : 'employee'} · {field.employee_count ?? 0} employee{field.employee_count === 1 ? '' : 's'}</span></span><span className="font-semibold tabular-nums">{formatCurrency(field.amount)}</span></div>)}</div>
                  </div>
                  {(ytdSummary?.payroll_fields?.entries?.length ?? 0) > 0 && (
                    <Table stickyHeader containerClassName="max-h-[22rem] rounded-lg border border-gray-200">
                      <TableHeader>
                        <TableRow>
                          <TableHead>Pay date</TableHead>
                          <TableHead>Employee</TableHead>
                          <TableHead>Payroll field</TableHead>
                          <TableHead>Treatment</TableHead>
                          <TableHead>Source</TableHead>
                          <TableHead className="text-right">Amount</TableHead>
                        </TableRow>
                      </TableHeader>
                      <TableBody striped>
                        {ytdSummary!.payroll_fields.entries!.map((entry, index) => (
                          <TableRow key={`${entry.payroll_item_id}-${entry.label}-${index}`}>
                            <TableCell>{entry.pay_date || '—'}</TableCell>
                            <TableCell className="font-medium text-gray-900">{entry.employee_name || '—'}</TableCell>
                            <TableCell>{entry.label}</TableCell>
                            <TableCell className="capitalize">{entry.tax_treatment.replaceAll('_', ' ')}</TableCell>
                            <TableCell className="capitalize">{entry.source?.replaceAll('_', ' ') || '—'}</TableCell>
                            <TableCell className="text-right font-medium tabular-nums">{formatCurrency(entry.amount)}</TableCell>
                          </TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  )}
                </div>
              )}
            </CardContent>
            </Card>
          </>
        )}
      </div>
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border border-gray-200 bg-gray-50 p-4">
      <p className="text-sm font-medium text-gray-500">{label}</p>
      <p className="mt-2 text-xl font-semibold text-gray-900">{value}</p>
    </div>
  );
}
