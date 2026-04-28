import { useCallback, useEffect, useMemo, useState } from 'react';
import { Eye } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Select } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { clientPayPeriodsApi, clientReportsApi } from '@/services/api';
import { formatCurrency } from '@/lib/utils';
import type { PayPeriod } from '@/types';

export function ClientReports() {
  const [payPeriods, setPayPeriods] = useState<PayPeriod[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selectedPayPeriodId, setSelectedPayPeriodId] = useState<string>('');
  const [payrollRegister, setPayrollRegister] = useState<Awaited<ReturnType<typeof clientReportsApi.payrollRegister>>['report'] | null>(null);
  const [ytdSummary, setYtdSummary] = useState<Awaited<ReturnType<typeof clientReportsApi.ytdSummary>>['report'] | null>(null);

  const payPeriodOptions = useMemo(
    () => payPeriods.map((payPeriod) => ({ value: String(payPeriod.id), label: payPeriod.period_description || `${payPeriod.start_date} - ${payPeriod.end_date}` })),
    [payPeriods]
  );

  const loadBaseData = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const response = await clientPayPeriodsApi.list();
      setPayPeriods(response.pay_periods);
      if (response.pay_periods[0]) {
        setSelectedPayPeriodId(String(response.pay_periods[0].id));
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
      const response = await clientReportsApi.ytdSummary();
      setYtdSummary(response.report);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load report data');
    }
  }, []);

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
                  <Metric label="Total Deductions" value={formatCurrency(payrollRegister.summary.total_deductions)} />
                </div>
              )}
            </CardContent>
            </Card>

            <Card>
            <CardHeader>
              <CardTitle>Year-to-Date Employee Summary</CardTitle>
            </CardHeader>
            <CardContent className="p-0">
              <Table stickyHeader containerClassName="max-h-[26rem]">
                <TableHeader>
                  <TableRow>
                    <TableHead>Employee</TableHead>
                    <TableHead>Gross Pay</TableHead>
                    <TableHead>FIT</TableHead>
                    <TableHead>Net Pay</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody striped>
                  {(ytdSummary?.employees || []).map((employee) => (
                    <TableRow key={employee.employee_id}>
                      <TableCell className="font-medium text-gray-900">{employee.name}</TableCell>
                      <TableCell>{formatCurrency(employee.gross_pay)}</TableCell>
                      <TableCell>{formatCurrency(employee.withholding_tax)}</TableCell>
                      <TableCell>{formatCurrency(employee.net_pay)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
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
