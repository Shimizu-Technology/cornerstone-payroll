import { useFeedbackState } from '@/lib/use-feedback-state';
import { ActionFeedback } from '@/components/ui/action-feedback';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Eye } from 'lucide-react';
import { Header } from '@/components/layout/Header';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Select } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { MobileField, MobileRecordCard } from '@/components/ui/mobile-record';
import { ReportDownloadMenu, type ReportDownloadFormat } from '@/components/reports/ReportDownloadMenu';
import { PayrollSourceNotice } from '@/components/reports/PayrollSourceNotice';
import { clientPayPeriodsApi, clientReportsApi, type PayrollHistoryRecord } from '@/services/api';
import { comparePayPeriodsByPeriod, formatCurrency } from '@/lib/utils';

function finiteAmount(value: number | string | null | undefined): number {
  const parsed = Number(value);
  return value == null || !Number.isFinite(parsed) ? 0 : parsed;
}

export function ClientReports() {
  const currentYear = new Date().getFullYear();
  const [payPeriods, setPayPeriods] = useState<PayrollHistoryRecord[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError, errorFeedbackAttempt] = useFeedbackState<string | null>(null);
  const [selectedPayPeriodId, setSelectedPayPeriodId] = useState<string>('');
  const [payrollRegister, setPayrollRegister] = useState<Awaited<ReturnType<typeof clientReportsApi.payrollRegister>>['report'] | null>(null);
  const [ytdSummary, setYtdSummary] = useState<Awaited<ReturnType<typeof clientReportsApi.ytdSummary>>['report'] | null>(null);
  const [annualSummary, setAnnualSummary] = useState<Awaited<ReturnType<typeof clientReportsApi.annualPayrollSummary>>['report'] | null>(null);
  const [startDate, setStartDate] = useState(`${currentYear}-01-01`);
  const [endDate, setEndDate] = useState(new Date().toISOString().slice(0, 10));
  const [includeZeroPay, setIncludeZeroPay] = useState(true);
  const ytdRequestSequence = useRef(0);
  const [exporting, setExporting] = useState<string | null>(null);

  const payPeriodOptions = useMemo(
    () => payPeriods.map((payPeriod) => ({ value: String(payPeriod.id), label: `${payPeriod.start_date} - ${payPeriod.end_date}` })),
    [payPeriods]
  );

  const loadBaseData = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const response = await clientPayPeriodsApi.list();
      const sorted = response.pay_periods
        .filter((payPeriod) => payPeriod.record_type === 'native')
        .sort((a, b) => comparePayPeriodsByPeriod(a, b, 'desc'));
      setPayPeriods(sorted);
      if (sorted[0]) {
        setSelectedPayPeriodId(String(sorted[0].id));
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load reports');
    } finally {
      setLoading(false);
    }
  }, [setError]);

  const loadPayrollRegister = useCallback(async () => {
    try {
      const response = await clientReportsApi.payrollRegister(Number(selectedPayPeriodId));
      setPayrollRegister(response.report);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load payroll register');
    }
  }, [selectedPayPeriodId, setError]);

  const loadYtdSummary = useCallback(async () => {
    const requestSequence = ++ytdRequestSequence.current;
    setYtdSummary(null);
    setError(null);
    try {
      const response = await clientReportsApi.ytdSummary({ start_date: startDate, end_date: endDate, include_zero_pay: includeZeroPay });
      if (requestSequence === ytdRequestSequence.current) setYtdSummary(response.report);
    } catch (err) {
      if (requestSequence === ytdRequestSequence.current) setError(err instanceof Error ? err.message : 'Failed to load report data');
    }
  }, [setError, startDate, endDate, includeZeroPay]);

  const loadAnnualSummary = useCallback(async () => {
    try {
      const response = await clientReportsApi.annualPayrollSummary();
      setAnnualSummary(response.report);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load annual payroll totals');
    }
  }, [setError]);

  useEffect(() => {
    void loadBaseData();
  }, [loadBaseData]);

  useEffect(() => {
    if (!selectedPayPeriodId) return;
    void loadPayrollRegister();
  }, [loadPayrollRegister, selectedPayPeriodId]);

  useEffect(() => {
    void loadYtdSummary();
    return () => { ytdRequestSequence.current += 1; };
  }, [loadYtdSummary]);

  useEffect(() => {
    void loadAnnualSummary();
  }, [loadAnnualSummary]);

  const downloadBlob = (blob: Blob, filename: string) => {
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = filename;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 100);
  };

  const exportReport = async (
    key: string,
    fallbackFilename: string,
    loader: () => Promise<{ blob: Blob; filename?: string }>
  ) => {
    try {
      setExporting(key);
      setError(null);
      const file = await loader();
      downloadBlob(file.blob, file.filename || fallbackFilename);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to export report');
    } finally {
      setExporting(null);
    }
  };

  const payrollRegisterFormats: ReportDownloadFormat[] = selectedPayPeriodId ? [
    {
      key: 'register-pdf',
      label: 'PDF',
      description: 'Print-ready payroll register',
      kind: 'pdf',
      loading: exporting === 'register-pdf',
      onSelect: () => exportReport(
        'register-pdf',
        `payroll_register_${selectedPayPeriodId}.pdf`,
        () => clientReportsApi.payrollRegisterPdf(Number(selectedPayPeriodId))
      ),
    },
    {
      key: 'register-xlsx',
      label: 'Excel workbook',
      description: 'Formatted workbook for analysis',
      kind: 'spreadsheet',
      loading: exporting === 'register-xlsx',
      onSelect: () => exportReport(
        'register-xlsx',
        `payroll_register_${selectedPayPeriodId}.xlsx`,
        () => clientReportsApi.payrollRegisterXlsx(Number(selectedPayPeriodId))
      ),
    },
    {
      key: 'register-csv',
      label: 'CSV data',
      description: 'Portable payroll-register rows',
      kind: 'data',
      loading: exporting === 'register-csv',
      onSelect: () => exportReport(
        'register-csv',
        `payroll_register_${selectedPayPeriodId}.csv`,
        () => clientReportsApi.payrollRegisterCsv(Number(selectedPayPeriodId))
      ),
    },
  ] : [];

  const summaryPeriod = { start_date: startDate, end_date: endDate, include_zero_pay: includeZeroPay };
  const summaryFormats: ReportDownloadFormat[] = [
    {
      key: 'summary-pdf',
      label: 'PDF',
      description: 'Print-ready payroll summary',
      kind: 'pdf',
      loading: exporting === 'summary-pdf',
      onSelect: () => exportReport(
        'summary-pdf',
        `payroll_summary_${startDate}_${endDate}.pdf`,
        () => clientReportsApi.ytdSummaryPdf(summaryPeriod)
      ),
    },
    {
      key: 'summary-xlsx',
      label: 'Excel workbook',
      description: 'Formatted period workbook',
      kind: 'spreadsheet',
      loading: exporting === 'summary-xlsx',
      onSelect: () => exportReport(
        'summary-xlsx',
        `payroll_summary_${startDate}_${endDate}.xlsx`,
        () => clientReportsApi.ytdSummaryXlsx(summaryPeriod)
      ),
    },
    {
      key: 'summary-csv',
      label: 'CSV data',
      description: 'Portable employee summary rows',
      kind: 'data',
      loading: exporting === 'summary-csv',
      onSelect: () => exportReport(
        'summary-csv',
        `payroll_summary_${startDate}_${endDate}.csv`,
        () => clientReportsApi.ytdSummaryCsv(summaryPeriod)
      ),
    },
  ];

  const annualSummaryFormats: ReportDownloadFormat[] = [
    {
      key: 'annual-pdf',
      label: 'PDF',
      description: 'Shareable year-by-year summary',
      kind: 'pdf',
      loading: exporting === 'annual-pdf',
      onSelect: () => exportReport('annual-pdf', 'annual_payroll_summary.pdf', clientReportsApi.annualPayrollSummaryPdf),
    },
    {
      key: 'annual-xlsx',
      label: 'Excel workbook',
      description: 'Annual totals and source detail',
      kind: 'spreadsheet',
      loading: exporting === 'annual-xlsx',
      onSelect: () => exportReport('annual-xlsx', 'annual_payroll_summary.xlsx', clientReportsApi.annualPayrollSummaryXlsx),
    },
    {
      key: 'annual-csv',
      label: 'CSV data',
      description: 'One row per payroll year',
      kind: 'data',
      loading: exporting === 'annual-csv',
      onSelect: () => exportReport('annual-csv', 'annual_payroll_summary.csv', clientReportsApi.annualPayrollSummaryCsv),
    },
  ];

  const annualSourceLabel = (row: NonNullable<typeof annualSummary>['years'][number]) => [
    row.cornerstone_payroll_count > 0
      ? `${row.cornerstone_payroll_count} Cornerstone payroll${row.cornerstone_payroll_count === 1 ? '' : 's'}`
      : null,
    row.quickbooks_payroll_count > 0
      ? `${row.quickbooks_payroll_count} QuickBooks payroll${row.quickbooks_payroll_count === 1 ? '' : 's'}`
      : null,
    row.opening_summary_count > 0
      ? `${row.opening_summary_count} QuickBooks opening summar${row.opening_summary_count === 1 ? 'y' : 'ies'}`
      : null,
    row.adjustment_count > 0
      ? `${row.adjustment_count} ledger adjustment${row.adjustment_count === 1 ? '' : 's'}`
      : null,
  ].filter(Boolean).join(' · ');

  return (
    <div>
      <Header title="Reports" description="Read-only payroll reports for finalized payroll periods." />

      <div className="space-y-8 p-4 sm:p-6 lg:p-8">
        {error && <ActionFeedback retryKey={errorFeedbackAttempt} tone="error" message={error} />}

        {loading ? (
          <div className="py-12 text-center text-sm text-gray-500">Loading reports...</div>
        ) : (
          <>
            <Card>
            <CardHeader>
              <CardTitle>Payroll Register</CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              <Select className="w-full" value={selectedPayPeriodId} onChange={(e) => setSelectedPayPeriodId(e.target.value)}>
                <option value="">Select a pay period</option>
                {payPeriodOptions.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </Select>
              <p className="text-sm leading-6 text-gray-500">The payroll register is available for Cornerstone payrolls. Open an imported payroll from Pay Periods to review its locked QuickBooks records.</p>
              <div className="flex flex-wrap gap-3">
                <Button variant="outline" disabled={!selectedPayPeriodId} onClick={() => void loadPayrollRegister()}>
                  <Eye className="mr-2 h-4 w-4" />
                  View Report
                </Button>
                <ReportDownloadMenu
                  formats={payrollRegisterFormats}
                  disabled={!selectedPayPeriodId || exporting !== null}
                  ariaLabel="Export payroll register"
                />
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
              <CardHeader className="gap-4 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <CardTitle>Annual Payroll Totals</CardTitle>
                  <p className="mt-2 text-sm leading-6 text-gray-500">Year-by-year totals across locked QuickBooks imports and committed Cornerstone payroll.</p>
                </div>
                <ReportDownloadMenu formats={annualSummaryFormats} disabled={!annualSummary || exporting !== null} ariaLabel="Export annual payroll totals" />
              </CardHeader>
              <CardContent className="space-y-4 p-4">
                {annualSummary && (
                  <>
                    <div className="rounded-xl border border-blue-200 bg-blue-50 px-4 py-4 text-sm leading-6 text-blue-900">
                      <p className="font-semibold">Imported payroll values remain locked.</p>
                      <p className="mt-2">{annualSummary.source_statement}</p>
                    </div>
                    <div className="grid gap-4 md:grid-cols-4">
                      <Metric label="All-Year Gross Pay" value={formatCurrency(annualSummary.totals.gross_pay)} />
                      <Metric label="All-Year Net Pay" value={formatCurrency(annualSummary.totals.net_pay)} />
                      <Metric label="Employer Costs" value={formatCurrency(finiteAmount(annualSummary.totals.employer_taxes) + finiteAmount(annualSummary.totals.employer_contributions))} />
                      <Metric label="Total Payroll Cost" value={formatCurrency(annualSummary.totals.total_payroll_cost)} />
                    </div>
                    <div className="space-y-3 lg:hidden">
                      {annualSummary.years.map((row) => (
                        <MobileRecordCard key={row.year}>
                          <p className="text-lg font-semibold text-neutral-950">{row.year}</p>
                          <p className="mt-1 text-xs leading-5 text-neutral-600">{annualSourceLabel(row)}</p>
                          {row.excluded_unlinked_paycheck_count > 0 && <p className="mt-2 text-xs text-amber-800">{row.excluded_unlinked_paycheck_count} unlinked imported paychecks excluded ({formatCurrency(row.excluded_unlinked_gross_pay)} gross / {formatCurrency(row.excluded_unlinked_net_pay)} net)</p>}
                          <div className="mt-4 grid grid-cols-2 gap-3">
                            <MobileField label="Gross pay" value={formatCurrency(row.gross_pay)} />
                            <MobileField label="Employee taxes" value={formatCurrency(row.employee_taxes)} />
                            <MobileField label="Deductions" value={formatCurrency(finiteAmount(row.pretax_deductions) + finiteAmount(row.after_tax_deductions))} />
                            <MobileField label="Net pay" value={formatCurrency(row.net_pay)} />
                            <MobileField label="Total cost" value={formatCurrency(row.total_payroll_cost)} />
                          </div>
                        </MobileRecordCard>
                      ))}
                      {annualSummary.years.length === 0 && <p className="py-8 text-center text-sm text-neutral-500">No committed or locked payroll history is available yet.</p>}
                    </div>
                    <div className="hidden lg:block">
                    <Table>
                      <TableHeader>
                        <TableRow>
                          <TableHead>Year &amp; source</TableHead>
                          <TableHead className="text-right">Gross pay</TableHead>
                          <TableHead className="text-right">Employee taxes</TableHead>
                          <TableHead className="text-right">Deductions</TableHead>
                          <TableHead className="text-right">Net pay</TableHead>
                          <TableHead className="text-right">Total cost</TableHead>
                        </TableRow>
                      </TableHeader>
                      <TableBody striped>
                        {annualSummary.years.map((row) => (
                          <TableRow key={row.year}>
                            <TableCell>
                              <p className="font-semibold text-gray-900">{row.year}</p>
                              <p className="mt-2 text-xs text-gray-500">{annualSourceLabel(row)}</p>
                              {row.excluded_unlinked_paycheck_count > 0 && (
                                <p className="mt-2 text-xs font-semibold text-amber-700">
                                  {row.excluded_unlinked_paycheck_count} unlinked imported paycheck{row.excluded_unlinked_paycheck_count === 1 ? '' : 's'} excluded ({formatCurrency(row.excluded_unlinked_gross_pay)} gross / {formatCurrency(row.excluded_unlinked_net_pay)} net)
                                </p>
                              )}
                            </TableCell>
                            <TableCell className="text-right tabular-nums">{formatCurrency(row.gross_pay)}</TableCell>
                            <TableCell className="text-right tabular-nums">{formatCurrency(row.employee_taxes)}</TableCell>
                            <TableCell className="text-right tabular-nums">{formatCurrency(finiteAmount(row.pretax_deductions) + finiteAmount(row.after_tax_deductions))}</TableCell>
                            <TableCell className="text-right font-semibold tabular-nums">{formatCurrency(row.net_pay)}</TableCell>
                            <TableCell className="text-right font-semibold tabular-nums">{formatCurrency(row.total_payroll_cost)}</TableCell>
                          </TableRow>
                        ))}
                        {annualSummary.years.length === 0 && (
                          <TableRow>
                            <TableCell colSpan={6} className="py-10 text-center text-gray-500">
                              No committed or locked payroll history is available yet.
                            </TableCell>
                          </TableRow>
                        )}
                      </TableBody>
                    </Table>
                    </div>
                  </>
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
                <input aria-label="Client report start date" type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} className="h-11 min-w-0 w-full rounded-md border border-gray-300 px-3 text-sm sm:w-auto" />
                <span className="text-sm text-gray-500">to</span>
                <input aria-label="Client report end date" type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} className="h-11 min-w-0 w-full rounded-md border border-gray-300 px-3 text-sm sm:w-auto" />
                <label className="flex min-h-12 items-center gap-2 text-sm text-gray-700">
                  <input type="checkbox" checked={includeZeroPay} onChange={(e) => setIncludeZeroPay(e.target.checked)} className="h-4 w-4 accent-primary" />
                  Include active employees with $0 pay
                </label>
                <Button variant="outline" onClick={() => void loadYtdSummary()}>View Report</Button>
                <ReportDownloadMenu
                  formats={summaryFormats}
                  disabled={exporting !== null}
                  ariaLabel="Export payroll summary"
                />
              </div>
              <PayrollSourceNotice summary={ytdSummary?.source_summary} mentionFieldScope />
              {ytdSummary?.historical_deductions?.source_bucket_totals.length ? (
                <p role="note" className="text-sm text-amber-900">{ytdSummary.historical_deductions.classification_note}</p>
              ) : null}
              {ytdSummary?.company_totals && (
                <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                  <Metric label="OT hours" value={(ytdSummary.company_totals.total_overtime_hours ?? 0).toFixed(2)} />
                  <Metric label="Health Insurance (payroll fields + historical)" value={formatCurrency(ytdSummary.company_totals.health_insurance_deductions ?? 0)} />
                  <Metric label="Historical Loans (type unclassified)" value={formatCurrency(ytdSummary.company_totals.historical_loan_deductions_unclassified ?? 0)} />
                  <Metric label="401(k) After Tax label in source pre-tax bucket" value={formatCurrency(ytdSummary.company_totals.source_labeled_after_tax_401k_in_pretax_bucket ?? 0)} />
                </div>
              )}
              {ytdSummary?.employee_visibility && !ytdSummary.employee_visibility.include_zero_pay && (
                <p className="text-xs text-gray-600">
                  {ytdSummary.employee_visibility.active_zero_pay_count} active $0-pay employee{ytdSummary.employee_visibility.active_zero_pay_count !== 1 ? 's' : ''} hidden from detail. Company totals still include all payroll activity.
                </p>
              )}
              <div className="space-y-3 lg:hidden" aria-label="Employee payroll summary">
                {(ytdSummary?.employees || []).map((employee) => (
                  <MobileRecordCard key={employee.employee_id}>
                    <div className="flex flex-wrap items-start justify-between gap-2">
                      <p className="min-w-0 font-semibold text-neutral-950">{employee.name}</p>
                      <div><p className="text-xs font-semibold uppercase tracking-wide text-neutral-500">Net pay</p><p className="font-semibold tabular-nums text-neutral-950">{formatCurrency(employee.net_pay)}</p></div>
                    </div>
                    <div className="mt-4 grid grid-cols-2 gap-3">
                      <MobileField label="OT hours" value={finiteAmount(employee.total_overtime_hours).toFixed(2)} />
                      <MobileField label="Gross pay" value={formatCurrency(employee.gross_pay)} />
                      <MobileField label="Other earnings" value={formatCurrency(employee.custom_earnings_total ?? 0)} />
                      <MobileField label="Field additions" value={formatCurrency(finiteAmount(employee.payroll_field_taxable_additions_total) + finiteAmount(employee.payroll_field_non_taxable_additions_total))} />
                      <MobileField label="Other deductions" value={formatCurrency(employee.custom_deductions_total ?? 0)} />
                      <MobileField label="Field deductions" value={formatCurrency(finiteAmount(employee.payroll_field_pre_tax_deductions_total) + finiteAmount(employee.payroll_field_post_tax_deductions_total))} />
                      <MobileField label="Health insurance" value={formatCurrency(employee.health_insurance_deductions ?? 0)} />
                      <MobileField label="Historical loans" value={formatCurrency(employee.historical_loan_deductions_unclassified ?? 0)} />
                      <MobileField label="Employer contributions" value={formatCurrency(employee.payroll_field_employer_contributions_total ?? 0)} />
                      <MobileField label="Total deductions" value={formatCurrency(employee.total_deductions ?? 0)} />
                      <MobileField label="FIT" value={formatCurrency(employee.withholding_tax)} />
                    </div>
                  </MobileRecordCard>
                ))}
                {(!ytdSummary?.employees || ytdSummary.employees.length === 0) && <p className="py-8 text-center text-sm text-neutral-500">No employee payroll details for these dates.</p>}
              </div>
              <div className="hidden lg:block">
              <Table stickyHeader containerClassName="max-h-[26rem]">
                <TableHeader>
                  <TableRow>
                    <TableHead>Employee</TableHead>
                    <TableHead>OT Hours</TableHead>
                    <TableHead>Gross Pay</TableHead>
                    <TableHead>Other Earn.</TableHead>
                    <TableHead>Field Add.</TableHead>
                    <TableHead>Other Ded.</TableHead>
                    <TableHead>Field Ded.</TableHead>
                    <TableHead>Health Insurance</TableHead>
                    <TableHead>Historical Loans</TableHead>
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
                      <TableCell>{(employee.total_overtime_hours ?? 0).toFixed(2)}</TableCell>
                      <TableCell>{formatCurrency(employee.gross_pay)}</TableCell>
                      <TableCell>{formatCurrency(employee.custom_earnings_total ?? 0)}</TableCell>
                      <TableCell>{formatCurrency(finiteAmount(employee.payroll_field_taxable_additions_total) + finiteAmount(employee.payroll_field_non_taxable_additions_total))}</TableCell>
                      <TableCell>{formatCurrency(employee.custom_deductions_total ?? 0)}</TableCell>
                      <TableCell>{formatCurrency(finiteAmount(employee.payroll_field_pre_tax_deductions_total) + finiteAmount(employee.payroll_field_post_tax_deductions_total))}</TableCell>
                      <TableCell>{formatCurrency(employee.health_insurance_deductions ?? 0)}</TableCell>
                      <TableCell>{formatCurrency(employee.historical_loan_deductions_unclassified ?? 0)}</TableCell>
                      <TableCell>{formatCurrency(employee.payroll_field_employer_contributions_total ?? 0)}</TableCell>
                      <TableCell>{formatCurrency(employee.total_deductions ?? 0)}</TableCell>
                      <TableCell>{formatCurrency(employee.withholding_tax)}</TableCell>
                      <TableCell>{formatCurrency(employee.net_pay)}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
              </div>
              {(ytdSummary?.payroll_fields?.totals.length ?? 0) > 0 && (
                <div className="space-y-4 rounded-xl border border-gray-200 p-4">
                  <div>
                    <p className="font-semibold text-gray-900">Payroll field reconciliation</p>
                    <p className="text-sm text-gray-500">Field values from finalized Cornerstone payroll snapshots in this period. Imported QuickBooks totals are included above but do not have Cornerstone payroll-field detail.</p>
                  </div>
                    <div className="overflow-hidden rounded-lg border border-gray-200">
                      <div className="divide-y">{ytdSummary!.payroll_fields.totals.map((field, index) => <div key={`${field.label}-${index}`} className="flex flex-wrap items-start justify-between gap-2 px-4 py-3 text-sm"><span className="min-w-0"><span className="block font-medium text-gray-900">{field.label}</span><span className="mt-1 block text-gray-500">{field.tax_treatment.replaceAll('_', ' ')} · {field.employer_paid ? 'employer' : 'employee'} · {field.employee_count ?? 0} employee{field.employee_count === 1 ? '' : 's'}</span></span><span className="font-semibold tabular-nums">{formatCurrency(field.amount)}</span></div>)}</div>
                  </div>
                  {(ytdSummary?.payroll_fields?.entries?.length ?? 0) > 0 && (
                    <>
                    <div className="space-y-3 lg:hidden" aria-label="Payroll field entries">
                      {ytdSummary!.payroll_fields.entries!.map((entry, index) => (
                        <MobileRecordCard key={`${entry.payroll_item_id}-${entry.label}-${index}`}>
                          <div className="flex flex-wrap items-start justify-between gap-2">
                            <p className="min-w-0 font-semibold text-neutral-950">{entry.employee_name || '—'}</p>
                            <p className="font-semibold tabular-nums text-neutral-950">{formatCurrency(entry.amount)}</p>
                          </div>
                          <div className="mt-3 grid grid-cols-2 gap-3">
                            <MobileField label="Pay date" value={entry.pay_date || '—'} />
                            <MobileField label="Payroll field" value={entry.label} />
                            <MobileField label="Treatment" value={entry.tax_treatment.replaceAll('_', ' ')} />
                            <MobileField label="Source" value={entry.source?.replaceAll('_', ' ') || '—'} />
                          </div>
                        </MobileRecordCard>
                      ))}
                    </div>
                    <div className="hidden lg:block">
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
                    </div>
                    </>
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
